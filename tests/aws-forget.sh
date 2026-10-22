#!/usr/bin/env bash
# cg aws forget: this laptop stops playing on AWS - only while nothing cg made
# there still bills, and without deleting anything or touching the access key.
#
# "Remove AWS" in the app is this command. It forgets the region in .env, which
# is what "an AWS machine" means to the app; refusing is the point of it, because
# a forgotten laptop no longer shows the machine or the games that cost money.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.aws" "$T/repo"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
printf '[default]\naws_access_key_id = AKIDEXAMPLE\n' > "$T/home/.aws/credentials"

# Another region's archive, named as cg names one for this account and host, so
# it counts as cg's own.
OLD="cg-library-$(printf '%s' "123456789012-gamevps" | sha256sum | cut -c1-12)"
export OLD

# AWS as each case wants it: BOX the machine's state (or "down": no answer),
# GAMES the saved games here, OTHER the games in another region's bucket.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *describe-instances*) [[ $BOX == down ]] && exit 255; echo "$BOX" ;;
  *"sts get-caller-identity"*) echo 123456789012 ;;
  *"s3 cp"*"$OLD"*index.json*) echo "{\"apps\": [$OTHER]}" ;;
  *"s3 cp"*index.json*) echo "{\"apps\": [$GAMES]}" ;;
  *"s3api list-buckets"*) echo "cg-library-test $OLD" ;;
  *get-bucket-location*) echo ap-south-1 ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"
GAME='{"appid": "1", "name": "Diablo IV", "installdir": "D4", "bytes": 1}'

forget() { # forget <box> <games> <other> [args] -> its output, then rc=N
  printf 'GAME_S3_BUCKET=cg-library-test\nGAME_REGION=ap-south-2\nGAME_INSTANCE_ID=i-1\nGAME_RES=1920x1080\n' > "$T/repo/.env"
  ( cd "$T/repo" && env -i PATH="$T/bin:$PATH" HOME="$T/home" CG_COLOR=never CG_INR_PER_USD=88 \
      BOX="$1" GAMES="$2" OTHER="$3" OLD="$OLD" bash ./cg aws forget "${@:4}" 2>&1; echo "rc=$?" )
}
region() { grep -c '^GAME_REGION=' "$T/repo/.env"; }

echo "1. nothing left there: forgotten"
out=$(forget terminated "" "")
contains "it says so"                         "$out" "no longer plays on AWS"
contains "  and what it did not do"           "$out" "nothing in AWS was deleted"
contains "  ending well"                      "$out" "rc=0"
check    "the region leaves .env"             "$(region)" "0"
check    "  and nothing else does"            "$(grep -c '^GAME_RES=1920x1080' "$T/repo/.env")" "1"
check    "the access key is left alone"       "$(grep -c AKIDEXAMPLE "$T/home/.aws/credentials")" "1"

echo "2. a machine still there: refused"
out=$(forget running "" "")
contains "it says which"                      "$out" "a machine is still on AWS (running)"
contains "  and fails"                        "$out" "rc=1"
check    "the region stays"                   "$(region)" "1"

echo "3. games still saved: refused"
out=$(forget terminated "$GAME" "")
contains "it counts them"                     "$out" "1 game still saved in AWS"
check    "  the region stays"                 "$(region)" "1"
out=$(forget terminated "" "$GAME")
contains "in another region too"              "$out" "still saved in another AWS region"
check    "  the region stays"                 "$(region)" "1"

echo "4. AWS does not answer: not known, so not forgotten"
out=$(forget down "" "")
contains "it says it could not ask"           "$out" "could not be asked"
contains "  with its own code"                "$out" "rc=3"
check    "  the region stays"                 "$(region)" "1"
out=$(forget down "" "" --anyway)
contains "--anyway forgets it all the same"   "$out" "rc=0"
check    "  the region goes"                  "$(region)" "0"

echo; echo "aws-forget: $pass passed, $fail failed"
(( fail == 0 ))
