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
LIBS="${GAME_NOTIFY_LIBS:-/scratch/steam /scratch2/steam /home/ubuntu/.local/share/Steam}"
NOTIFY="${GAME_NOTIFY_CMD:-/usr/local/bin/cg-notify}"
mkdir -p "$STATE"

for lib in $LIBS; do
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
