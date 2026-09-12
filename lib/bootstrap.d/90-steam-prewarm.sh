# --- Sunshine ----------------------------------------------------------------
# `steam` on first run downloads ~200 MB and self-updates behind a GUI dialog.
# Doing it once at first boot means the user gets a client that is already
# current instead of a progress bar. `+quit` makes it update and exit.
# Pin Steam to the dock. Must go through xfconf-query, not a direct edit of
# xfce4-panel.xml: xfconfd owns that file while the session runs and silently
# overwrites direct edits on the next panel restart.
cat > /usr/local/bin/pin-steam-to-dock.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ -f "$HOME/.config/xfce4/.steam-pinned" ]] && exit 0
export DISPLAY=:0
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
[[ -f /usr/share/applications/steam.desktop ]] || exit 0

PID=30
# panel-2 is the bottom dock in the default xfce4 layout; panel-1 is the top bar.
cur=$(xfconf-query -c xfce4-panel -p /panels/panel-2/plugin-ids 2>/dev/null | tail -n +3 | tr '\n' ' ')
[[ -z ${cur// /} ]] && exit 0
grep -qw "$PID" <<< "$cur" && { touch "$HOME/.config/xfce4/.steam-pinned"; exit 0; }

xfconf-query -c xfce4-panel -p /plugins/plugin-$PID -n -t string -s launcher 2>/dev/null
xfconf-query -c xfce4-panel -p /plugins/plugin-$PID/items -n -t string -s steam.desktop -a 2>/dev/null
mkdir -p "$HOME/.config/xfce4/panel/launcher-$PID"
cp /usr/share/applications/steam.desktop "$HOME/.config/xfce4/panel/launcher-$PID/"

args=""; for i in $cur; do args="$args -t int -s $i"; done
# shellcheck disable=SC2086
xfconf-query -c xfce4-panel -p /panels/panel-2/plugin-ids $args -t int -s $PID 2>/dev/null
xfce4-panel -r >/dev/null 2>&1 &
touch "$HOME/.config/xfce4/.steam-pinned"
EOF
chmod 755 /usr/local/bin/pin-steam-to-dock.sh

# A separate, idempotent script rather than a step inside the prewarm: the
# library registration is an *invariant*, not a one-time install. It has to hold
# after every stop (which reformats /scratch and destroys the in-library marker)
# and after the first sign-in (when Steam rewrites libraryfolders.vdf from its
# own state and can drop an entry it does not believe in). The prewarm marker
# used to gate this, so once set, a broken library could never repair itself.
#
# Cheap when nothing is wrong: if the entry and the marker agree, it exits
# without starting Steam at all. It only pays the ~90s adoption cost when the
# invariant is actually violated.
cat > /usr/local/bin/steam-ensure-library.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
LOG="$HOME/steam-prewarm.log"
LIB="${STEAM_LIB_DIR:-/scratch/steam}"   # overridable so the logic can be tested off-box
say() { echo "$(date -Iseconds) ensure-library: $*" >>"$LOG"; }

export DISPLAY=:0
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export PATH="/usr/bin:/usr/games:/usr/local/bin:/bin"
STEAM=$(command -v steam || echo /usr/bin/steam)

ROOT=$(readlink -f "$HOME/.steam/steam" 2>/dev/null || echo "")
[[ -n $ROOT && -d "$ROOT/ubuntu12_64" ]] || { say "no client yet - nothing to do"; exit 0; }
CONF="$ROOT/config/libraryfolders.vdf"
MARKER="$LIB/steamapps/libraryfolder.vdf"

cid_of() { sed -n 's/.*"contentid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$1" 2>/dev/null | tail -1; }
entry_cid() {
  grep -A4 '"'"$LIB"'"' "$CONF" 2>/dev/null \
    | sed -n 's/.*"contentid"[[:space:]]*"\([0-9]*\)".*/\1/p' | head -1
}

# Steam is the authority on its own config: never edit it underneath a running
# client, or the rewrite on exit throws the edit away.
steam_running() {
  pgrep -x steam >/dev/null 2>&1 && return 0
  pgrep -u "$(id -u)" -f '/ubuntu12_(32|64)/steam' >/dev/null 2>&1
}
steam_stop() {
  pkill -x steam 2>/dev/null || true
  pkill -u "$(id -u)" -f '/ubuntu12_(32|64)/steam' 2>/dev/null || true
}

healthy() {
  local e m
  e=$(entry_cid); m=$(cid_of "$MARKER")
  [[ -n $e && -n $m && $e == "$m" ]]
}

if healthy; then say "ok (cid $(entry_cid))"; exit 0; fi
if steam_running; then say "steam is running - not touching its config"; exit 0; fi

say "repairing: entry='$(entry_cid)' marker='$(cid_of "$MARKER")'"

# The repair path has to run Steam, and graphical.target is reached before X
# accepts connections. The healthy path above needs no display, so this wait
# only ever costs something on a boot that actually has to fix the library.
for _ in $(seq 1 24); do xset q >/dev/null 2>&1 && break; sleep 5; done
xset q >/dev/null 2>&1 || { say "no X after 2 min - will retry next boot"; exit 0; }

for attempt in 1 2 3; do
  mkdir -p "$LIB/steamapps/common" "$ROOT/config" "$ROOT/steamapps"

  # Keep whichever id already exists so Steam sees the library it adopted
  # before, rather than a new one competing with it.
  CID=$(entry_cid); [[ -n $CID ]] || CID=$(cid_of "$MARKER")
  [[ -n $CID ]] || CID=$(python3 -c 'import random;print(random.getrandbits(63))')

  cat > "$MARKER" <<VDF
"libraryfolder"
{
	"contentid"		"$CID"
	"label"		""
}
VDF

  # Steam writes libraryfolders.vdf only after a sign-in, so on a fresh client
  # it does not exist and there is nothing to append to. Seed the skeleton.
  for F in "$CONF" "$ROOT/steamapps/libraryfolders.vdf"; do
    [[ -f $F ]] && continue
    cat > "$F" <<SKEL
"libraryfolders"
{
	"0"
	{
		"path"		"$ROOT"
		"label"		""
		"contentid"		"0"
		"totalsize"		"0"
		"update_clean_bytes_tally"		"0"
		"time_last_update_verified"		"0"
		"apps"
		{
		}
	}
}
SKEL
  done

  for F in "$CONF" "$ROOT/steamapps/libraryfolders.vdf"; do
    [[ -f $F ]] || continue
    grep -q "$LIB" "$F" && continue
    python3 - "$F" "$CID" "$LIB" <<'INNER'
import sys
p, cid, lib = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
entry = ('\t"1"\n\t{\n\t\t"path"\t\t"' + lib + '"\n\t\t"label"\t\t""\n'
         '\t\t"contentid"\t\t"' + cid + '"\n\t\t"totalsize"\t\t"0"\n'
         '\t\t"update_clean_bytes_tally"\t\t"0"\n\t\t"time_last_update_verified"\t\t"0"\n'
         '\t\t"apps"\n\t\t{\n\t\t}\n\t}\n')
i = s.rstrip().rfind('}')
open(p, 'w').write(s[:i] + entry + s[i:])
INNER
  done

  # Writing the entry is not the same as Steam believing it. Steam rebuilds the
  # file from its own state on start and drops a library it never adopted, so
  # the only real test is: run it, stop it, and see whether the entry survived.
  "$STEAM" +quit >>"$LOG" 2>&1 &
  SPID=$!
  for _ in $(seq 1 20); do steam_running && break; sleep 3; done
  for _ in $(seq 1 40); do steam_running || break; sleep 3; done   # let it exit
  steam_stop; wait "$SPID" 2>/dev/null || true; sleep 3

  if healthy; then say "registered (attempt $attempt, cid $CID)"; exit 0; fi
  say "attempt $attempt did not stick"
done

say "FAILED to register $LIB after 3 attempts"
exit 1
EOF
chmod 755 /usr/local/bin/steam-ensure-library.sh

# Runs on every graphical boot, not once: see above. Ordered after the prewarm
# so the two never drive Steam at the same time.
cat > /etc/systemd/system/steam-library.service <<'EOF'
[Unit]
Description=Keep /scratch/steam registered as a Steam library
After=graphical.target steam-prewarm.service scratch-disk.service

[Service]
Type=oneshot
User=ubuntu
ExecStart=/usr/local/bin/steam-ensure-library.sh
RemainAfterExit=no
TimeoutStartSec=600

[Install]
WantedBy=graphical.target
EOF
systemctl enable steam-library.service

cat > /usr/local/bin/steam-prewarm.sh <<'EOF'
#!/usr/bin/env bash
# Runs as the desktop user on first graphical boot. Everything it writes must
# be somewhere that user can write - /var/log is not.
set -uo pipefail
MARK="$HOME/.steam-prewarmed"
[[ -f $MARK ]] && exit 0
LOG="$HOME/steam-prewarm.log"
PHASE="$HOME/.steam-phase"
phase() { echo "$*" > "$PHASE"; }
export DISPLAY=:0
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
# Steam's first run puts up a zenity dialog. Without a session bus zenity dies
# and Steam reports "Installation cancelled" - a systemd User= service gets no
# session bus unless it is told where to find one.
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
# Valve's .deb installs /usr/bin/steam; Ubuntu's stub used /usr/games. Neither
# is guaranteed to be on systemd's default PATH - the service once failed with
# "No such file or directory" for exactly this reason.
export PATH="/usr/bin:/usr/games:/usr/local/bin:/bin"
STEAM=$(command -v steam || echo /usr/bin/steam)

# Measure the client in MB. Must follow symlinks and cover both layouts:
# Valve's .deb installs into ~/.local/share/Steam and makes ~/.steam/steam a
# symlink to it, so a plain `du -s ~/.steam` reports a constant 4K no matter how
# much has downloaded - which made the settle-detection below fire at 60s and
# kill Steam mid-download.
steam_size() {
  du -smL "$HOME/.steam" "$HOME/.local/share/Steam" 2>/dev/null \
    | awk '{t+=$1} END{print t+0}'
}

# `pgrep -x steam` alone is not enough. /usr/bin/steam is a shell script, so the
# kernel names the process after its interpreter, not the script - the check can
# miss a launcher that is running perfectly well, and then `pkill -x steam` fails
# to stop it too. Match the real client binary by path as well. Scoped with -u:
# an unscoped `pkill -f` once matched the calling shell's own command line.
steam_running() {
  pgrep -x steam >/dev/null 2>&1 && return 0
  pgrep -u "$(id -u)" -f '/ubuntu12_(32|64)/steam' >/dev/null 2>&1
}
steam_stop() {
  pkill -x steam 2>/dev/null || true
  pkill -u "$(id -u)" -f '/ubuntu12_(32|64)/steam' 2>/dev/null || true
}

# graphical.target is reached before X actually accepts connections, so the
# first attempt ran with no usable display. Wait for the server itself.
for _ in $(seq 1 60); do
  xset q >/dev/null 2>&1 && break
  sleep 5
done
xset q >/dev/null 2>&1 || { echo "no X after 5 min" >>"$LOG"; exit 0; }

# Valve's package ships the bootstrap tarball inside the .deb, and its launcher
# extracts it with no prompt - so first run needs nothing but a display. This is
# the whole reason for using Valve's .deb over Ubuntu's steam-installer, which
# downloads the client behind a zenity licence dialog that a headless first boot
# cannot answer, then reports "Installation cancelled".
#
# `steam +quit` does not reliably exit once the update finishes - it sat
# through the whole timeout with ten processes alive. So run it in the
# background and decide for ourselves when it is done.
#
# "size stopped growing" is NOT that signal on its own. Steam alternates between
# downloading and verifying/installing, and during an install phase the tree
# stops growing while the process is working perfectly well - a build died
# exactly there, killed at 267 MB because it paused for 60 seconds.
#
# So gate the whole heuristic on the artifact we actually want: the unpacked
# client. Until ubuntu12_64 exists, a flat size means "still working", never
# "finished", and we simply keep waiting.
client_installed() {
  local r
  r=$(readlink -f "$HOME/.steam/steam" 2>/dev/null) || return 1
  [[ -n $r && -d "$r/ubuntu12_64" ]]
}

phase "unpacking client and downloading update"
attempt=0
while (( attempt < 3 )) && ! client_installed; do
  attempt=$(( attempt + 1 ))
  "$STEAM" +quit >>"$LOG" 2>&1 &
  SPID=$!
  # Record which detection matched, so a failure leaves evidence rather than a
  # guess about how the launcher names its processes.
  sleep 20
  echo "attempt $attempt: launcher pid $SPID; -x match: $(pgrep -x steam >/dev/null 2>&1 && echo yes || echo no); size $(steam_size)MB" >>"$LOG"

  prev=-1; stable=0; waited=0
  while (( waited < 1200 )); do
    kill -0 "$SPID" 2>/dev/null || steam_running || break   # exited on its own
    cur=$(steam_size)
    if client_installed && (( cur > 0 && waited >= 120 && cur == prev )); then
      stable=$(( stable + 1 ))
      (( stable >= 4 )) && break                # installed AND ~60s flat
    else
      stable=0
    fi
    prev=$cur
    sleep 15; waited=$(( waited + 15 ))
  done
  steam_stop
  wait "$SPID" 2>/dev/null || true
  echo "attempt $attempt: settled at ${prev}MB after ${waited}s; installed: $(client_installed && echo yes || echo no)" >>"$LOG"
  client_installed || sleep 10
done

# Only claim success if the client is actually there - otherwise leave the
# marker unset so the next boot tries again.
ROOT=$(readlink -f "$HOME/.steam/steam" 2>/dev/null || echo "")
[[ -n $ROOT && -d "$ROOT/ubuntu12_64" ]] || { echo "client did not install" >>"$LOG"; exit 0; }

# Registering the NVMe library is an invariant that must survive stops and
# sign-ins, so it lives in its own idempotent script that also runs on every
# boot. Call it here so a fresh build is ready without waiting for a reboot.
phase "registering NVMe library"
/usr/local/bin/steam-ensure-library.sh || true

phase "pinning steam to the dock"
/usr/local/bin/pin-steam-to-dock.sh >>"$LOG" 2>&1 || true
phase "done"
touch "$MARK"
EOF
chmod 755 /usr/local/bin/steam-prewarm.sh

cat > /etc/systemd/system/steam-prewarm.service <<'EOF'
[Unit]
Description=Download and update the Steam client once, after the desktop is up
After=graphical.target

[Service]
Type=oneshot
User=ubuntu
ExecStart=/usr/local/bin/steam-prewarm.sh
RemainAfterExit=yes
TimeoutStartSec=1200

[Install]
WantedBy=graphical.target
EOF
systemctl enable steam-prewarm.service

