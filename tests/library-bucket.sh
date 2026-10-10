#!/usr/bin/env bash
# `cg library` must not need .env to tell it where the archive is.
#
# The bucket name is a function of the account, the host and the region - the
# same function that creates it - so demanding that .env carry it made every
# library read fail until an init had written it. Clearing it to move region did
# exactly that: `cg library` exited 1 with "no bucket yet - run cg init", and
# the desktop app reported a failed read for a bucket whose name was never in
# question.
#
# The split this file pins: READS derive the name, WRITES AND DELETES do not.
# Deriving a name and then deleting whatever is inside it is a worse failure
# than refusing, so library clean, library forget and destroy --all still
# require an explicitly configured bucket.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# The name the real formula produces for this account/host/region, so the test
# asserts the derivation rather than a string typed twice.
WANT=$(bash -c 'source lib/s3-region.sh; cg_bucket_name 123456789012 gamevps ap-south-1')

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"sts get-caller-identity"*)
    [[ -n ${NO_ACCOUNT:-} ]] && { echo "Unable to locate credentials" >&2; exit 255; }
    echo 123456789012 ;;
  # The index: present only when INDEX=1, so "empty archive" and "unreadable"
  # stay distinguishable - the one lie this tool must never tell.
  *"s3 cp s3://"*index.json*-*)
    [[ -n ${INDEX:-} ]] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 1; }
    echo '{"apps":[{"appid":"2344520","name":"Diablo IV","bytes":1024,"prefix":"steam/steamapps/common/x"}]}' ;;
  *"s3 ls s3://"*steam/steamapps/*--summarize*)
    # A brand-new bucket has NOTHING under steamapps/.
    printf 'Total Objects: %s\n   Total Size: %s\n' "${APPS_OBJECTS:-0}" "${APPS_BYTES:-0}" ;;
  *"s3 ls s3://"*steam/index.json*)
    [[ -n ${INDEX:-} ]] || exit 1; echo "index.json" ;;
  *"s3 ls s3://"*) exit 0 ;;
  *iam*) exit 1 ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"; chmod +x "$T/bin/tailscale"

# .env with NO bucket - exactly the state a region move leaves behind.
printf 'GAME_REGION=ap-south-1\nGAME_TS_HOST=gamevps\nGAME_S3_BUCKET=\n' > "$T/home/.env"

cg_() { env PATH="$T/bin:$PATH" HOME="$T/home" CG_ENV_FILE="$T/home/.env" \
          CG_COLOR=never "$@" ./cg "${CMD[@]}" 2>&1; }

echo "1. a read works with no bucket in .env"
CMD=(library --bucket)
out=$(cg_)
check "the derived name is printed" "$(tr -d '[:space:]' <<<"$out")" "$WANT"
lacks "and it does not say to run init" "$out" "not set - run cg init"

CMD=(library list)
out=$(cg_); rc=$?
check "listing an empty archive succeeds" "$rc" "0"
contains "  and says it is empty"         "$out" "the archive is empty"
# This is the lie the whole library path exists to avoid, so it is checked here
# too: empty must never be reported for an archive nobody could read.
lacks "  not that it could not look"      "$out" "was not readable"

echo "2. an account-only bucket is EMPTY, not an old-format archive"
# The new bucket carries one object - a 21.8 KB Steam login copied across to
# save a re-login - and counting everything under steam/ made that read as an
# archive from a box predating per-game archiving.
CMD=(library list)
out=$(APPS_OBJECTS=0 cg_)
lacks "no talk of predating anything" "$out" "predates per-game archiving"
contains "  it is simply empty"       "$out" "the archive is empty"
# With real games and no index, the old-format message IS right.
out=$(APPS_OBJECTS=12 APPS_BYTES=1048576 cg_)
contains "but a game-bearing bucket with no index says so" "$out" "predates per-game archiving"

echo "3. the index is used when it is there"
CMD=(library list)
out=$(INDEX=1 cg_)
contains "the game is listed" "$out" "Diablo IV"

echo "4. the json the app reads carries the bucket, not null"
CMD=(library list --json)
out=$(cg_); rc=$?
check "it succeeds"            "$rc" "0"
check "the bucket is named"    "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["bucket"])' <<<"$out")" "$WANT"
# On success the key is ABSENT rather than null, and that is fine: a reader
# tests for it, and absent is falsy. What matters is that it is never present
# alongside a games list - "no games" and "I could not look" must stay distinct.
check "  carries no error key"  "$(python3 -c 'import json,sys;print("error" in json.load(sys.stdin))' <<<"$out")" "False"
check "  and an empty list, not null" "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["games"])' <<<"$out")" "[]"

echo "5. deletes still refuse without an explicit bucket"
# Deriving a name and then deleting what is in it is worse than refusing.
for c in "library clean" "library forget 2344520"; do
  CMD=($c)
  out=$(cg_); rc=$?
  contains "cg $c refuses" "$out" "no bucket configured"
  check    "  and exits non-zero" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
done
src=$(cat cg)
contains "the refusal is in the clean path"  "$src" '[[ -n ${GAME_S3_BUCKET:-} ]] || die "no bucket configured"'
check    "  and in exactly the two delete paths" \
         "$(grep -c 'die "no bucket configured"' cg)" "2"

echo "6. an unreadable account is a failure, not a guessed bucket"
CMD=(library list)
out=$(NO_ACCOUNT=1 cg_); rc=$?
check    "it fails"                    "$([[ $rc -ne 0 ]] && echo yes)" "yes"
contains "  and says AWS did not answer" "$out" "AWS did not answer"
lacks    "  and never claims empty"    "$out" "the archive is empty"

echo "7. the resolver asks AWS once, not once per use"
# cg_bucket is called from several places in one run and the account lookup is a
# network round trip on the path of an opening screen.
contains "the answer is remembered" "$src" '_CG_BUCKET='
contains "  and reused"             "$src" 'if [[ -n $_CG_BUCKET ]]; then printf'
contains "  with .env still winning" "$src" 'if [[ -n ${GAME_S3_BUCKET:-} ]]; then printf'

echo ""
echo "library-bucket: $pass passed, $fail failed"
(( fail == 0 ))
