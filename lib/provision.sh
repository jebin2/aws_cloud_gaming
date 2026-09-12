#!/usr/bin/env bash
# Creates the GPU instance the rest of the scripts assume exists.
# Idempotent: re-running reuses an existing gamevps instance rather than
# launching a second one.
set -euo pipefail

cd "$(dirname "$0")/.."   # lib/ -> repo root; .env and paths live there

REGION="${GAME_REGION:-ap-south-2}"
TS_HOST="${GAME_TS_HOST:-gamevps}"
TYPE="${GAME_INSTANCE_TYPE:-g6.xlarge}"
DISK_GB="${GAME_DISK_GB:-100}"
SPOT="${GAME_SPOT:-0}"
# Persistent game library. Lives on its own EBS volume so the instance - and its
# root disk - can be destroyed between sessions while the games stay. An EBS
# volume is locked to one AZ, so once this exists its AZ decides where every
# future instance launches.
GAMES_GB="${GAME_GAMES_GB:-160}"
GAMES_TAG="${TS_HOST}-games"
KEY_NAME="$TS_HOST"
KEY_FILE="$HOME/.ssh/${TS_HOST}.pem"
SG_NAME="${TS_HOST}-sg"
TS_AUTHKEY="${GAME_TS_AUTHKEY:?set GAME_TS_AUTHKEY (Tailscale pre-auth key)}"

ec2() { aws ec2 "$@" --region "$REGION"; }

existing=$(ec2 describe-instances \
  --filters "Name=tag:Name,Values=$TS_HOST" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [[ $existing != None && -n $existing ]]; then
  echo "reusing existing instance $existing"
  INSTANCE_ID=$existing
else
  # A saved image from `game destroy` already has driver, desktop, Sunshine and
  # Tailscale on it, so restoring skips bootstrap entirely - minutes, not ~20.
  RESTORE=0
  AMI=$(ec2 describe-images --owners self \
    --filters "Name=tag:Name,Values=${TS_HOST}-image" "Name=state,Values=available" \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text 2>/dev/null || echo None)
  if [[ -n $AMI && $AMI != None ]]; then
    RESTORE=1
    echo "==> restoring from saved image $AMI"
  else
    echo "==> resolving latest Ubuntu 24.04 AMI"
    AMI=$(aws ssm get-parameter --region "$REGION" \
      --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
      --query 'Parameter.Value' --output text)
    echo "    $AMI"
  fi

  if ! ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
    echo "==> creating key pair -> $KEY_FILE"
    mkdir -p "$(dirname "$KEY_FILE")"
    ec2 create-key-pair --key-name "$KEY_NAME" \
      --query KeyMaterial --output text > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
  fi

  # The only inbound rule is Tailscale's UDP port. Without it, Tailscale cannot
  # negotiate a direct path and silently falls back to a DERP relay - which
  # still works, but adds tens of ms and makes streaming feel sluggish. The
  # port is safe to expose: Tailscale traffic is end-to-end encrypted and
  # unauthenticated peers get nowhere. No SSH, no Sunshine ports.
  SG=$(ec2 describe-security-groups --group-names "$SG_NAME" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  if [[ -z $SG || $SG == None ]]; then
    echo "==> creating security group (tailscale UDP only)"
    SG=$(ec2 create-security-group --group-name "$SG_NAME" \
      --description "cloud gaming host; reachable over Tailscale only" \
      --query GroupId --output text)
    ec2 authorize-security-group-ingress --group-id "$SG" \
      --ip-permissions "IpProtocol=udp,FromPort=41641,ToPort=41641,IpRanges=[{CidrIp=0.0.0.0/0,Description='tailscale direct path'}]" \
      >/dev/null
  fi
  echo "    $SG"

  # A restored image is already built; re-running bootstrap would reinstall over
  # a working system and re-join Tailscale as a duplicate node.
  USERDATA=$(mktemp)
  trap 'rm -f "$USERDATA" "${USERDATA}.gz"' EXIT
  UD=()
  if (( RESTORE )); then
    echo "==> skipping bootstrap (image is already built)"
  else
    echo "==> rendering user-data"
    # The build is authored as numbered modules under lib/bootstrap.d/ so each
    # step can be read and changed on its own. They are concatenated here
    # because user-data has to be one self-contained script - the box has no
    # copy of this repo.
    shopt -s nullglob
    parts=(lib/bootstrap.d/*.sh)
    (( ${#parts[@]} )) || { echo "no bootstrap modules found in lib/bootstrap.d/"; exit 1; }
    # Comments are ~47% of the module source and the single most valuable thing
    # in this repo - every one of them records a failure that cost a build. The
    # BOX does not need them, so strip whole-line comments here and keep them in
    # git. Shebangs are exempt: `#!` lines matter inside the heredocs that write
    # the on-host scripts. This bought back ~3 KB of a 16 KB budget that had
    # 409 bytes left.
    # host/ is injected as a tarball so those scripts have one home, and so the
    # watchdog is installed by the build itself rather than over ssh afterwards.
    HOST_TGZ_B64=$(tar -cz -C host . 2>/dev/null | base64 -w0)
    cat "${parts[@]}" \
      | grep -vE '^[[:space:]]*#([^!]|$)' \
      | sed -e "s|__TS_AUTHKEY__|$TS_AUTHKEY|" -e "s|__TS_HOST__|$TS_HOST|" \
            -e "s|__HOST_TGZ_B64__|$HOST_TGZ_B64|" > "$USERDATA"
    echo "    assembled ${#parts[@]} modules"
    # EC2 caps user-data at 16 KB, which bootstrap.sh outgrew. cloud-init
    # detects the gzip magic bytes and decompresses on its own, so shipping it
    # compressed costs nothing and roughly quadruples the room available.
    gzip -9 -c "$USERDATA" > "${USERDATA}.gz"
    raw=$(wc -c < "$USERDATA"); gz=$(wc -c < "${USERDATA}.gz")
    echo "    $raw bytes -> $gz gzipped (limit 16384)"
    (( gz < 16384 )) || { echo "user-data still too large even gzipped"; exit 1; }
    UD=(--user-data "fileb://${USERDATA}.gz")
  fi

  # A game volume, if it exists, dictates the AZ: EBS cannot cross one.
  GAMES_VOL=$(ec2 describe-volumes --filters "Name=tag:Name,Values=$GAMES_TAG" \
    --query 'Volumes[0].VolumeId' --output text 2>/dev/null || echo None)
  PLACE=()
  if [[ -n $GAMES_VOL && $GAMES_VOL != None ]]; then
    GAMES_AZ=$(ec2 describe-volumes --volume-ids "$GAMES_VOL" \
      --query 'Volumes[0].AvailabilityZone' --output text)
    echo "==> game volume $GAMES_VOL in $GAMES_AZ - pinning the instance there"
    PLACE=(--placement "AvailabilityZone=$GAMES_AZ")
  fi

  MARKET=()
  if [[ $SPOT == 1 ]]; then
    # 'stop' on interruption keeps the disk, and it requires a persistent
    # request. Persistent means AWS may relaunch after an interruption - see
    # the Spot section of the README for what that does and does not do.
    MARKET=(--instance-market-options
      'MarketType=spot,SpotOptions={SpotInstanceType=persistent,InstanceInterruptionBehavior=stop}')
    echo "==> launching $TYPE (spot)"
  else
    echo "==> launching $TYPE"
  fi
  # shutdown-behaviour is set at launch, not after: the watchdog issues
  # `shutdown -h`, and a window where that means "terminate" would destroy
  # the machine and its disk.
  INSTANCE_ID=$(ec2 run-instances \
    --image-id "$AMI" \
    --instance-type "$TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG" \
    --instance-initiated-shutdown-behavior stop \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TS_HOST}]" \
    ${UD[@]+"${UD[@]}"} \
    ${MARKET[@]+"${MARKET[@]}"} \
    ${PLACE[@]+"${PLACE[@]}"} \
    --query 'Instances[0].InstanceId' --output text) || {
      echo "launch failed. If this says there is no spot capacity, the game volume"
      echo "pins the AZ and that AZ is full right now. Retry, or use on-demand in"
      echo "the same AZ:  GAME_SPOT=0 cg init"
      exit 1
    }
  echo "    $INSTANCE_ID"
fi

# --- persistent game library volume -------------------------------------------
# Created in the instance's own AZ the first time, then reused forever. Never
# deleted by `cg destroy` - only by `cg games --delete`.
INST_AZ=$(ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
GAMES_VOL=$(ec2 describe-volumes --filters "Name=tag:Name,Values=$GAMES_TAG" \
  --query 'Volumes[0].VolumeId' --output text 2>/dev/null || echo None)
if [[ -z $GAMES_VOL || $GAMES_VOL == None ]]; then
  echo "==> creating the ${GAMES_GB}GB game library volume in $INST_AZ"
  GAMES_VOL=$(ec2 create-volume --availability-zone "$INST_AZ" \
    --size "$GAMES_GB" --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$GAMES_TAG}]" \
    --query VolumeId --output text)
  echo "    $GAMES_VOL"
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$GAMES_VOL"
fi

state=$(ec2 describe-volumes --volume-ids "$GAMES_VOL" \
  --query 'Volumes[0].State' --output text)
if [[ $state == available ]]; then
  echo "==> attaching $GAMES_VOL"
  ec2 attach-volume --volume-id "$GAMES_VOL" --instance-id "$INSTANCE_ID" \
    --device /dev/sdf >/dev/null
  aws ec2 wait volume-in-use --region "$REGION" --volume-ids "$GAMES_VOL"
elif [[ $state == in-use ]]; then
  echo "    $GAMES_VOL already attached"
fi
# DeleteOnTermination must stay false, or terminating the box takes the games.
ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"DeleteOnTermination\":false}}]" \
  2>/dev/null || true

# Update our own keys in place. .env may hold values this script did not put
# there (auth keys, for one), so it must never be truncated.
touch .env
tmp=$(mktemp)
grep -vE '^(GAME_INSTANCE_ID|GAME_REGION|GAME_TS_HOST)=' .env > "$tmp" || true
{
  echo "GAME_INSTANCE_ID=$INSTANCE_ID"
  echo "GAME_REGION=$REGION"
  echo "GAME_TS_HOST=$TS_HOST"
} >> "$tmp"
cat "$tmp" > .env
rm -f "$tmp"
chmod 600 .env
echo "updated .env"
