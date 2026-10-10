#!/usr/bin/env bash
# A presigned URL is signed FOR A REGION, and the bucket's region is not the
# box's region.
#
# This cost a 30-minute build. `cg config set GAME_REGION ap-south-1` moved the
# box to Mumbai, but the bucket name is derived from the account and the host -
# there is no region in it - so init found the SAME bucket still sitting in
# ap-south-2. The upload worked, because `aws s3 cp` follows S3's redirect and
# retries. The presign did not: it signs for whatever --region it is handed, and
# S3 answered the box's download with HTTP 400. user-data aborted before
# tailscale was installed, so the build then waited half an hour for a node that
# could never appear, and the only visible symptom was "no new node joined".
#
# Verified against the real bucket at the time: presigned for ap-south-1 -> 400,
# presigned for ap-south-2 -> 200.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export HOME="$T"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *get-bucket-location*)
    [[ -n ${LOC_FAIL:-} ]] && { echo "AccessDenied" >&2; exit 254; }
    echo "${LOC-ap-south-2}" ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"

ask() { env PATH="$T/bin:$PATH" "$@" \
          bash -c 'source lib/s3-region.sh; s3_bucket_region cg-library-test; echo "rc=$?"' 2>/dev/null; }

echo "1. the bucket's own region is reported"
check "a constrained bucket"       "$(ask LOC=ap-south-2)" "ap-south-2rc=0"
check "  and a different one"      "$(ask LOC=eu-west-1)"  "eu-west-1rc=0"

echo "2. us-east-1 predates the constraint and reports it empty"
# Left as the empty string this would have produced `--region ''`, which is a
# different wrong answer from the one being fixed.
check "None becomes us-east-1"     "$(ask LOC=None)"   "us-east-1rc=0"
check "  null too"                 "$(ask LOC=null)"   "us-east-1rc=0"
check "  and an empty answer"      "$(ask LOC=)"       "us-east-1rc=0"

echo "3. an unreadable location is a failure, not a guess"
# The caller falls back to the configured region, which is right when the two
# genuinely match - but it must be the CALLER's choice, not a silent default
# that hides a cross-region bucket.
check "it fails rather than inventing" "$(ask LOC_FAIL=1)" "rc=1"

echo "4. provision presigns with the bucket's region"
prov=$(cat lib/provision.sh)
contains "the bucket's region is resolved"  "$prov" 'BUCKET_REGION=$(s3_bucket_region "$S3_BUCKET")'
contains "  falling back to the box's"      "$prov" '|| BUCKET_REGION=$REGION'
contains "the presign uses it"              "$prov" '--region "$BUCKET_REGION" --expires-in 7200'
# This is the line that was wrong. If it comes back, the box gets a 400 again.
lacks    "and never the box's region"       "$prov" 'presign "s3://$S3_BUCKET/boot/host.tgz" --region "$REGION"'
contains "the upload uses it too"           "$prov" '"s3://$S3_BUCKET/boot/host.tgz" --region "$BUCKET_REGION"'
contains "and the helper is sourced"        "$prov" "source lib/s3-region.sh"

echo "5. a cross-region archive is said out loud, because it is money"
contains "the mismatch is reported"   "$prov" 'the archive is in $BUCKET_REGION but the box is in $REGION'
contains "  marked as a warning"      "$prov" 'echo "!! the archive is in'
contains "  with the per-GB price"    "$prov" '0.086/GB'
contains "  and what it costs a pull" "$prov" "INR 1,234"
contains "  and how to start fresh"   "$prov" "set GAME_S3_BUCKET to a new name"

echo "6. nothing in the helper costs anything or changes anything"
# Comments stripped: this file explains WHY `aws s3 cp` hid the bug, and a
# search of the prose found that sentence rather than a call.
body=$(sed 's/#.*//' lib/s3-region.sh)
for verb in create-bucket delete-bucket put-object cp sync rm mb rb; do
  lacks "the helper never runs $verb" "$body" "aws s3 $verb"
done
contains "it says the call is free" "$(cat lib/s3-region.sh)" "not charged"

echo ""
echo "s3-region: $pass passed, $fail failed"
(( fail == 0 ))
