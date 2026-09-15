#!/usr/bin/env bash
# The shutdown push's wrapper (host/cg-shutdown-push.sh): the last upload before
# the box goes, and the last chance anything on the box has to say games were
# lost - when the push fails, or when TimeoutStopSec cuts it off.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
cat > "$T/bin/cg-library" <<'FAKE'
#!/usr/bin/env bash
echo "pushing Diablo IV"
echo "error: the library was not restored on this boot" >&2
# Its pid, for the cut-off case; exec keeps it, so killing this process ends the sleep.
[[ -n ${PIDFILE:-} ]] && echo $$ > "$PIDFILE"
[[ ${PUSH_SLEEP:-0} != 0 ]] && exec sleep "$PUSH_SLEEP"
exit "${PUSH_RC:-0}"
FAKE
cat > "$T/bin/cg-notify" <<'FAKE'
#!/usr/bin/env bash
echo "NOTIFY [$1] [$2]" >> "$LOG"
FAKE
chmod +x "$T/bin"/*

# `env`, so callers can add VAR=value pairs before the command.
env_() { env LOG="$T/log" CG_LIBRARY_BIN="$T/bin/cg-library" CG_NOTIFY_BIN="$T/bin/cg-notify" "$@"; }
run() { # run  -> "rc=<n>", output of the wrapper in $T/out
  rm -f "$T/log"; touch "$T/log"
  env_ PUSH_RC="${PUSH_RC:-0}" bash host/cg-shutdown-push.sh > "$T/out" 2>&1
  echo "rc=$?"
}

echo "1. a push that works: nothing to say"
out=$(PUSH_RC=0 run)
check    "exit 0"                        "$out" "rc=0"
check    "no notification"               "$(cat "$T/log")" ""
contains "its output still reaches the journal" "$(cat "$T/out")" "pushing Diablo IV"

echo "2. a push that fails: said, with its last line, and its exit status kept"
out=$(PUSH_RC=3 run)
check    "the push's exit status"        "$out" "rc=3"
contains "notified"                      "$(cat "$T/log")" "[shutdown upload FAILED]"
contains "  with the reason"             "$(cat "$T/log")" "not restored on this boot"
contains "  and the exit status"         "$(cat "$T/log")" "exited 3"

echo "3. cut off by the shutdown timeout: said, and the push stopped"
rm -f "$T/log"; touch "$T/log"
# `env` directly, not through env_: a shell function run in the background is a
# forked subshell, so $! would be that subshell and the signal would miss the wrapper.
rm -f "$T/push.pid"
env LOG="$T/log" CG_LIBRARY_BIN="$T/bin/cg-library" CG_NOTIFY_BIN="$T/bin/cg-notify" PUSH_SLEEP=30 \
  PIDFILE="$T/push.pid" bash host/cg-shutdown-push.sh > "$T/out" 2>&1 &
wrapper=$!
# Wait for the push itself, by pid - matching a command line with pgrep -f also
# matched whatever shell happened to have that text in its own command.
for _ in $(seq 1 50); do [[ -s $T/push.pid ]] && break; sleep 0.1; done
pushpid=$(cat "$T/push.pid" 2>/dev/null)
kill -TERM "$wrapper"; wait "$wrapper"; rc=$?
check    "exit 143, as for SIGTERM"      "rc=$rc" "rc=143"
contains "notified"                      "$(cat "$T/log")" "[shutdown upload cut off]"
for _ in $(seq 1 20); do kill -0 "$pushpid" 2>/dev/null || break; sleep 0.1; done
check    "the push is not left running"  "$(kill -0 "$pushpid" 2>/dev/null && echo running || echo gone)" "gone"

echo "4. no cg-notify installed: still pushes, still exits with the push's status"
rm -f "$T/log"; touch "$T/log"
LOG="$T/log" CG_LIBRARY_BIN="$T/bin/cg-library" CG_NOTIFY_BIN=/nonexistent PUSH_RC=2 \
  bash host/cg-shutdown-push.sh > "$T/out" 2>&1; rc=$?
check    "exit status kept"              "rc=$rc" "rc=2"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
