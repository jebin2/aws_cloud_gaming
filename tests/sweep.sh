#!/usr/bin/env bash
# `cg sweep` answers the question `cg machines` structurally cannot: not "what
# does this region rent" but "which region should the box be in at all".
#
# It exists because of a week spent retrying g6.xlarge in ap-south-2 on the
# assumption that spot capacity returns, while get-spot-placement-scores - free,
# and available the whole time - scored ap-south-2 at 1/10 for every type the
# rig can use and ap-south-1 at 9/10. Three things in here are therefore load
# bearing, and each one is a bug that actually happened:
#
#   * the scores must be asked for from a region that SUPPORTS the API. The
#     configured region does not; ap-south-2 answers UnsupportedOperation, and
#     the first version of this reported a dash in the only column it exists for.
#   * a missing score is not a zero. AWS returns nothing for a region that does
#     not offer the type, and printing that as 0 reads as "no capacity" for a
#     machine that was never on sale there.
#   * an unreadable quota is not a zero either. 0 means ask for quota; unreadable
#     means the region needs an opt-in first. Different actions, so they must not
#     collapse into one symbol.
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

# Three regions: the configured one (near, no capacity), a near one with
# capacity, and one so far away no GPU could rescue it. Plus a region that is
# not enabled, which is where the quota becomes unreadable.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *describe-regions*--all-regions*)
    printf 'home-region-1\topted-in\n'
    printf 'near-region-1\topt-in-not-required\n'
    printf 'cold-region-1\tnot-opted-in\n'
    printf 'far-region-1\topt-in-not-required\n' ;;
  *describe-regions*)
    # Without --all-regions AWS lists only enabled regions, which is what the
    # app's picker is allowed to offer.
    [[ -n ${REGIONS_FAIL:-} ]] && exit 1
    printf 'home-region-1\topted-in\n'
    printf 'near-region-1\topt-in-not-required\n'
    printf 'far-region-1\topt-in-not-required\n' ;;
  *get-spot-placement-scores*)
    # The real failure: the API does not exist in the configured region.
    case "$args" in
      *--region\ home-region-1*) echo "An error occurred (UnsupportedOperation)" >&2; exit 254 ;;
    esac
    # g4dn has capacity in near-region-1 only. g6 is offered in the cold region
    # and nowhere else. No row at all for far-region-1, and none for g5
    # anywhere - a type nobody sells must not become a zero.
    case "$args" in
      *g4dn.xlarge*) printf 'near-region-1\t9\nhome-region-1\t1\n' ;;
      *g6.xlarge*)   printf 'cold-region-1\t9\nhome-region-1\t1\n' ;;
    esac ;;
  *get-parameter*longName*)
    case "$args" in
      *home-region-1*) echo "Asia Pacific (Hometown)" ;;
      *near-region-1*) echo "Asia Pacific (Nearby)" ;;
      *cold-region-1*) echo "Asia Pacific (Faraway)" ;;
      *) echo None ;;
    esac ;;
  *get-service-quota*L-DB2E81BA*) echo "${OD_Q:-4.0}" ;;
  *get-service-quota*L-3819A6DF*) echo "${SP_Q:-0.0}" ;;
  *describe-instance-type-offerings*)
    case "$args" in *home-region-1*) printf 'g6.xlarge\n' ;;
                    *near-region-1*) printf 'g4dn.xlarge\n' ;; esac ;;
  *describe-spot-price-history*)
    case "$args" in *near-region-1*) printf 'g4dn.xlarge\t0.2102\n' ;;
                    *home-region-1*) printf 'g6.xlarge\t0.1505\n' ;; esac ;;
  *get-products*)
    t=""; case "$args" in *g4dn.xlarge*) t=0.5790 ;; *g6.xlarge*) t=0.9664 ;; esac
    [[ -n $t ]] && printf '{"terms":{"OnDemand":{"a":{"priceDimensions":{"b":{"pricePerUnit":{"USD":"%s"}}}}}}}' "$t" ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"

# A latency probe that answers by region name, so the budget can be tested
# without a network. far-region-1 is past 80ms; the rest are not.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *far-region-1*)  echo -n 0.250000; exit 0 ;;
    *cold-region-1*) echo -n 0.048000; exit 0 ;;
    *near-region-1*) echo -n 0.022000; exit 0 ;;
    *home-region-1*) echo -n 0.019000; exit 0 ;;
  esac
done
exit 1
FAKE
chmod +x "$T/bin/curl"

run() { # run <extra env assignments...> -- runs sweep_json with the stubs
  env PATH="$T/bin:$PATH" HOME="$T" REGION=home-region-1 GAME_REGION=home-region-1 \
      CG_SWEEP_SAMPLES=1 CG_INR_PER_USD=88 "$@" \
      bash -c 'source lib/common.sh >/dev/null 2>&1; source lib/rates.sh
               source lib/machines.sh; source lib/sweep.sh; sweep_json' 2>/dev/null
}

echo "1. the scores are asked for from a region that supports the API"
# This is the whole bug: the configured region answers UnsupportedOperation, so
# every score came back empty and the column the command exists for read "-".
out=$(run)
check "near-region-1 scores 9 for g4dn" \
      "$(jq_ '[m["score"] for r in d["regions"] if r["region"]=="near-region-1" for m in r["machines"] if m["type"]=="g4dn.xlarge"][0]' <<<"$out")" "9"
check "  and the home region scores 1"  \
      "$(jq_ '[m["score"] for r in d["regions"] if r["region"]=="home-region-1" for m in r["machines"] if m["type"]=="g6.xlarge"][0]' <<<"$out")" "1"
# Proof it fell back rather than guessed: an explicit source region that also
# refuses must produce no scores at all.
none=$(run CG_SWEEP_FROM=home-region-1)
check "  pinning the unsupported region yields no score" \
      "$(jq_ 'sum(1 for r in d["regions"] for m in r["machines"] if m["score"] is not None)' <<<"$none")" "0"

echo "2. a region AWS said nothing about is unscored, not zero"
check "g5 is absent everywhere, so it is not listed at all" \
      "$(jq_ 'sum(1 for r in d["regions"] for m in r["machines"] if m["type"]=="g5.xlarge")' <<<"$out")" "0"
# far-region-1 never appears in a score answer AND is beyond the budget; it must
# be reported as too far rather than as a scored region with nothing in it.
check "the far region is excluded by latency" \
      "$(jq_ '[r["region"] for r in d["too_far"]]' <<<"$out")" "['far-region-1']"
lacks "  and is not among the candidates" \
      "$(jq_ '[r["region"] for r in d["regions"]]' <<<"$out")" "far-region-1"

echo "3. an unreadable quota is not a zero quota"
check "the cold region's quota is null, not 0" \
      "$(jq_ '[r["quota"] for r in d["regions"] if r["region"]=="cold-region-1"][0]' <<<"$out")" "None"
check "  and it is marked not enabled" \
      "$(jq_ '[r["enabled"] for r in d["regions"] if r["region"]=="cold-region-1"][0]' <<<"$out")" "False"
check "an enabled region reports both numbers" \
      "$(jq_ '[r["quota"]["spot_vcpu"] for r in d["regions"] if r["region"]=="near-region-1"][0]' <<<"$out")" "0"
show=$(env PATH="$T/bin:$PATH" HOME="$T" REGION=home-region-1 GAME_REGION=home-region-1 \
        CG_SWEEP_SAMPLES=1 CG_INR_PER_USD=88 \
        bash -c 'source lib/common.sh >/dev/null 2>&1; source lib/rates.sh
                 source lib/machines.sh; source lib/sweep.sh; sweep_show' 2>/dev/null)
contains "the table says opt-in where the quota could not be read" "$show" "opt-in"
contains "  and 0 where it is genuinely zero"  "$show" "ok/0"
contains "  and explains the difference"       "$show" "the quota cannot be read yet"

echo "4. capacity outranks nearness, because that is the finding"
# The home region is nearest and has quota, and is still the wrong answer. If
# this sorts by latency the command tells you to stay where you are.
check "the first region listed is the one with capacity" \
      "$(jq_ 'd["regions"][0]["region"]' <<<"$out")" "near-region-1"
contains "  and the home region is marked, not hidden" "$show" "*home-region-1"

echo "5. an on-demand price is read even where nothing else can be"
# The Pricing API answers for a region that is not enabled, which is the only
# number available before opting in - and so the only way to cost the move.
check "the cold region is priced" \
      "$(jq_ '[m["inr_hour_ondemand"] for r in d["regions"] if r["region"]=="cold-region-1" for m in r["machines"]][0]' <<<"$out")" "85"
check "  but has no spot price, which needs the region enabled" \
      "$(jq_ '[m["inr_hour_spot"] for r in d["regions"] if r["region"]=="cold-region-1" for m in r["machines"]][0]' <<<"$out")" "None"

echo "6. when nothing can be measured, nothing is excluded"
# curl being INSTALLED proves nothing: behind a firewall that blocks outbound
# 443 every probe fails, and a budget applied to that would exclude all 34
# regions and claim nowhere on earth can stream. So the code asks whether any
# measurement arrived, which is what this stub takes away.
cat > "$T/bin/curl" <<'DEAD'
#!/usr/bin/env bash
exit 7
DEAD
chmod +x "$T/bin/curl"
nocurl=$(run)
check "no region is dropped for latency" \
      "$(jq_ 'len(d["too_far"])' <<<"$nocurl")" "0"
check "  nor moved to unreachable"      "$(jq_ 'len(d["unreachable"])' <<<"$nocurl")" "0"
check "  and latency is reported as unmeasured" \
      "$(jq_ 'd["measured"]' <<<"$nocurl")" "False"
check "  every region is still a candidate" \
      "$(jq_ 'len(d["regions"])' <<<"$nocurl")" "4"
nshow=$(env PATH="$T/bin:$PATH" HOME="$T" REGION=home-region-1 GAME_REGION=home-region-1 \
        CG_SWEEP_SAMPLES=1 CG_INR_PER_USD=88 \
        bash -c 'source lib/common.sh >/dev/null 2>&1; source lib/rates.sh
                 source lib/machines.sh; source lib/sweep.sh; sweep_show' 2>/dev/null)
contains "the table admits it did not measure" "$nshow" "could NOT be measured"
lacks "  and does not claim a budget it never applied" "$nshow" "the budget is 80ms"
# One region answering is enough to filter on: the others become unreachable
# rather than silently passing the budget they were never measured against.
cat > "$T/bin/curl" <<'ONE'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *near-region-1*) echo -n 0.022000; exit 0 ;; esac; done
exit 7
ONE
chmod +x "$T/bin/curl"
one=$(run)
check "the measured region is a candidate" \
      "$(jq_ '[r["region"] for r in d["regions"]]' <<<"$one")" "['near-region-1']"
check "  and the unmeasured ones are listed as such" \
      "$(jq_ 'len(d["unreachable"])' <<<"$one")" "3"

echo "7. the region list for the app is one call, and keeps the current region"
reg=$(env PATH="$T/bin:$PATH" HOME="$T" REGION=home-region-1 GAME_REGION=home-region-1 \
      bash -c 'source lib/common.sh >/dev/null 2>&1; source lib/machines.sh
               source lib/sweep.sh; regions_json' 2>/dev/null)
check "only enabled regions are offered" \
      "$(jq_ '[r["region"] for r in d["regions"]]' <<<"$reg")" \
      "['far-region-1', 'home-region-1', 'near-region-1']"
lacks "  a region needing an opt-in is not offered" "$reg" "cold-region-1"
# A picker that silently drops the configured value looks like the setting was
# lost, and the first thing anyone does then is set it again by hand.
lost=$(env PATH="$T/bin:$PATH" HOME="$T" REGION=home-region-1 GAME_REGION=home-region-1 \
       REGIONS_FAIL=1 bash -c 'source lib/common.sh >/dev/null 2>&1
               source lib/machines.sh; source lib/sweep.sh; regions_json' 2>/dev/null)
check "the current region survives a failed listing" \
      "$(jq_ '[r["region"] for r in d["regions"]]' <<<"$lost")" "['home-region-1']"

echo "8. cg takes a region argument where it used to swallow it"
# `cg machines ap-south-1 --all` reported the CURRENT region and dropped --all,
# because the dispatch passed $1 straight through as the flag.
contains "the dispatch recognises a region" "$(cat cg)" 'MREG=$1; shift; else MREG=$REGION'
contains "and machines_show gets the flag after it" "$(cat cg)" 'machines_show "$MREG" "${1:-}"'
contains "sweep has its own command"       "$(cat cg)" 'sweep|regions-sweep)'
contains "and regions does too"            "$(cat cg)" 'regions)   if (( JSON )); then regions_json'

echo "9. the region setting is shape-checked, because it used to be free text"
v() { bash -c 'source lib/common.sh >/dev/null 2>&1; source lib/config.sh
                config_validate GAME_REGION "$1"' _ "$1" 2>/dev/null; }
check "a real region passes"        "$(v ap-south-1)" ""
check "  so does a three-part name" "$(v us-gov-west-1)" ""
contains "a typo is refused"        "$(v ap-sout-1x)" "does not look like an AWS region"
contains "  and so is a bucket name pasted in" "$(v my-bucket)" "does not look like an AWS region"
check "the kind is declared region" \
      "$(bash -c 'source lib/common.sh >/dev/null 2>&1; source lib/config.sh
                  config_field GAME_REGION 2' 2>/dev/null)" "region"
contains "and the registry warns the archive stays behind" \
      "$(bash -c 'source lib/common.sh >/dev/null 2>&1; source lib/config.sh
                  config_field GAME_REGION 5' 2>/dev/null)" "archive does not follow"

echo "10. every call in here is free, and none of them launch anything"
body=$(cat lib/sweep.sh)
for verb in run-instances request-spot-instances create-bucket terminate-instances \
            enable-region modify-instance create-tags start-instances; do
  lacks "sweep never calls $verb" "$body" "$verb"
done

echo "11. the app reads this, and is warned what a move costs"
js=$(cat app/renderer/app.js); main=$(cat app/main/index.js)
contains "the sweep is a free read"       "$main" "'sweep']"
# --cached, never a scan, on the path an opening window takes: a scan is 90
# seconds and no screen may wait on one.
contains "the app reads the remembered scan" "$js" "[['sweep', '--cached', '--json'], 'sweep']"
lacks    "  and never scans at startup"      "$js" "[['sweep', '--json'], 'sweep'],"
contains "  rescanning is a button"          "$js" "function scanRegions"
contains "the answer has a painter"          "$js" "sweep: paintSweep"
# The table is the only control, and a row is a region AND a machine.
contains "rows are built from the sweep"     "$js" "for (const r of sweepNow.regions)"
contains "  and fall back to this region"    "$js" "machinesNow.machines"
contains "  a price cell is the control"     "$js" "function priceCell"
# A region change is the most expensive setting in the app and the least
# obviously so, because nothing visibly breaks until the next build reinstalls
# 163GB it could have kept.
contains "moving region asks first"          "$js" "Move to \${row.region} on \${row.type}?"
contains "  and says the archive stays put"  "$js" "does not follow"
contains "  and that nothing is deleted"     "$js" "Nothing is deleted or moved"
contains "  and is marked destructive"       "$js" "danger: moving"
# Three settings, one decision - written together, region last.
contains "the type is written"               "$js" "'config', 'set', 'GAME_INSTANCE_TYPE'"
contains "  the model too"                   "$js" "'config', 'set', 'GAME_SPOT'"
contains "  and the region last of the three" "$js" "if (moving) await runCg(['config', 'set', 'GAME_REGION'"
# The app must never enable a region: that is an account-level change, and the
# table marks an unenabled region unpickable precisely so it cannot try.
lacks "the app never opts a region in"       "$js" "enable-region"
lacks "  nor the main process"               "$main" "enable-region"
contains "  it says so in the cell"          "$js" "needs opt-in"

echo ""
echo "sweep: $pass passed, $fail failed"
(( fail == 0 ))
