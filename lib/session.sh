#!/usr/bin/env bash
# One stream at a time, from this laptop.
#
# `cg open` runs for as long as Moonlight does. Nothing stopped a second one
# from starting: close the desktop app mid-session and reopen it, press Play,
# and a second Moonlight window streams the same box - two streams fighting over
# one GPU, both spending egress, and the first `cg open` still waiting to end
# the session. The lock below is what makes the second one refuse.
#
# It is a pid file, not flock: the app and `cg status` want to SAY what is
# running, and a pid answers that. Costs nothing - no AWS call is involved.
#
# A pid can be reused after a reboot, so the file is only believed when the
# process is alive AND still looks like a cg session. `ps -o args=` rather than
# /proc, because this runs on a laptop and that may be a Mac.

session_file() { printf '%s/cg-session-%s.pid' "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "$(id -u)"; }

# session_running - prints "<pid> <epoch-started>" and returns 0 if a session
# holds the lock, otherwise returns 1 and prints nothing.
session_running() {
  local f pid started args
  f=$(session_file)
  [[ -r $f ]] || return 1
  read -r pid started _ < "$f" || return 1
  [[ ${pid:-} =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  args=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
  [[ $args == *cg* || $args == *game* ]] || return 1   # the pid was reused
  printf '%s %s\n' "$pid" "${started:-}"
  return 0
}

# session_claim - take the lock for this process, and drop it on the way out.
session_claim() {
  local f; f=$(session_file)
  printf '%s %s\n' "$$" "$(date +%s)" > "$f" 2>/dev/null || return 0
  # cg_on_exit, not a bare trap: a second `trap ... EXIT` replaces the one that
  # closes the open step, and every run then ended with no closing line.
  cg_on_exit "rm -f '$f'"
}

# session_age_s - how long the running session has been up, or nothing.
session_age_s() {
  local pid started now
  read -r pid started < <(session_running) || return 1
  [[ ${started:-} =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  printf '%s\n' "$(( now - started ))"
}

# session_end - end the stream this laptop holds, Moonlight first.
#
# `cg open` waits on Moonlight, so killing Moonlight lets it finish the way it
# normally does. TERM to the children, then to `cg open` itself; SIGKILL only if
# ten seconds of asking politely got nowhere.
session_end() {
  local pid started i
  read -r pid started < <(session_running) || return 0
  pkill -TERM -P "$pid" 2>/dev/null || true    # moonlight, the child that holds it open
  kill -TERM "$pid" 2>/dev/null || true
  for ((i = 0; i < 20; i++)); do
    session_running >/dev/null || return 0
    sleep 0.5
  done
  kill -KILL "$pid" 2>/dev/null || true
  session_running >/dev/null && return 1 || return 0
}

# session_end_first - what `cg destroy` calls. A stream open onto the box being
# deleted goes black mid-push, and the `cg open` behind it then offers to end a
# box that no longer exists. Close it first, and say so.
session_end_first() {
  local pid started
  read -r pid started < <(session_running) || return 0
  log "a stream is open from this laptop (pid $pid) - it streams the box being destroyed"
  if cg_confirm end-session "close the stream first? [Y/n] " Y; then
    if session_end; then log_as ok "stream closed"
    else log_as warn "could not close the stream (pid $pid) - close the Moonlight window"; fi
  else
    log_as warn "leaving the stream open - Moonlight will lose the box mid-destroy"
  fi
}
