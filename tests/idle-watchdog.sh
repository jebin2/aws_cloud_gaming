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
printf '#!/usr/bin/env bash\nshift 3\necho "PUSH" >> "$LOG"\nsleep ${PUSH_SLEEP:-0}\nexit ${PUSH_RC:-0}\n' > "$T/bin/runuser"
printf '#!/usr/bin/env bash\ntrue\n' > "$T/bin/cg-library"
chmod +x "$T/bin"/*

run() { # run <idle-start> [PUSH_RC]
  rm -f "$T/log"; mkdir -p "$T/state"
  echo "${1:-0}" > "$T/state/idle"
  # Thresholds no real traffic reaches. The script reads the REAL counters of lo
  # and of this machine's default-route interface, and keeps them between runs -
  # so anything the laptop sent or received between two cases counted as use,
  # reset the idle counter, and "just shuts down" got nothing. It failed a full
  # suite run while a build was streaming beside it, and failed 4 of 7 every time
  # with loopback traffic running. These cases test what happens AT the limit.
  LOG="$T/log" PATH="$T/bin:$PATH" PUSH_RC="${2:-0}" \
  THRESHOLD=999999999999999 RX_THRESHOLD=999999999999999 \
  CG_NOTIFY_BIN="$PWD/host/cg-notify" UPLOAD_POLL_SEC=0.1 UPLOAD_WARN_SEC="${UPLOAD_WARN_SEC:-3600}" \
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
# The message matters as much as the order. The push is piped into logger, and a
# pipeline's status is logger's, not the push's - so the push records its own exit
# status, and that decides the message. Asserted, because getting it wrong prints
# "mirror complete" over a failed upload: the exact shape of every
# exit-code-as-evidence bug in this project.
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

echo "5. a notification before shutting down - only when a URL is configured"
printf '#!/usr/bin/env bash\necho "CURL $*" >> "$LOG"\nexit ${CURL_RC:-0}\n' > "$T/bin/curl"
printf '#!/usr/bin/env bash\ntrue\n' > "$T/bin/cg-library"
chmod +x "$T/bin/curl" "$T/bin/cg-library"
run 3 >/dev/null
check "no URL: no request"              "$(grep -c '^CURL' "$T/log" || true)" "0"
CG_NTFY_URL=https://ntfy.sh/t run 3 >/dev/null
check "URL: one request, to it"         "$(grep -c '^CURL.*https://ntfy.sh/t' "$T/log")" "1"
check "  sent before the shutdown"      "$(grep -oE '^(CURL|SHUTDOWN)' "$T/log" | tr '\n' ' ')" "CURL SHUTDOWN "
check "  and says the games were mirrored" "$(grep -c '^CURL.*games mirrored to S3' "$T/log")" "1"
CG_NTFY_URL=https://ntfy.sh/t CURL_RC=7 run 3 >/dev/null
check "a failed request still shuts down" "$(grep -c '^SHUTDOWN' "$T/log")" "1"
CG_NTFY_URL=https://ntfy.sh/t run 0 >/dev/null
check "below the limit: nothing sent"   "$(grep -c '^CURL' "$T/log" || true)" "0"

echo "6. an upload before shutdown that runs long is said out loud - and still ends in a shutdown"
CG_NTFY_URL=https://ntfy.sh/t PUSH_SLEEP=2 UPLOAD_WARN_SEC=1 run 3 >/dev/null
check "one 'still running' notification"  "$(grep -c '^CURL.*upload before shutdown still running' "$T/log")" "1"
check "  then the usual one, then the shutdown" "$(grep -oE '^(CURL|SHUTDOWN)' "$T/log" | tr '\n' ' ')" "CURL CURL SHUTDOWN "
CG_NTFY_URL=https://ntfy.sh/t run 3 >/dev/null
check "a quick upload says nothing of the kind" "$(grep -c 'still running' "$T/log" || true)" "0"
PUSH_SLEEP=2 UPLOAD_WARN_SEC=1 run 3 >/dev/null
check "no URL: no request, however long"  "$(grep -c '^CURL' "$T/log" || true)" "0"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
