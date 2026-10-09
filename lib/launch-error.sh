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

# launch_error_report <errfile> - reads TYPE, REGION, INSTANCE_PROFILE,
# KEY_NAME and KEY_FILE from the environment, as provision.sh has them set.
launch_error_report() {
  local f=$1 code msg
  code=$(launch_error_code "$f") || code=""
  msg=$(launch_error_message "$f") || msg=""

  echo "!! launch failed${code:+: $code}"
  [[ -n $msg ]] && sed 's/^/    /' <<<"$msg"
  echo ""
  case "$code" in
    MaxSpotInstanceCountExceeded)
      echo "  Your own spot allocation is still held. AWS releases the vCPU quota a"
      echo "  minute or two AFTER an instance terminates, so an immediate rebuild"
      echo "  hits it. Nothing is wrong - wait ~2 minutes and run it again."
      echo "  If it persists, the quota (L-3819A6DF) is smaller than ${TYPE:-the instance} needs:"
      echo "    GAME_SPOT=0 cg init"
      echo "  What holds it: aws ec2 describe-spot-instance-requests --region ${REGION:-}"
      ;;
    InsufficientInstanceCapacity|SpotMaxPriceTooLow)
      # Which purchase model was asked for decides what there is to say. Telling
      # someone already on demand to "try on demand" is worse than saying
      # nothing: it reads as a fix, and they have nowhere to go after trying it.
      if [[ ${SPOT:-0} == 1 ]]; then
        echo "  No spare ${TYPE:-instance} SPOT capacity in ${REGION:-the region} right now."
        echo "  Nothing pins the AZ any more, so this is the whole region being short,"
        echo "  not one zone. On demand has first claim on the same machines:"
        echo "    GAME_SPOT=0 cg init"
        echo "  Another GPU is a separate pool, and may have capacity: cg machines"
      else
        echo "  No spare ${TYPE:-instance} capacity in ${REGION:-the region} at all - this is"
        echo "  ON DEMAND, so there is no fuller-priced model left to fall back to."
        echo "  Nothing pins the AZ, so the whole region is short of this machine."
        echo "  What is left:"
        echo "    cg machines          another GPU is a separate pool of hardware"
        echo "    --region <other>     another region, but your archive is not in it"
        echo "  Or wait: capacity comes back without warning, usually within hours."
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
