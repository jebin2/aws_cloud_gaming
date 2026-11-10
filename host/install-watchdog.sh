#!/usr/bin/env bash
# Run this ON THE GAME BOX, as root. The build does: lib/bootstrap.d/15-watchdog.sh.
set -euo pipefail
install -m 755 idle-watchdog.sh /usr/local/bin/idle-watchdog.sh
install -m 755 ayis-notify /usr/local/bin/ayis-notify
install -m 644 idle-watchdog.service /etc/systemd/system/
install -m 644 idle-watchdog.timer   /etc/systemd/system/
install -m 755 disk-monitor.sh /usr/local/bin/disk-monitor.sh
install -m 644 disk-monitor.service /etc/systemd/system/
install -m 644 disk-monitor.timer   /etc/systemd/system/
install -m 755 game-notify.sh /usr/local/bin/game-notify.sh
install -m 644 game-notify.service /etc/systemd/system/
install -m 644 game-notify.timer   /etc/systemd/system/
# Notifications: the build and ayis init put the ntfy URL beside this script when
# GAME_NTFY_URL is set. No file means off - so removing the setting removes this.
if [[ -s notify.url ]]; then
  install -m 600 /dev/null /etc/ayis-notify.conf
  printf 'AYIS_NTFY_URL=%s\n' "$(head -n 1 notify.url)" > /etc/ayis-notify.conf
else
  rm -f /etc/ayis-notify.conf
fi
systemctl daemon-reload
systemctl enable --now idle-watchdog.timer
systemctl enable --now disk-monitor.timer
systemctl enable --now game-notify.timer
systemctl list-timers idle-watchdog.timer disk-monitor.timer game-notify.timer --no-pager
echo "watchdog armed.     follow with: journalctl -t idle-watchdog -f"
echo "disk monitor armed. follow with: journalctl -t disk-monitor -f"
# The desktop's help picture: the picture, and the autostart entry that puts it on
# the desktop the first time someone logs in. Last, and in a subshell that never
# fails the script: a picture that could not be installed must not stop the
# watchdog above it from being armed. Not every bundle carries the picture.
(
  set +e
  [[ -f ayis-help.png ]] || exit 0
  install -D -m 644 ayis-help.png /usr/share/backgrounds/ayis-help.png \
    && install -m 755 ayis-wallpaper.sh /usr/local/bin/ayis-wallpaper.sh \
    && install -D -m 644 ayis-wallpaper.desktop /etc/xdg/autostart/ayis-wallpaper.desktop \
    || echo "the desktop help picture was not installed (the watchdog is unaffected)"
)
