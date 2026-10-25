#!/usr/bin/env bash
# Writes the oracle for internal/costdaily: what lib/cost-daily.py prints for
# each answer in testdata/cost/in, at two exchange rates (one known, one not).
# Run it again only to change the oracle on purpose.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=testdata/cost/oracle
rm -rf "$out"; mkdir -p "$out"
for f in testdata/cost/in/*.json; do
  n=$(basename "$f" .json)
  for rate in known unknown; do
    env=(CG_EGRESS_FREE_GB=100 CG_TAX_PCT=0)
    [[ $rate == known ]] && env+=(CG_INR_PER_USD=88)
    for mode in table json aggregate; do
      flag=(); [[ $mode == json ]] && flag=(--json); [[ $mode == aggregate ]] && flag=(--aggregate)
      env -i PATH="$PATH" "${env[@]}" python3 lib/cost-daily.py "${flag[@]}" < "$f" \
        > "$out/$n.$rate.$mode.txt" 2>&1 || true
    done
  done
done
