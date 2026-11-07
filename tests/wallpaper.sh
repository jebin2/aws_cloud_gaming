#!/usr/bin/env bash
# The game PC's help picture: the right size, put on the desktop once at the first
# login, never over a wallpaper the person chose afterwards, and sent with the
# scripts.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

echo "1. the picture"
size=$(python3 -I -c 'from PIL import Image; print("%dx%d" % Image.open("lib/assets/gamepc-help.png").size)' 2>/dev/null || echo "no-pillow")
if [[ $size == no-pillow ]]; then echo "  (no Pillow - size skipped)"
else check "it is the size of the streamed screen" "$size" "1920x1080"; fi
check "it is a PNG" "$(head -c 4 lib/assets/gamepc-help.png | tail -c 3)" "PNG"
check "and is small enough for a bundle" "$(( $(stat -c %s lib/assets/gamepc-help.png) < 400000 ))" "1"

echo "2. the first login"
mkdir -p "$T/bin" "$T/home/.config"
IMG="$T/pic.png"; : > "$IMG"
# xfconf-query as xfdesktop leaves it: one monitor with its properties.
printf '#!/usr/bin/env bash\nif [[ $1 == -c ]] && [[ $3 == -l ]]; then echo /backdrop/screen0/monitorDVI-D-0/workspace0/last-image; echo /backdrop/screen0/monitorDVI-D-0/workspace0/image-style; exit 0; fi\necho "SET $*" >> "$LOG"\n' > "$T/bin/xfconf-query"
printf '#!/usr/bin/env bash\nprintf "Monitors: 1\\n 0: +*DVI-D-0 1920/0x1080/0+0+0  DVI-D-0\\n"\n' > "$T/bin/xrandr"
chmod +x "$T/bin"/*
run() { LOG="$T/log" HOME="$T/home" PATH="$T/bin:$PATH" CG_WALLPAPER="${1:-$IMG}" CG_WALLPAPER_WAIT=1 bash host/cg-wallpaper.sh; }
rm -f "$T/log"; run
check "it sets the picture on the monitor that is there" "$(grep -c "SET .*monitorDVI-D-0/workspace0/last-image .*$IMG" "$T/log")" "1"
check "  fills the screen at any size (zoomed)"  "$(grep -c 'image-style.* 5$' "$T/log")" "1"
check "  with a plain background colour behind it" "$(grep -c 'color-style.* 0$' "$T/log")" "1"
check "  and remembers that it did"              "$([[ -e $T/home/.config/cg-wallpaper-set ]] && echo yes)" "yes"
rm -f "$T/log"; run
check "the next login does not put it back"      "$(cat "$T/log" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "3. no picture, or no property yet"
rm -f "$T/home/.config/cg-wallpaper-set" "$T/log"; run "$T/missing.png"
check "no picture: nothing is touched"           "$(cat "$T/log" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "  and nothing is remembered"              "$([[ -e $T/home/.config/cg-wallpaper-set ]] && echo yes || echo no)" "no"
printf '#!/usr/bin/env bash\nif [[ $1 == -c ]] && [[ $3 == -l ]]; then exit 0; fi\necho "SET $*" >> "$LOG"\n' > "$T/bin/xfconf-query"
rm -f "$T/log"; run
check "no property yet: it names the monitors and creates them" "$(grep -c 'monitorDVI-D-0/workspace0/last-image' "$T/log")" "1"
check "  and the first one too"                  "$(grep -c 'monitor0/workspace0/last-image' "$T/log")" "1"

echo "4. it is sent, and installed"
check "the installer puts the picture in place" "$(grep -c 'install -D -m 644 gamepc-help.png /usr/share/backgrounds/gamepc-help.png' host/install-watchdog.sh)" "1"
check "  the script"                             "$(grep -c 'install -m 755 cg-wallpaper.sh /usr/local/bin/cg-wallpaper.sh' host/install-watchdog.sh)" "1"
check "  and the autostart entry"                "$(grep -c 'cg-wallpaper.desktop /etc/xdg/autostart/cg-wallpaper.desktop' host/install-watchdog.sh)" "1"
check "the entry runs the script, in Xfce only"  "$(grep -cE '^(Exec=/usr/local/bin/cg-wallpaper.sh|OnlyShowIn=XFCE;)$' host/cg-wallpaper.desktop)" "2"
check "the picture is embedded in the program"   "$(grep -c 'lib/assets' embed.go)" "1"

# A picture that cannot be installed must not stop the watchdog from being armed.
sed -n '/^(/,/^)/p' host/install-watchdog.sh > "$T/block.sh"
rm -rf "$T/b"; mkdir -p "$T/b"; cp lib/assets/gamepc-help.png "$T/b/"
out=$(cd "$T/b" && PATH="$T/failbin:$PATH" bash "$T/block.sh" 2>&1; echo "rc=$?")
check "a bundle with the picture but not its script does not fail the installer" "$(grep -c 'rc=0' <<<"$out")" "1"
check "  and says so"                              "$(grep -c 'help picture was not installed' <<<"$out")" "1"
out=$(cd "$T" && bash "$T/block.sh" 2>&1; echo "rc=$?")
check "a bundle with no picture is silently fine" "$out" "rc=0"
check "the picture step comes after the timers are armed" "$([[ $(grep -n 'enable --now disk-monitor.timer' host/install-watchdog.sh | cut -d: -f1) -lt $(grep -n 'gamepc-help.png' host/install-watchdog.sh | head -1 | cut -d: -f1) ]] && echo yes)" "yes"

echo "wallpaper: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
