#!/usr/bin/env bash
# One phone notification when a game that was downloading is done. Run every
# minute by game-notify.timer.
#
# It only tells you about a download it SAW start: it writes a marker for every
# game whose manifest says "downloading" (StateFlags 1024), and the notification
# goes out when that game's flags no longer say so and say fully installed (4),
# not paused (512) and not waiting for an update (2).
# A game that is simply there - restored from the archive, or installed before
# this ran - has no marker and says nothing. Off without CG_NTFY_URL, like every
# other notification from the box (cg-notify decides).
set -uo pipefail

STATE="${GAME_NOTIFY_STATE:-/var/lib/cg-game-notify}"
VDFS="${GAME_NOTIFY_VDFS:-/home/*/.local/share/Steam/config/libraryfolders.vdf}"
NOTIFY="${GAME_NOTIFY_CMD:-/usr/local/bin/cg-notify}"
mkdir -p "$STATE"

# Every library on the box: the archive's, the added disk's, and each folder Steam
# lists itself - Steam's Add Drive makes its own (/scratch2/SteamLibrary), not the
# one cg named, and a game installed there must be seen.
libs() {
  if [[ -n ${GAME_NOTIFY_LIBS+x} ]]; then echo "$GAME_NOTIFY_LIBS"; return; fi
  {
    echo /scratch/steam; echo /scratch2/steam
    for v in $VDFS; do
      [[ -f $v ]] && sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$v"
    done
    for r in /home/*/.local/share/Steam; do [[ -d $r ]] && echo "$r"; done
  } | awk '!seen[$0]++'
}

for lib in $(libs); do
  for f in "$lib"/steamapps/appmanifest_*.acf; do
    [[ -f $f ]] || continue
    id=$(basename "$f" .acf); id=${id#appmanifest_}
    flags=$(sed -n 's/.*"StateFlags"[[:space:]]*"\([0-9]*\)".*/\1/p' "$f" | head -1)
    [[ -n $flags ]] || continue
    if (( flags & 1024 )); then
      name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -1)
      printf '%s\n' "${name:-$id}" > "$STATE/$id"
    elif [[ -f $STATE/$id ]] && (( flags & 4 )) && ! (( flags & (512 | 2) )); then
      name=$(head -n 1 "$STATE/$id")
      rm -f "$STATE/$id"
      "$NOTIFY" "Game ready" "$name finished downloading and is ready to play" default video_game
    fi
  done
done
exit 0
