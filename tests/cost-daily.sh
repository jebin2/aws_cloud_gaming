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

echo "4b. --json: the same answer as data"
# section 4 left IN pointing at an empty file; this one wants the fixture.
j=$(IN="$T/ce.json" daily --json)
jq_() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k)
print(json.dumps(d))' "$1" <<<"$j"; }
check "one row per day that billed"   "$(jq_ days | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "2"
check "  with its hours"              "$(jq_ days.0.hours)" "3.3"
check "  compute for that day"        "$(jq_ days.0.compute)" "3.2"
check "the month total"               "$(jq_ total_usd)" "3.76"
check "  in rupees too"               "$(jq_ total_inr)" "331"
check "hours by purchase model"       "$(jq_ hours.on_demand)" "3.3"
check "  and spot"                    "$(jq_ hours.spot)" "2.0"
check "the rate actually paid"        "$(jq_ usd_per_hour.spot)" "0.21"
check "egress used"                   "$(jq_ egress.gb_used)" "9.4"
check "  and what is left of the free 100 GB" "$(jq_ egress.gb_left)" "90.6"
check "usage types, dearest first"    "$(jq_ usage.0.type)" '"BoxUsage:g6.xlarge"'
check "a broken answer is an empty object" "$(IN="$T/bad.json" daily --json)" "{}"

echo "4c. the prices come with the answer"
# The desktop app must never hold a price. cg publishes the table it uses, and
# works out the standby burn itself, so a screen only renders what it is given.
mkdir -p "$T/bin" "$T/repo"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
printf 'GAME_S3_BUCKET=cg-library-test\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\n' > "$T/repo/.env"
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"ce get-cost-and-usage"*) echo '[{"d":"2026-09-16","g":[]}]' ;;
  *accountPlanRemainingCredits*) echo 139.35 ;;
  *"s3 ls"*) printf 'Total Objects: 10\n   Total Size: 171986001052\n' ;;
  *"describe-volumes"*sum*) echo 50 ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"
cj=$( cd "$T/repo" && env -i PATH="$T/bin:$PATH" HOME="$T/home" CG_COLOR=never \
        bash lib/setup cost --json 2>/dev/null )
jq2() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d))' "$1" <<<"$cj"; }
check "the S3 price is published"      "$(jq2 rates.s3_gb_month)" "0.025"
check "  the EBS price too"            "$(jq2 rates.ebs_gb_month)" "0.0912"
check "  the egress price"             "$(jq2 rates.egress_gb)" "0.1093"
check "  and what a refresh costs"     "$(jq2 rates.ce_call_usd)" "0.01"
check "the rupee rate is one number"   "$(jq2 rates.inr_per_usd)" "88.0"
# 160.2 GB archive at $0.025 + a 50 GB volume at $0.0912
check "standby is worked out by cg"    "$(jq2 standby.usd_month)" "8.56"
check "  and per day"                  "$(jq2 standby.usd_day)" "0.2853"
check "  split by what holds it"       "$(jq2 standby.volumes_usd_month)" "4.56"

echo "5. wired in"
check "cg passes the flag through"     "$(grep -c 'lib/setup cost "$@"' cg)" "1"
check "both daily paths ask Cost Explorer the same way" "$(grep -c 'granularity DAILY' lib/setup)" "2"
check "  and renders the summary from it"         "$(grep -c 'cost-daily.py --aggregate' lib/setup)" "1"
check "cg help mentions it"            "$(grep -c 'cg cost \[--daily\]' cg)" "1"
check "cg cost --json is one object"  "$(grep -c 'exec lib/setup cost --json' cg)" "1"
check "the prices live in one file"   "$(grep -c 'CG_S3_USD_GB_MONTH=' lib/rates.sh)" "1"
check "  and nowhere else in cg"      "$(grep -c '0\.0912\|0\.1093' lib/setup cg lib/game | grep -vc ':0')" "0"
check "  built from the same call"    "$(grep -c 'cost-daily.py --json' lib/setup)" "1"
# The archive is the only thing still billing with no box, so cg cost says when it goes.
check "cost shows the archive countdown"  "$(sed -n '/^cost() {/,/^}/p' lib/setup | grep -c 'game archive    %s')" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
