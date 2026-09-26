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
CG_INR_PER_USD="${CG_INR_PER_USD:-88}"
export CG_S3_USD_GB_MONTH CG_EBS_USD_GB_MONTH CG_SNAPSHOT_USD_GB_MONTH \
       CG_EGRESS_USD_GB CG_EGRESS_FREE_GB CG_CE_CALL_USD CG_INR_PER_USD

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
}))'
}
