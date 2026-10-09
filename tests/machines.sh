#!/usr/bin/env bash
# `cg machines` is the only place that knows what a region rents.
#
# It exists because the desktop app needed an instance-type picker, and a list
# of types in the renderer would go stale the first time the region gained a
# shape. It also has to be honest about two things the old hard-coded type hid:
# that a quota may not cover a shape at all, and that spot prices differ by more
# than 2x between zones while nothing pins the zone.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
jq_() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

# Two shapes that fit a 4 vCPU quota and two that cannot, priced differently in
# the two zones - the real shape of ap-south-2.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-service-quota*L-DB2E81BA*)  echo "${OD_Q:-4.0}" ;;
  *get-service-quota*L-3819A6DF*)  echo "${SP_Q:-4.0}" ;;
  *describe-instance-type-offerings*)
    [[ -n ${NO_OFFERS:-} ]] && exit 0
    printf 'g6.xlarge\tap-south-2a\ng6.xlarge\tap-south-2b\n'
    printf 'g6e.xlarge\tap-south-2a\ng6e.xlarge\tap-south-2b\n'
    printf 'g6.2xlarge\tap-south-2b\n' ;;
  *describe-instance-types*)
    printf 'g6.xlarge\t4\t16384\tL4\t22888\t250\t1\n'
    printf 'g6e.xlarge\t4\t32768\tL40S\t45776\t250\t1\n'
    printf 'g6.2xlarge\t8\t32768\tL4\t22888\t450\t1\n' ;;
  *describe-spot-price-history*)
    # Newest first, as AWS returns it: the stale 2b row must be ignored.
    printf 'g6.xlarge\tap-south-2b\t0.1464\n'
    printf 'g6.xlarge\tap-south-2a\t0.1938\n'
    printf 'g6.xlarge\tap-south-2b\t0.9999\n'
    printf 'g6e.xlarge\tap-south-2b\t0.5534\n'
    printf 'g6e.xlarge\tap-south-2a\t1.1868\n'
    printf 'g6.2xlarge\tap-south-2b\t0.2800\n' ;;
  *get-products*)
    t=""; case "$args" in *g6e.xlarge*) t=2.2384 ;; *g6.xlarge*) t=0.9664 ;; *) t=1.9328 ;; esac
    printf '{"terms":{"OnDemand":{"a":{"priceDimensions":{"b":{"pricePerUnit":{"USD":"%s"}}}}}}}' "$t" ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"

run() { # run [--json|show] ; env overrides honoured
  ( PATH="$T/bin:$PATH" GAME_SPOT="${SPOT:-1}" CG_INR_PER_USD=88 \
    GAME_INSTANCE_TYPE="${CONFIGURED-g6.xlarge}" \
    bash -c 'source lib/config.sh; source lib/machines.sh
             if [[ ${1:-} == --json ]]; then machines_json ap-south-2
             else machines_show ap-south-2 "${2:-}"; fi' _ "$@" 2>&1 )
}

echo "1. every machine fact comes from AWS, none from the script"
j=$(run --json)
check "the configured type is reported" "$(jq_ 'd["configured"]' <<<"$j")" "g6.xlarge"
check "vCPU from describe-instance-types" \
      "$(jq_ '[m["vcpu"] for m in d["machines"] if m["type"]=="g6e.xlarge"][0]' <<<"$j")" "4"
check "GPU name, verbatim" \
      "$(jq_ '[m["gpu"] for m in d["machines"] if m["type"]=="g6e.xlarge"][0]' <<<"$j")" "L40S"
check "VRAM in GB, from MiB" \
      "$(jq_ '[m["vram_gib"] for m in d["machines"] if m["type"]=="g6e.xlarge"][0]' <<<"$j")" "44.7"
check "the instance store, which the archive restore needs" \
      "$(jq_ '[m["store_gb"] for m in d["machines"] if m["type"]=="g6.xlarge"][0]' <<<"$j")" "250"

echo "2. the cheapest zone is the price, and the dearest is disclosed"
# Zones differ by more than 2x and nothing pins the zone, so one number would
# be a promise this cannot keep.
check "cheapest spot price" \
      "$(jq_ '[m["usd_hour_spot"] for m in d["machines"] if m["type"]=="g6.xlarge"][0]' <<<"$j")" "0.1464"
check "  and its zone is named" \
      "$(jq_ '[m["spot_az"] for m in d["machines"] if m["type"]=="g6.xlarge"][0]' <<<"$j")" "ap-south-2b"
check "the dearest zone is reported too" \
      "$(jq_ '[m["usd_hour_spot_max"] for m in d["machines"] if m["type"]=="g6.xlarge"][0]' <<<"$j")" "0.1938"
# AWS returns newest first; a second, older row for the same zone must not win.
check "a stale price for the same zone is ignored" \
      "$(jq_ '[m["usd_hour_spot"] for m in d["machines"] if m["type"]=="g6.xlarge"][0] != 0.9999' <<<"$j")" "True"
check "INR is converted with the rate, not a literal" \
      "$(jq_ '[m["inr_hour_spot"] for m in d["machines"] if m["type"]=="g6e.xlarge"][0]' <<<"$j")" "49"
check "on demand is read from the Pricing API" \
      "$(jq_ '[m["inr_hour_ondemand"] for m in d["machines"] if m["type"]=="g6.xlarge"][0]' <<<"$j")" "85"

echo "3. what a quota cannot cover is marked, not hidden"
check "8 vCPU does not fit a 4 vCPU spot quota" \
      "$(jq_ '[m["fits_spot"] for m in d["machines"] if m["type"]=="g6.2xlarge"][0]' <<<"$j")" "False"
check "  nor the on-demand one" \
      "$(jq_ '[m["fits_ondemand"] for m in d["machines"] if m["type"]=="g6.2xlarge"][0]' <<<"$j")" "False"
check "  but it is still listed" \
      "$(jq_ 'len([m for m in d["machines"] if m["type"]=="g6.2xlarge"])' <<<"$j")" "1"
check "4 vCPU fits both" \
      "$(jq_ '[m["fits_spot"] and m["fits_ondemand"] for m in d["machines"] if m["type"]=="g6.xlarge"][0]' <<<"$j")" "True"

echo "3b. a quota of zero makes a whole purchase model unusable"
j0=$(SP_Q=0.0 run --json)
check "nothing fits spot"      "$(jq_ 'len([m for m in d["machines"] if m["fits_spot"]])' <<<"$j0")" "0"
check "  on demand still does" "$(jq_ 'len([m for m in d["machines"] if m["fits_ondemand"]])' <<<"$j0")" "2"
check "  and the quota is reported" "$(jq_ 'd["quota"]["spot_vcpu"]' <<<"$j0")" "0"

echo "4. cheapest usable first, by the purchase model in force"
check "on spot, the cheap L4 leads" "$(jq_ 'd["machines"][0]["type"]' <<<"$j")" "g6.xlarge"
check "  and the oversized shape sinks" "$(jq_ 'd["machines"][-1]["type"]' <<<"$j")" "g6.2xlarge"

echo "5. the human table shows what you can pick, and counts the rest"
out=$(run show)
contains "the configured type is starred" "$out" "*g6.xlarge"
contains "the other usable shape is offered" "$out" "g6e.xlarge"
lacks    "the unreachable one is not in the table" "$out" "g6.2xlarge "
contains "  but it is counted"            "$out" "1 larger shapes exist here that no quota covers"
contains "and the zone caveat is stated"  "$out" "nothing pins the zone"
contains "with the way to change it"      "$out" "cg config set GAME_INSTANCE_TYPE"
out=$(run show --all)
contains "--all shows everything"         "$out" "g6.2xlarge"
contains "  saying why it cannot be used" "$out" "no quota covers 8 vCPU"

echo "6. an unreadable region says so rather than showing an empty list"
# The failure that started all of this was a report that looked like an answer.
j2=$(NO_OFFERS=1 run --json)
contains "the error is carried" "$j2" '"error"'
check    "and no machines are invented" "$(jq_ 'len(d["machines"])' <<<"$j2")" "0"
out=$(NO_OFFERS=1 run show)
contains "the person is told"   "$out" "no GPU instance types are offered"

echo "7. no price or machine is written down in the script"
check "no instance type literals" \
      "$(grep -cE "g6\.xlarge|g6e\.|L40S" lib/machines.sh)" "0"
check "no INR rate literal"  "$(grep -c 'INR_PER_USD:-88' lib/machines.sh)" "1"
contains "the families are overridable" "$(cat lib/machines.sh)" "CG_MACHINE_FAMILIES"

echo "8. the sandboxes know what cg sources"
# Adding lib/machines.sh to cg broke two suites that copy a fixed list of lib
# files into a sandbox: cg died with a bash error before the first assertion,
# which reads as the feature being broken rather than a file being missing.
# This finds that mismatch directly instead.
sourced=$(grep -oE '^source lib/[a-z-]+\.sh' cg | sed 's|^source lib/||')
for s in $sourced; do
  for suite in tests/init-watchdog.sh tests/destroy-all.sh; do
    if grep -q "lib/$s" "$suite"; then
      echo "  ok   $suite copies $s"; pass=$((pass+1))
    else
      echo "  FAIL $suite does not copy lib/$s, which cg sources"; fail=$((fail+1))
    fi
  done
done

echo ""
echo "machines: $pass passed, $fail failed"
(( fail == 0 ))
