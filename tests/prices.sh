#!/usr/bin/env bash
# Every price is AWS's own, read from the Price List API - none written down.
#
# A table typed in once had drifted: disk copies were priced at the archive
# tier, a quarter of what AWS charges, and AWS can change any price on any day.
# lib/prices.py asks the Price List API (free) for the region in use, and
# lib/rates.sh keeps the answer for a day. This drives both against a fake
# `aws`, so nothing here touches the network.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME" "$T/bin"

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

# A fake Price List API. Each product is answered by usage type, the way the
# real one is; the disk is found by region and volume type, and its usage type
# carries the billing prefix ("APS5-") the others are asked by. Several tiers,
# out of order, and a free one: the first paid tier is the price.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
[[ -n ${PRICING_DOWN:-} ]] && exit 255
prod() { # prod <usagetype> <usd:begin>...
  local ut=$1; shift; local dims="" i=0 p
  for p in "$@"; do
    dims+="${dims:+,}\"d$i\":{\"unit\":\"x\",\"beginRange\":\"${p#*:}\",\"pricePerUnit\":{\"USD\":\"${p%%:*}\"}}"
    i=$((i+1))
  done
  python3 -c 'import json,sys; print(json.dumps({"PriceList":[json.dumps({"product":{"attributes":{"usagetype":sys.argv[1]}},
    "terms":{"OnDemand":{"t":{"priceDimensions":json.loads(sys.argv[2])}}}})]}))' "$ut" "{$dims}"
}
case "$*" in
  *"regionCode,Value=ap-south-2"*"volumeApiName,Value=gp3"*) prod APS5-EBS:VolumeUsage.gp3 0.0912:0 ;;
  *"regionCode,Value=nowhere-1"*) echo '{"PriceList":[]}' ;;
  *"usagetype,Value=APS5-EBS:SnapshotUsage"*)        prod APS5-EBS:SnapshotUsage 0.05:0 ;;
  *"usagetype,Value=APS5-TimedStorage-ByteHrs"*)     prod APS5-TimedStorage-ByteHrs 0.023:512000 0.025:0 0.024:51200 ;;
  *"usagetype,Value=APS5-PublicIPv4:InUseAddress"*)  prod APS5-PublicIPv4:InUseAddress 0.005:0 ;;
  *"usagetype,Value=APS5-DataTransfer-Out-Bytes"*)   prod APS5-DataTransfer-Out-Bytes 0.085:10240 0:0 0.1093:0 ;;
  *"usagetype,Value=APS5-AWS-Out-Bytes"*)            prod APS5-AWS-Out-Bytes 0.086:0 ;;
  *"usagetype,Value=USE1-APIRequest"*)               prod USE1-APIRequest 0.01:0 ;;
  *) echo '{"PriceList":[]}' ;;
esac
FAKE
chmod +x "$T/bin/aws"
export CALLS="$T/calls" PATH="$T/bin:$PATH"
: > "$CALLS"

echo "1. lib/prices.py reads each price from the Price List API"
out=$(python3 lib/prices.py ap-south-2); rc=$?
check    "it succeeds"                      "$rc" "0"
contains "the disk"                         "$out" "CG_EBS_USD_GB_MONTH=0.0912"
contains "a disk copy at the standard tier" "$out" "CG_SNAPSHOT_USD_GB_MONTH=0.05"
contains "S3, its first tier"               "$out" "CG_S3_USD_GB_MONTH=0.025"
contains "the address"                      "$out" "CG_IPV4_USD_HOUR=0.005"
contains "data out, its first paid tier"    "$out" "CG_EGRESS_USD_GB=0.1093"
contains "data to another region"           "$out" "CG_XREGION_USD_GB=0.086"
contains "a bill check"                     "$out" "CG_CE_CALL_USD=0.01"
check    "one --filters per call (the CLI keeps only the last)" \
         "$(grep -c -- '--filters.*--filters' "$CALLS")" "0"
out=$(python3 lib/prices.py nowhere-1); rc=$?
check    "a region with no prices: it fails" "$rc" "1"
check    "  and prints nothing, not a half table" "$out" ""

echo "2. lib/rates.sh: from AWS, kept a day"
rates() { env -u CG_PRICES_FILE -u CG_S3_USD_GB_MONTH -u CG_EBS_USD_GB_MONTH -u CG_SNAPSHOT_USD_GB_MONTH \
            -u CG_EGRESS_USD_GB -u CG_CE_CALL_USD -u CG_XREGION_USD_GB -u CG_IPV4_USD_HOUR \
            -u CG_TAX_PCT -u CG_FX_INR_PER_USD "$@" CG_INR_PER_USD=100 \
            bash -c 'source lib/rates.sh; echo "$CG_SNAPSHOT_USD_GB_MONTH $CG_S3_USD_GB_MONTH $CG_INR_PER_USD"'; }
: > "$CALLS"
check    "the prices are AWS's"             "$(rates REGION=ap-south-2 CG_TAX_PCT=0)" "0.05 0.025 100"
check    "  and cached for the region"      "$(grep -c '' "$HOME/.cache/cg/prices-ap-south-2")" "7"
n=$(wc -l < "$CALLS")
rates REGION=ap-south-2 CG_TAX_PCT=0 >/dev/null
check    "the same day, AWS is not asked again" "$(wc -l < "$CALLS")" "$n"
touch -d '2 days ago' "$HOME/.cache/cg/prices-ap-south-2"
check    "a day old and AWS down: the last answer stands" \
         "$(rates REGION=ap-south-2 CG_TAX_PCT=0 PRICING_DOWN=1)" "0.05 0.025 100"
rm -f "$HOME/.cache/cg/prices-ap-south-2"
check    "never read and AWS down: unknown, not a guess" \
         "$(rates REGION=ap-south-2 CG_TAX_PCT=0 PRICING_DOWN=1)" "  100"
j=$(env -u CG_PRICES_FILE -u CG_S3_USD_GB_MONTH -u CG_SNAPSHOT_USD_GB_MONTH REGION=ap-south-2 PRICING_DOWN=1 \
      CG_INR_PER_USD=100 bash -c 'source lib/rates.sh; rates_json')
check    "  and null in the table, never 0" \
         "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["s3_gb_month"], d["snapshot_gb_month"])' <<<"$j")" "None None"
check    "a price set by hand wins"         "$(rates REGION=ap-south-2 CG_TAX_PCT=0 CG_S3_USD_GB_MONTH=0.5)" "0.05 0.5 100"

echo "3. GST: AWS India adds 18% to every charge"
gst() { env -u CG_FX_INR_PER_USD "$@" bash -c 'source lib/rates.sh; echo "$CG_FX_INR_PER_USD $CG_INR_PER_USD"; source lib/rates.sh; echo "$CG_INR_PER_USD"' | paste -sd' '; }
check    "a dollar of charges is the rate plus the tax" "$(gst CG_INR_PER_USD=100 CG_TAX_PCT=18)" "100 118 118"
check    "  added once, however often it is sourced"    "$(gst CG_INR_PER_USD=100 CG_TAX_PCT=18 | cut -d' ' -f3)" "118"
check    "  and none for an account billed elsewhere"    "$(gst CG_INR_PER_USD=94.95 CG_TAX_PCT=0)" "94.95 94.95 94.95"

echo "4. no price is written down anywhere"
# AWS's prices as they were typed in before - any of them back in code is a
# price that stops being true the day AWS changes it. Comments may name them.
code() { grep -nE "$1" cg lib/setup lib/game lib/*.sh lib/*.py lambda/*.py app/renderer/app.js \
           | grep -vE '^[^:]+:[0-9]+:\s*(#|//|\*)' | grep -v 'lib/rates.sh:.*CG_EGRESS_FREE_GB\|CG_TAX_PCT:-18'; }
check    "no AWS price literal"      "$(code '(^|[^0-9.])0\.(0912|1093|086|0125|025|05|005)([^0-9]|$)' | wc -l)" "0"
# The forms the fixed 88 took: a default, an "or", a constant, a multiplier.
check    "no rupee rate literal"     "$(code 'INR_PER_USD:-[0-9]|INR_PER_USD"\) or [0-9]|INR_PER_USD = [0-9]|[*/] *88([^0-9]|$)|= *88\.0' | wc -l)" "0"
# Nor any other fact about a machine or a build that AWS or a measurement
# knows better: the disk was 229 GB everywhere, the build "10-20 min".
check    "no fixed game disk size"   "$(code '(disk_gb|DISK_GB)[^,]*(229|:-2[0-9]{2})|\b229 GB fits' | wc -l)" "0"
check    "no promised build time"    "$(code '10-20 min|10–20 min|10 to 20 min' | wc -l)" "0"
check    "no watchdog minutes copied" "$(code 'cw_int "[^"]*" [0-9]|idle_min \|\| [0-9]|rate\(5 minutes\)' | wc -l)" "0"
check    "the free allowance and GST are the only two, in one file" \
         "$(grep -cE '^CG_(EGRESS_FREE_GB|TAX_PCT)=' lib/rates.sh)" "2"

echo
echo "prices: $pass passed, $fail failed"
(( fail == 0 ))
