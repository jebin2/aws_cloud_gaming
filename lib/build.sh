#!/usr/bin/env bash
# The second half of every build, whatever the machine is: an AWS box cg just
# launched, or a machine of your own. From "it is building itself" to "ready to
# play" - one path, so both say the same things in the same order and fail the
# same way. lib/setup (the AWS target) and lib/host.sh (your own) set it up.
#
# The target supplies:
#   BUILD_SSH   user@machine, as mssh reaches it
#   BUILD_KEY   its key file, or "" for your own ssh setup
#   BUILD_IP    its tailnet address
#   BUILD_SAVE  a function, called as  BUILD_SAVE KEY VALUE,  that keeps the
#               Sunshine login (.env for the AWS box, hosts.json for yours)
#   BUILD_NAME  how to name it in what is said ("the box", "homeserver")
# and may define two hooks:
#   build_after_stream   once the machine reports it is built
#   build_steam_report   once Steam has installed; may set STEAM_MSG
# It leaves PAIRED, STEAM_OK and STEAM_MSG for the summary.
#
# Returns 2 when the build itself did not finish - what to say about a machine
# left running is the target's business.

# shellcheck source=lib/sunshine-login.sh
source lib/sunshine-login.sh
# shellcheck source=lib/pair.sh
source lib/pair.sh

build_finish() {
  say "building ${BUILD_NAME:-the box} - live progress below ($(cg_build_takes))"
  stream_build "$BUILD_SSH" "$BUILD_KEY" || return 2
  if declare -F build_after_stream >/dev/null; then build_after_stream; fi
  IP=$BUILD_IP

  # Sunshine's first-run account can be created over its API, which removes the
  # "open a browser and invent a password" step. The PIN exchange cannot:
  # POST /api/pin needs a 32-hex pairing_id whose origin Sunshine does not
  # document and exposes no endpoint for, so that half stays manual.
  # Pair Moonlight without a browser. The one undocumented piece is GET /api/pin,
  # which lists pending pairing requests and their ids - found by reading the web
  # UI's own JS bundle, since the API reference documents only the POST. Without
  # it there is no way to learn the pairing_id that POST /api/pin demands.

  # Neutral heading: this block may create an account or find one already
    # there, and announcing "creating" before knowing which is how a rerun
    # came to look like it was regenerating credentials every time.
    say "Sunshine account"
  # Wait for Sunshine to answer before deciding anything. A connection failure
  # used to fall through to "already configured", which on a fresh box meant no
  # account was ever created and pairing then failed with stale credentials.
  # Poll /welcome itself, not /. Sunshine answers on / before /welcome is ready,
  # so checking / raced ahead and a not-yet-200 /welcome was misread as
  # "already configured" - which then skipped account creation and pairing.
  # Three outcomes, and each must END the loop as soon as it is certain:
  #   200          first run, no account yet      -> create one
  #   2xx/3xx/4xx  Sunshine is up and configured  -> nothing to do
  #   000          not listening yet              -> keep waiting
  #
  # This only broke on 200, so a configured box ran the loop to exhaustion: 40
  # iterations of sleep 3 + sleep 5 is over five minutes of waiting on every
  # rerun, for an answer it already had on the first request. Measured 6s now.
  #
  # A non-200 is confirmed a few times rather than trusted at once, because
  # Sunshine serves / and redirects for a moment before /welcome settles - which
  # is what an earlier single check got wrong in the other direction.
  SUN_UP=0; WELCOME=0; configured=0
  for _ in $(seq 1 40); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$IP:47990/welcome" 2>/dev/null || echo 000)
    case $code in
      200) SUN_UP=1; WELCOME=1; break ;;
      000) configured=0 ;;
      *)   SUN_UP=1; configured=$(( configured + 1 ))
           (( configured >= 3 )) && break ;;
    esac
    sleep 3
  done

  # The login: saved here first, checked against the box, set again on the box
  # when they disagree - lib/sunshine-login.sh, shared with your own machines.
  # shellcheck source=lib/sunshine-login.sh
  source lib/sunshine-login.sh
  if (( ! SUN_UP )); then
    log "Sunshine is not answering on $IP:47990 - skipping account and pairing"
    log "check on the box: systemctl --user status app-dev.lizardbyte.app.Sunshine.service"
  else
    sun_login_ensure "$IP" "$WELCOME" "$BUILD_SAVE" mssh "$BUILD_SSH" "$BUILD_KEY" || true
  fi

  say "moonlight pairing"
  PAIRED=0
  if command -v moonlight >/dev/null && timeout 45 moonlight list "$IP" 2>/dev/null | grep -q .; then
    log "already paired"
    PAIRED=1
  elif command -v moonlight >/dev/null && [[ -n ${SUNSHINE_USER:-} && -n ${SUNSHINE_PASS:-} ]]; then
    # Once more before giving up. A pairing that does not stick is now REPORTED
    # as a failure instead of printed as "paired", so a retry is worth the seconds.
    if pair_moonlight "$IP" "$SUNSHINE_USER" "$SUNSHINE_PASS" \
       || { log "pairing did not stick - trying once more"; pair_moonlight "$IP" "$SUNSHINE_USER" "$SUNSHINE_PASS"; }; then
      log "paired"
      PAIRED=1
    else
      log "automatic pairing failed - pair by hand, see below"
      PAIRED=0
    fi
  else
    log "skipped (moonlight or credentials missing) - pair by hand, see below"
    PAIRED=0
  fi
  say "waiting for Steam to finish installing"
  STEAM_OK=0
  STEAM_MSG="still installing - check ~/steam-prewarm.log on the box."
  if wait_for_steam "$BUILD_SSH" "$BUILD_KEY" 1500; then
    STEAM_OK=1
    STEAM_MSG="installed. Sign in and it is ready."
    if declare -F build_steam_report >/dev/null; then build_steam_report; fi

  fi
  return 0
}
