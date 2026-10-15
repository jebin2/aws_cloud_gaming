#!/usr/bin/env bash
# cg_sleep: a poll loop's wait, which the test runner scales down.
#
# Four suites spent most of their minutes asleep in cg's poll loops - 400
# three-second waits in one - against stubs that answer at once. cg_sleep is
# exactly `sleep` unless CG_SLEEP_PCT is set, and the loops count time by the
# nominal seconds, so a timeout means the same either way.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export HOME="$T"

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
between()  { if (( $2 >= $3 && $2 <= $4 )); then echo "  ok   $1 (${2}ms)"; pass=$((pass+1));
             else echo "  FAIL $1: ${2}ms, want $3-$4"; fail=$((fail+1)); fi; }

eval "$(sed -n '/^cg_sleep() {/,/^}/p' lib/common.sh)"
ms() { local s; s=$(date +%s%N); "$@"; echo $(( ($(date +%s%N) - s) / 1000000 )); }

echo "1. unset, it is sleep"
between "a whole second is a second"   "$(env -u CG_SLEEP_PCT bash -c "$(declare -f cg_sleep ms); ms cg_sleep 1")" 990 1300
between "  and a half is a half"       "$(env -u CG_SLEEP_PCT bash -c "$(declare -f cg_sleep ms); ms cg_sleep 0.5")" 490 800

echo "2. scaled, for tests"
between "1% of 15s is about 150ms"     "$(CG_SLEEP_PCT=1 bash -c "$(declare -f cg_sleep ms); ms cg_sleep 15")" 140 450
between "50% of 0.25s is about 125ms"  "$(CG_SLEEP_PCT=50 bash -c "$(declare -f cg_sleep ms); ms cg_sleep 0.25")" 115 420

echo "3. the laptop's poll loops use it"
# A loop that goes back to a plain sleep is a suite that goes back to minutes.
check "no plain sleep counts waited"   "$(grep -cE '^\s*sleep [0-9]+; waited=' lib/common.sh)" "0"
check "  every one counts by cg_sleep" "$(grep -cE '^\s*cg_sleep [0-9]+; waited=' lib/common.sh)" "9"
check "pairing's retries too"          "$(grep -cE '^\s*cg_sleep 2' lib/pair.sh)" "4"
check "and game up's wait_for"         "$(grep -c 'cg_sleep 2' lib/game)" "2"
check "  with no plain sleep left in it" "$(grep -cE '(^|;)\s*sleep [0-9]' lib/game)" "0"
# The ones that run ON THE BOX, over ssh, are not cg's to scale: the box has no
# cg_sleep, and those waits are real.
check "the box's Steam wait is untouched" "$(grep -c 'pgrep -x steam >/dev/null || break; sleep 2' cg)" "1"

echo ""
echo "cg-sleep: $pass passed, $fail failed"
(( fail == 0 ))
