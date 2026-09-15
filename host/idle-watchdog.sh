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
# Every other knob here is overridable; this one was not, purely by oversight.
STATE="${STATE:-/var/lib/idle-watchdog}"
# Overridable so the shutdown path can be tested. A watchdog whose only job is
# to power off a machine is not something to verify by running it for real.
CG_LIBRARY_BIN="${CG_LIBRARY_BIN:-/usr/local/bin/cg-library}"
SHUTDOWN_BIN="${SHUTDOWN_BIN:-/sbin/shutdown}"
# From /etc/cg-notify.conf, via the unit's EnvironmentFile. Unset is off.
CG_NTFY_URL="${CG_NTFY_URL:-}"

# Best effort, never fatal: nothing about a notification may stop a shutdown.
notify() { # notify <title> <message>
  [[ -n $CG_NTFY_URL ]] || return 0
  curl -fsS -m 5 -H "Title: $(hostname -s 2>/dev/null || echo box): $1" -H "Priority: high" \
       -H "Tags: zzz" -d "$2" "$CG_NTFY_URL" >/dev/null 2>&1 \
    || logger -t idle-watchdog "notification not sent (ignored)"
  return 0
}

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
  # Mirror BEFORE shutting down, not on the way out.
  #
  # cg-library-shutdown.service exists and works, but it runs from ExecStop
  # under TimeoutStopSec - and a first upload of a 140 GB game does not fit in
  # any shutdown window. Measured: 104 GB of egress in the 15 minutes systemd
  # allowed, then the push was killed with ~72 GB of 140 landed and no manifest
  # written. The archive was correctly marked incomplete, which is to say the
  # whole session's download was lost.
  #
  # Here there is no clock. The box is fully alive, the push takes as long as it
  # takes, and the extra minutes cost a few rupees of spot time against a
  # re-download measured in hours. ExecStop stays as the backstop for stops this
  # watchdog did not initiate.
  mirrored="no game mirror on this box"
  if [[ -x $CG_LIBRARY_BIN ]]; then
    logger -t idle-watchdog "idle limit reached - mirroring the library before shutdown"
    if runuser -u ubuntu -- "$CG_LIBRARY_BIN" push 2>&1 | logger -t idle-watchdog; then
      logger -t idle-watchdog "mirror complete"
      mirrored="games mirrored to S3"
    else
      logger -t idle-watchdog "mirror FAILED - shutting down anyway; games since the last push are lost"
      mirrored="the game mirror FAILED - games since the last push are lost"
    fi
  fi
  notify "idle box shutting down" "No stream or download for ${IDLE_LIMIT} minutes; $mirrored."
  logger -t idle-watchdog "shutting down"
  "$SHUTDOWN_BIN" -h now "idle watchdog"
fi
