#!/usr/bin/env bash
# Runs every suite and EXITS NON-ZERO if any of them fails.
#
# That is the whole point. The ad-hoc loop this replaces was
#
#     for t in tests/*.sh; do printf ...; bash "$t" >/dev/null && echo PASS || echo FAIL; done
#
# which prints FAIL and returns 0, because the last command in the loop is the
# `echo`. Chaining `&& git commit` after it therefore committed on a red suite -
# it happened once, and the only reason it was caught was that the word FAIL was
# visible in the scrollback.
#
# It also keeps each failure's output, which the loop discarded to /dev/null -
# so a failure that cannot be reproduced afterwards is at least legible once.
#
# RUN IT UNPIPED. `bash tests/run-all.sh | tail -4 && git commit` throws away
# this script's exit status - the pipeline reports tail's - and commits on a red
# suite exactly as the loop it replaced did. That happened, with this file
# already in the repo. If you want a short view, use the file:
#
#     bash tests/run-all.sh > /tmp/t.log || { tail -20 /tmp/t.log; false; }
#
# The suites run side by side, TEST_JOBS at a time (default 8). Each makes its
# own temporary HOME and writes nothing into the repo, so they share no state;
# run one after another they took seven minutes, most of it waiting. Results
# are still printed in order, and the exit status still says whether any failed.
set -uo pipefail
cd "$(dirname "$0")/.."
TIMEOUT="${TEST_TIMEOUT:-180}"
JOBS="${TEST_JOBS:-8}"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT

suites=()
for t in tests/*.sh; do [[ $t == tests/run-all.sh ]] || suites+=("$t"); done

# One suite: its output and its exit status, each in a file named after it.
run_one() {
  local t=$1 n; n=$(basename "$t" .sh)
  timeout "$TIMEOUT" bash "$t" >"$dir/$n.out" 2>&1
  echo $? >"$dir/$n.rc"
}
export -f run_one; export TIMEOUT dir
printf '%s\0' "${suites[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'run_one "$1"' _ {}

failed=0 ran=0
for t in "${suites[@]}"; do
  n=$(basename "$t" .sh); ran=$((ran+1))
  rc=$(cat "$dir/$n.rc" 2>/dev/null || echo 1)
  printf '%-28s' "$t"
  if [[ $rc == 0 ]]; then
    printf 'PASS  (%s assertions)\n' "$(grep -c '^  ok ' "$dir/$n.out" 2>/dev/null || echo '?')"
  else
    failed=$((failed+1))
    [[ $rc == 124 ]] && printf 'TIMEOUT after %ss\n' "$TIMEOUT" || printf 'FAIL (exit %d)\n' "$rc"
    sed 's/^/      /' "$dir/$n.out" | grep -E 'FAIL|error|Traceback' | head -8
    echo "      --- rerun: bash $t"
  fi
done

echo
if (( failed )); then
  echo "$failed of $ran suites FAILED"
  exit 1
fi
echo "all $ran suites passed"
