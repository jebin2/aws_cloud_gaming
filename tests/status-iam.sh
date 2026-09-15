#!/usr/bin/env bash
# Tests the IAM lines in `cg status` against a stubbed AWS CLI.
#
# These lines exist because status showed no IAM at all, and that is how an
# active access key - one that could stop instances, held on an internet-facing
# host - survived `cg destroy --all` without anyone noticing. Nothing that
# listed what existed ever mentioned it.
#
# The function is extracted from lib/setup rather than driving the whole status
# view, which would need every AWS call in it stubbed.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' should not contain '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# ROLE=1 the instance role exists; CWROLE=1 the cloud watchdog's role exists.
# Every call is recorded, so "never looks up an IAM user" can be asserted.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$CALLS"
case "$args" in
  *"get-role --role-name gamevps-cloud-watchdog"*) [[ ${CWROLE:-0} == 1 ]] || exit 1; echo "role" ;;
  *"get-role"*) [[ ${ROLE:-0} == 1 ]] || exit 1; echo "role" ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"

RC=0
run() {
  local out
  out=$( cd "$T" && PATH="$T/bin:$PATH" TS_HOST=gamevps \
      ROLE="${ROLE:-0}" CWROLE="${CWROLE:-0}" CALLS="$T/calls" \
      bash -c 'source "$1"; iam_lines' _ "$T/fn.sh" 2>&1 )
  RC=$?
  printf '%s' "$out"
}
sed -n '/^iam_lines() {/,/^}/p' lib/setup > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "could not extract iam_lines from lib/setup"; exit 1; }

echo "1. nothing exists yet"
: > "$T/.env"
out=$(ROLE=0 run)
contains "role reported absent" "$out" "instance role   none"
contains "watchdog role absent" "$out" "watchdog role   none - cg init creates it"

echo "2. roles present"
out=$(ROLE=1 run)
contains "names the role" "$out" "gamevps-box"
out=$(ROLE=1 CWROLE=1 run)
contains "names the watchdog role, and what it may do" "$out" "watchdog role   gamevps-cloud-watchdog  (the cloud watchdog: ends only the gamevps box)"

# Exit status, on every path. The function runs inside `set -e` callers, so a
# non-zero return kills `cg status` and `cg cost` outright - which is exactly
# what happened: `[[ ... ]] && printf` as the last statement returned 1 whenever
# its test was false. The output assertions above all passed while that was
# live, because they captured stdout and ignored $?.
echo "3. no IAM user or access key is ever looked up - nothing here uses one"
: > "$T/calls"
ROLE=1 CWROLE=1 run >/dev/null
check "no get-user, no access keys" "$(grep -cE 'get-user|access-key' "$T/calls" || true)" "0"

echo "4. iam_lines returns 0 on every path"
for spec in "0 0" "1 0" "0 1" "1 1"; do
  set -- $spec
  ROLE=$1 CWROLE=$2 run >/dev/null
  check "role=$1 watchdog-role=$2" "$RC" "0"
done

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
