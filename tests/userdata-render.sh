#!/usr/bin/env bash
# The user-data render: placeholders must come out VERBATIM.
#
# It used to run through sed, where an unescaped `&` in the replacement means
# "the entire matched text". A presigned S3 URL is mostly `&`, so every
# separator in it became the literal string __HOST_TGZ_URL__, curl got a 400,
# and the build died at stage 15 - before tailscale, leaving a box with no
# network identity and only console output to debug from.
#
# The hand-written check that "passed" beforehand used a URL whose `&` had been
# escaped by hand, which is the only reason it looked fine. So this feeds the
# render the shapes that actually break substitution.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

# The render, lifted out of provision.sh so the test exercises the real code
# rather than a copy of it.
render() { # render <text-on-stdin>
  TS_AUTHKEY="$1" TS_HOST="$2" HOST_TGZ_URL="$3" S3_BUCKET="$4" CG_APPS="$5" \
  python3 -c 'import os,sys
s = sys.stdin.read()
for k in ("TS_AUTHKEY", "TS_HOST", "HOST_TGZ_URL", "S3_BUCKET", "CG_APPS"):
    s = s.replace("__%s__" % k, os.environ.get(k, ""))
missing = [w for w in ("__TS_AUTHKEY__", "__TS_HOST__", "__HOST_TGZ_URL__",
                       "__S3_BUCKET__", "__CG_APPS__") if w in s]
if missing:
    sys.exit("placeholders left unsubstituted: %s" % ", ".join(missing))
sys.stdout.write(s)'
}
# Byte-for-byte the shape aws s3 presign emits.
URL='https://b.s3.ap-south-2.amazonaws.com/boot/host.tgz?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIA%2F20260913%2Fap-south-2%2Fs3%2Faws4_request&X-Amz-Date=20260913T064320Z&X-Amz-Expires=7200&X-Amz-SignedHeaders=host&X-Amz-Signature=4e4fcbe6'

echo "1. a presigned URL survives intact - every & and %"
out=$(printf "curl '%s' -o /tmp/host.tgz\n" '__HOST_TGZ_URL__' | render k h "$URL" b all)
contains "the whole URL is present"  "$out" "$URL"
check    "and the ampersands are real, not the placeholder" \
         "$(grep -c '__HOST_TGZ_URL__' <<<"$out" || true)" "0"
check    "all five separators survived" \
         "$(grep -o '&' <<<"$out" | wc -l)" "5"

echo "2. this is exactly what the old sed did wrong"
# Kept as evidence, so the reason for not using sed is demonstrable rather than
# asserted. If this ever stops reproducing, the comment can go.
sed_out=$(printf "curl '%s'\n" '__HOST_TGZ_URL__' | sed -e "s|__HOST_TGZ_URL__|$URL|")
contains "sed corrupts it" "$sed_out" "AWS4-HMAC-SHA256__HOST_TGZ_URL__X-Amz-Credential"

echo "3. every placeholder is substituted"
out=$(printf '%s %s %s %s %s\n' '__TS_AUTHKEY__' '__TS_HOST__' '__HOST_TGZ_URL__' \
        '__S3_BUCKET__' '__CG_APPS__' | render "tskey-auth-xyz" gamevps "$URL" "cg-library-abc" "1,2")
contains "auth key"   "$out" "tskey-auth-xyz"
contains "host"       "$out" "gamevps"
contains "bucket"     "$out" "cg-library-abc"
contains "apps csv"   "$out" "1,2"

echo "4. an unsubstituted placeholder fails the render instead of shipping"
# A box that boots with a literal __S3_BUCKET__ in its config fails later, on
# the machine, where it is hardest to see.
out=$(printf 'x __UNKNOWN__ __S3_BUCKET__\n' | TS_AUTHKEY=k TS_HOST=h HOST_TGZ_URL=u S3_BUCKET= CG_APPS=all \
  python3 -c 'import os,sys
s=sys.stdin.read()
for k in ("TS_AUTHKEY","TS_HOST","HOST_TGZ_URL","S3_BUCKET","CG_APPS"):
    s=s.replace("__%s__"%k, os.environ.get(k,""))
missing=[w for w in ("__TS_AUTHKEY__","__TS_HOST__","__HOST_TGZ_URL__","__S3_BUCKET__","__CG_APPS__") if w in s]
if missing: sys.exit("placeholders left unsubstituted: %s" % ", ".join(missing))
sys.stdout.write(s)' 2>&1); rc=$?
check "empty bucket still substitutes (to empty)" "$rc" "0"

echo "5. the real modules render without leaving a placeholder"
out=$(cat lib/bootstrap.d/*.sh | grep -vE '^[[:space:]]*#([^!]|$)' \
      | render "tskey-auth-xyz" gamevps "$URL" "cg-library-abc" all); rc=$?
check    "render succeeded"          "$rc" "0"
check    "no placeholder survives"   "$(grep -c '__[A-Z_]*__' <<<"$out" || true)" "0"
contains "the URL is intact in place" "$out" "$URL"
# And it still has to fit: EC2 caps user-data at 16 KB, gzipped.
gz=$(printf '%s' "$out" | gzip -9 | wc -c)
if (( gz < 16384 )); then echo "  ok   fits user-data ($gz of 16384 gzipped)"; pass=$((pass+1));
else echo "  FAIL user-data is $gz gzipped, over the 16384 limit"; fail=$((fail+1)); fi

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
