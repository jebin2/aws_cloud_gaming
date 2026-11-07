#!/usr/bin/env bash
# Once per user, at the first login: the help picture as the desktop's background.
# Run by the autostart entry beside it. Only once: a wallpaper the person picked
# afterwards is theirs, and is not put back at the next login.
set -uo pipefail
IMG="${CG_WALLPAPER:-/usr/share/backgrounds/gamepc-help.png}"
MARK="${CG_WALLPAPER_MARK:-$HOME/.config/cg-wallpaper-set}"
WAIT="${CG_WALLPAPER_WAIT:-20}"
[[ -f $IMG ]] || exit 0
[[ -e $MARK ]] && exit 0

# xfdesktop writes a property set per monitor as it starts; wait for them.
for ((i = 0; i < WAIT; i++)); do
  xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -q 'last-image$' && break
  sleep 1
done

# Creates the property if it is not there, and sets it if it is.
put() { # put <property> <type> <value>
  xfconf-query -c xfce4-desktop -p "$1" -n -t "$2" -s "$3" 2>/dev/null \
    || xfconf-query -c xfce4-desktop -p "$1" -s "$3" 2>/dev/null
}
props=$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep 'last-image$' || true)
if [[ -z $props ]]; then
  # No property yet: name the monitors ourselves.
  for m in 0 $(xrandr --listmonitors 2>/dev/null | awk 'NR > 1 {print $NF}'); do
    props+="/backdrop/screen0/monitor$m/workspace0/last-image"$'\n'
  done
fi
while read -r p; do
  [[ -n $p ]] || continue
  base=${p%/last-image}
  put "$p" string "$IMG"
  put "$base/image-style" int 5     # zoomed: fills the screen at any size
  put "$base/color-style" int 0
done <<<"$props"

mkdir -p "$(dirname "$MARK")"
: > "$MARK"
