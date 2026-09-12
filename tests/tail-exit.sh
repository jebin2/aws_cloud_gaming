#!/usr/bin/env bash
# Asserts every long-running script ends with an explicit `exit`.
#
# Bash does not load a script into memory. It reads one command, runs it, then
# seeks back to read the next. After the last command completes it returns to
# read again - and if the file changed meanwhile (an edit, a git pull, a git
# checkout) that read resumes at a stale byte offset, mid-statement:
#
#     ./cg: line 944: syntax error near unexpected token `;;'
#
# That happened twice during one session while `cg destroy` was running: every
# real step completed, and the error came afterwards, from bash looking for more
# input. A trailing `exit` means it never looks.
#
# This is a property test rather than a behaviour test, because the failure only
# appears when a file is modified mid-run - which no test should arrange.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0

# Scripts that can run for minutes, where an edit landing mid-run is plausible.
SCRIPTS=(cg lib/setup lib/game lib/provision.sh lib/aws-setup.sh lib/library-aws.sh
         host/cg-library host/install-library.sh)

for f in "${SCRIPTS[@]}"; do
  if [[ ! -f $f ]]; then
    echo "  FAIL $f is missing"; fail=$((fail+1)); continue
  fi
  # Last non-blank, non-comment line.
  last=$(grep -vE '^[[:space:]]*(#|$)' "$f" | tail -1 | tr -d '[:space:]')
  if [[ $last == exit || $last == exit0 || $last =~ ^exit ]]; then
    echo "  ok   $f ends with '$last'"; pass=$((pass+1))
  else
    echo "  FAIL $f ends with '$last' - add an explicit exit (see the note in cg)"
    fail=$((fail+1))
  fi
done

# And prove the mechanism itself still behaves as described, so the reason for
# the rule above is verified rather than asserted.
echo
echo "mechanism: a script rewritten during its last command"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
probe() { # probe <trailing-line>; echoes the exit status
  printf '#!/usr/bin/env bash\nsleep 1\n%s' "$1" > "$T/run.sh"
  ( bash "$T/run.sh" >"$T/out" 2>&1; echo "$?" > "$T/rc" ) &
  local pid=$!
  sleep 0.3
  printf '#!/usr/bin/env bash\nsleep 1\n%s;;\n' "$1" > "$T/run.sh"   # same prefix, garbage appended
  wait $pid
  cat "$T/rc"
}
rc_without=$(probe "")
rc_with=$(probe "exit 0
")
if [[ $rc_without != 0 ]]; then
  echo "  ok   without a trailing exit it breaks (rc=$rc_without)"; pass=$((pass+1))
else
  echo "  FAIL a rewrite mid-run no longer breaks an exit-less script; the rule may be obsolete"
  fail=$((fail+1))
fi
if [[ $rc_with == 0 ]]; then
  echo "  ok   with a trailing exit it survives (rc=0)"; pass=$((pass+1))
else
  echo "  FAIL a trailing exit did not prevent it (rc=$rc_with)"; fail=$((fail+1))
fi

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
