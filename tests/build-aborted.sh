#!/usr/bin/env bash
# A build that died in 30 seconds looked like one still going 30 minutes later.
#
# `verify` returns 1 and user-data runs under `set -e`, so a failed check ends
# the build: nothing after it runs, no desktop appears, and the readiness marker
# can never be written. The watcher printed the FAILED line and then went on
# polling for that marker until it timed out. Twice now a build has died early
# and the only thing the user saw was a long wait - once a presigned URL signed
# for the wrong region, once the nvidia driver check pinned to a package name.
#
# The two shortcuts that look right and are not:
#
#   1. "a FAILED means it is over" - no. The library stage ends its verifies
#      with `|| true` deliberately; those print FAILED and the build carries on.
#   2. "cloud-init says done but there is no marker, so it is over" - no, and
#      this is the dangerous one. 99-finish.sh writes the marker on the NEXT
#      boot, after graphical.target AND the library restore. There is a long,
#      perfectly healthy window where cloud-init is done and the marker is
#      absent. Acting on that would condemn every good build.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

# The shipped function, not a copy of it.
ab() { bash -c '
  set -uo pipefail
  '"$(sed -n '/^build_aborted()/,/^}/p' lib/common.sh)"'
  build_aborted "$1" "$2" && echo aborted || echo waiting' _ "$1" "$2" 2>&1; }

echo "1. the real abort: a fatal verify failed and user-data is gone"
check "error, never finished"      "$(ab 1 'error|no')"   "aborted"

echo "1b. a machine of yours: its build ended, and not well"
# set -e stops a build without printing FAILED, and there is no reboot to wait
# for: the result file saying so is the end, FAILED or not. It waited 40
# minutes for a build that had stopped two minutes in.
check "exited, no FAILED seen"      "$(ab 0 'exited|no')"  "aborted"
check "  exited, FAILED seen"       "$(ab 1 'exited|no')"  "aborted"
check "  but done is done"          "$(ab 0 'done|yes')"   "waiting"
contains "the result file is read where there is no cloud-init" "$(cat lib/common.sh)" 's=done || s=exited'
# The probe itself, run: its two paths pointed at a sandbox, and a cloud-init
# that says "done" - as Ubuntu's own install says on a machine of yours.
probe() { # probe <rc file content, or "-" for none> -> what the probe prints
  local d; d=$(mktemp -d); mkdir -p "$d/lib" "$d/log" "$d/bin"
  printf '#!/bin/sh\necho "status: done"\n' > "$d/bin/cloud-init"; chmod +x "$d/bin/cloud-init"
  [[ $1 != - ]] && printf '%s\n' "$1" > "$d/lib/cloud-gaming-bootstrap.rc"
  ( source lib/common.sh >/dev/null 2>&1
    cmd=${_build_state_cmd//\/var\/lib/$d\/lib}; cmd=${cmd//\/var\/log/$d\/log}
    PATH="$d/bin:$PATH" sh -c "$cmd" )
  rm -rf "$d"
}
check "a failed build's own word beats cloud-init's 'done'" "$(probe 1)" "exited|no"
check "  and so does a good one"                            "$(probe 0)" "done|no"
check "  with no result file, cloud-init is asked"          "$(probe -)" "done|no"
contains "  and asked once a minute, not only after a FAILED" "$(cat lib/common.sh)" 'failed_seen || waited % 60 == 0'

echo "2. a healthy build is never condemned"
check "still running"              "$(ab 1 'running|no')" "waiting"
check "  no FAILED seen at all"    "$(ab 0 'error|no')"   "waiting"
# Trap 2: the post-reboot window. cloud-init is done, the marker has not been
# written yet because the library restore is still going, and a non-fatal
# FAILED from the library stage was seen earlier. This MUST keep waiting.
check "  done, finished, marker not yet written" "$(ab 1 'done|yes')" "waiting"
check "  error but the log reached the end"      "$(ab 1 'error|yes')" "waiting"
# A non-fatal FAILED while the build is still going.
check "  library FAILED, build continuing"       "$(ab 1 'running|no')" "waiting"

echo "3. an unanswerable probe waits rather than guessing"
# ssh flakes constantly during this build - the box reboots partway through.
# An empty answer must never be read as an abort.
check "empty state"               "$(ab 1 '')"          "waiting"
check "  unknown status"          "$(ab 1 'unknown|no')" "waiting"
check "  a truncated answer"      "$(ab 1 'error')"      "waiting"

echo "4. the probe answers both halves in one round trip"
src=$(cat lib/common.sh)
contains "cloud-init is asked"      "$src" "cloud-init status 2>/dev/null | head -1"
contains "  and the log's last word" "$src" 'grep -q "bootstrap complete"'
# That string has to be the one 99-finish.sh actually prints, or the second
# half is always "no" and a good build trips the check.
contains "which 99-finish really prints" "$(cat lib/bootstrap.d/99-finish.sh)" "bootstrap complete"

echo "5. both watchers use it - styled and plain"
check "the check appears twice"  "$(grep -c 'if build_aborted "\$failed_seen" "\$state"' lib/common.sh)" "2"
check "  FAILED is recorded twice" "$(grep -c 'failed_seen=1; last_fail=' lib/common.sh)" "2"
check "  and the probe is shared, defined once" "$(grep -c '^_build_state_cmd=' lib/common.sh)" "1"
# At once after a FAILED, and once a minute otherwise: a healthy build pays one
# ssh a minute, not one every poll, and a silent stop is still caught.
check "  guarded: after a FAILED, or once a minute" "$(grep -c 'if (( failed_seen || waited % 60 == 0 )); then' lib/common.sh)" "2"

echo "6. it says what happened, not just that something did"
contains "the failing step is named" "$src" 'the build STOPPED here: $f'
contains "  or, with none, the end of the log" "$src" "the end of its log"
contains "  and that nothing after it ran" "$src" "nothing after that step ran"
contains "  and where to look"       "$src" "sudo tail -50 /var/log/cloud-gaming-bootstrap.log"

echo "7. this file's own needles are safe"
bad=$(sed 's/\\\$//g' "$0" | grep -nE '^(contains|lacks|check) +"[^"]*" +"[^"]*" +"[^"]*(\$\{|\$\()' || true)
if [[ -z $bad ]]; then echo "  ok   every needle with a \$ is single-quoted"; pass=$((pass+1))
else echo "  FAIL double-quoted needles bash will expand:"; echo "$bad"; fail=$((fail+1)); fi

echo ""
echo "build-aborted: $pass passed, $fail failed"
(( fail == 0 ))
