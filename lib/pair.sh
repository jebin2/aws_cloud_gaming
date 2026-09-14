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
#
# Success is a NEW CLIENT IN SUNSHINE'S LIST, nothing less. On 2026-09-14 this
# returned success because Sunshine accepted the PIN - `cg init` printed "paired"
# - while Sunshine had saved no client at all, and Moonlight then refused to
# stream. Accepting the PIN is the request; a saved client is the result.

# The id of the pairing request Moonlight has open, or nothing.
# Live shape (Sunshine, 2026-09-14): {"pairings":[{"id":...}]}. The windowed
# fallback used to parse this as a bare list with a "uniqueid", which the API
# never returns - so the fallback could not succeed.
_sunshine_pending_id() { # <ip> <user> <pass>
  curl -sk -u "$2:$3" --max-time 10 "https://$1:47990/api/pin" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    p = json.load(sys.stdin).get("pairings") or []
    print(p[0]["id"] if p else "")
except Exception:
    print("")' 2>/dev/null
}

# The uuids of clients Sunshine has saved, one per line.
# Live shape: {"named_certs":[{"name","uuid","enabled"}],"status":true}.
_sunshine_client_uuids() { # <ip> <user> <pass>
  curl -sk -u "$2:$3" --max-time 10 "https://$1:47990/api/clients/list" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    for c in json.load(sys.stdin).get("named_certs") or []:
        print(c.get("uuid",""))
except Exception:
    pass' 2>/dev/null
}

pair_moonlight() {
  local ip=$1 su=$2 sp=$3 pin pid tries=0
  local max_tries=${PAIR_TRIES:-20} verify_tries=${PAIR_VERIFY_TRIES:-10}
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

  # What is already saved, so "a client appeared" means THIS pairing and not a
  # leftover from an earlier one.
  local before; before=$(_sunshine_client_uuids "$ip" "$su" "$sp")

  # Moonlight must be waiting before Sunshine has a request to approve.
  #
  # QT_QPA_PLATFORM=offscreen because `moonlight pair` is the full Qt app and
  # otherwise flashes a window up that this function then has to kill. If no
  # pairing request reaches Sunshine that way, try again the normal way rather
  # than leaving you to pair by hand over a cosmetic improvement.
  ( env QT_QPA_PLATFORM=offscreen moonlight pair --pin "$pin" "$ip" >/dev/null 2>&1 ) &
  local mlpid=$!
  while (( tries < max_tries )); do
    pid=$(_sunshine_pending_id "$ip" "$su" "$sp")
    [[ -n $pid ]] && break
    sleep 2; tries=$(( tries + 1 ))
  done
  if [[ -z ${pid:-} ]]; then
    kill "$mlpid" 2>/dev/null; wait "$mlpid" 2>/dev/null || true
    log "no pairing request seen offscreen - retrying with a window"
    tries=0
    ( moonlight pair --pin "$pin" "$ip" >/dev/null 2>&1 ) &
    mlpid=$!
    while (( tries < max_tries )); do
      pid=$(_sunshine_pending_id "$ip" "$su" "$sp")
      [[ -n $pid ]] && break
      sleep 2; tries=$(( tries + 1 ))
    done
  fi
  [[ -n $pid ]] || { kill "$mlpid" 2>/dev/null; log "moonlight never registered a pairing request"; return 1; }

  if ! curl -sk -u "$su:$sp" --max-time 20 -X POST -H 'Content-Type: application/json' \
       -d "{\"pairing_id\":\"$pid\",\"pin\":\"$pin\",\"name\":\"$(hostname)\"}" \
       "https://$ip:47990/api/pin" 2>/dev/null | grep -q '"status":true'; then
    kill "$mlpid" 2>/dev/null; wait "$mlpid" 2>/dev/null || true
    log "Sunshine rejected the PIN"
    return 1
  fi

  # Wait for the client to be SAVED, with Moonlight still running - the
  # handshake finishes on Moonlight's side, so it is not closed until the
  # result is in.
  local after new="" v=0
  while (( v < verify_tries )); do
    after=$(_sunshine_client_uuids "$ip" "$su" "$sp")
    new=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | grep -v '^$' || true)
    [[ -n $new ]] && break
    sleep 2; v=$(( v + 1 ))
  done

  # `moonlight pair` runs the full Qt GUI and does not always close itself
  # once the handshake completes, so it sits there looking hung.
  local w=0
  while (( w < 15 )) && kill -0 "$mlpid" 2>/dev/null; do sleep 1; w=$(( w + 1 )); done
  if kill -0 "$mlpid" 2>/dev/null; then
    kill "$mlpid" 2>/dev/null
    sleep 1
    kill -9 "$mlpid" 2>/dev/null || true
    log "closed the moonlight pairing window"
  fi
  wait "$mlpid" 2>/dev/null || true

  if [[ -z $new ]]; then
    log "Sunshine accepted the PIN but saved no client - NOT paired"
    return 1
  fi
  return 0
}
