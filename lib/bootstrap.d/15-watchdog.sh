# --- Layer 2: the on-host idle watchdog ---------------------------------------
# Installed HERE, early in the build, rather than over ssh once the build
# finishes. The build takes minutes and used to run with no guard at all: a
# Ctrl+C on the laptop, a dropped connection or a stalled build left a GPU
# instance running with nothing to stop it.
#
# Safe this early because the watchdog has a 20-minute boot grace and counts
# inbound bytes as activity, so it cannot shut down a build in progress.
#
# host/ stays the single source of truth - provision.sh injects it here as a
# base64 tarball rather than duplicating the scripts in this module.
progress "installing the idle watchdog"
mkdir -p /opt/cloud-gaming-host
printf '%s' '__HOST_TGZ_B64__' | base64 -d | tar -xz -C /opt/cloud-gaming-host
( cd /opt/cloud-gaming-host && bash ./install-watchdog.sh ) >/dev/null 2>&1 \
  || echo "watchdog install failed - the box is UNGUARDED"

verify "idle watchdog armed" systemctl is-enabled idle-watchdog.timer
verify "disk monitor armed" systemctl is-enabled disk-monitor.timer
