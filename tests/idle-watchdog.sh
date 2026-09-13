#!/usr/bin/env bash
# Layer 2, the on-host watchdog: when it decides to shut the box down, it must
# mirror the library FIRST.
#
# It used to just call `shutdown -h` and leave the upload to
# cg-library-shutdown.service, which runs from ExecStop under TimeoutStopSec.
# That is fine for a delta and hopeless for a first upload: measured at 104 GB
# of egress in the 15 minutes systemd allowed, then killed with ~72 GB of a
# 140 GB game landed and no manifest written. A whole session's download, lost
# to a clock that only exists during shutdown.
#
# Before shutdown there is no clock. The extra minutes cost a few rupees of spot
# time against a re-download measured in hours.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=host/idle-watchdog.sh
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho "SHUTDOWN" >> "$LOG"\n' > "$T/bin/shutdown"
# Records its arguments so the MESSAGES can be asserted, and does NOT read
# stdin - reading it hung the whole suite, because the script calls
# `logger -t tag "message"` with no pipe and a stub that cats stdin waits on the
# terminal forever.
printf '#!/usr/bin/env bash\necho "LOG $*" >> "$LOG"\nexit 0\n' > "$T/bin/logger"
# runuser -u ubuntu -- <cmd> push
printf '#!/usr/bin/env bash\nshift 3\necho "PUSH" >> "$LOG"\nexit ${PUSH_RC:-0}\n' > "$T/bin/runuser"
printf '#!/usr/bin/env bash\ntrue\n' > "$T/bin/cg-library"
chmod +x "$T/bin"/*

run() { # run <idle-start> [PUSH_RC]
  rm -f "$T/log"; mkdir -p "$T/state"
  echo "${1:-0}" > "$T/state/idle"
  LOG="$T/log" PATH="$T/bin:$PATH" PUSH_RC="${2:-0}" \
  STATE="$T/state" IDLE_LIMIT=3 BOOT_GRACE=0 IFACE=lo \
  CG_LIBRARY_BIN="$T/bin/cg-library" SHUTDOWN_BIN="$T/bin/shutdown" \
    bash "$SRC" >/dev/null 2>&1
  grep -oE 'PUSH|SHUTDOWN' "$T/log" 2>/dev/null | tr '\n' ' '
}

echo "1. at the idle limit: mirror first, then shut down"
check "in that order" "$(run 3)" "PUSH SHUTDOWN "

echo "2. below the limit: neither"
check "nothing happens" "$(run 0)" ""

echo "3. a failed mirror still shuts the box down, and SAYS it failed"
# The box is idle and billing. Refusing to stop because the upload failed would
# turn a lost download into a lost download AND a running GPU instance.
#
# The message matters as much as the order. The push is piped into logger, so
# `if runuser ... | logger` tests the PIPELINE - which is logger's status, not
# the push's. It reports the failure only because `set -o pipefail` is on at the
# top of the script. That is load-bearing and invisible, so it gets asserted:
# without pipefail this prints "mirror complete" over a failed upload, which is
# the exact shape of every exit-code-as-evidence bug in this project.
out=$(run 3 1)
check "shuts down anyway" "$out" "PUSH SHUTDOWN "
if grep -q 'mirror FAILED' "$T/log"; then echo "  ok   reported the failure"; pass=$((pass+1));
else echo "  FAIL reported success over a failed push (is pipefail still set?)"; fail=$((fail+1)); fi
if grep -q 'mirror complete' "$T/log"; then
  echo "  FAIL also claimed the mirror completed"; fail=$((fail+1));
else echo "  ok   did not also claim success"; pass=$((pass+1)); fi

echo "3b. a successful mirror is reported as complete"
out=$(run 3 0)
if grep -q 'mirror complete' "$T/log"; then echo "  ok   says so"; pass=$((pass+1));
else echo "  FAIL a successful push was not reported"; fail=$((fail+1)); fi

echo "4. no cg-library installed: shut down without pretending to mirror"
rm -f "$T/bin/cg-library"
check "just shuts down" "$(run 3)" "SHUTDOWN "

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
