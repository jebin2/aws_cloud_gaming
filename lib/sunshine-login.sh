#!/usr/bin/env bash
# The Sunshine login: this laptop and the machine must never hold different ones.
#
# Shared by the AWS build (lib/setup) and your own machines (lib/host.sh): the
# same three rules wherever Sunshine runs.
#   1. A new password is saved HERE before the machine is given it. Saved after,
#      an init that ended in between - the app closed mid-build - left the
#      machine with a password nothing here knew, and every pairing failed.
#   2. The saved login is checked against the machine, not assumed - which also
#      catches a reply lost after Sunshine took the password.
#   3. When they disagree, it is set again ON the machine (sunshine --creds over
#      ssh), which needs no old password.
#
# The caller says where a login is kept (a save function) and how to reach the
# machine (an ssh command); SUNSHINE_USER and SUNSHINE_PASS carry the login.

# sun_login_ok <ip> <user> <pass> - 0 when Sunshine takes this login: the same
# authenticated call pairing makes.
sun_login_ok() {
  [[ -n ${2:-} && -n ${3:-} ]] || return 1
  [[ $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -u "$2:$3" \
         "https://$1:47990/api/clients/list" 2>/dev/null) == 200 ]]
}

# sun_new_login <save-fn> - a fresh password, saved before anything uses it.
sun_new_login() {
  SUNSHINE_USER="${SUNSHINE_USER:-admin}"
  SUNSHINE_PASS="$(python3 -c 'import secrets;print(secrets.token_urlsafe(18))')"
  "$1" SUNSHINE_USER "$SUNSHINE_USER"
  "$1" SUNSHINE_PASS "$SUNSHINE_PASS"
}

# sun_login_ensure <ip> <first-run 0|1> <save-fn> <ssh command...>
# Leaves SUNSHINE_USER/SUNSHINE_PASS holding a login the machine accepts, and
# says what it did through `log`. Returns 1 only when that could not be done.
sun_login_ensure() {
  local ip=$1 welcome=$2 save=$3; shift 3
  if (( welcome )); then
    sun_new_login "$save"
    curl -sk --max-time 15 -X POST -H 'Content-Type: application/json' \
         -d "{\"newUsername\":\"$SUNSHINE_USER\",\"newPassword\":\"$SUNSHINE_PASS\",\"confirmNewPassword\":\"$SUNSHINE_PASS\"}" \
         "https://$ip:47990/api/password" >/dev/null 2>&1 || true
  fi
  if sun_login_ok "$ip" "${SUNSHINE_USER:-}" "${SUNSHINE_PASS:-}"; then
    if (( welcome )); then log "created; credentials saved"; else log "already configured, and the saved login works"; fi
    return 0
  fi
  if [[ -z ${SUNSHINE_PASS:-} ]]; then
    log "no Sunshine login saved here yet - setting one on the machine"
  else
    log "the machine's Sunshine login is not the one saved here - setting it again on the machine"
  fi
  sun_new_login "$save"
  # sunshine --creds writes the login and exits; a restart makes the running
  # Sunshine read it. The unit is found rather than named: the package names
  # it differently from one distribution to the next.
  if "$@" "sunshine --creds '$SUNSHINE_USER' '$SUNSHINE_PASS' >/dev/null 2>&1 \
         && u=\$(XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user list-unit-files '*unshine*' --no-legend 2>/dev/null | awk 'NR==1{print \$1}') \
         && XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user restart \"\$u\"" 2>/dev/null; then
    local _
    for _ in $(seq 1 20); do sun_login_ok "$ip" "$SUNSHINE_USER" "$SUNSHINE_PASS" && break; sleep 3; done
  fi
  if sun_login_ok "$ip" "$SUNSHINE_USER" "$SUNSHINE_PASS"; then
    log "reset; credentials saved"
    return 0
  fi
  log "could not set the Sunshine login - do it in the browser at https://$ip:47990"
  return 1
}
