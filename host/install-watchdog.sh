#!/usr/bin/env bash
# Run this ON THE VPS, as root.
set -euo pipefail
install -m 755 idle-watchdog.sh /usr/local/bin/idle-watchdog.sh
install -m 644 idle-watchdog.service /etc/systemd/system/
install -m 644 idle-watchdog.timer   /etc/systemd/system/
install -m 755 disk-monitor.sh /usr/local/bin/disk-monitor.sh
install -m 644 disk-monitor.service /etc/systemd/system/
install -m 644 disk-monitor.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now idle-watchdog.timer
systemctl enable --now disk-monitor.timer
systemctl list-timers idle-watchdog.timer disk-monitor.timer --no-pager
echo "watchdog armed.     follow with: journalctl -t idle-watchdog -f"
echo "disk monitor armed. follow with: journalctl -t disk-monitor -f"
