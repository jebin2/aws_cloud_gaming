#!/usr/bin/env bash
# The end of cg init: what you now have, and only then what is left to do.
# Sourced by lib/setup - not run directly. It reads the build's own variables:
# TS_NODE, IP, PAIRED, EXPIRY_OFF, SUNSHINE_USER, GAME_INSTANCE_ID, REGION, TYPE,
# GAME_SPOT, GAMES_LIB, STEAM_MSG, SSH and the C_* command names.
#
# It used to be a list of numbered steps, most of which said "[DONE
# automatically]". Once pairing and key expiry both happen on their own, a list
# of finished chores is noise; what is worth seeing is what the box ended up
# with, and where to look if something is off.
#
# The Sunshine PASSWORD is deliberately not printed. This output gets pasted
# into chats and issues; the password stays in .env as SUNSHINE_PASS.

# What only the box knows, in one ssh round trip. Tab-separated lines:
#   login <yes|no>                 a Steam login token is present
#   library <yes|no>               the games library is registered with Steam
#   game <appid> <bytes> <name>    one per installed app manifest
summary_box_facts() { # summary_box_facts <games library dir>
  $SSH 'bash -s' "$1" <<'REMOTE' 2>/dev/null
lib=$1
if grep -q '"ConnectCache"' ~/.local/share/Steam/local.vdf 2>/dev/null; then
  printf 'login\tyes\n'; else printf 'login\tno\n'; fi
if grep -qF "$lib" ~/.steam/steam/config/libraryfolders.vdf 2>/dev/null; then
  printf 'library\tyes\n'; else printf 'library\tno\n'; fi
for m in "$lib"/steamapps/appmanifest_*.acf; do
  [ -f "$m" ] || continue
  id=$(sed -nE 's/^[[:space:]]*"appid"[[:space:]]*"([0-9]+)".*/\1/p' "$m" | head -n 1)
  size=$(sed -nE 's/^[[:space:]]*"SizeOnDisk"[[:space:]]*"([0-9]+)".*/\1/p' "$m" | head -n 1)
  name=$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*"(.*)".*/\1/p' "$m" | head -n 1)
  printf 'game\t%s\t%s\t%s\n' "$id" "${size:-0}" "$name"
done
REMOTE
}

# A row: an emoji and a label on a terminal, the label alone anywhere else - so a
# redirected build log stays plain, like every other report here.
summary_row() { # summary_row <emoji> <label> <text>
  if _cg_styled; then printf '  %s %-10s %s\n' "$1" "$2" "$3"
  else printf '  %-12s %s\n' "$2" "$3"; fi
}
summary_more() { # summary_more <text>   - a continuation line under the last row
  if _cg_styled; then printf '  %-13s %s\n' "" "$1"
  else printf '  %-12s %s\n' "" "$1"; fi
}

summary_pair_step() {
  cat <<EOF
  STEP - pair Moonlight   [ACTION NEEDED]
  ------------------------------------------------------------------
  a) Run this. It prints a 4-digit PIN and waits:

       moonlight pair $IP

  b) Open this, log in with SUNSHINE_USER / SUNSHINE_PASS from .env,
     go to 'PIN', and enter that PIN. Accept the certificate warning.

       https://$IP:47990

  c) Confirm - this should list Desktop:

       moonlight list $IP
EOF
}

summary_expiry_step() {
  cat <<EOF
  STEP - stop the Tailscale key expiring   [ACTION NEEDED]
  ------------------------------------------------------------------
  Tailscale keys expire after ~180 days by default. When this one does,
  the node drops off the tailnet and $C_OPEN hangs waiting for it.
  cg init does this itself when TAILSCALE_API_KEY is set and valid; why it
  could not this time is under "turning off Tailscale key expiry" above.

       https://login.tailscale.com/admin/machines

  Find "$TS_NODE" -> the "..." menu -> Disable key expiry.
EOF
}

init_summary() {
  local facts login="" library="" games="" left=0 title
  facts=$(summary_box_facts "$GAMES_LIB") || facts=""
  if [[ -n $facts ]]; then
    login=$(awk -F'\t' '$1 == "login" {print $2}' <<<"$facts")
    library=$(awk -F'\t' '$1 == "library" {print $2}' <<<"$facts")
    # Proton and the Steam runtimes have manifests too; they are not games.
    games=$(awk -F'\t' '$1 == "game" && $4 !~ /^(Proton|Steam Linux Runtime|Steamworks Common)/ {
              printf "%s\t%.1f GB\n", $4, $3 / 1073741824 }' <<<"$facts")
  fi
  (( ${PAIRED:-0} )) || left=$((left + 1))
  (( ${EXPIRY_OFF:-0} )) || left=$((left + 1))
  case $left in
    0) title="Ready · $TS_NODE" ;;
    1) title="Ready · 1 step left" ;;
    *) title="Ready · $left steps left" ;;
  esac

  {
  echo
  summary_row "🚀" "Box" "${GAME_INSTANCE_ID:-unknown} · $TYPE $([[ ${GAME_SPOT:-0} == 1 ]] && echo spot || echo on-demand) · $REGION"
  summary_more "billing by the hour - end it with: cg destroy"

  summary_row "🌐" "Tailscale" "$TS_NODE · $IP · key expiry $( (( ${EXPIRY_OFF:-0} )) && echo off || echo "ON - see below")"
  summary_more "https://login.tailscale.com/admin/machines"

  summary_row "🎮" "Moonlight" "$( (( ${PAIRED:-0} )) && echo "paired with Sunshine" || echo "NOT paired - see below")"
  summary_row "🔑" "Sunshine" "https://$IP:47990"
  summary_more "user ${SUNSHINE_USER:-admin} · password: SUNSHINE_PASS in .env"

  local steam
  if [[ ${STEAM_MSG:-} == "still installing"* ]]; then
    steam="still installing - check: cg log steam"
  else
    case $login in
      yes) steam="signed in" ;;
      no)  steam="not signed in - sign in once, and the next push saves it" ;;
      *)   steam="unknown - the box did not answer" ;;
    esac
  fi
  summary_row "🛒" "Steam" "$steam"
  case $library in
    yes) summary_more "library $GAMES_LIB registered" ;;
    no)  summary_more "library NOT registered - add $GAMES_LIB in Steam > Settings > Storage" ;;
  esac

  if [[ -z $facts ]]; then
    summary_row "📦" "Games" "unknown - the box did not answer"
  elif [[ -z $games ]]; then
    summary_row "📦" "Games" "none installed"
  else
    local first=1 name size line
    while IFS=$'\t' read -r name size; do
      line=$(printf '%-30s %9s' "$name" "$size")
      if (( first )); then summary_row "📦" "Games" "$line"; first=0
      else summary_more "$line"; fi
    done <<<"$games"
  fi

  local rule days watchdog
  rule=$(cw_aws events describe-rule --name "$CW_NAME" --query State --output text 2>/dev/null) || rule=""
  if [[ $rule == ENABLED ]]; then watchdog="cloud watchdog $(cw_int "${GAME_WATCHDOG_IDLE_MIN:-}" 30) min"
  else watchdog="cloud watchdog NOT armed - run: cg watchdog install"; fi
  summary_row "🔒" "Guards" "on-host 15 min · $watchdog"
  days=$(cw_expiry_days)
  if (( days == 0 )); then summary_more "game archive kept forever"
  else summary_more "game archive deleted after $days days with no box"; fi
  summary_more "budget \$$(awk -v i="${GAME_BUDGET_INR:-5000}" 'BEGIN{printf "%.0f", i/88}') · notifications $([[ -n $(cg_ntfy_url) ]] && echo on || echo "off (set GAME_NTFY_URL)")"
  echo

  if ! (( ${PAIRED:-0} )); then summary_pair_step; echo; fi
  if ! (( ${EXPIRY_OFF:-0} )); then summary_expiry_step; echo; fi

  echo "  $C_OPEN to play · $C_STATUS · cg destroy when done"
  echo
  } | cg_block "🎉" "$title"
}
