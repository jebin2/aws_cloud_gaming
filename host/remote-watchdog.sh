#!/usr/bin/env bash
# Layer 4: an off-site dead-man's switch. Runs on an always-on host - a VPS, a
# home server, anything with a systemd timer - and stops the game instance when
# it looks abandoned.
#
# It exists for the two cases the other layers cannot cover:
#   - the on-host watchdog dies with the box it protects
#   - the CloudWatch alarm can be deleted, disarmed, or simply misconfigured,
#     and it has stopped a box once in this project with no visible reasoning
#
# So the point of this layer is not just redundancy: every decision it makes is
# written down, with the numbers behind it.
set -uo pipefail
out=""

CFG=${CFG:-/etc/cloud-gaming-watchdog.conf}
[[ -r $CFG ]] && . "$CFG"

REGION="${GAME_REGION:?set GAME_REGION in $CFG}"
TS_HOST="${GAME_TS_HOST:-gamevps}"
IDLE_LIMIT="${IDLE_LIMIT:-6}"             # consecutive idle checks before stopping
THRESHOLD="${THRESHOLD:-10485760}"        # bytes in+out per window that counts as busy (10 MB)
WINDOW="${WINDOW:-300}"                   # seconds per CloudWatch datapoint
BOOT_GRACE="${BOOT_GRACE:-20}"            # minutes after launch before arming
STATE="${STATE:-/var/lib/cloud-gaming-watchdog}"
LOG="${LOG:-/var/log/cloud-gaming-watchdog.log}"

mkdir -p "$STATE"
say() { printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG"; logger -t cg-watchdog "$*" 2>/dev/null || true; }
aws_() { aws --region "$REGION" "$@"; }

# --- find the instance --------------------------------------------------------
# Distinguish "no instance" from "could not ask". Swallowing the error made a
# blind watchdog report "nothing to do" for half an hour while an instance was
# running: the units run as root and the credentials had been written to a
# user's home, so every call failed silently. A guard that cannot see must say
# so, not claim everything is fine.
if ! out=$(aws_ ec2 describe-instances \
  --filters "Name=tag:Name,Values=$TS_HOST" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].[InstanceId,LaunchTime,InstanceLifecycle]' --output text 2>&1); then
  say "CANNOT QUERY AWS - this watchdog is blind: ${out//$'\n'/ }"
  exit 1
fi
read -r ID LAUNCH LIFECYCLE <<<"$out"

if [[ -z ${ID:-} || $ID == None ]]; then
  echo 0 > "$STATE/idle"
  say "no running instance tagged $TS_HOST - nothing to do"
  exit 0
fi

# --- boot grace ---------------------------------------------------------------
# Mirrors the on-host watchdog: a box that has just come up is still installing,
# and a fresh instance has no metrics yet, which would otherwise read as idle.
age_min=$(( ( $(date +%s) - $(date -d "$LAUNCH" +%s 2>/dev/null || echo 0) ) / 60 ))
if (( age_min < BOOT_GRACE )); then
  echo 0 > "$STATE/idle"
  say "$ID up ${age_min}m - inside the ${BOOT_GRACE}m boot grace"
  exit 0
fi

# --- traffic in the last window ----------------------------------------------
# in + out, for the same reason the other two layers count both: streaming is
# outbound, a game download is inbound, and watching one direction stops the box
# in the middle of the other.
sum_metric() {
  aws_ cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name "$1" \
    --dimensions "Name=InstanceId,Value=$ID" --statistics Sum --period "$WINDOW" \
    --start-time "$(date -u -d "-$((WINDOW*3)) seconds" +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Sum' --output text 2>/dev/null
}
nin=$(sum_metric NetworkIn); nout=$(sum_metric NetworkOut)
[[ $nin  =~ ^[0-9.]+$ ]] || nin=""
[[ $nout =~ ^[0-9.]+$ ]] || nout=""

idle=$(cat "$STATE/idle" 2>/dev/null || echo 0)

if [[ -z $nin && -z $nout ]]; then
  # Running, past the grace period, and publishing nothing. This is the wedged
  # case the CloudWatch alarm used to treat as healthy, so count it as idle
  # rather than as an absence of evidence.
  idle=$(( idle + 1 ))
  say "$ID running but NO metrics (wedged?) idle=$idle/$IDLE_LIMIT"
else
  total=$(awk -v a="${nin:-0}" -v b="${nout:-0}" 'BEGIN{printf "%.0f", a+b}')
  if (( total >= THRESHOLD )); then
    idle=0
    say "$ID busy: in=${nin:-0}B out=${nout:-0}B total=${total}B - counter reset"
  else
    idle=$(( idle + 1 ))
    say "$ID quiet: in=${nin:-0}B out=${nout:-0}B total=${total}B < ${THRESHOLD}B idle=$idle/$IDLE_LIMIT"
  fi
fi
echo "$idle" > "$STATE/idle"

# --- act ----------------------------------------------------------------------
# Which verb depends on the purchase model, and the wrong one is worse than
# doing nothing:
#
#   on demand -> stop.      Reversible; you restart the box.
#   spot      -> terminate. Stopping a spot instance disables its request, so
#                           the box can never start again AND keeps billing for
#                           its root volume. Terminating is safe because the
#                           request is one-time and cannot relaunch, and the
#                           games are mirrored to S3 as the machine shuts down.
#
# Read from the same describe-instances call that found the instance, so this
# costs no extra API request and cannot disagree with it.
if (( idle >= IDLE_LIMIT )); then
  if [[ ${LIFECYCLE:-} == spot ]]; then VERB=terminate; else VERB=stop; fi
  say "idle limit reached - ${VERB%e}ing $ID (lifecycle: ${LIFECYCLE:-on-demand})"
  if aws_ ec2 "${VERB}-instances" --instance-ids "$ID" >/dev/null 2>&1; then
    say "$VERB issued for $ID"
    echo 0 > "$STATE/idle"
  else
    say "FAILED to $VERB $ID - check the IAM policy allows ec2:$(
      [[ $VERB == terminate ]] && echo TerminateInstances || echo StopInstances)"
  fi
fi
