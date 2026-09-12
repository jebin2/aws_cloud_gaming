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

# ROLE=1 the instance role exists; USER=1 the watchdog user exists;
# KEY= the active key id it reports ("None" for a user with no active key).
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"get-role"*) [[ ${ROLE:-0} == 1 ]] || exit 1; echo "role" ;;
  *"get-user"*) [[ ${USER_EXISTS:-0} == 1 ]] || exit 1; echo "user" ;;
  *list-access-keys*) echo "${KEY:-None}" ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"

run() {
  ( cd "$T" && PATH="$T/bin:$PATH" TS_HOST=gamevps \
      ROLE="${ROLE:-0}" USER_EXISTS="${USER_EXISTS:-0}" KEY="${KEY:-None}" \
      bash -c 'source "$1"; iam_lines' _ "$T/fn.sh" 2>&1 )
}
sed -n '/^iam_lines() {/,/^}/p' lib/setup > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "could not extract iam_lines from lib/setup"; exit 1; }

echo "1. nothing exists yet"
: > "$T/.env"
out=$(ROLE=0 USER_EXISTS=0 run)
contains "role reported absent" "$out" "instance role   none"
contains "no watchdog key"      "$out" "watchdog key    none"

echo "2. role present"
out=$(ROLE=1 USER_EXISTS=0 run)
contains "names the role" "$out" "gamevps-box"

echo "3. an ACTIVE watchdog key is shown, with what it can do"
printf 'GAME_WATCHDOG_AWS_KEY_ID=AKIAFAKE\n' > "$T/.env"
out=$(ROLE=1 USER_EXISTS=1 KEY=AKIAFAKE run)
contains "shows the key id"     "$out" "AKIAFAKE"
contains "says it is active"    "$out" "ACTIVE"
contains "says what it can do"  "$out" "can stop instances"
lacks    "not called orphaned"  "$out" "orphaned"

echo "4. a key AWS honours but .env does not hold is flagged as orphaned"
# Unusable and unauditable: it can never be used again, only revoked.
: > "$T/.env"
out=$(ROLE=1 USER_EXISTS=1 KEY=AKIAFAKE run)
contains "flagged orphaned"     "$out" "orphaned"
contains "says how to revoke"   "$out" "cg destroy --all"

echo "5. a user with no active key is not reported as a live credential"
out=$(ROLE=1 USER_EXISTS=1 KEY=None run)
contains "says it has no key"   "$out" "no active key"
lacks    "not called ACTIVE"    "$out" "ACTIVE"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
