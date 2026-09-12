#!/usr/bin/env bash
# Layers 3 & 4: cloud-side backstops. Run once, locally, after the instance exists.
set -euo pipefail

# .env is written by provision.sh. Anything already exported wins over it.
if [[ -f "$(dirname "$0")/../.env" ]]; then
  while IFS='=' read -r k v; do
    [[ $k == GAME_* && -z ${!k:-} ]] && export "$k=$v"
  done < "$(dirname "$0")/../.env"
fi

INSTANCE_ID="${GAME_INSTANCE_ID:-i-CHANGEME}"
REGION="${GAME_REGION:-ap-south-2}"
BUDGET_INR="${GAME_BUDGET_INR:-5000}"
# Resource names must match what setup/game look up, which is $TS_HOST-based.
TS_HOST="${GAME_TS_HOST:-gamevps}"
EMAIL="${GAME_ALERT_EMAIL:?set GAME_ALERT_EMAIL}"

# --- CRITICAL: make an in-guest `shutdown -h` STOP the instance, not destroy it.
# If this is left as 'terminate', the watchdog deletes your machine and its disk.
#
# Spot instances refuse ModifyInstanceAttribute for this setting outright
# (UnsupportedOperation), so the value has to come from RunInstances - which it
# does, see provision.sh. Skipping the call is therefore safe, but only if the
# attribute really is 'stop', so check rather than assume: this is the single
# setting that decides whether the idle watchdog stops the box or destroys it.
echo "==> enforcing stop-on-shutdown"
lifecycle=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].InstanceLifecycle' --output text 2>/dev/null)
if [[ $lifecycle == spot ]]; then
  echo "    spot instance - set at launch, cannot be modified after"
else
  aws ec2 modify-instance-attribute --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --instance-initiated-shutdown-behavior stop
fi
behavior=$(aws ec2 describe-instance-attribute --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --attribute instanceInitiatedShutdownBehavior \
  --query 'InstanceInitiatedShutdownBehavior.Value' --output text)
echo "    $behavior"
if [[ $behavior != stop ]]; then
  echo "    FATAL: shutdown behaviour is '$behavior', not 'stop'." >&2
  echo "    The idle watchdog would TERMINATE this instance and delete its disk." >&2
  echo "    Do not leave it running. Destroy and rebuild:  cg destroy && cg init" >&2
  exit 1
fi

# --- Layer 3: stop the instance if it stops pushing video for 30 min.
# Catches a hung OS, a dead watchdog, a wedged Sunshine.
# Streaming at 20 Mbps moves ~750 MB per 5-min period; 10 MB is comfortably idle.
echo "==> idle-stop alarm"
aws cloudwatch put-metric-alarm --region "$REGION" \
  --alarm-name "${TS_HOST}-idle-stop" \
  --alarm-description "Stop the game host when no stream traffic for 30 minutes" \
  --namespace AWS/EC2 --metric-name NetworkOut \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --statistic Sum --period 300 --evaluation-periods 6 \
  --threshold 10000000 --comparison-operator LessThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "arn:aws:automate:${REGION}:ec2:stop"

# Leave the stop action disarmed. A new alarm is judged against the *previous*
# 30 minutes immediately, so arming it here stops the box mid-setup - the
# install window looks exactly like an idle one. `set-alarm-state` does not
# help: CloudWatch re-evaluates the same history and returns to ALARM.
# `game up` arms it once a session actually starts, which is the only time
# this layer is meant to be watching.
aws cloudwatch disable-alarm-actions --region "$REGION" --alarm-name "${TS_HOST}-idle-stop"
echo "    idle-stop action stays disarmed until 'game up' arms it"

# --- Layer 4: budget. ---------------------------------------------------------
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
