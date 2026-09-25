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
  # A driven run answers on stdin; there are no keystrokes to mask.
  if cg_json; then IFS= read -r v || return 1; printf '%s' "$v"; return 0; fi
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
  local prompt=$1 re=$2 what=$3 optional=${4:-} v try id
  id=${what,,}; id=${id// /-}
  for try in 1 2 3; do
    cg_json && _cg_event ask id "$id" prompt "$prompt" default "" secret 1
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

# settings_number <KEY> <default> <min> <prompt> - a whole number, asked with its
# default shown. Enter keeps the default, and either way the value is saved, so it
# is not asked again. Three tries; end of input saves nothing.
settings_number() {
  local key=$1 def=$2 min=$3 prompt=$4 v try
  for try in 1 2 3; do
    if cg_json; then
      _cg_event ask id "${key,,}" prompt "$prompt" default "$def"
    else
      # The prompt is printed here, not by read -p, which shows it only on a terminal.
      printf '%s [%s]: ' "$prompt" "$def" >&2
    fi
    IFS= read -r v || { cg_json || echo >&2; return 1; }
    v=${v//[[:space:]]/}; v=${v:-$def}
    if [[ $v =~ ^[0-9]+$ ]] && (( 10#$v >= min )); then
      v=$((10#$v))
      env_set "$key" "$v"
      export "$key=$v"
      return 0
    fi
    echo "    a whole number, at least $min - try again" >&2
  done
  return 1
}

# settings_prompts <fix: 0|1>
#   required  TAILSCALE_AUTH_KEY, EMAIL_ALERTS - asked whenever missing
#   optional  TAILSCALE_API_KEY, GAME_DISK_GB, GAME_ARCHIVE_EXPIRY_DAYS, GAME_NTFY_URL -
#             asked by --fix, with the default shown, and only when .env does not
#             mention them: whatever is answered is saved, so it is not asked again
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
    GAME_ALERT_EMAIL=$(cg_ask alert-email "  email for billing alerts (comma-separated for several): ")
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

  if [[ -z ${GAME_DISK_GB+set} ]] && (( fix )) && settings_tty; then
    echo
    echo "Root disk, in GB: the OS, the driver and Steam - games live on the box's own NVMe."
    echo "About INR 8 per GB a month while the box exists, and it cannot be shrunk later."
    settings_number GAME_DISK_GB 50 30 "  root disk GB" \
      || log_as fail "no disk size saved - the default, 50 GB, is used, and cg check --fix asks again"
  fi
  log_as info "root disk ${GAME_DISK_GB:-50} GB$([[ -z ${GAME_DISK_GB:-} ]] && echo " (the default)")"

  if [[ -z ${GAME_ARCHIVE_EXPIRY_DAYS+set} ]] && (( fix )) && settings_tty; then
    echo
    echo "Days with no box before the cloud watchdog deletes your game archive in S3 (about"
    echo "INR 350 a month for 160 GB). 0 keeps it forever. The next cg init applies a change."
    settings_number GAME_ARCHIVE_EXPIRY_DAYS 14 0 "  delete the archive after how many days" \
      || log_as fail "no expiry saved - the default, 14 days, is used, and cg check --fix asks again"
  fi
  if [[ ${GAME_ARCHIVE_EXPIRY_DAYS:-14} == 0 ]]; then
    log_as info "game archive: kept forever (GAME_ARCHIVE_EXPIRY_DAYS=0)"
  else
    log_as info "game archive: deleted after ${GAME_ARCHIVE_EXPIRY_DAYS:-14} days with no box"
  fi

  cw_adopt_ntfy
  if [[ -z ${GAME_NTFY_URL+set} ]] && (( fix )) && settings_tty; then
    echo
    echo "Optional: notifications on your phone. Install the ntfy app, subscribe to a long random"
    echo "topic name, and paste that name (or a full ntfy URL) here. Enter skips."
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
