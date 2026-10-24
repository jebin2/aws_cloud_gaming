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

# session_release - drop the lock now, rather than on exit, and only if it is
# this process's. Not session_end: that ends whoever holds the lock, and when
# that is this process it sends TERM to itself - every `cg host open` ended
# killed, exit 143, and the app called a normal session a failed one.
session_release() {
  local f pid
  f=$(session_file)
  read -r pid _ < "$f" 2>/dev/null || return 0
  [[ $pid == "$$" ]] && rm -f "$f"
  return 0
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

# moonlight_flags <array-name> - the stream settings from .env as Moonlight's
# arguments, into the named array. One copy, for every machine a stream starts
# from: the AWS box (lib/game) and your own (lib/host.sh).
moonlight_flags() {
  local -n _mf=$1
  _mf=()
  # The display mode has a default of cg's - full screen - rather than none:
  # unset, it is what it always was. lib/game has no settings registry of its
  # own loaded, so it is read here.
  declare -F config_field >/dev/null || source "${BASH_SOURCE[0]%/*}/config.sh"
  local mode=${GAME_DISPLAY_MODE:-$(config_field GAME_DISPLAY_MODE 3)} size=${GAME_RES:-}
  # In a window, Moonlight sizes the window to the stream: the window's size is
  # the stream's resolution there.
  [[ $mode == windowed && -n ${GAME_WINDOW_SIZE:-} ]] && size=$GAME_WINDOW_SIZE
  [[ -n $size ]]                  && _mf+=(--resolution "$size") || true
  [[ -n ${GAME_FPS:-} ]]          && _mf+=(--fps "$GAME_FPS") || true
  [[ -n ${GAME_BITRATE_KBPS:-} ]] && _mf+=(--bitrate "$GAME_BITRATE_KBPS") || true
  [[ -n $mode ]]                  && _mf+=(--display-mode "$mode") || true
  [[ -n ${GAME_VIDEO_CODEC:-} ]]  && _mf+=(--video-codec "$GAME_VIDEO_CODEC") || true
  [[ ${GAME_PERF_OVERLAY:-0} == 1 ]] && _mf+=(--performance-overlay) || true
}

# hypr_place <moonlight-pid> <WxH|""> <log> - on Hyprland, float each window
# Moonlight opens, at the size asked, centred. Hyprland tiles every new window
# and a tiled window fills the space it is given, so "in a window" opened
# looking full screen at a size nobody set. Each window is taken as it appears
# - Moonlight opens a small one while it connects, then the stream's - for as
# long as Moonlight runs, up to a few minutes. A window Moonlight made full
# screen itself is left alone and said so: that is Moonlight's choice, not
# Hyprland's. What it found goes in Moonlight's log and the run's output.
hypr_place() {
  local pid=$1 size=$2 log=$3 i seen=" " win addr floating full wh
  for ((i = 0; i < 360; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    while read -r addr floating full wh; do
      [[ -n $addr && $seen != *" $addr "* ]] || continue
      seen+="$addr "
      if [[ $full != 0 ]]; then
        win="Moonlight made its window full screen itself ($wh) - Hyprland did not"
      else
        [[ $floating == 1 ]] || hyprctl dispatch setfloating "address:$addr" >/dev/null 2>&1 || true
        [[ -z $size ]] || hyprctl dispatch resizewindowpixel "exact ${size%x*} ${size#*x},address:$addr" >/dev/null 2>&1 || true
        { hyprctl dispatch focuswindow "address:$addr" && hyprctl dispatch centerwindow 1; } >/dev/null 2>&1 || true
        win="Hyprland had the window $([[ $floating == 1 ]] && echo floating || echo tiled) at $wh - floated${size:+ at $size}, centred"
      fi
      printf '# cg: %s\n' "$win" >> "$log"
      cg_echo "    window: $win"
    done < <(hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    if c.get("pid") == int(sys.argv[1]) and c.get("mapped", True) and not c.get("hidden", False):
        full = int(c.get("fullscreen") or 0)   # a bool on older Hyprland, a state on newer
        w, h = c.get("size", [0, 0])
        print(c["address"], int(bool(c.get("floating"))), full, "%dx%d" % (w, h))' "$pid" 2>/dev/null)
    sleep 0.5
  done
}

# stream_play <ip> <app> - the stream itself, from whatever machine: Moonlight
# with the stream settings, timed. Shared by the AWS box (lib/game) and your own
# (lib/host.sh); the lock, and anything to do with the machine before and after,
# stay with them.
#
# Stream settings come from .env as launch flags rather than by rewriting
# Moonlight's config: the flags win for this session and leave whatever you set
# in the GUI untouched. A variable left unset passes no flag at all, so
# Moonlight's own saved setting remains the default.
#
# Moonlight's own output goes to a file of its own, not into cg's: it is a
# debug log - every decoder it tried, every packet format - thousands of lines
# that buried the one worth reading. A stream that ends within seconds did not
# end by choice, so then its last warnings are said, and where the rest is.
stream_play() {
  local ip=$1 app=${2:-Desktop} t0=$SECONDS mlf=() took mlog
  mlog="${XDG_CACHE_HOME:-$HOME/.cache}/cg/moonlight.log"
  mkdir -p "${mlog%/*}"
  moonlight_flags mlf
  (( ${#mlf[@]} )) && cg_echo "    stream: ${mlf[*]}" || true
  # What was asked of Moonlight, at the top of its log: it never says itself.
  printf '# cg: moonlight stream %s %s %s\n' "${mlf[*]}" "$ip" "$app" > "$mlog"
  # In the background and waited on, so the window can be placed while it
  # runs. Still cg's child: Stop and session_end reach it as before.
  moonlight stream ${mlf[@]+"${mlf[@]}"} "$ip" "$app" >> "$mlog" 2>&1 &
  local mpid=$!
  if [[ " ${mlf[*]} " == *" --display-mode windowed "* && -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] \
     && command -v hyprctl >/dev/null; then
    local wsize=${GAME_WINDOW_SIZE:-${GAME_RES:-}}
    hypr_place "$mpid" "$wsize" "$mlog" &
  fi
  wait "$mpid" || true
  took=$(( SECONDS - t0 ))
  if (( took < 20 )); then
    log_as warn "the stream ended after ${took}s - Moonlight said:"
    # Its own warnings and errors, not the decoder probing that fills the rest.
    grep -E 'Qt (Warning|Critical)|SDL (Error|Critical)|[Ff]ailed to start|[Cc]onnection|offline' "$mlog" \
      | grep -vE 'QML|portal|libplacebo|VDPAU|AMF|v4l2m2m|cuvid|hwdevice|decoder for format' \
      | tail -4 | sed 's/^/    /' || true
    log "  all of it: $mlog"
  fi
  if _cg_styled; then _cg_line ok "session ended after $(_cg_dur "$took")"
  elif (( took < 60 )); then printf 'session ended after %ds\n' "$took"
  else printf 'session ended after %dm\n' $(( took / 60 )); fi
}
