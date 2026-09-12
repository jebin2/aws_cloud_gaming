#!/usr/bin/env bash
# Layer 2: on-host dead-man's switch. Shuts down when the machine is doing
# nothing. Independent of Sunshine internals - it just watches bytes on the wire.
#
# "Doing nothing" means two things at once, because there are two ways to be
# busy here:
#   - streaming  -> outbound bytes on the tailnet interface
#   - downloading -> inbound bytes on the public interface
# Watching only the first shuts the box down mid-download, and since games live
# on ephemeral storage that download is lost rather than resumed.
set -euo pipefail

IFACE="${IFACE:-tailscale0}"          # the tunnel: streaming shows up here
IDLE_LIMIT="${IDLE_LIMIT:-15}"        # consecutive idle minutes before shutdown
THRESHOLD="${THRESHOLD:-204800}"      # bytes/min of stream traffic below which we call it idle (200 KB)
RX_THRESHOLD="${RX_THRESHOLD:-10485760}"  # bytes/min inbound that counts as a real download (10 MB)
BOOT_GRACE="${BOOT_GRACE:-20}"        # minutes after boot before the switch arms
STATE=/var/lib/idle-watchdog

mkdir -p "$STATE"

# Don't shut down while the user is still connecting / launching a game.
uptime_min=$(( $(cut -d. -f1 /proc/uptime) / 60 ))
(( uptime_min < BOOT_GRACE )) && exit 0

counter() { # counter <iface> <tx|rx>; 0 if the interface is absent
  local f="/sys/class/net/$1/statistics/$2_bytes"
  [[ -r $f ]] && cat "$f" || echo 0
}

delta_since() { # delta_since <name> <current>; bytes since the last run
  local key=$1 now=$2 prev d
  prev=$(cat "$STATE/$key" 2>/dev/null || echo "$now")
  echo "$now" > "$STATE/$key"
  d=$(( now - prev ))
  (( d < 0 )) && d=0               # counter reset on reboot
  echo "$d"
}

# The public interface is whatever the default route uses - ens5 on Nitro, but
# do not hard-code it.
WAN=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
WAN="${WAN:-eth0}"

tx_delta=$(delta_since tx "$(counter "$IFACE" tx)")
rx_delta=$(delta_since rx "$(counter "$WAN" rx)")

streaming=0;  (( tx_delta >= THRESHOLD ))    && streaming=1
downloading=0; (( rx_delta >= RX_THRESHOLD )) && downloading=1

idle=$(cat "$STATE/idle" 2>/dev/null || echo 0)
if (( streaming || downloading )); then idle=0; else idle=$(( idle + 1 )); fi
echo "$idle" > "$STATE/idle"

logger -t idle-watchdog \
  "tx=${tx_delta}B rx=${rx_delta}B streaming=${streaming} downloading=${downloading} idle=${idle}/${IDLE_LIMIT}"

if (( idle >= IDLE_LIMIT )); then
  logger -t idle-watchdog "idle limit reached - shutting down"
  /sbin/shutdown -h now "idle watchdog"
fi
