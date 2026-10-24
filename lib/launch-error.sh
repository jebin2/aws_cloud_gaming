#!/usr/bin/env bash
# What to say when run-instances refuses.
#
# Sourced by lib/provision.sh, which does NOT source lib/common.sh - so this
# prints rather than logs. The first line carries the "!! " marker that
# cg_relay turns into a `fail` line, which is what lets the desktop app show
# the cause in its own panel instead of as line 183 of a scrolling log.
#
# One cause, not a list. The list that used to print here ran to 25 lines and
# pushed AWS's own message off the top of the screen, which is how a launch
# failure came to look like it had no error at all.

# The AWS error code, if the message has one. Both shapes appear depending on
# CLI version: "An error occurred (Code) when calling ..." and a bare code.
launch_error_code() { # launch_error_code <errfile>
  sed -nE 's/.*An error occurred \(([A-Za-z0-9.]+)\).*/\1/p' "$1" | head -1
}

# AWS's own sentence, with the CLI's framing stripped off. The framing is not
# one fixed shape: a retried call reads "... operation (reached max retries: 2):
# Insufficient capacity.", so everything up to the LAST ": " that follows the
# operation name goes, not just a bare "operation: ".
launch_error_message() { # launch_error_message <errfile>
  sed -E 's/^aws: \[ERROR\]: //
          s/.*An error occurred \([A-Za-z0-9.]+\) when calling the [A-Za-z]+ operation( \([^)]*\))?: //' "$1" \
    | grep -v '^[[:space:]]*$' | tail -2
}

# spot_holders - the spot machines in REGION that hold the spot allowance now,
# one "<id> <state> <type> <launched>" a line: any that exists counts, a
# stopped one and one still shutting down included. Read-only and free.
# Nothing when there are none; "?" when AWS could not be asked.
spot_holders() {
  local out t=()
  # Bounded where it can be: macOS has no timeout(1).
  command -v timeout >/dev/null && t=(timeout 20)
  out=$(${t[@]+"${t[@]}"} aws ec2 describe-instances --region "${REGION:-}" \
          --filters Name=instance-lifecycle,Values=spot \
                    Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
          --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime]' \
          --output text 2>/dev/null) || { echo "?"; return 0; }
  grep -v '^[[:space:]]*$' <<<"$out" || true
}

# launch_error_report <errfile> - reads TYPE, REGION, INSTANCE_PROFILE,
# KEY_NAME and KEY_FILE from the environment, as provision.sh has them set.
launch_error_report() {
  local f=$1 code msg
  code=$(launch_error_code "$f") || code=""
  msg=$(launch_error_message "$f") || msg=""

  # The headline is what the app shows on its own, so it says what happened in
  # words rather than repeating AWS's error code at someone who did not ask for
  # one. The code still appears - underneath, where it belongs when you are
  # searching for it.
  # The spot allowance is full: what fills it is asked, not guessed. "Your old
  # allocation, wait two minutes" was the guess - true just after a delete,
  # and wrong when a machine is still there, billing.
  local holders="" live=""
  if [[ $code == MaxSpotInstanceCountExceeded ]]; then
    holders=$(spot_holders)
    [[ $holders == "?" ]] || live=$(awk '$2 != "shutting-down"' <<<"$holders")
  fi

  local headline
  case "$code" in
    InsufficientInstanceCapacity|SpotMaxPriceTooLow)
      if [[ ${SPOT:-0} == 1 ]]; then
        headline="AWS has no spare ${TYPE:-instance} at the spot price in ${REGION:-this region}"
      else
        headline="AWS has no spare ${TYPE:-instance} in ${REGION:-this region} right now"
      fi ;;
    MaxSpotInstanceCountExceeded)
      if [[ -n $live ]]; then
        headline="a spot machine in ${REGION:-this region} is still there and holds your spot allowance: $(awk 'NR == 1 { print $1 " (" $2 ")" }' <<<"$live")"
      elif [[ -n $holders && $holders != "?" ]]; then
        headline="your previous spot machine is still shutting down - try again in a minute or two"
      else
        headline="your previous spot allocation has not been released yet"
      fi ;;
    VcpuLimitExceeded|InstanceLimitExceeded)
      headline="your AWS quota is too small for ${TYPE:-this machine} in ${REGION:-this region}" ;;
    InvalidKeyPair.NotFound)
      headline="the SSH key pair ${KEY_NAME:-} is missing from ${REGION:-this region}" ;;
    AccessDenied|AccessDeniedException|UnauthorizedOperation)
      headline="AWS refused the request: this key is not allowed to launch with a role" ;;
    OptInRequired|SubscriptionRequiredException|AuthFailure|UnauthorizedAccount|Blocked)
      headline="AWS refused the account itself" ;;
    *)
      headline="the instance could not be launched" ;;
  esac
  echo "!! $headline"
  # Nothing this build launched exists to clean up or pay for: run-instances
  # refusing is the one failure where that is certain, and it is the first
  # thing worth knowing - unless another machine is what refused it.
  if [[ -n $live ]]; then
    echo "    nothing was launched by this build - but the machine above is still billing"
  else
    echo "    nothing was launched, and nothing is billing"
  fi
  [[ -n $msg ]] && sed 's/^/    AWS said: /' <<<"$msg"
  [[ -n $code ]] && echo "    error code: $code"
  echo ""
  case "$code" in
    MaxSpotInstanceCountExceeded)
      if [[ -n $holders && $holders != "?" ]]; then
        echo "  Spot machines in ${REGION:-the region} right now:"
        awk '{ print "    " $1 "  " $2 "  " $3 "  launched " $4 }' <<<"$holders"
        echo ""
      fi
      if [[ -n $live ]]; then
        echo "  Each one counts against the spot allowance while it exists, stopped or not,"
        echo "  and a running one is billing. If it is the machine cg built, delete it -"
        echo "  Delete on the app's Machine page, or: cg destroy - then build again."
        echo "  Anything else is in the EC2 console."
        echo "  If the allowance is simply too small for two: GAME_SPOT=0 cg init (L-3819A6DF)"
      elif [[ -n $holders && $holders != "?" ]]; then
        echo "  It is on its way out; AWS frees its share of the allowance once it is gone."
        echo "  Nothing is wrong - try again in a minute or two."
      else
        echo "  Your own spot allocation is still held. AWS releases the vCPU quota a"
        echo "  minute or two AFTER an instance terminates, so an immediate rebuild"
        echo "  hits it. Nothing is wrong - wait ~2 minutes and run it again."
        echo "  If it persists, the quota (L-3819A6DF) is smaller than ${TYPE:-the instance} needs:"
        echo "    GAME_SPOT=0 cg init"
        echo "  What holds it: aws ec2 describe-spot-instance-requests --region ${REGION:-}"
      fi
      ;;
    InsufficientInstanceCapacity|SpotMaxPriceTooLow)
      # Which purchase model was asked for decides what there is to say. Telling
      # someone already on demand to "try on demand" is worse than saying
      # nothing: it reads as a fix, and they have nowhere to go after trying it.
      # Not your quota, not your setup, and not something retrying harder
      # fixes: the pool is empty. What matters is which of the four ways out
      # applies, and they differ by what was asked for.
      if [[ ${SPOT:-0} == 1 ]]; then
        echo "  Spot rents the machines nobody else is paying full price for, and there"
        echo "  are none of those here at the moment. On demand is the same machine at"
        echo "  the full price, and it has first claim - so it usually works when this"
        echo "  does not."
        echo ""
        echo "  Pay full price, and build now:"
        echo "      cg config set GAME_SPOT 0       (Settings > purchase model, in the app)"
        echo "  Try a different GPU - each shape is its own pool:"
        echo "      cg machines"
        echo "  Or see which region has capacity, free and about 90 seconds:"
        echo "      cg sweep                        (Scan all regions, in the app)"
        echo ""
        echo "  Or come back later. Spot capacity returns on its own, often within hours,"
        echo "  and nothing here needs fixing in the meantime."
      else
        echo "  This was an ON DEMAND launch, so there is no fuller-priced option left to"
        echo "  fall back to - the region is simply out of this machine."
        echo ""
        echo "  Try a different GPU - each shape is its own pool:"
        echo "      cg machines"
        echo "  Or see which region has capacity, free and about 90 seconds:"
        echo "      cg sweep                        (Scan all regions, in the app)"
        echo "      note: your game archive lives in ${REGION:-this region} and does not"
        echo "      follow you - a box elsewhere re-downloads what it needs."
        echo ""
        echo "  Or come back later. Capacity returns without warning, usually within hours."
      fi
      ;;
    VcpuLimitExceeded|InstanceLimitExceeded)
      echo "  The on-demand vCPU quota in ${REGION:-the region} is smaller than"
      echo "  ${TYPE:-this instance} needs. What you have: cg status"
      ;;
    AccessDenied|AccessDeniedException|UnauthorizedOperation)
      echo "  Launching with an instance profile needs iam:PassRole for"
      echo "  ${INSTANCE_PROFILE:-the instance profile}. Without it the box cannot reach"
      echo "  S3, and the game library will not survive a stop."
      ;;
    InvalidKeyPair.NotFound)
      echo "  The key pair ${KEY_NAME:-} no longer exists in ${REGION:-the region}."
      echo "  cg check --fix recreates it and the matching ${KEY_FILE:-.pem}."
      ;;
    OptInRequired|SubscriptionRequiredException|AuthFailure|UnauthorizedAccount|Blocked)
      echo "  AWS refused the ACCOUNT, not the request - a suspension, a verification"
      echo "  hold, or a payment problem. Read the console banner before changing"
      echo "  anything here; no amount of retrying fixes this one."
      ;;
    *)
      echo "  Not an error this script has been taught. The usual causes:"
      echo "    MaxSpotInstanceCountExceeded   your old allocation, wait ~2 minutes"
      echo "    InsufficientInstanceCapacity   region short of ${TYPE:-the instance}, GAME_SPOT=0 cg init"
      echo "    VcpuLimitExceeded              quota smaller than ${TYPE:-the instance} needs"
      echo "    AccessDenied on iam:PassRole   cannot pass ${INSTANCE_PROFILE:-the profile}"
      echo "  Spot requests: aws ec2 describe-spot-instance-requests --region ${REGION:-}"
      ;;
  esac
  echo ""
}
