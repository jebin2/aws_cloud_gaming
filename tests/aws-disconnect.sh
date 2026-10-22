#!/usr/bin/env bash
# cg aws disconnect: this laptop stops playing on AWS and leaves nothing there
# that bills - the machine, every region's saved games, leftover disks and
# images, the watchdog, the budget - and says so only once it has looked.
#
# "Disconnect" in the app is this command, and cg aws inventory is what its
# confirmation lists. The AWS here is a fake with state: each thing exists as a
# file, and a delete removes it - so "nothing is left" is checked, not assumed.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.aws" "$T/repo" "$T/aws"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
printf '[default]\naws_access_key_id = AKIDEXAMPLE\n' > "$T/home/.aws/credentials"
name() { printf 'cg-library-%s' "$(printf '%s' "123456789012-gamevps-$1" | sha256sum | cut -c1-12)"; }
HERE=$(name ap-south-2); OLD=$(name ap-south-1)
export HERE OLD S="$T/aws"

# What is there: each a file in $S, gone once AWS is told to delete it.
seed() {
  rm -f "$S"/*
  printf 'i-1\trunning\tg6.xlarge\n' > "$S/machine"
  touch "$S/here" "$S/old" "$S/vol" "$S/img" "$S/cw" "$S/budget" "$S/login"
  # cg's settings in SSM: a game's keep timer here, and one in the old region.
  printf 'ap-south-2 /cloud-gaming/gamevps/kept/%s/2\nap-south-1 /cloud-gaming/gamevps/kept/%s/1\nap-south-2 /cloud-gaming/gamevps/archive-last-seen\n' \
    "$HERE" "$OLD" > "$S/marks"
}
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
a="$*"
[[ -n ${AWS_DOWN:-} ]] && exit 255
q() { [[ $a == *"$1"* ]]; }
case $a in
  *"sts get-caller-identity"*) echo 123456789012 ;;
  *describe-instances*)
    if q instance-state-name; then
      [[ -f $S/machine ]] || exit 0
      if q '[InstanceId,State.Name'; then cat "$S/machine"; else cut -f1 "$S/machine"; fi
    elif q InstanceLifecycle; then echo None
    else [[ -f $S/machine ]] && cut -f2 "$S/machine" || echo terminated; fi ;;
  *terminate-instances*) rm -f "$S/machine" ;;
  *describe-volumes*)
    if q 'status,Values=available'; then
      [[ -f $S/vol ]] || exit 0
      if q '[VolumeId,Size]'; then printf 'vol-1\t50\n'; else printf 'vol-1\tNone\n'; fi
    elif q volume-ids; then echo available
    else printf 'None\tNone\n'; fi ;;
  *delete-volume*) rm -f "$S/vol" ;;
  *describe-images*)
    if q image-ids; then echo snap-1
    elif [[ -f $S/img ]]; then if q '[ImageId'; then printf 'ami-1\t30\n'; else echo ami-1; fi; fi ;;
  *deregister-image*) rm -f "$S/img" ;;
  *"s3api head-bucket"*)
    q "$HERE" && [[ -f $S/here ]] && exit 0
    q "$OLD" && [[ -f $S/old ]] && exit 0
    exit 254 ;;
  *"s3api list-buckets"*) n=""; [[ -f $S/here ]] && n="$HERE"; [[ -f $S/old ]] && n="$n $OLD"; echo "${n# }" ;;
  *get-bucket-location*) q "$OLD" && echo ap-south-1 || echo ap-south-2 ;;
  *"s3 ls"*)
    if q "$OLD"; then [[ -f $S/old ]] && echo "2026-01-01 00:00:00 2147483648 steam/steamapps/common/D4/data"
    else [[ -f $S/here ]] && printf 'Total Objects: 3\nTotal Size: 1073741824\n'; fi ;;
  *"s3 cp"*index.json*)
    if q "$OLD"; then [[ -f $S/old ]] && echo '{"apps": [{"appid": "1", "name": "Diablo IV", "installdir": "D4", "bytes": 2147483648}]}'
    elif [[ -f $S/here ]]; then echo '{"apps": [{"appid": "2", "name": "Hades", "installdir": "Hades", "bytes": 1073741824}]}'
    else echo "An error occurred (NoSuchBucket)" >&2; exit 1; fi ;;
  *"s3 rb"*)
    if q "$OLD"; then [[ -n ${OLD_STUCK:-} ]] && exit 1; rm -f "$S/old"; fi
    q "$HERE" && rm -f "$S/here" "$S/login"
    echo "rb $a" >> "$S/../deleted.log" ;;
  *"s3 ls"*steam/account/*) q "$HERE" && [[ -f $S/login && -f $S/here ]] && echo "2026-01-01 00:00:00 22528 steam-account.tgz" ;;
  *"ssm get-parameters-by-path"*)
    r=$(sed -n 's/.*--region \([^ ]*\).*/\1/p' <<<"$a")
    [[ -s $S/marks ]] && awk -v r="$r" '$1 == r {print $2}' "$S/marks" | paste -sd '\t' ;;
  *"ssm delete-parameters"*)
    r=$(sed -n 's/.*--region \([^ ]*\).*/\1/p' <<<"$a")
    for n in $(sed -n 's/.*--names \(.*\)$/\1/p' <<<"$a"); do
      grep -vxF "$r $n" "$S/marks" > "$S/marks.n"; mv "$S/marks.n" "$S/marks"; done
    [[ -s $S/marks ]] || rm -f "$S/marks" ;;
  *"budgets describe-budget"*) [[ -f $S/budget ]] || exit 254 ;;
  *"budgets delete-budget"*) [[ -n ${BUDGET_STUCK:-} ]] || rm -f "$S/budget" ;;
  *get-function-configuration*) [[ -f $S/cw ]] || exit 254 ;;
  *"iam get-role"*) [[ $a == *-box* ]] && exit 254; [[ -f $S/cw ]] || exit 254 ;;
  *delete-function*) rm -f "$S/cw" ;;
  *) : ;;
esac
FAKE
chmod +x "$T/bin/aws"

cgr() { # cgr <args...> - cg in the sandbox, its output, then rc=N
  ( cd "$T/repo" && env -i PATH="$T/bin:$PATH" HOME="$T/home" CG_COLOR=never CG_INR_PER_USD=88 CG_SLEEP_PCT=1 \
      CG_PRICES_FILE="$OLDPWD/tests/prices.env" S="$S" HERE="$HERE" OLD="$OLD" \
      AWS_DOWN="${AWS_DOWN:-}" OLD_STUCK="${OLD_STUCK:-}" BUDGET_STUCK="${BUDGET_STUCK:-}" CG_JSON="${CG_JSON_MODE:-}" bash ./cg "$@" 2>&1; echo "rc=$?" )
}
env_reset() { printf 'GAME_REGION=ap-south-2\nGAME_INSTANCE_ID=i-1\nGAME_RES=1920x1080\n' > "$T/repo/.env"; }
region() { grep -c '^GAME_REGION=' "$T/repo/.env"; }
there() { ls "$S" | sort | tr '\n' ' ' | sed 's/ $//'; }

echo "1. the inventory: everything cg has there, read live"
env_reset; seed
j=$(cgr aws inventory --json)
kinds=$(sed '$d' <<<"$j" | python3 -c 'import json,sys; print(" ".join(i["kind"] for i in json.load(sys.stdin)["items"]))')
check    "machine, both regions' games, disks, images, watchdog, budget, settings" "$kinds" "machine games games disks images watchdog budget settings"
contains "  the machine as it is"         "$j" '"detail": "g6.xlarge, running"'
contains "  the games here, counted, and the Steam login with them" "$j" '"detail": "1 game, 1.0 GB and the saved Steam login"'
contains "  every region's settings in SSM" "$j" '"detail": "3 settings in SSM"'
contains "  and those in another region"  "$j" '"detail": "1 game, 2.0 GB in ap-south-1"'
contains "  a running machine bills by the hour" "$j" '"hourly": true'
check    "  and it is only a look"        "$(there)" "budget cw here img login machine marks old vol"
contains "a laptop without AWS has nothing to show" "$(printf 'GAME_RES=x\n' > "$T/repo/.env"; CG_JSON_MODE= cgr aws inventory --json)" '"connected": false'

echo "2. not confirmed: nothing deleted"
env_reset; seed
out=$(printf 'no\n' | CG_JSON_MODE=1 cgr aws disconnect)
contains "it asks for DELETE"             "$out" '"id":"aws-disconnect"'
contains "  having said what goes"        "$out" "Saved games elsewhere"
contains "  and what stays"               "$out" "region opt-ins and GPU quota stay"
contains "anything else is a no"          "$out" "nothing was deleted"
contains "  and fails"                    "$out" "rc=1"
check    "  everything is still there"    "$(there)" "budget cw here img login machine marks old vol"
check    "  and AWS still set up"         "$(region)" "1"

echo "3. confirmed: nothing of cg's is left"
env_reset; seed; rm -f "$T/deleted.log"
out=$(printf 'DELETE\n' | CG_JSON_MODE=1 cgr aws disconnect)
contains "it ends well"                   "$out" "rc=0"
contains "  saying nothing is left billing" "$out" "AWS disconnected - nothing of cg is left billing"
check    "  and nothing is: the login and every region's settings went too" "$(there)" ""
contains "the other region's games went too" "$(cat "$T/deleted.log")" "$OLD"
check    "the region leaves .env"         "$(region)" "0"
check    "  and nothing else does"        "$(grep -c '^GAME_RES=1920x1080' "$T/repo/.env")" "1"
check    "the access key is kept"         "$(grep -c AKIDEXAMPLE "$T/home/.aws/credentials")" "1"

echo "4. AWS does not answer: nothing touched"
env_reset; seed
out=$(printf 'DELETE\n' | AWS_DOWN=1 CG_JSON_MODE=1 cgr aws disconnect)
contains "it says so"                     "$out" "AWS could not be asked what is there - nothing was deleted"
contains "  with its own code"            "$out" "rc=3"
check    "  and everything is still there" "$(there)" "budget cw here img login machine marks old vol"

echo "5. something will not go: said, and AWS stays set up to see it"
env_reset; seed
out=$(printf 'DELETE\n' | OLD_STUCK=1 CG_JSON_MODE=1 cgr aws disconnect)
contains "it names what is still there"   "$out" "still there: Saved games elsewhere - 1 game, 2.0 GB in ap-south-1"
contains "  and fails"                    "$out" "rc=1"
lacks    "  never claiming nothing is left" "$out" "nothing of cg is left billing"
check    "  AWS stays set up, to see it"  "$(region)" "1"
check    "  the rest went, its settings too - only the stuck bucket stays" "$(there)" "old"

echo "6. something free will not go: not done either - nothing of cg's is meant to stay"
env_reset; seed
out=$(printf 'DELETE\n' | BUDGET_STUCK=1 CG_JSON_MODE=1 cgr aws disconnect)
contains "it names it"                    "$out" "still there: Budget alert"
contains "  and fails"                    "$out" "rc=1"
check    "  AWS stays set up"             "$(region)" "1"

echo; echo "aws-disconnect: $pass passed, $fail failed"
(( fail == 0 ))
