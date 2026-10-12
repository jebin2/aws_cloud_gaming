#!/usr/bin/env bash
# `cg quota`: asking AWS for the GPU limit, and the appeal that gets it.
#
# A new account can launch zero GPU instances, and both limits start at 0. The
# request is free and the API takes it - but the first answer is an automatic
# refusal, and what gets approved is the APPEAL on that same case. cg cannot
# send that: the Support API needs a Business plan. So it asks, tracks the
# answer, and writes the appeal out of facts this rig already measured.
set -uo pipefail
cd "$(dirname "$0")/.."
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
for b in bash sh env grep sed awk python3 cat cut tr sort head tail date stat \
         mktemp rm mv cp chmod id uname dirname basename readlink wc find sleep \
         mkdir tee touch timeout; do
  p=$(command -v "$b") && ln -sf "$p" "$T/bin/$b"
done

# The Service Quotas API, as a fake. OD_VAL and SPOT_VAL are the applied
# values; HIST is what the history returns for the quota being asked about;
# REQ_FAIL makes the submit refuse.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "${AWS_LOG:-/dev/null}"
case "$*" in
  *"describe-instance-types"*) echo "4" ;;
  *"get-service-quota"*)
    case "$*" in
      *L-DB2E81BA*) printf '%s\n' "${OD_VAL:-0.0}" ;;
      *L-3819A6DF*) printf '%s\n' "${SPOT_VAL:-0.0}" ;;
    esac ;;
  *"list-requested-service-quota-change-history-by-quota"*)
    printf '%s\n' "${HIST:-None}" ;;
  *"request-service-quota-increase"*)
    if [[ -n ${REQ_FAIL:-} ]]; then
      echo "An error occurred (${REQ_FAIL}) when calling the RequestServiceQuotaIncrease operation: no." >&2
      exit 254
    fi
    printf 'req-123\t178899999999999\tPENDING\n' ;;
esac
exit 0
FAKE
chmod +x "$T/bin/aws"

cg_() { # cg_ <args...> - EXTRA passes env through
  # shellcheck disable=SC2086
  ( cd "$T/repo" && env -i PATH="$T/bin" HOME="$T/home" CG_COLOR=never \
      AWS_LOG="$T/awslog" OD_VAL="${OD_VAL:-0.0}" SPOT_VAL="${SPOT_VAL:-0.0}" \
      HIST="${HIST:-None}" REQ_FAIL="${REQ_FAIL:-}" \
      GAME_REGION=ap-south-1 GAME_INSTANCE_TYPE=g6.xlarge \
      GAME_BUDGET_INR=5000 GAME_WATCHDOG_IDLE_MIN=30 GAME_WATCHDOG_STUCK_MIN=180 \
      ${EXTRA:-} bash ./cg "$@" 2>&1 )
}
j() { python3 -I -c 'import json,sys
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[k] if d is not None else None
print(json.dumps(d))' "$@"; }

echo "1. both limits, because they are two different limits"
rm -f "$T/awslog"
out=$(cg_ quota --json)
check    "it is valid JSON"            "$(python3 -I -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$out")" "yes"
check    "on demand has its own code"  "$(j ondemand code <<<"$out")" '"L-DB2E81BA"'
check    "  and spot its own"          "$(j spot code <<<"$out")" '"L-3819A6DF"'
check    "zero is not enough"          "$(j ondemand enough <<<"$out")" "false"
# Exactly one box: the appeal that worked said so in as many words.
check    "it asks what one box needs"  "$(j vcpus_needed <<<"$out")" "4"
check    "  from the real machine"     "$(j instance_type <<<"$out")" '"g6.xlarge"'

echo "2. a quota that already covers a box is not a problem"
out=$(OD_VAL=4.0 cg_ quota --json)
check    "4 covers a 4 vCPU box"       "$(j ondemand enough <<<"$out")" "true"
out=$(OD_VAL=4.0 cg_ quota)
contains "and only the short one is named" "$out" "ask for spot"
lacks    "  not the one that is fine"  "$out" "ask for ondemand and spot"

echo "3. asking"
rm -f "$T/awslog"
out=$(cg_ quota request ondemand)
contains "it says what it is asking for" "$out" "asking for 4 vCPU of G and VT on demand in ap-south-1"
contains "  for exactly one box"       "$(cat "$T/awslog")" "--desired-value 4"
contains "  against the right quota"   "$(cat "$T/awslog")" "--quota-code L-DB2E81BA"
contains "  and reports the request"   "$out" "req-123"
# The refusal is part of the process, and saying so up front is the difference
# between "it failed" and "that is step one".
contains "it warns the first answer is no" "$out" "automatic refusal"
contains "  and names what gets it approved" "$out" "cg quota appeal ondemand"

echo "3b. asking for what you already have"
rm -f "$T/awslog"
out=$(OD_VAL=4.0 cg_ quota request ondemand)
contains "it declines"                 "$out" "already 4"
lacks    "  without asking AWS"        "$(cat "$T/awslog")" "request-service-quota-increase"

echo "3c. an open request is not asked twice"
# AWS refuses duplicates outright, and a second ask resets nothing.
rm -f "$T/awslog"
out=$(HIST="$(printf 'PENDING\t4.0\t2026-09-06T14:59:10+05:30\t100000000000001')" cg_ quota request spot)
contains "it says one is open"         "$out" "already open"
contains "  with its case"             "$out" "100000000000001"
lacks    "  and asks for nothing"      "$(cat "$T/awslog")" "request-service-quota-increase"

echo "3d. AWS refusing the ask itself"
out=$(REQ_FAIL=AccessDeniedException cg_ quota request ondemand)
contains "it says so"                  "$out" "AWS refused the request"
contains "  quoting AWS"               "$out" "AccessDeniedException"

echo "4. the appeal, from this rig's own numbers"
out=$(cg_ quota appeal ondemand)
contains "it is an appeal, not a new ask" "$out" "Requesting an appeal with detailed use case"
contains "the machine is named"        "$out" "A single g6.xlarge (4 vCPU)"
contains "  asking for the minimum"    "$out" "exactly 4 vCPUs - the"
contains "  and never more than one"   "$out" "never run more than one at a time"
contains "the budget is the real one"  "$out" "5000 INR/month"
contains "  the idle timeout too"      "$out" "30 minutes with no stream traffic"
contains "  and the forced shutdown"   "$out" "180 minutes"
contains "the region is named"         "$out" "ap-south-1"
# The line that answers the question the refusal is really asking.
contains "and the last line"           "$out" "not for cryptocurrency mining, ML training, or resale"

echo "5. wired in, and written down"
contains "cg dispatches quota"         "$(cat cg)" "quota)     case"
contains "  and help names it"         "$(cat cg)" "cg quota [request|appeal]"
doc=$(cat docs/quota-request.md)
contains "the playbook names both codes" "$doc" "L-DB2E81BA"
contains "  and the spot one"          "$doc" "L-3819A6DF"
contains "  says the refusal is normal" "$doc" "automatic refusal is not a rejection"
contains "  and why cg cannot appeal"  "$doc" "SubscriptionRequiredException"
app=$(cat app/renderer/app.js)
contains "the app offers the ask"      "$app" "Ask AWS for GPU quota"
contains "  and drafts the appeal"     "$app" "'quota', 'appeal'"
main=$(cat app/main/index.js)
contains "the case link is allowed"    "$main" "console.aws.amazon.com"
contains "  and still only https"      "$main" "u.protocol !== 'https:'"

echo ""
echo "quota: $pass passed, $fail failed"
(( fail == 0 ))
