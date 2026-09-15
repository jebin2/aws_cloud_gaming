#!/usr/bin/env bash
# Run this ON THE GAME BOX, as root. The build does: lib/bootstrap.d/15-watchdog.sh.
set -euo pipefail
install -m 755 idle-watchdog.sh /usr/local/bin/idle-watchdog.sh
install -m 755 cg-notify /usr/local/bin/cg-notify
install -m 644 idle-watchdog.service /etc/systemd/system/
install -m 644 idle-watchdog.timer   /etc/systemd/system/
install -m 755 disk-monitor.sh /usr/local/bin/disk-monitor.sh
install -m 644 disk-monitor.service /etc/systemd/system/
install -m 644 disk-monitor.timer   /etc/systemd/system/
# Notifications: the build and cg init put the ntfy URL beside this script when
# GAME_NTFY_URL is set. No file means off - so removing the setting removes this.
if [[ -s notify.url ]]; then
  install -m 600 /dev/null /etc/cg-notify.conf
  printf 'CG_NTFY_URL=%s\n' "$(head -n 1 notify.url)" > /etc/cg-notify.conf
else
  rm -f /etc/cg-notify.conf
fi
systemctl daemon-reload
systemctl enable --now idle-watchdog.timer
systemctl enable --now disk-monitor.timer
systemctl list-timers idle-watchdog.timer disk-monitor.timer --no-pager
echo "watchdog armed.     follow with: journalctl -t idle-watchdog -f"
echo "disk monitor armed. follow with: journalctl -t disk-monitor -f"
