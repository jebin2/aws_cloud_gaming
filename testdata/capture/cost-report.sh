#!/usr/bin/env bash
# Writes the oracle for internal/costreport: what lib/cost-report.py prints for
# the monthly shape of each answer in testdata/cost/in, under four settings.
set -euo pipefail
cd "$(dirname "$0")/../.."
repo=$PWD
out=testdata/cost/report-oracle
rm -rf "$out"; mkdir -p "$out"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT   # the report caches egress in ./.cg-cache
declare -A variant=(
  [all]="CG_INR_PER_USD=88 CG_EGRESS_USD_GB=0.1093 CG_EGRESS_FREE_GB=100"
  [no-inr]="CG_EGRESS_USD_GB=0.1093 CG_EGRESS_FREE_GB=100"
  [no-egress-price]="CG_INR_PER_USD=88 CG_EGRESS_FREE_GB=100"
  [no-free]="CG_INR_PER_USD=88 CG_EGRESS_USD_GB=0.1093"
)
for f in testdata/cost/in/*.json; do
  n=$(basename "$f" .json)
  agg=$(env -i PATH="$PATH" python3 lib/cost-daily.py --aggregate < "$f")
  for v in "${!variant[@]}"; do
    # shellcheck disable=SC2086
    (cd "$work" && env -i PATH="$PATH" ${variant[$v]} python3 "$repo/lib/cost-report.py" <<<"$agg") \
      > "$out/$n.$v.txt" 2>&1 || true
  done
done
