#!/usr/bin/env bash
# The .env settings cg check and cg init need: asked for when missing, and saved.
# Sourced by lib/setup, after lib/common.sh and lib/cloud-watchdog.sh.
#
# Typed answers used to last one run - nothing wrote them to .env, so every run
# asked again - and the two optional settings were never asked for at all, only
# warned about. On a new laptop that meant a first cg init with no notifications.

settings_tty() { [[ -t 0 ]]; }

# settings_masked <prompt> - what is typed or pasted, on stdout, with a * on screen
# for each character. A plain hidden read showed nothing at all, so a pasted key
# looked as if the paste had failed. Backspace works. Escape sequences - the
# bracketed-paste markers some terminals wrap a paste in, arrow keys - are
# skipped, so they are neither shown nor saved. Returns 1 at end of input with
# nothing typed.
settings_masked() {
  local c v="" esc=0
  printf '%s' "$1" >&2
  while :; do
    if ! IFS= read -rsn1 c; then
      echo >&2
      [[ -n $v ]] || return 1
      break
    fi
    if (( esc )); then
      [[ $c == [A-Za-z~] ]] && esc=0
      continue
    fi
    case $c in
      ""|$'\r')      echo >&2; break ;;
      $'\e')         esc=1 ;;
      $'\x7f'|$'\b') if [[ -n $v ]]; then v=${v%?}; printf '\b \b' >&2; fi ;;
      *)             v+=$c; printf '*' >&2 ;;
    esac
  done
  printf '%s' "$v"
}

# settings_secret <prompt> <regex> <what> [optional] - a pasted secret, on stdout.
# Stray whitespace is removed, and up to three tries are given. Returns 1 with no
# usable answer; an optional one returns an empty value when Enter is pressed on
# its own.
settings_secret() {
  local prompt=$1 re=$2 what=$3 optional=${4:-} v try
  for try in 1 2 3; do
    v=$(settings_masked "$prompt") || return 1     # end of input: no answer, not a skip
    v=${v//[[:space:]]/}
    if [[ -z $v ]]; then
      [[ -n $optional ]] && return 0
      echo "    nothing arrived - paste with Ctrl+Shift+V (or right-click, Paste), then press Enter" >&2
      continue
    fi
    if [[ $v =~ $re ]]; then
      printf '%s' "$v"
      return 0
    fi
    echo "    that is not a $what - check you copied all of it, and paste again" >&2
  done
  return 1
}

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
    GAME_TS_AUTHKEY=$(settings_secret "  paste auth key: " '^tskey-[A-Za-z0-9-]+$' "Tailscale auth key") \
      || die "no auth key given - copy it from the Tailscale page and paste it with Ctrl+Shift+V"
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
    if v=$(settings_secret "  paste API token (Enter to skip): " '^tskey-[A-Za-z0-9-]+$' \
             "Tailscale API token" optional); then
      env_set TAILSCALE_API_KEY "$v"
      export TAILSCALE_API_KEY="$v"
    else
      log_as fail "no valid API token - not saved, so cg check --fix asks again"
    fi
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
    v=$(settings_secret "  ntfy topic or URL (Enter to skip): " '^[A-Za-z0-9:/._-]+$' \
          "ntfy topic or URL" optional) || v="-"
    if [[ $v == "-" || ( -n $v && -z $(GAME_NTFY_URL="$v" cg_ntfy_url) ) ]]; then
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
