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
set -uo pipefail
cd "$(dirname "$0")/.."
TIMEOUT="${TEST_TIMEOUT:-180}"
failed=0 ran=0
out=$(mktemp); trap 'rm -f "$out"' EXIT

for t in tests/*.sh; do
  [[ $t == tests/run-all.sh ]] && continue
  ran=$((ran+1))
  printf '%-28s' "$t"
  if timeout "$TIMEOUT" bash "$t" >"$out" 2>&1; then
    printf 'PASS  (%s assertions)\n' "$(grep -c '^  ok ' "$out" 2>/dev/null || echo '?')"
  else
    rc=$?
    failed=$((failed+1))
    [[ $rc == 124 ]] && printf 'TIMEOUT after %ss\n' "$TIMEOUT" || printf 'FAIL (exit %d)\n' "$rc"
    sed 's/^/      /' "$out" | grep -E 'FAIL|error|Traceback' | head -8
    echo "      --- full output above this line was captured; rerun: bash $t"
  fi
done

echo
if (( failed )); then
  echo "$failed of $ran suites FAILED"
  exit 1
fi
echo "all $ran suites passed"
