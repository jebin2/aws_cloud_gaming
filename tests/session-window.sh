#!/usr/bin/env bash
# Moonlight in a window, on Hyprland. Asked for a window, it still filled the
# screen: Hyprland tiles every new window, and Moonlight opens its stream
# maximized when its launcher is - which a tiled window can be. cg puts each
# window it opens out of full screen, floating, at the size asked, centred,
# looks again a second later, and says what it found. Elsewhere, and full
# screen, Hyprland is not touched.
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
# Hyprland: one window, owned by Moonlight, in the state FULL says (0 tiled,
# 1 maximized, 2 full screen) until cg changes it - or, with STUBBORN, until
# Moonlight puts it back.
cat > "$T/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
state=$(cat "$T/state" 2>/dev/null || echo "${FULL:-0} false 1880 1020")
read -r full floating w h <<<"$state"
if [[ $1 == clients ]]; then
  pid=$(cat "$T/ml.pid" 2>/dev/null) || { echo '[]'; exit 0; }
  printf '[{"address":"0x5a1","pid":%s,"mapped":true,"hidden":false,"floating":%s,"fullscreen":%s,"size":[%s,%s]}]\n' \
    "$pid" "$floating" "$full" "$w" "$h"
  exit 0
fi
echo "$*" >> "$T/calls"
case "$*" in
  "dispatch fullscreenstate 0 0") [[ -n ${STUBBORN:-} ]] || full=0 ;;
  "dispatch setfloating"*) floating=true ;;
  "dispatch resizewindowpixel exact "*) read -r _ _ _ w h _ <<<"${*//,/ }" ;;
esac
echo "$full $floating $w $h" > "$T/state"
FAKE
chmod +x "$T/bin/"*
play() { : > "$T/calls"; rm -f "$T/ml.pid" "$T/state"
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
lacks    "  not taken out of a full screen it is not in" "$calls" "fullscreenstate"
contains "and says so"                      "$out" "window: Moonlight opened the window tiled at 1880x1020 - set to a window at 1280x720, centred"
contains "  in Moonlight's log too"         "$mlog" "# cg: Moonlight opened the window tiled"

echo "2. opened full screen or maximized anyway: set back to a window"
out=$(play HYPRLAND_INSTANCE_SIGNATURE=x GAME_DISPLAY_MODE=windowed GAME_WINDOW_SIZE=1280x720 FULL=2)
calls=$(cat "$T/calls")
contains "out of full screen"               "$calls" "dispatch fullscreenstate 0 0"
contains "  then floated and sized"         "$calls" "dispatch resizewindowpixel exact 1280 720,address:0x5a1"
contains "  and said"                       "$out" "window: Moonlight opened the window full screen at 1880x1020 - set to a window at 1280x720, centred"
out=$(play HYPRLAND_INSTANCE_SIGNATURE=x GAME_DISPLAY_MODE=windowed GAME_WINDOW_SIZE=1280x720 FULL=1)
contains "maximized is named as that"       "$out" "opened the window maximized"
out=$(play HYPRLAND_INSTANCE_SIGNATURE=x GAME_DISPLAY_MODE=windowed GAME_WINDOW_SIZE=1280x720 FULL=2 STUBBORN=1)
contains "put back by Moonlight: said, with its state" "$out" "and put it back full screen (state 2) after it was set to a window"

echo "3. full screen, or not Hyprland: Hyprland is not touched"
out=$(play HYPRLAND_INSTANCE_SIGNATURE=x GAME_RES=1920x1080)
contains "full screen by default"           "$(cat "$T/cache/cg/moonlight.log")" "args: stream --resolution 1920x1080 --display-mode fullscreen"
lacks    "  nothing dispatched"             "$(cat "$T/calls")" "dispatch"
out=$(play GAME_DISPLAY_MODE=windowed GAME_WINDOW_SIZE=1280x720)
lacks    "no Hyprland: nothing dispatched"  "$(cat "$T/calls")" "dispatch"
contains "  and Moonlight still gets its window" "$(cat "$T/cache/cg/moonlight.log")" "--display-mode windowed"

echo; echo "session-window: $pass passed, $fail failed"; (( fail == 0 ))
