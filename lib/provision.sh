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
# Persistent game library. Held in S3 and restored onto the instance store at
# boot - see lib/library-aws.sh for why, and 16-library.sh for how. It used to
# be a 160 GB EBS volume, which billed INR 1,284/month whether or not the box
# existed and pinned every launch to the volume's AZ. Nothing pins the AZ now.
GAMES_TAG="${TS_HOST}-games"   # the old volume, if one still exists: cg games
INSTANCE_PROFILE="${TS_HOST}-box"
KEY_NAME="$TS_HOST"
KEY_FILE="$HOME/.ssh/${TS_HOST}.pem"
SG_NAME="${TS_HOST}-sg"
TS_AUTHKEY="${GAME_TS_AUTHKEY:?set GAME_TS_AUTHKEY (Tailscale pre-auth key)}"

ec2() { aws ec2 "$@" --region "$REGION"; }

# The bucket and the instance role the box needs, created before the launch that
# references the profile. Idempotent, so this is also the repair path.
echo "==> ensuring the S3 game library and the box's instance role"
S3_BUCKET=$(GAME_REGION="$REGION" GAME_TS_HOST="$TS_HOST" bash lib/library-aws.sh) \
  || { echo "could not set up the game library bucket/role"; exit 1; }
# Checked, not trusted. This value is substituted into user-data by sed and then
# into the box's config; anything unexpected in it either breaks the render with
# a cryptic sed error or, worse, renders and points the box at the wrong place.
[[ $S3_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
  || { echo "library setup returned something that is not a bucket name:"; \
       printf '%s\n' "$S3_BUCKET" | sed 's/^/    /'; exit 1; }
echo "    s3://$S3_BUCKET"

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
    # The remote watchdog runs on an always-on VPS, not on the box, so it must
    # not ride along in user-data - it cost ~2 KB of a 16 KB budget.
    # The same comment-stripping as above, for the same reason and with one
    # extra: base64 of a gzip is incompressible, so every byte of host/ costs a
    # full byte of the 16 KB budget while the modules around it cost ~40% of
    # one. Stripping host/ is worth roughly four times as much per line.
    HOST_SRC=$(mktemp -d)
    tar -c -C host --exclude='remote-watchdog.*' -f - . | tar -x -C "$HOST_SRC"
    for f in "$HOST_SRC"/*; do
      [[ -f $f ]] || continue
      grep -vE '^[[:space:]]*#([^!]|$)' "$f" > "$f.stripped" && mv "$f.stripped" "$f"
    done
    chmod 755 "$HOST_SRC"/*.sh "$HOST_SRC"/cg-library 2>/dev/null || true
    # host/ goes to S3 and the box fetches it, rather than riding along inside
    # user-data as base64. It used to: 9,572 bytes of a 16,384 byte budget -
    # 58% - and base64 of a gzip does not compress, so every byte cost a full
    # byte while the modules around it cost about 40% of one. That left 68
    # bytes of headroom, which is not a budget, it is a tripwire.
    #
    # A presigned GET, valid two hours, so the box needs no credentials at the
    # point in the build where it has none. The URL is ~600 bytes.
    HOST_TGZ=$(mktemp); tar -cz -C "$HOST_SRC" . > "$HOST_TGZ" 2>/dev/null
    aws s3 cp "$HOST_TGZ" "s3://$S3_BUCKET/boot/host.tgz" --region "$REGION" >/dev/null \
      || { echo "could not upload host/ to s3://$S3_BUCKET/boot/host.tgz"; exit 1; }
    HOST_TGZ_URL=$(aws s3 presign "s3://$S3_BUCKET/boot/host.tgz" --region "$REGION" --expires-in 7200)
    [[ $HOST_TGZ_URL == https://* ]] || { echo "could not presign the host bundle"; exit 1; }
    rm -rf "$HOST_SRC" "$HOST_TGZ"
    # Substituted in python, not sed. A presigned URL is full of `&`, and in a
    # sed replacement an unescaped `&` means "the entire matched text" - so every
    # separator in the URL came out as the literal string __HOST_TGZ_URL__, curl
    # got a 400, and the build died before tailscale existed. The bug survived a
    # hand-written test because the URL in it had its `&` escaped by hand.
    #
    # Nothing here needs regex or escaping: these are literal replacements, so
    # use a tool that does literal replacement.
    cat "${parts[@]}" \
      | grep -vE '^[[:space:]]*#([^!]|$)' \
      | TS_AUTHKEY="$TS_AUTHKEY" TS_HOST="$TS_HOST" HOST_TGZ_URL="$HOST_TGZ_URL" \
        S3_BUCKET="$S3_BUCKET" CG_APPS="${GAME_APPS:-all}" \
        python3 -c 'import os,sys
s = sys.stdin.read()
for k in ("TS_AUTHKEY", "TS_HOST", "HOST_TGZ_URL", "S3_BUCKET", "CG_APPS"):
    s = s.replace("__%s__" % k, os.environ.get(k, ""))
missing = [w for w in ("__TS_AUTHKEY__", "__TS_HOST__", "__HOST_TGZ_URL__",
                       "__S3_BUCKET__", "__CG_APPS__") if w in s]
if missing:
    sys.exit("placeholders left unsubstituted: %s" % ", ".join(missing))
sys.stdout.write(s)' > "$USERDATA" \
      || { echo "could not render user-data"; exit 1; }
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

  # No AZ pinning. S3 is regional, so any zone will do - which materially
  # improves the odds on a spot launch, since InsufficientInstanceCapacity is
  # per-AZ and the old game volume used to force one specific zone.
  PLACE=()

  # ONE-TIME spot, not persistent, and terminate rather than stop.
  #
  # The old design was persistent + InstanceInterruptionBehavior=stop, because
  # the games lived on the instance store and terminating meant losing them.
  # That constraint is gone - they are in S3 - and the old design had two costs:
  #
  #   - a persistent request RELAUNCHES the moment its instance is terminated,
  #     so nothing may terminate the box without cancelling the request first.
  #     No cost guard can do that (the on-host watchdog holds no credentials),
  #     which is why all three had to stop instead.
  #   - and stopping a spot instance disables its request permanently, leaving
  #     a box that can never start again while its root volume keeps billing.
  #
  # So every guard firing produced a dead-but-billing instance. A one-time
  # request never relaunches, which makes terminate safe, which lets the guards
  # actually remove the thing they are guarding against.
  #
  # A one-time request only supports InstanceInterruptionBehavior=terminate, so
  # an AWS interruption now terminates instead of stopping. No loss: a stop
  # wipes the instance store anyway, and the S3 mirror is what preserves the
  # games in either case.
  MARKET=() SHUTDOWN_BEHAVIOR=stop
  if [[ $SPOT == 1 ]]; then
    MARKET=(--instance-market-options
      'MarketType=spot,SpotOptions={SpotInstanceType=one-time}')
    # So the on-host watchdog's `shutdown -h` removes the box rather than
    # stranding it. Safe only because nothing can relaunch a one-time request.
    SHUTDOWN_BEHAVIOR=terminate
    echo "==> launching $TYPE (spot, one-time - shutdown means terminate)"
  else
    echo "==> launching $TYPE"
  fi
  # shutdown-behaviour is set at launch, not after: the watchdog issues
  # `shutdown -h`, and the window matters. On demand it must mean "stop", so a
  # misfiring watchdog parks the box instead of deleting it. On one-time spot it
  # must mean "terminate", because a stopped spot instance can never start again
  # and would bill for its root volume forever.
  # A freshly created instance profile is not immediately usable by
  # run-instances - IAM is eventually consistent, and the first call after
  # creating one fails with "Invalid IAM Instance Profile name" for a few
  # seconds. Retried here rather than left as an init that fails once and works
  # when you run it again, which is the kind of thing that gets diagnosed as
  # flakiness instead of propagation.
  launch() {
    ec2 run-instances \
      --image-id "$AMI" \
      --instance-type "$TYPE" \
      --key-name "$KEY_NAME" \
      --security-group-ids "$SG" \
      --iam-instance-profile "Name=$INSTANCE_PROFILE" \
      --instance-initiated-shutdown-behavior "$SHUTDOWN_BEHAVIOR" \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3,DeleteOnTermination=true}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TS_HOST}]" \
      ${UD[@]+"${UD[@]}"} \
      ${MARKET[@]+"${MARKET[@]}"} \
      ${PLACE[@]+"${PLACE[@]}"} \
      --query 'Instances[0].InstanceId' --output text
  }
  ERRF=$(mktemp); trap 'rm -f "$USERDATA" "${USERDATA}.gz" "$ERRF"' EXIT
  INSTANCE_ID=""
  for attempt in 1 2 3 4 5 6; do
    if INSTANCE_ID=$(launch 2>"$ERRF"); then break; fi
    INSTANCE_ID=""
    if grep -q 'Invalid IAM Instance Profile' "$ERRF"; then
      echo "    instance profile $INSTANCE_PROFILE not visible yet (attempt $attempt) - waiting"
      sleep 5
      continue
    fi
    break
  done
  if [[ -z $INSTANCE_ID ]]; then
      cat "$ERRF" >&2
      echo ""
      echo "launch failed. The things this is usually:"
      echo ""
      echo "  MaxSpotInstanceCountExceeded, right after a destroy"
      echo "    AWS releases the spot vCPU quota a minute or two AFTER the instance"
      echo "    terminates, so an immediate rebuild hits your own old allocation."
      echo "    Nothing is wrong - wait ~2 minutes and run it again."
      echo "    Check with: aws ec2 describe-spot-instance-requests --region $REGION"
      echo ""
      echo "  MaxSpotInstanceCountExceeded, persistently"
      echo "    Your spot quota (L-3819A6DF) is smaller than this instance needs,"
      echo "    or an older request still holds it. On-demand instead:"
      echo "      GAME_SPOT=0 cg init"
      echo ""
      echo "  InsufficientInstanceCapacity"
      echo "    No spare $TYPE capacity right now. Nothing pins the AZ any more, so"
      echo "    this is the whole region being short. On-demand usually fits:"
      echo "      GAME_SPOT=0 cg init"
      echo ""
      echo "  AccessDenied on iam:PassRole"
      echo "    Launching with an instance profile needs iam:PassRole for"
      echo "    $INSTANCE_PROFILE. Without it the box cannot reach S3 and the"
      echo "    game library will not survive a stop."
      echo ""
      exit 1
  fi
  echo "    $INSTANCE_ID"
fi

# --- the instance role, on a reused instance -----------------------------------
# A box launched before the library moved to S3 has no instance profile, and
# without one the restore and the push both fail with a permission error 10
# minutes into a download. Attaching it to a running instance is allowed, so
# repair it here rather than requiring a rebuild.
assoc=$(ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" "Name=state,Values=associated,associating" \
  --query 'IamInstanceProfileAssociations[0].AssociationId' --output text 2>/dev/null || echo None)
if [[ -z $assoc || $assoc == None ]]; then
  echo "==> attaching instance profile $INSTANCE_PROFILE to $INSTANCE_ID"
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID" || true
  ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" >/dev/null 2>&1 \
    || echo "    could not attach it - the box will not reach S3 (needs iam:PassRole)"
fi

# The old EBS game volume is deliberately NOT attached any more: nothing mounts
# it, and attaching it would re-pin the AZ for no benefit. It is not deleted
# either - deleting storage that might hold the only copy of something is not a
# thing to do silently. `cg games` shows what it still costs and removes it.
old_vol=$(ec2 describe-volumes --filters "Name=tag:Name,Values=$GAMES_TAG" \
  --query 'Volumes[0].VolumeId' --output text 2>/dev/null || echo None)
if [[ -n $old_vol && $old_vol != None ]]; then
  echo "==> note: the old EBS game volume $old_vol still exists and still bills"
  echo "    it is no longer used or attached - reclaim it with: cg games --delete"
fi

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

# See the note at the end of cg: bash reads a script incrementally and returns
# for more input after the last command, so a file edited while this runs can
# resume at a stale offset. An explicit exit ends the read.
exit 0
