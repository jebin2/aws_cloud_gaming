#!/usr/bin/env bash
# `cg cost --daily`: the day-by-day table, and the promise that it costs no more
# than `cg cost` - Cost Explorer bills $0.01 per request, so the daily answer is
# also what the monthly summary is rendered from (lib/cost-daily.py --aggregate).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

# Two days that billed and one that did not, with a usage type for every column.
cat > "$T/ce.json" <<'JSON'
[{"d":"2026-09-14","g":[{"u":"APS5-BoxUsage:g6.xlarge","c":"3.20","q":"3.3"},
                        {"u":"APS5-TimedStorage-ByteHrs","c":"0.07","q":"2.8"},
                        {"u":"APS5-DataTransfer-Out-Bytes","c":"0","q":"9.4"},
                        {"u":"USE1-APIRequest","c":"0.01","q":"1"}]},
 {"d":"2026-09-15","g":[]},
 {"d":"2026-09-16","g":[{"u":"APS5-SpotUsage:g6.xlarge","c":"0.42","q":"2.0"},
                        {"u":"APS5-EBS:VolumeUsage.gp3","c":"0.05","q":"1.1"},
                        {"u":"APS5-PublicIPv4:InUseAddress","c":"0.01","q":"2.0"}]}]
JSON

daily() { python3 "$REPO/lib/cost-daily.py" "$@" < "${IN:-$T/ce.json}" 2>&1; }

echo "1. the table"
r=$(daily)
contains "a column per kind of charge" "$r" "DATE          HRS  COMPUTE       S3     DISK   EGRESS      API    OTHER    TOTAL     INR"
contains "a day with a box: its hours" "$r" "2026-09-14    3.3     3.20     0.07"
contains "  and its total in INR"      "$r" "3.28     289"
contains "spot hours count as compute" "$r" "2026-09-16    2.0     0.42"
contains "  the volume as disk"        "$r" "0.42        -     0.05"
contains "  and the IPv4 as other"     "$r" "0.01     0.48      42"
contains "the month's total"           "$r" "TOTAL         5.3     3.62     0.07     0.05        -     0.01     0.01     3.76     331"

echo "2. what is not shown"
lacks    "a day with nothing billed is left out" "$r" "2026-09-15"
contains "  but counted"                         "$r" "1 day(s) with nothing billed are not shown"
contains "free egress shows as a dash, not 0.00" "$r" "0.07        -"

echo "3. the same answer feeds the monthly summary, so there is only one API call"
agg=$(daily --aggregate)
check    "valid JSON"                  "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' <<<"$agg")" "7"
# lib/cost-report.py caches the egress figure in ./.cg-cache, so run it elsewhere.
r=$(cd "$T" && python3 "$REPO/lib/cost-report.py" <<<"$agg" 2>&1)
contains "the usage-type table"        "$r" "USAGE TYPE"
contains "  on-demand hours"           "$r" "3.3 h on demand"
contains "  spot hours"                "$r" "2.0 h on spot"
contains "  the same month total"      "$r" "3.76"
contains "  and the egress allowance"  "$r" "9.4 GB of 100 GB free"
check    "  which it caches for cg status" "$(cut -d' ' -f2 "$T/.cg-cache/egress")" "9.400"

echo "4. nothing billed, or no answer at all"
IN=/dev/null; printf '[]' > "$T/empty.json"
r=$(IN="$T/empty.json" daily)
contains "an empty month says so"      "$r" "nothing billed yet this month"
printf 'not json' > "$T/bad.json"
r=$(IN="$T/bad.json" daily)
contains "a broken answer is said"     "$r" "(Cost Explorer unavailable)"
check    "  and aggregates to nothing" "$(IN="$T/bad.json" daily --aggregate)" "[]"

echo "5. wired in"
check "cg passes the flag through"     "$(grep -c 'lib/setup cost "$@"' cg)" "1"
check "setup asks Cost Explorer once, day by day" "$(grep -c 'granularity DAILY' lib/setup)" "1"
check "  and renders the summary from it"         "$(grep -c 'cost-daily.py --aggregate' lib/setup)" "1"
check "cg help mentions it"            "$(grep -c 'cg cost \[--daily\]' cg)" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
