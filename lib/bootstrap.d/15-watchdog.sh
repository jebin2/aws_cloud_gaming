# --- Layer 2: the on-host idle watchdog ---------------------------------------
# Installed HERE, early in the build, rather than over ssh once the build
# finishes. The build takes minutes and used to run with no guard at all: a
# Ctrl+C on the laptop, a dropped connection or a stalled build left a GPU
# instance running with nothing to stop it.
#
# Safe this early because the watchdog has a 20-minute boot grace and counts
# inbound bytes as activity, so it cannot shut down a build in progress.
#
# host/ stays the single source of truth - provision.sh uploads it to S3 and
# this fetches it, rather than duplicating the scripts in this module.
progress "installing the idle watchdog"
mkdir -p /opt/cloud-gaming-host
# Fetched from S3 with a presigned URL rather than carried inline as base64:
# inline cost 58% of the 16 KB user-data budget and left 68 bytes spare. The URL
# is presigned so this works before the box has any AWS credentials configured.
# NOT fatal, deliberately. This runs before tailscale, so exiting here leaves a
# box with no network identity: unreachable by ssh, no log streaming, only
# console output - which is exactly the state a corrupted URL produced once, and
# the hardest possible thing to debug. Carrying on costs layer 2 and leaves the
# box reachable; layers 3 and 4 are armed before launch and still bound the
# spend. The verify lines below report the loss, and `cg init` streams them.
if curl -fsSL --retry 5 --retry-delay 3 '__HOST_TGZ_URL__' -o /tmp/host.tgz; then
  tar -xz -C /opt/cloud-gaming-host -f /tmp/host.tgz
  rm -f /tmp/host.tgz
else
  echo ">>> FAILED: could not download the host bundle from S3"
  echo ">>>         layer 2 (on-host watchdog) and the S3 library mirror will be MISSING"
  echo ">>>         the box is still reachable; layers 3 and 4 still stop it"
fi
( cd /opt/cloud-gaming-host && bash ./install-watchdog.sh ) >/dev/null 2>&1 \
  || echo "watchdog install failed - the box is UNGUARDED"

verify "idle watchdog armed" systemctl is-enabled idle-watchdog.timer
verify "disk monitor armed" systemctl is-enabled disk-monitor.timer
