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
# moonlight_gpu - on a laptop with an Intel and an NVIDIA GPU, Moonlight runs on
# the Intel one and never touches NVIDIA's. Before it streams, Moonlight tries
# every GPU it can find - a test window, a test decode - and a hung NVIDIA
# driver (Xid 109, seen on one such laptop) freezes any process that opens it:
# Moonlight sat at "connecting" and never asked the host for anything. Intel
# decodes a game stream perfectly well. Only what is installed is set, and a
# choice already made in the environment is left alone. Exported once, here,
# for every Moonlight cg starts - the stream, pairing, the "is it paired" check
# - and said in MOONLIGHT_GPU. CG_GPU_ROOT is for tests.
moonlight_gpu() {
  local root=${CG_GPU_ROOT:-} d drv intel="" va="" vk="" egl
  MOONLIGHT_GPU=""
  if [[ -n ${__GLX_VENDOR_LIBRARY_NAME:-}${__EGL_VENDOR_LIBRARY_FILENAMES:-}${LIBVA_DRIVER_NAME:-}${VK_DRIVER_FILES:-}${VK_ICD_FILENAMES:-} ]]; then
    # Chosen already - by you, or by the app, which makes the same choice for
    # itself before it starts cg. Said when it is this one.
    [[ ${__GLX_VENDOR_LIBRARY_NAME:-} == mesa ]] && MOONLIGHT_GPU="the Intel GPU (NVIDIA left alone)"
    return 0
  fi
  [[ -e $root/dev/nvidiactl || -e $root/proc/driver/nvidia/version ]] || return 0
  for d in "$root"/sys/class/drm/renderD*/device/driver; do
    drv=$(readlink -f "$d" 2>/dev/null) || continue
    case ${drv##*/} in i915|xe) intel=1 ;; esac
  done
  [[ -n $intel ]] || return 0
  egl=$root/usr/share/glvnd/egl_vendor.d/50_mesa.json
  for vk in "$root/usr/share/vulkan/icd.d/intel_icd.$(uname -m).json" "$root/usr/share/vulkan/icd.d/intel_icd.json" ""; do
    [[ -z $vk || -f $vk ]] && break
  done
  for d in "$root/usr/lib/dri" "$root/usr/lib64/dri" "$root/usr/lib/x86_64-linux-gnu/dri"; do
    if [[ -f $d/iHD_drv_video.so ]]; then va=iHD; break; fi
    [[ -f $d/i965_drv_video.so ]] && va=i965
  done
  export __GLX_VENDOR_LIBRARY_NAME=mesa
  if [[ -f $egl ]]; then export __EGL_VENDOR_LIBRARY_FILENAMES=$egl; fi
  if [[ -n $vk ]]; then export VK_DRIVER_FILES=$vk VK_ICD_FILENAMES=$vk; fi
  if [[ -n $va ]]; then export LIBVA_DRIVER_NAME=$va; fi
  MOONLIGHT_GPU="the Intel GPU (NVIDIA left alone)"
}
[[ $(uname -s) == Linux ]] && moonlight_gpu

# No display mode: Moonlight keeps its own, full screen unless changed there. A
# GAME_DISPLAY_MODE left in .env by the window mode that was tried and removed
# is not passed on.
moonlight_flags() {
  local -n _mf=$1
  _mf=()
  [[ -n ${GAME_RES:-} ]]          && _mf+=(--resolution "$GAME_RES") || true
  [[ -n ${GAME_FPS:-} ]]          && _mf+=(--fps "$GAME_FPS") || true
  [[ -n ${GAME_BITRATE_KBPS:-} ]] && _mf+=(--bitrate "$GAME_BITRATE_KBPS") || true
  [[ -n ${GAME_VIDEO_CODEC:-} ]]  && _mf+=(--video-codec "$GAME_VIDEO_CODEC") || true
  [[ ${GAME_PERF_OVERLAY:-0} == 1 ]] && _mf+=(--performance-overlay) || true
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
  [[ -n ${MOONLIGHT_GPU:-} ]] && cg_echo "    decoding on $MOONLIGHT_GPU" || true
  moonlight stream ${mlf[@]+"${mlf[@]}"} "$ip" "$app" > "$mlog" 2>&1 || true
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
