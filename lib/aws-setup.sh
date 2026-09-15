#!/usr/bin/env bash
# Account-side guard setup: the shutdown behaviour check and the budget. Run locally.
set -euo pipefail

# .env is written by provision.sh. Anything already exported wins over it.
if [[ -f "$(dirname "$0")/../.env" ]]; then
  while IFS='=' read -r k v; do
    [[ $k == GAME_* && -z ${!k:-} ]] && export "$k=$v"
  done < "$(dirname "$0")/../.env"
fi

INSTANCE_ID="${GAME_INSTANCE_ID:-i-CHANGEME}"
# `budget` mode arms the budget BEFORE anything is launched: it is account-level and
# needs no instance, and a build that dies with the laptop should not leave an
# unwatched bill. The instance-level guards necessarily come after the launch.
MODE="${1:-all}"
REGION="${GAME_REGION:-ap-south-2}"
BUDGET_INR="${GAME_BUDGET_INR:-5000}"
# Resource names must match what setup/game look up, which is $TS_HOST-based.
TS_HOST="${GAME_TS_HOST:-gamevps}"
EMAIL="${GAME_ALERT_EMAIL:?set GAME_ALERT_EMAIL}"

# Each guard runs as early as it can, which is why this takes a mode:
#   shutdown  right after launch. The watchdog arms on the box within a minute
#             and its only action is `shutdown -h`, so whether that stops the
#             instance or TERMINATES it must be confirmed before it can fire.
#   budget    before anything launches - account-level, needs no instance.
#   all       both.

if [[ $MODE == shutdown || $MODE == all ]]; then
# --- CRITICAL: make an in-guest `shutdown -h` STOP the instance, not destroy it.
# If this is left as 'terminate', the watchdog deletes your machine and its disk.
#
# Spot instances refuse ModifyInstanceAttribute for this setting outright
# (UnsupportedOperation), so the value has to come from RunInstances - which it
# does, see provision.sh. Skipping the call is therefore safe, but only if the
# attribute really is 'stop', so check rather than assume: this is the single
# setting that decides whether the idle watchdog stops the box or destroys it.
# What `shutdown -h` must mean differs by purchase model, so this checks the
# right thing rather than one fixed value.
#
#   on demand  -> stop.      A misfiring watchdog parks the box; you restart it.
#   spot       -> terminate. A stopped spot instance can NEVER start again (its
#                            request is disabled by the stop) and would bill for
#                            its root volume forever. Safe because the request
#                            is one-time, so nothing relaunches, and because the
#                            games are mirrored to S3 before shutdown completes.
#
# It used to demand 'stop' unconditionally and then excuse spot with "set at
# launch, cannot be modified" - which was true, and meant the FATAL check below
# could never protect a spot instance at all.
lifecycle=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].InstanceLifecycle' --output text 2>/dev/null)
if [[ $lifecycle == spot ]]; then
  WANT=terminate
  echo "==> confirming shutdown means terminate (one-time spot)"
  echo "    set at launch; a spot instance's shutdown behaviour cannot be modified after"
else
  WANT=stop
  echo "==> enforcing stop-on-shutdown (on demand)"
  aws ec2 modify-instance-attribute --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --instance-initiated-shutdown-behavior stop
fi
behavior=$(aws ec2 describe-instance-attribute --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --attribute instanceInitiatedShutdownBehavior \
  --query 'InstanceInitiatedShutdownBehavior.Value' --output text)
echo "    $behavior"
if [[ $behavior != "$WANT" ]]; then
  echo "    FATAL: shutdown behaviour is '$behavior', expected '$WANT'." >&2
  if [[ $WANT == stop ]]; then
    echo "    The idle watchdog would TERMINATE this instance and delete its disk." >&2
  else
    echo "    The idle watchdog would STOP this spot instance, which can then never" >&2
    echo "    start again while its root volume keeps billing." >&2
  fi
  echo "    Do not leave it running. Destroy and rebuild:  cg destroy && cg init" >&2
  exit 1
fi

fi

if [[ $MODE == budget || $MODE == all ]]; then
# --- The budget. Not a layer: it stops nothing, it tells you. ------------------
# AWS Budgets rather than a CloudWatch EstimatedCharges alarm. That alarm needs
# two things a fresh account does not have: "Receive Billing Alerts" switched on
# by the *root* user (no API for it), and an SNS subscription each recipient has
# to confirm by email. Miss either and the alarm sits in INSUFFICIENT_DATA
# forever - armed in appearance only, which is worse than no alarm at all.
#
# A budget emails its subscribers directly. No root toggle, no confirmation
# step, and it works the moment it is created. The first two budgets are free.
echo "==> budget"
USD=$(awk -v i="$BUDGET_INR" 'BEGIN{printf "%.0f", i/88}')
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

subs=""
IFS=',' read -ra EMAILS <<< "$EMAIL"
for e in "${EMAILS[@]}"; do
  e="${e// /}"
  [[ -z $e ]] && continue
  subs="${subs:+$subs,}{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$e\"}"
  echo "    alerts to $e"
done
[[ -n $subs ]] || { echo "    no alert address given - skipping budget"; exit 0; }

bfile=$(mktemp); nfile=$(mktemp)
trap 'rm -f "$bfile" "$nfile"' EXIT
cat > "$bfile" <<JSON
{"BudgetName":"${TS_HOST}-monthly","BudgetLimit":{"Amount":"$USD","Unit":"USD"},
 "TimeUnit":"MONTHLY","BudgetType":"COST"}
JSON
# 80% of actual spend, and a forecast that the month will blow the limit - the
# forecast is the one that gives useful warning rather than a post-mortem.
cat > "$nfile" <<JSON
[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN",
   "Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[$subs]},
 {"Notification":{"NotificationType":"FORECASTED","ComparisonOperator":"GREATER_THAN",
   "Threshold":100,"ThresholdType":"PERCENTAGE"},"Subscribers":[$subs]}]
JSON

if aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "${TS_HOST}-monthly" >/dev/null 2>&1; then
  aws budgets update-budget --account-id "$ACCOUNT" --new-budget "file://$bfile" >/dev/null
  echo "    updated existing budget"
else
  aws budgets create-budget --account-id "$ACCOUNT" \
    --budget "file://$bfile" --notifications-with-subscribers "file://$nfile" >/dev/null
  echo "    created"
fi

echo "done. budget at \$${USD} (~INR ${BUDGET_INR}); warns at 80% actual and 100% forecast"

fi

# See the note at the end of cg: bash reads a script incrementally and returns
# for more input after the last command, so a file edited while this runs can
# resume at a stale offset. An explicit exit ends the read.
exit 0
