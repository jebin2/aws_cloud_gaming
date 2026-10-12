#!/usr/bin/env bash
# Turning a region on.
#
# The opposite of a quota: no case, no person, one call - and AWS works through
# DISABLED -> ENABLING -> ENABLED over a few minutes. What it needs instead is
# care. It is an ACCOUNT-level change, and undoing it is slower than doing it,
# so it is asked about rather than done quietly, and it is watched rather than
# assumed - "asked AWS" is not "the region works".
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
         mktemp rm mv cp chmod id uname dirname basename readlink wc find \
         mkdir tee touch timeout; do
  p=$(command -v "$b") && ln -sf "$p" "$T/bin/$b"
done
# sleep, faked: region_enable waits ten seconds between looks, and a test that
# honours that takes a minute to say what it could say instantly.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"

# The Account API. STATUSES is a list of statuses the region reports on
# successive calls, so a test can watch it move.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "${AWS_LOG:-/dev/null}"
# What the real CLI accepts, and nothing else. `aws account list-regions` has no
# --region-names, and a fake that answered it anyway is why a call that could
# never work passed every assertion in this file.
for a in "$@"; do
  case $a in
    --*) case $a in
           --max-results|--query|--output|--region-name|--region-opt-status-contains) ;;
           *) echo "aws: [ERROR]: Unknown options: $a" >&2; exit 252 ;;
         esac ;;
  esac
done
case "$*" in
  *"get-region-opt-status"*)
    n=$(wc -l < "${TICK:-/dev/null}" 2>/dev/null || echo 0)
    echo "$n" >> "${TICK:?}"
    set -- ${STATUSES-DISABLED}
    [[ $# -eq 0 ]] && exit 0          # AWS knows no such region
    idx=$(( n + 1 )); [[ $idx -gt $# ]] && idx=$#
    eval "printf '%s\n' \"\${$idx}\"" ;;
  *"list-regions"*)
    printf 'af-south-1\tDISABLED\nap-east-1\tDISABLED\nap-south-1\tENABLED_BY_DEFAULT\nap-south-2\tENABLED\nap-southeast-5\t%s\n' "${LIST_AP5:-DISABLED}" ;;
  *"enable-region"*)
    if [[ -n ${ENABLE_FAIL:-} ]]; then
      echo "An error occurred (${ENABLE_FAIL}) when calling the EnableRegion operation: no." >&2
      exit 254
    fi ;;
esac
exit 0
FAKE
chmod +x "$T/bin/aws"

cg_() {
  # shellcheck disable=SC2086
  ( cd "$T/repo" && env -i PATH="$T/bin" HOME="$T/home" CG_COLOR=never \
      AWS_LOG="$T/awslog" TICK="$T/tick" STATUSES="${STATUSES-DISABLED}" \
      LIST_AP5="${LIST_AP5:-DISABLED}" ENABLE_FAIL="${ENABLE_FAIL:-}" \
      GAME_REGION=ap-south-1 ${EXTRA:-} bash ./cg "$@" 2>&1 )
}
fresh() { rm -f "$T/awslog" "$T/tick"; touch "$T/tick"; }

echo "1. which regions this account may use"
fresh
j=$(cg_ regions optin --json)
check    "it is valid JSON"           "$(python3 -I -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$j")" "yes"
check    "  disabled ones are listed" "$(python3 -I -c 'import json,sys;print(",".join(json.load(sys.stdin)["disabled"]))' <<<"$j")" "af-south-1,ap-east-1,ap-southeast-5"
# describe-regions only lists what is already on, which is the opposite of what
# this question is about.
contains "it asks the Account API"    "$(cat "$T/awslog")" "account list-regions"
# The call for ONE region is its own API. list-regions has no --region-names,
# and asking for one that way fails as "no such region" - which reads as AWS
# not having the region at all.
contains "one region has its own call" "$(cat lib/sweep.sh)" "get-region-opt-status --region-name"
lacks    "  and not a filter that does not exist" "$(cat lib/sweep.sh)" "list-regions --region-names"
lacks    "  not describe-regions"     "$(cat "$T/awslog")" "describe-regions"
out=$(cg_ regions optin)
contains "the human view counts the enabled ones" "$out" "enabled: 2"
contains "  and names the rest"       "$out" "ap-southeast-5   disabled"

echo "2. enabling one"
fresh
out=$(STATUSES="DISABLED ENABLING ENABLED" cg_ regions enable ap-southeast-5)
contains "it says what it is doing"   "$out" "enabling ap-southeast-5"
# Said before it happens, not after: it is account-wide and slow to undo.
contains "  that it is account-level" "$out" "account-level change"
contains "  and slow to undo"         "$out" "slower than turning it on"
contains "the call is made"           "$(cat "$T/awslog")" "account enable-region --region-name ap-southeast-5"
contains "it waits for AWS"           "$out" "still enabling"
contains "  and confirms the end"     "$out" "ap-southeast-5 is enabled"

echo "3. one that is already on"
fresh
out=$(STATUSES="ENABLED" cg_ regions enable ap-southeast-5)
contains "it says so"                 "$out" "already enabled"
lacks    "  and asks nothing"         "$(cat "$T/awslog")" "enable-region"

echo "4. one that is already on its way"
fresh
out=$(STATUSES="ENABLING ENABLING ENABLED" cg_ regions enable ap-southeast-5)
contains "it does not ask twice"      "$out" "already being enabled"
lacks    "  no second call"           "$(cat "$T/awslog")" "enable-region"
contains "  but it still watches"     "$out" "is enabled"

echo "5. a region AWS has never heard of"
fresh
out=$(STATUSES="" cg_ regions enable xx-nowhere-1; echo "rc=$?")
contains "it says so"                 "$out" "does not list a region called xx-nowhere-1"
contains "  and fails"                "$out" "rc=1"
lacks    "  without calling enable"   "$(cat "$T/awslog")" "enable-region"

echo "6. the two refusals worth naming"
fresh
out=$(ENABLE_FAIL=AccessDeniedException cg_ regions enable ap-southeast-5; echo "rc=$?")
contains "AWS's refusal is quoted"    "$out" "AWS refused"
contains "  and the permission named" "$out" "account:EnableRegion"
contains "  and it fails"             "$out" "rc=1"
fresh
out=$(ENABLE_FAIL=OrganizationNotEmptyException cg_ regions enable ap-southeast-5)
contains "an Organization is named too" "$out" "only the management account"

echo "7. still enabling when the watch runs out"
fresh
out=$(STATUSES="DISABLED ENABLING ENABLING ENABLING ENABLING ENABLING ENABLING ENABLING" \
      cg_ regions enable ap-southeast-5; echo "rc=$?")
# Minutes, not seconds: an unfinished enable is not a failure, and saying so is
# the difference between waiting and retrying.
contains "it says it is still going"  "$out" "still enabling - this is normal"
contains "  and how to look again"    "$out" "cg regions optin"
contains "  without failing"          "$out" "rc=0"

echo "8. wired in"
contains "cg dispatches optin"        "$(cat cg)" "optin)   shift"
contains "  and enable"               "$(cat cg)" "enable)  shift"
contains "  and help names both"      "$(cat cg)" "cg regions [optin|enable <r>]"
js=$(cat app/renderer/app.js)
contains "the app offers it"          "$js" "Enable a region"
contains "  reads the list"           "$js" "'regions', 'optin', '--json'"
contains "  and runs cg to enable"    "$js" "'regions', 'enable'"
# The sweep's own numbers next to each candidate: a bare region code is a
# guess, "Malaysia, 48ms, 9/10" is a decision.
contains "  with latency and capacity" "$js" "at \${best.score}/10"

echo ""
echo "region-optin: $pass passed, $fail failed"
(( fail == 0 ))
