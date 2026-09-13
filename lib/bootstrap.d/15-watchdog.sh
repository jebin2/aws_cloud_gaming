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
# A failure here is fatal - every later stage installs out of this directory.
if ! curl -fsSL --retry 5 --retry-delay 3 '__HOST_TGZ_URL__' -o /tmp/host.tgz; then
  echo ">>> FAILED: could not download host bundle - the box will be UNGUARDED"
  exit 1
fi
tar -xz -C /opt/cloud-gaming-host -f /tmp/host.tgz
rm -f /tmp/host.tgz
( cd /opt/cloud-gaming-host && bash ./install-watchdog.sh ) >/dev/null 2>&1 \
  || echo "watchdog install failed - the box is UNGUARDED"

verify "idle watchdog armed" systemctl is-enabled idle-watchdog.timer
verify "disk monitor armed" systemctl is-enabled disk-monitor.timer
