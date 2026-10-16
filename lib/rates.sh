#!/usr/bin/env bash
# The prices, in one place.
#
# They were spread across awk one-liners in three files and had begun to leak
# into the desktop app, which is exactly the drift the app rule exists to stop:
# the scripts are the source of truth, so a price the app prints must have come
# from a command, and a price cg prints must have come from here.
#
# ap-south-2 (Hyderabad), verified against the AWS Pricing API - see docs/cost.md,
# which carries the dates and the method.
CG_S3_USD_GB_MONTH="${CG_S3_USD_GB_MONTH:-0.025}"        # S3 standard
CG_EBS_USD_GB_MONTH="${CG_EBS_USD_GB_MONTH:-0.0912}"     # gp3 root volume
CG_SNAPSHOT_USD_GB_MONTH="${CG_SNAPSHOT_USD_GB_MONTH:-0.0125}"
CG_EGRESS_USD_GB="${CG_EGRESS_USD_GB:-0.1093}"           # after the free 100 GB
CG_EGRESS_FREE_GB="${CG_EGRESS_FREE_GB:-100}"
CG_CE_CALL_USD="${CG_CE_CALL_USD:-0.01}"                 # one Cost Explorer call
# The rupee rate: today's, not a number written down once. Fetched at most
# once a day from an exchange-rate endpoint and kept in a cache file; if the
# fetch fails, the last good rate stands, and 88 only if there has never been
# one. A rate set in the environment or .env wins and nothing is fetched. The
# request carries nothing about this laptop - "USD to INR, 1" - and no AWS call
# is made. The fixed 88 had every rupee figure about 7% low by October 2026.
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
[[ -n ${CG_INR_PER_USD:-} ]] || CG_INR_PER_USD=$(cg_fx_inr) || CG_INR_PER_USD=88
# Every public IPv4 address, attached or not, since February 2024: the running
# box's own, and an Elastic IP left behind with no box at all.
CG_IPV4_USD_HOUR="${CG_IPV4_USD_HOUR:-0.005}"
export CG_S3_USD_GB_MONTH CG_EBS_USD_GB_MONTH CG_SNAPSHOT_USD_GB_MONTH \
       CG_EGRESS_USD_GB CG_EGRESS_FREE_GB CG_CE_CALL_USD CG_INR_PER_USD CG_IPV4_USD_HOUR

# rates_json - the table itself, for a program that must show a price without
# inventing one.
rates_json() {
  python3 -c '
import json, os
g = os.environ.get
print(json.dumps({
  "s3_gb_month":       float(g("CG_S3_USD_GB_MONTH")),
  "ebs_gb_month":      float(g("CG_EBS_USD_GB_MONTH")),
  "snapshot_gb_month": float(g("CG_SNAPSHOT_USD_GB_MONTH")),
  "egress_gb":         float(g("CG_EGRESS_USD_GB")),
  "egress_free_gb":    float(g("CG_EGRESS_FREE_GB")),
  "ce_call_usd":       float(g("CG_CE_CALL_USD")),
  "inr_per_usd":       float(g("CG_INR_PER_USD")),
  "ipv4_hour":         float(g("CG_IPV4_USD_HOUR")),
}))'
}
