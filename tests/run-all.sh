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
# The suites run side by side, TEST_JOBS at a time (default 8). The runner gives
# each one an empty HOME of its own - most also make their own, but that was a
# habit, not a rule, and side by side two suites writing ~/.config would be two
# suites failing at random. They write nothing into the repo.
#
# Each suite's time is printed, so a slow one is visible rather than guessed at.
# A failed suite's whole output is kept, at the path printed beside it; a run
# that passes keeps nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
TIMEOUT="${TEST_TIMEOUT:-180}"
JOBS="${TEST_JOBS:-8}"
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo "TEST_JOBS must be a whole number of 1 or more, not '$JOBS'" >&2; exit 2; }
[[ $TIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo "TEST_TIMEOUT must be a whole number of seconds, not '$TIMEOUT'" >&2; exit 2; }
dir=$(mktemp -d)
keep=0
trap '(( keep )) || rm -rf "$dir"' EXIT

# python3 as the interpreter itself, not a version manager's shim. pyenv's
# python3 is a bash script that works out which Python to run on every call -
# about 80ms each, four times the interpreter's own start - and the suites call
# it thousands of times: init-watchdog's fake aws alone is 31 calls per cg run,
# and the suite took 33s instead of 11. Asked once here, then first on PATH.
# Where python3 is already the binary this changes nothing.
real_py=$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)
if [[ -x $real_py && $(command -v python3) != "$real_py" ]]; then
  mkdir -p "$dir/py" && ln -s "$real_py" "$dir/py/python3"
  export PATH="$dir/py:$PATH"
fi

suites=()
for t in tests/*.sh; do [[ $t == tests/run-all.sh ]] || suites+=("$t"); done

# One suite: its output, its exit status and how long it took, each in a file
# named after it. Whether the time limit fired is recorded by the limit itself,
# not inferred from exit 124 - which a suite could return on its own.
run_one() {
  local t=$1 n start; n=$(basename "$t" .sh)
  mkdir -p "$dir/home-$n/run"
  start=$(date +%s%N)
  # CG_SLEEP_PCT=1: cg's poll loops wait 1% as long (see cg_sleep in
  # lib/common.sh). Four suites spent most of their minutes asleep in them.
  # CG_INR_PER_USD=88: the rupee rate is otherwise fetched once a day from an
  # exchange-rate endpoint (lib/rates.sh). Pinned, the suites are offline and
  # every rupee they check is the same on every run.
  # XDG_RUNTIME_DIR: cg's "a stream is open" marker lives there, not in HOME.
  # Shared, a suite streaming beside destroy-all made its destroy ask "close
  # the stream first?" - which ate the typed DESTROY-ALL, so it aborted.
  HOME="$dir/home-$n" XDG_RUNTIME_DIR="$dir/home-$n/run" CG_SLEEP_PCT="${CG_SLEEP_PCT:-1}" CG_INR_PER_USD="${CG_INR_PER_USD:-88}" \
    timeout "$TIMEOUT" bash "$t" >"$dir/$n.out" 2>&1
  echo $? >"$dir/$n.rc"
  echo $(( ($(date +%s%N) - start) / 1000000 )) >"$dir/$n.ms"
}
export -f run_one; export TIMEOUT dir
printf '%s\0' "${suites[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'run_one "$1"' _ {}

failed=0 ran=0
for t in "${suites[@]}"; do
  n=$(basename "$t" .sh); ran=$((ran+1))
  rc=$(cat "$dir/$n.rc" 2>/dev/null || echo 1)
  ms=$(cat "$dir/$n.ms" 2>/dev/null || echo 0)
  printf '%-28s %6.1fs  ' "$t" "$(awk "BEGIN{print $ms/1000}")"
  if [[ $rc == 0 ]]; then
    printf 'PASS  (%s assertions)\n' "$(grep -c '^  ok ' "$dir/$n.out" 2>/dev/null || echo '?')"
  else
    failed=$((failed+1)); keep=1
    if [[ $rc == 124 ]] && (( ms >= TIMEOUT * 1000 )); then printf 'TIMEOUT after %ss\n' "$TIMEOUT"
    else printf 'FAIL (exit %d)\n' "$rc"; fi
    sed 's/^/      /' "$dir/$n.out" | grep -E 'FAIL|error|Traceback' | head -8
    echo "      --- full output: $dir/$n.out   rerun: bash $t"
  fi
done

echo
if (( failed )); then
  echo "$failed of $ran suites FAILED (logs kept in $dir)"
  exit 1
fi
echo "all $ran suites passed"
