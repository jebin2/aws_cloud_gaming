#!/usr/bin/env bash
# Moonlight in a window, on Hyprland. Hyprland tiles every new window, and a
# tiled window fills its space: "in a window" opened looking full screen, at a
# size nobody set. cg floats each window Moonlight opens, at the size asked,
# and says what it found - a window Moonlight made full screen itself is left
# alone. Elsewhere, and full screen, Hyprland is not touched.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
# Moonlight: says what it was given, opens its window, streams for a moment.
cat > "$T/bin/moonlight" <<'FAKE'
#!/usr/bin/env bash
echo "args: $*"
echo $$ > "$T/ml.pid"
sleep 2
FAKE
# Hyprland: one window, owned by Moonlight, tiled (or full screen, if asked).
cat > "$T/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
if [[ $1 == clients ]]; then
  pid=$(cat "$T/ml.pid" 2>/dev/null) || { echo '[]'; exit 0; }
  printf '[{"address":"0x5a1","pid":%s,"mapped":true,"hidden":false,"floating":false,"fullscreen":%s,"size":[1880,1020]}]\n' \
    "$pid" "${FULL:-0}"
else
  echo "$*" >> "$T/calls"
fi
FAKE
chmod +x "$T/bin/"*
play() { : > "$T/calls"; rm -f "$T/ml.pid"
  ( env -i PATH="$T/bin:$PATH" HOME="$T" XDG_CACHE_HOME="$T/cache" T="$T" CG_COLOR=never "$@" \
      bash -c 'source lib/common.sh; source lib/session.sh; stream_play 100.64.0.9 Desktop' 2>&1 ); }

echo "1. in a window, on Hyprland: floated at the size asked"
out=$(play HYPRLAND_INSTANCE_SIGNATURE=x GAME_DISPLAY_MODE=windowed GAME_WINDOW_SIZE=1280x720 GAME_RES=1920x1080)
calls=$(cat "$T/calls"); mlog=$(cat "$T/cache/cg/moonlight.log")
contains "Moonlight is asked for a window"  "$mlog" "args: stream --resolution 1280x720 --display-mode windowed"
contains "  and the log says what was asked" "$mlog" "# cg: moonlight stream --resolution 1280x720 --display-mode windowed 100.64.0.9 Desktop"
contains "Hyprland floats it"               "$calls" "dispatch setfloating address:0x5a1"
contains "  at the size asked"              "$calls" "dispatch resizewindowpixel exact 1280 720,address:0x5a1"
contains "  centred"                        "$calls" "dispatch centerwindow 1"
contains "and says so"                      "$out" "window: Hyprland had the window tiled at 1880x1020 - floated at 1280x720, centred"
contains "  in Moonlight's log too"         "$mlog" "# cg: Hyprland had the window tiled"

echo "2. a window Moonlight made full screen itself is left alone"
out=$(play HYPRLAND_INSTANCE_SIGNATURE=x GAME_DISPLAY_MODE=windowed GAME_WINDOW_SIZE=1280x720 FULL=2)
lacks    "nothing dispatched"               "$(cat "$T/calls")" "setfloating"
contains "  and that is said"               "$out" "Moonlight made its window full screen itself"

echo "3. full screen, or not Hyprland: Hyprland is not touched"
out=$(play HYPRLAND_INSTANCE_SIGNATURE=x GAME_RES=1920x1080)
contains "full screen by default"           "$(cat "$T/cache/cg/moonlight.log")" "args: stream --resolution 1920x1080 --display-mode fullscreen"
lacks    "  nothing dispatched"             "$(cat "$T/calls")" "dispatch"
out=$(play GAME_DISPLAY_MODE=windowed GAME_WINDOW_SIZE=1280x720)
lacks    "no Hyprland: nothing dispatched"  "$(cat "$T/calls")" "dispatch"
contains "  and Moonlight still gets its window" "$(cat "$T/cache/cg/moonlight.log")" "--display-mode windowed"

echo; echo "session-window: $pass passed, $fail failed"; (( fail == 0 ))
