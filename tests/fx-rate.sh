#!/usr/bin/env bash
# The rupee rate: today's, fetched at most once a day, never a guess.
#
# lib/rates.sh used to say 88 and nothing else; by October 2026 the rupee was
# near 95, and every rupee figure in cg and the app was about 7% low. It now
# asks an exchange-rate endpoint once a day and keeps the answer. This drives
# it against a local file - curl reads file:// URLs - so it never touches the
# network.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"

check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
# rate <url> [env...]: what lib/rates.sh settles on, in a clean shell.
rate() { local url=$1; shift
  env -u CG_INR_PER_USD "$@" CG_FX_URL="$url" bash -c 'source lib/rates.sh; echo "$CG_INR_PER_USD"'; }
CACHE="$HOME/.cache/cg/inr-per-usd"

printf '{"value":94.94651,"rates":{"INR":94.94651}}' > "$T/good.json"
printf '{"value":5000}' > "$T/silly.json"
printf 'not json' > "$T/broken.json"

echo "1. the endpoint answers"
check "today's rate, to two places"       "$(rate "file://$T/good.json")" "94.95"
check "  and kept for the day"            "$(cat "$CACHE")" "94.95"

echo "2. the same day, it is not asked again"
printf '{"value":80}' > "$T/good.json"
check "the cached rate, not the new one"  "$(rate "file://$T/good.json")" "94.95"

echo "3. a day later it is"
touch -d '2 days ago' "$CACHE"
check "the new rate"                      "$(rate "file://$T/good.json")" "80.00"

echo "4. a broken answer is not believed"
touch -d '2 days ago' "$CACHE"
check "5000 rupees to the dollar: the last good rate" "$(rate "file://$T/silly.json")" "80.00"
touch -d '2 days ago' "$CACHE"
check "not json: the last good rate"      "$(rate "file://$T/broken.json")" "80.00"
touch -d '2 days ago' "$CACHE"
check "unreachable: the last good rate"   "$(rate "file://$T/missing.json")" "80.00"

echo "5. never fetched and unreachable"
check "88, and only then"                 "$(rate "file://$T/missing.json" HOME="$T/empty")" "88"

echo "6. a rate set by hand wins"
check "it is used"                        "$(CG_INR_PER_USD=90 CG_FX_URL="file://$T/good.json" bash -c 'source lib/rates.sh; echo "$CG_INR_PER_USD"')" "90"
check "  and nothing is fetched"          "$(ls "$T/empty/.cache" 2>/dev/null | wc -l)" "0"

echo ""
echo "fx-rate: $pass passed, $fail failed"
(( fail == 0 ))
