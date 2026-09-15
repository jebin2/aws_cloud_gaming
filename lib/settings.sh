#!/usr/bin/env bash
# The .env settings cg check and cg init need: asked for when missing, and saved.
# Sourced by lib/setup, after lib/common.sh and lib/cloud-watchdog.sh.
#
# Typed answers used to last one run - nothing wrote them to .env, so every run
# asked again - and the two optional settings were never asked for at all, only
# warned about. On a new laptop that meant a first cg init with no notifications.

settings_tty() { [[ -t 0 ]]; }

# settings_prompts <fix: 0|1>
#   required  TAILSCALE_AUTH_KEY, EMAIL_ALERTS - asked whenever missing
#   optional  TAILSCALE_API_KEY, GAME_NTFY_URL - asked by --fix, and only when .env
#             does not mention them: an empty KEY= is a choice to go without, so
#             it is not asked again
# Values are saved to .env and never printed.
settings_prompts() {
  local fix=${1:-0} v
  # Accept the names these are commonly already exported under.
  : "${GAME_TS_AUTHKEY:=${TAILSCALE_AUTH_KEY:-}}"
  : "${GAME_ALERT_EMAIL:=${EMAIL_ALERTS:-}}"

  if [[ -z $GAME_TS_AUTHKEY ]]; then
    echo
    echo "A Tailscale pre-auth key is needed to join the box to your tailnet."
    echo "Generate one at: https://login.tailscale.com/admin/settings/keys"
    echo "  Reusable: on  - a retry needs a key that has not been spent."
    echo "  Ephemeral: OFF - ephemeral nodes are purged when they go offline, and"
    echo "             this box goes offline every time the watchdog stops it."
    read -rsp "  paste auth key: " GAME_TS_AUTHKEY || true; echo
    [[ -n $GAME_TS_AUTHKEY ]] || die "no auth key given"
    env_set TAILSCALE_AUTH_KEY "$GAME_TS_AUTHKEY"
  fi
  if [[ -z $GAME_ALERT_EMAIL ]]; then
    read -rp "  email for billing alerts (comma-separated for several): " GAME_ALERT_EMAIL || true
    [[ -n $GAME_ALERT_EMAIL ]] || die "no email given"
    env_set EMAIL_ALERTS "$GAME_ALERT_EMAIL"
  fi
  export GAME_TS_AUTHKEY GAME_ALERT_EMAIL
  log_as ok "Tailscale auth key and alert email set"

  if [[ -z ${TAILSCALE_API_KEY+set} ]] && (( fix )) && settings_tty; then
    echo
    echo "Optional: a Tailscale API access token - not the auth key. With it, cg init removes old"
    echo "box entries, so the box keeps its name, and turns off the box's key expiry."
    echo "Generate one at: https://login.tailscale.com/admin/settings/keys"
    read -rsp "  paste API token (Enter to skip): " v || true; echo
    env_set TAILSCALE_API_KEY "$v"
    export TAILSCALE_API_KEY="$v"
  fi
  if [[ -n ${TAILSCALE_API_KEY:-} ]]; then
    log_as ok "Tailscale API key set - old nodes are pruned and key expiry is turned off"
  else
    log_as warn "no TAILSCALE_API_KEY - old nodes and key expiry stay manual"
  fi

  cw_adopt_ntfy
  if [[ -z ${GAME_NTFY_URL+set} ]] && (( fix )) && settings_tty; then
    echo
    echo "Optional: phone notifications through ntfy - a long random topic name, or a full ntfy URL."
    read -rsp "  ntfy topic or URL (Enter to skip): " v || true; echo
    if [[ -n $v && -z $(GAME_NTFY_URL="$v" cg_ntfy_url) ]]; then
      log_as fail "that is not a valid ntfy topic or URL - not saved, so cg check --fix asks again"
    else
      env_set GAME_NTFY_URL "$v"
      export GAME_NTFY_URL="$v"
    fi
  fi
  if [[ -n ${GAME_NTFY_URL:-} ]]; then
    log_as ok "notifications on (GAME_NTFY_URL set)"
  else
    log_as info "notifications off - GAME_NTFY_URL not set"
  fi
}
