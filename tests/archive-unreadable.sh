#!/usr/bin/env bash
# An archive that cannot be read is not an empty archive.
#
# `library_index` ended in `|| echo '{"apps":[]}'`, so expired credentials, a
# denied bucket or a dead network all came out as an EMPTY ARCHIVE - and
# `cg library list` said "the archive is empty" about 160 GB of games sitting
# safely in S3. That is the most alarming lie this tool can tell.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home" "$T/repo"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
printf 'GAME_S3_BUCKET=cg-library-test\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\n' > "$T/repo/.env"

# FAIL= the error the fake aws returns for the index read: none, creds, denied,
# gone, network, or missing (a readable bucket with no index in it).
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"s3 cp"*index.json*)
    case "${FAIL:-none}" in
      creds)   echo "fatal error: An error occurred (InvalidAccessKeyId) when calling the HeadObject operation: The AWS Access Key Id you provided does not exist in our records." >&2; exit 1 ;;
      denied)  echo "download failed: An error occurred (AccessDenied) when calling the HeadObject operation: Access Denied" >&2; exit 1 ;;
      403)     echo "download failed: An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 1 ;;
      gone)    echo "An error occurred (NoSuchBucket) when calling the ListObjectsV2 operation" >&2; exit 1 ;;
      network) echo "Could not connect to the endpoint URL: \"https://s3.ap-south-2.amazonaws.com/\"" >&2; exit 1 ;;
      missing) echo "fatal error: An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 1 ;;
      *) cat <<'IDX'
{"apps":[{"appid":"2344520","name":"Diablo IV","installdir":"Diablo IV","bytes":171986001052,"pushed":"2026-09-16T00:00:00Z"}]}
IDX
      ;;
    esac ;;
  *"s3 ls"*--summarize*) printf 'Total Objects: 6218\n   Total Size: 171986001052\n' ;;
  *"s3 ls"*) exit 0 ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"

cg_() { ( cd "$T/repo" && env -i PATH="$T/bin:$PATH" HOME="$T/home" CG_COLOR=never \
            FAIL="${FAIL:-none}" bash ./cg "$@" 2>&1 ); }
err_() { python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("error") or "")
except Exception: print("NOT JSON")'; }

echo "1. an archive that reads fine"
out=$(cg_ library list)
contains "the game is listed"            "$out" "Diablo IV"
j=$(FAIL=none cg_ library list --json)
check    "  and no error is reported"    "$(err_ <<<"$j")" ""
check    "  with the games as data"      "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)["games"]))' <<<"$j")" "1"

echo "2. a readable bucket with no index really is empty"
out=$(FAIL=missing cg_ library list)
contains "it says so"                    "$out" "the archive is empty"
check    "  and exits 0"                 "$( FAIL=missing cg_ library list >/dev/null 2>&1; echo $?)" "0"

echo "3. credentials that no longer work"
out=$(FAIL=creds cg_ library list)
lacks    "it does NOT say empty"         "$out" "the archive is empty"
contains "  it says it cannot read it"   "$out" "cannot read the archive"
contains "  names the cause"             "$out" "credentials are not valid"
contains "  and says what that means"    "$out" "NOT the same as the archive being empty"
check    "  exiting non-zero"            "$( FAIL=creds cg_ library list >/dev/null 2>&1; echo $?)" "1"
j=$(FAIL=creds cg_ library list --json)
contains "json: the error is a field"    "$(err_ <<<"$j")" "credentials are not valid"
check    "  games is null, not []"       "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["games"])' <<<"$j")" "None"

echo "4. every other way it can fail says what it was"
contains "denied"   "$(FAIL=denied  cg_ library list --json | err_)" "may not read"
contains "403"      "$(FAIL=403     cg_ library list --json | err_)" "refused the read (403)"
contains "no bucket" "$(FAIL=gone   cg_ library list --json | err_)" "does not exist"
contains "network"  "$(FAIL=network cg_ library list --json | err_)" "cannot reach S3"

echo "5. the rule, in the code"
check "the silent fallback is gone" "$(grep -c "echo '{\"apps\":\[\]}' *$" cg)" "0"
contains "the reason travels on stderr" "$(cat cg)" "The reason goes to STDERR"
contains "status says unknown, not empty" "$(cat lib/setup)" "UNREADABLE"
contains "  and the app repeats the distinction" "$(cat app/renderer/app.js)" 'this is not "empty"'

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
