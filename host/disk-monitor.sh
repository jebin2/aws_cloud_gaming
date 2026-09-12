#!/usr/bin/env bash
# Logs disk usage and warns before the root volume fills. Games and downloads
# and downloads live on other disks, so root growing is a sign something escaped
# - worth knowing early, because an EBS volume cannot be shrunk afterwards.
set -euo pipefail

WARN_PCT="${WARN_PCT:-85}"

pct()  { df --output=pcent "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
human() { df -h --output=used,size "$1" 2>/dev/null | tail -1 | tr -s ' ' | sed 's/^ //;s/ /\//'; }

root_pct=$(pct /)
root_use=$(human /)

if mountpoint -q /scratch; then
  scratch_pct=$(pct /scratch)
  scratch_use=$(human /scratch)
else
  scratch_pct=0
  scratch_use="not mounted"
fi

logger -t disk-monitor "root=${root_use} (${root_pct}%) scratch=${scratch_use} (${scratch_pct}%)"

(( root_pct < WARN_PCT )) && exit 0

logger -t disk-monitor "WARNING: root at ${root_pct}%, above ${WARN_PCT}%"

# Reach the autologin session so the warning is visible while streaming, not
# only in the journal.
uid=$(id -u ubuntu 2>/dev/null || echo "")
if [[ -n $uid ]]; then
  sudo -u ubuntu \
    DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    notify-send -u critical "Disk almost full" \
    "Root volume is ${root_pct}% full (${root_use}). Games belong on /games." \
    2>/dev/null || true
fi
