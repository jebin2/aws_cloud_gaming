#!/usr/bin/env bash
# ExecStop of cg-library-shutdown.service: the last mirror before the box goes.
#
# It is also the last chance anything on the box has to say that games were
# lost. The push can fail, or be cut off by TimeoutStopSec - and either way the
# box is about to vanish, so the notification has to be sent from here, now.
# A push that works says nothing: the cloud watchdog confirms the box is gone.
set -uo pipefail

CG_LIBRARY_BIN="${CG_LIBRARY_BIN:-/usr/local/bin/cg-library}"
CG_NOTIFY_BIN="${CG_NOTIFY_BIN:-/usr/local/bin/cg-notify}"

notify() { # notify <title> <message> - never fails
  [[ -x $CG_NOTIFY_BIN ]] && "$CG_NOTIFY_BIN" "$1" "$2" high warning
  return 0
}

out=$(mktemp -t cg-shutdown-push.XXXXXX 2>/dev/null) || out=/dev/null
push=""

# systemd sends SIGTERM when TimeoutStopSec runs out.
cut_off() {
  [[ -n $push ]] && kill "$push" 2>/dev/null
  cat "$out" 2>/dev/null
  notify "shutdown upload cut off" \
    "The box went down before its games finished mirroring to S3. Games since the last push are lost."
  exit 143
}
trap cut_off TERM INT

# To a file rather than straight to the journal, so a failure can quote its last
# line; the file goes to the journal afterwards either way.
"$CG_LIBRARY_BIN" push > "$out" 2>&1 &
push=$!
wait "$push"; rc=$?
cat "$out" 2>/dev/null

if (( rc != 0 )); then
  last=$(grep -v '^[[:space:]]*$' "$out" 2>/dev/null | tail -n 1)
  notify "shutdown upload FAILED" \
    "cg-library push exited $rc as the box went down${last:+: $last}. Games since the last push may be lost."
fi
[[ $out == /dev/null ]] || rm -f "$out"
exit "$rc"
