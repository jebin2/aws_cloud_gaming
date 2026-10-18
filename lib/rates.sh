#!/usr/bin/env bash
# The prices, in one place.
#
# They were spread across awk one-liners in three files and had begun to leak
# into the desktop app, which is exactly the drift the app rule exists to stop:
# the scripts are the source of truth, so a price the app prints must have come
# from a command, and a price cg prints must have come from here.
#
# None of them is written down. AWS can change any price at any time, and a
# table typed in once had already drifted: disk copies were priced at the
# archive tier, a quarter of what AWS charges for them. Every AWS price is read
# from AWS's Price List API (free) for the region in use - lib/prices.py - and
# kept for a day in the cache. If AWS cannot be asked, the last answer stands;
# if there has never been one, the price is left unset, and every figure built
# on it reads as unknown rather than as a guess.
#
# A price set in the environment wins and nothing is asked. So does a file of
# KEY=value lines named by CG_PRICES_FILE - which is how the tests run offline.

CG_RATE_KEYS="CG_S3_USD_GB_MONTH CG_EBS_USD_GB_MONTH CG_SNAPSHOT_USD_GB_MONTH CG_EGRESS_USD_GB CG_CE_CALL_USD CG_XREGION_USD_GB CG_IPV4_USD_HOUR"

# cg_prices <region> - AWS's prices for that region, KEY=value lines: the
# cache when under a day old, else asked again; a stale cache beats nothing.
cg_prices() {
  local region=$1 cache v
  [[ -n $region ]] || return 1
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/cg/prices-$region"
  if [[ -s $cache ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < 86400 )); then
    cat "$cache"; return 0
  fi
  if v=$(python3 "$(dirname "${BASH_SOURCE[0]}")/prices.py" "$region" 2>/dev/null) && [[ -n $v ]]; then
    mkdir -p "${cache%/*}" 2>/dev/null && printf '%s\n' "$v" > "$cache.new" 2>/dev/null \
      && mv -f "$cache.new" "$cache" 2>/dev/null
    printf '%s\n' "$v"; return 0
  fi
  [[ -s $cache ]] && { cat "$cache"; return 0; }
  return 1
}

# cg_price <region> <KEY> - one price for a region other than the one in use:
# moving games out of a region is billed at THAT region's rate.
cg_price() {
  if [[ -n ${CG_PRICES_FILE:-} && -r $CG_PRICES_FILE ]]; then
    sed -n "s/^$2=//p" "$CG_PRICES_FILE" | head -1; return 0
  fi
  cg_prices "$1" | sed -n "s/^$2=//p" | head -1
}

# Fill in whatever is not set already: from the file if one is named, else AWS.
_cg_rates_fill() {
  local k v src
  for k in $CG_RATE_KEYS CG_TAX_PCT CG_EGRESS_FREE_GB; do [[ -n ${!k:-} ]] || src=1; done
  [[ -n ${src:-} ]] || return 0
  if [[ -n ${CG_PRICES_FILE:-} && -r $CG_PRICES_FILE ]]; then
    src=$(cat "$CG_PRICES_FILE")
  else
    src=$(cg_prices "${REGION:-${GAME_REGION:-}}") || src=""
  fi
  while IFS='=' read -r k v; do
    [[ $k =~ ^CG_[A-Z0-9_]+$ && -n $v && -z ${!k:-} ]] && printf -v "$k" '%s' "$v"
  done <<<"$src"
  return 0
}
_cg_rates_fill

# The two figures no AWS API reports, so they are the only ones written here.
# The free allowance for data out to the internet: AWS's Free Tier, 100 GB a
# month across every region since 2021 - not in the price list, which starts at
# the first paid GB.
CG_EGRESS_FREE_GB="${CG_EGRESS_FREE_GB:-100}"
# GST. An account in India is billed by AWS India, which adds 18% GST to every
# charge - verified on this account's invoices (the seller, and the tax line).
# Cost Explorer and the price list are both before tax, so every rupee figure
# was 18% under what is paid. It is the law, not an AWS price: set
# CG_TAX_PCT=0 for an account billed somewhere else.
CG_TAX_PCT="${CG_TAX_PCT:-18}"

# The rupee rate: today's, not a number written down once. Fetched at most
# once a day from an exchange-rate endpoint and kept in a cache file; if the
# fetch fails, the last good rate stands, and with none it is unknown. A rate
# set in the environment or .env wins and nothing is fetched. The request
# carries nothing about this laptop - "USD to INR, 1" - and no AWS call is made.
CG_FX_URL="${CG_FX_URL:-https://jeapis.netlify.app/.netlify/functions/currency?from=USD&to=INR&amount=1}"
cg_fx_inr() {
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/cg/inr-per-usd" v
  if [[ -s $cache ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < 86400 )); then
    cat "$cache"; return 0
  fi
  # A rate outside 50-200 is a broken answer, not a currency crisis.
  v=$(curl -fsS --max-time 4 "$CG_FX_URL" 2>/dev/null | python3 -c '
import json, sys
v = float(json.load(sys.stdin)["value"])
assert 50 < v < 200
print(f"{v:.2f}")' 2>/dev/null) || v=""
  if [[ -n $v ]]; then
    mkdir -p "${cache%/*}" 2>/dev/null && printf '%s' "$v" > "$cache.new" 2>/dev/null \
      && mv -f "$cache.new" "$cache" 2>/dev/null
    echo "$v"; return 0
  fi
  [[ -s $cache ]] && { cat "$cache"; return 0; }   # a stale rate beats a guess
  return 1
}
# CG_FX_INR_PER_USD is the exchange rate. CG_INR_PER_USD is what a dollar of
# AWS charges costs in rupees - the exchange rate with GST on top - and is the
# one every rupee figure is made with. A CG_INR_PER_USD given from outside, with
# no exchange rate beside it, is taken as the exchange rate: that is what it
# meant before tax was counted. Sourced twice, the second reads CG_FX_INR_PER_USD
# and works the same answer out again rather than adding the tax twice.
[[ -n ${CG_FX_INR_PER_USD:-} ]] || CG_FX_INR_PER_USD=${CG_INR_PER_USD:-}
[[ -n ${CG_FX_INR_PER_USD:-} ]] || CG_FX_INR_PER_USD=$(cg_fx_inr) || CG_FX_INR_PER_USD=""
CG_INR_PER_USD=$CG_FX_INR_PER_USD
if [[ -n $CG_FX_INR_PER_USD ]] && awk -v t="$CG_TAX_PCT" 'BEGIN{exit !(t+0 != 0)}'; then
  CG_INR_PER_USD=$(awk -v f="$CG_FX_INR_PER_USD" -v t="$CG_TAX_PCT" 'BEGIN{printf "%.10g", f*(1+t/100)}')
fi

export CG_S3_USD_GB_MONTH CG_EBS_USD_GB_MONTH CG_SNAPSHOT_USD_GB_MONTH \
       CG_EGRESS_USD_GB CG_EGRESS_FREE_GB CG_CE_CALL_USD CG_INR_PER_USD CG_IPV4_USD_HOUR \
       CG_XREGION_USD_GB CG_FX_INR_PER_USD CG_TAX_PCT

# rates_json - the table itself, for a program that must show a price without
# inventing one. An unknown price is null, never 0.
rates_json() {
  python3 -c '
import json, os
def n(k):
    try: return float(os.environ[k])
    except (KeyError, ValueError): return None
print(json.dumps({
  "s3_gb_month":       n("CG_S3_USD_GB_MONTH"),
  "ebs_gb_month":      n("CG_EBS_USD_GB_MONTH"),
  "snapshot_gb_month": n("CG_SNAPSHOT_USD_GB_MONTH"),
  "egress_gb":         n("CG_EGRESS_USD_GB"),
  "egress_free_gb":    n("CG_EGRESS_FREE_GB"),
  "ce_call_usd":       n("CG_CE_CALL_USD"),
  "inr_per_usd":       n("CG_INR_PER_USD"),
  "fx_inr_per_usd":    n("CG_FX_INR_PER_USD"),
  "tax_pct":           n("CG_TAX_PCT"),
  "ipv4_hour":         n("CG_IPV4_USD_HOUR"),
  "xregion_gb":        n("CG_XREGION_USD_GB"),
}))'
}
