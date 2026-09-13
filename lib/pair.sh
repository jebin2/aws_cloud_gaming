#!/usr/bin/env bash
# Moonlight <-> Sunshine pairing, on its own so it can be re-run.
#
# It used to live inside lib/setup, below the command dispatch - so the only way
# to reach it was a full `cg init`. When pairing failed (Sunshine reporting zero
# paired clients, Moonlight refusing to stream) the remedy was rebuilding the
# whole box, which is twenty minutes to redo a handshake that takes four
# seconds.
#
# Sourced by lib/setup during a build, and by `cg pair` on its own.

pair_moonlight() {
  local ip=$1 su=$2 sp=$3 pin pid tries=0
  pin=$(python3 -c 'import secrets;print(f"{secrets.randbelow(10000):04d}")')

  # An abandoned pairing process makes Sunshine reject the next attempt with
  # 409 "a pairing session with this uniqueid already exists". Match on the
  # actual moonlight binary and inspect its argv - `pkill -f "moonlight pair"`
  # also matches any shell whose command line merely contains that text,
  # including this script's own invocation.
  local p
  for p in $(pgrep -x moonlight 2>/dev/null || true); do
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q ' pair '; then
      kill "$p" 2>/dev/null || true
    fi
  done
  sleep 2

  # Moonlight must be waiting before Sunshine has a request to approve.
  #
  # QT_QPA_PLATFORM=offscreen because `moonlight pair` is the full Qt app and
  # otherwise flashes a window up that this function then has to kill. Offscreen
  # needs no display at all, so no window can appear. Verified that the binary
  # runs offscreen (`moonlight list` works with DISPLAY and WAYLAND_DISPLAY
  # unset); NOT verified through a real handshake, because this only happens on
  # a host that is not yet paired. Hence the fallback below: if no pairing
  # request reaches Sunshine, try again the normal way rather than leaving you
  # to pair by hand over a cosmetic improvement.
  local ml_env=(env QT_QPA_PLATFORM=offscreen) attempt=1
  ( "${ml_env[@]}" moonlight pair --pin "$pin" "$ip" >/dev/null 2>&1 ) &
  local mlpid=$!

  while (( tries < 20 )); do
    pid=$(curl -sk -u "$su:$sp" --max-time 10 "https://$ip:47990/api/pin" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    p = json.load(sys.stdin).get("pairings") or []
    print(p[0]["id"] if p else "")
except Exception:
    print("")' 2>/dev/null)
    [[ -n $pid ]] && break
    sleep 2; tries=$(( tries + 1 ))
  done
  # Fall back to the windowed invocation before giving up: offscreen is a
  # convenience, pairing is not.
  if [[ -z ${pid:-} ]] && (( attempt == 1 )); then
    kill "$mlpid" 2>/dev/null; wait "$mlpid" 2>/dev/null || true
    log "no pairing request seen offscreen - retrying with a window"
    attempt=2; tries=0
    ( moonlight pair --pin "$pin" "$ip" >/dev/null 2>&1 ) &
    mlpid=$!
    while (( tries < 20 )); do
      pid=$(curl -sk -u "$su:$sp" --max-time 10 "https://$ip:47990/api/pin" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d[0]["uniqueid"] if isinstance(d,list) and d else "")
except Exception:
    print("")' 2>/dev/null)
      [[ -n $pid ]] && break
      sleep 2; tries=$(( tries + 1 ))
    done
  fi
  [[ -n $pid ]] || { kill "$mlpid" 2>/dev/null; log "moonlight never registered a pairing request"; return 1; }

  if curl -sk -u "$su:$sp" --max-time 20 -X POST -H 'Content-Type: application/json' \
       -d "{\"pairing_id\":\"$pid\",\"pin\":\"$pin\",\"name\":\"$(hostname)\"}" \
       "https://$ip:47990/api/pin" 2>/dev/null | grep -q '"status":true'; then
    # `moonlight pair` runs the full Qt GUI and does not always close itself
    # once the handshake completes, so it sits there looking hung. Give it a
    # few seconds to exit cleanly, then close it.
    local w=0
    while (( w < 15 )) && kill -0 "$mlpid" 2>/dev/null; do sleep 1; w=$(( w + 1 )); done
    if kill -0 "$mlpid" 2>/dev/null; then
      kill "$mlpid" 2>/dev/null
      sleep 1
      kill -9 "$mlpid" 2>/dev/null || true
      log "closed the moonlight pairing window"
    fi
    wait "$mlpid" 2>/dev/null || true
    return 0
  fi
  kill "$mlpid" 2>/dev/null; wait "$mlpid" 2>/dev/null || true
  return 1
}
