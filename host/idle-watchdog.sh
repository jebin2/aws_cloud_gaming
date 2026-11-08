#!/usr/bin/env bash
# Layer 2: on-host dead-man's switch. Shuts down when the machine is doing
# nothing. Independent of Sunshine internals - it just watches bytes on the wire.
#
# "Doing nothing" means two things at once, because there are two ways to be
# busy here:
#   - streaming  -> outbound bytes on the tailnet interface
#   - downloading -> inbound bytes on the public interface
#   - installing -> Steam has a game marked downloading and is still writing files
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
# Notifications go through cg-notify, which is off unless CG_NTFY_URL is set
# (from /etc/cg-notify.conf, via the unit's EnvironmentFile).
CG_NOTIFY_BIN="${CG_NOTIFY_BIN:-/usr/local/bin/cg-notify}"
# The push before shutdown has no clock, but it is watched: still running after
# this long, and every hour after that, it sends a notification.
UPLOAD_WARN_SEC="${UPLOAD_WARN_SEC:-3600}"
UPLOAD_POLL_SEC="${UPLOAD_POLL_SEC:-10}"

# A third way to be busy: Steam is putting a game in place. After the last byte
# arrives it spends minutes writing and moving files with next to no network, and a
# 200 GB game can take longer than IDLE_LIMIT - the traffic looked idle and the box
# went down before the game was installed. A manifest that says "downloading"
# (StateFlags 1024) counts only while files are actually being written (anything
# in the download folder or the game's folder changed in the last STEAM_QUIET
# minutes), so a flag left behind by a stuck or paused download cannot keep the
# box up and billing for ever.
STEAM_VDFS="${STEAM_VDFS:-/home/*/.local/share/Steam/config/libraryfolders.vdf}"
STEAM_QUIET="${STEAM_QUIET:-10}"
# Every library on the box: the archive's, the added disk's, and each folder Steam
# lists itself (Steam's Add Drive makes its own, /scratch2/SteamLibrary).
steam_libs() {
  if [[ -n ${STEAM_LIBS+x} ]]; then echo "$STEAM_LIBS"; return; fi
  {
    echo /scratch/steam; echo /scratch2/steam
    local v
    for v in $STEAM_VDFS; do
      [[ -f $v ]] && sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$v"
    done
    for v in /home/*/.local/share/Steam; do [[ -d $v ]] && echo "$v"; done
  } | awk '!seen[$0]++'
}
steam_working() {
  local lib f flags
  for lib in $(steam_libs); do
    for f in "$lib"/steamapps/appmanifest_*.acf; do
      [[ -f $f ]] || continue
      flags=$(sed -n 's/.*"StateFlags"[[:space:]]*"\([0-9]*\)".*/\1/p' "$f" | head -n 1)
      (( ${flags:-0} & 1024 )) || continue
      if [[ -n $(find "$lib/steamapps/downloading" "$lib/steamapps/common" -mmin "-$STEAM_QUIET" -print -quit 2>/dev/null) ]]; then
        return 0
      fi
    done
  done
  return 1
}

# Best effort, never fatal: nothing about a notification may stop a shutdown.
notify() { # notify <title> <message>
  [[ -x $CG_NOTIFY_BIN ]] && "$CG_NOTIFY_BIN" "$1" "$2" high zzz
  return 0
}

mkdir -p "$STATE"

# Don't shut down while the user is still connecting / launching a game.
uptime_min=$(( $(cut -d. -f1 /proc/uptime) / 60 ))
if (( uptime_min < BOOT_GRACE )); then
  # The count lives on the root disk, which a stop keeps. A machine that stopped
  # itself at 15 of 15 would otherwise wake with 15 already counted and stop again
  # at the first check after the grace, whatever the person was about to do.
  echo 0 > "$STATE/idle" 2>/dev/null || true
  exit 0
fi

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
installing=0;  steam_working && installing=1

idle=$(cat "$STATE/idle" 2>/dev/null || echo 0)
if (( streaming || downloading || installing )); then idle=0; else idle=$(( idle + 1 )); fi
echo "$idle" > "$STATE/idle"

logger -t idle-watchdog \
  "tx=${tx_delta}B rx=${rx_delta}B streaming=${streaming} downloading=${downloading} installing=${installing} idle=${idle}/${IDLE_LIMIT}"

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
  unsaved=""
  if [[ -x $CG_LIBRARY_BIN ]]; then
    logger -t idle-watchdog "idle limit reached - mirroring the library before shutdown"
    # In the background, so it can be watched. A push that hangs keeps the box
    # up and billing - and its own traffic looks like use to the cloud watchdog -
    # so one still running is said out loud, hourly.
    #
    # Output reaches logger through a process substitution, not a pipe: with a
    # pipe, $! is logger's pid, and logger can exit before the push - the watch
    # then ends early and a good push reads as failed. The exit status goes to a
    # file for the same reason a pipeline's would be logger's.
    rcfile="$STATE/mirror.rc"; rm -f "$rcfile"
    { if runuser -u ubuntu -- "$CG_LIBRARY_BIN" push 2>&1; then echo 0 > "$rcfile"; else echo 1 > "$rcfile"; fi; } \
      > >(logger -t idle-watchdog) 2>&1 &
    pushjob=$! started=$SECONDS next_warn=$UPLOAD_WARN_SEC
    while kill -0 "$pushjob" 2>/dev/null; do
      sleep "$UPLOAD_POLL_SEC"
      if (( SECONDS - started >= next_warn )) && kill -0 "$pushjob" 2>/dev/null; then
        notify "Still saving your games" \
          "It has been $(( (SECONDS - started) / 60 )) minutes. The game PC stays on, and charging, until it finishes."
        next_warn=$(( next_warn + 3600 ))
      fi
    done
    wait "$pushjob" 2>/dev/null || true
    if [[ $(cat "$rcfile" 2>/dev/null) == 0 ]]; then
      logger -t idle-watchdog "mirror complete"
      unsaved=""
    else
      logger -t idle-watchdog "mirror FAILED - shutting down anyway; games since the last push are lost"
      unsaved="Your latest games were not saved - they may need downloading again."
    fi
  fi
  # Only a failure is worth a message from here: the cloud watchdog already says
  # the idle box is going, and one message per shutdown is enough.
  [[ -z $unsaved ]] || notify "Your latest games were not saved" "$unsaved"
  logger -t idle-watchdog "shutting down"
  "$SHUTDOWN_BIN" -h now "idle watchdog"
fi
