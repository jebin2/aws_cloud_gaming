#!/usr/bin/env bash
# The phone hears when a game that was downloading is done - once - and says
# nothing about games that were simply there.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

LIB="$T/lib"; mkdir -p "$LIB/steamapps"
printf '#!/usr/bin/env bash\necho "$1 | $2" >> "%s/sent"\n' "$T" > "$T/notify"; chmod +x "$T/notify"
manifest() { # appid name flags
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n}\n' "$1" "$2" "$3" > "$LIB/steamapps/appmanifest_$1.acf"
}
run() { GAME_NOTIFY_STATE="$T/state" GAME_NOTIFY_LIBS="$LIB" GAME_NOTIFY_CMD="$T/notify" bash host/game-notify.sh; }
sent() { cat "$T/sent" 2>/dev/null | wc -l | tr -d ' '; }

echo "1. a game that was simply there"
manifest 100 "Hades" 4
run
check "says nothing" "$(sent)" "0"

echo "2. a download in progress"
manifest 200 "Red Dead Redemption 2" 1026
run
check "says nothing while it downloads" "$(sent)" "0"
manifest 200 "Red Dead Redemption 2" 512
run
check "  or while it is paused"        "$(sent)" "0"

manifest 200 "Red Dead Redemption 2" 516
run
check "  or paused on a game that is installed" "$(sent)" "0"

echo "3. it finishes"
manifest 200 "Red Dead Redemption 2" 4
run
check "one notification"              "$(sent)" "1"
check "  with the game's name"         "$(grep -c 'Red Dead Redemption 2 finished' "$T/sent")" "1"
run
check "  and only one"                 "$(sent)" "1"

echo "4. an update is a download too"
manifest 100 "Hades" 1030
run
manifest 100 "Hades" 4
run
check "it is told when done"          "$(grep -c 'Hades finished' "$T/sent")" "1"

echo "4b. a game on a library Steam lists itself (its Add Drive makes /scratch2/SteamLibrary)"
L2="$T/SteamLibrary"; mkdir -p "$L2/steamapps"
printf '"libraryfolders"\n{\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$L2" > "$T/libraryfolders.vdf"
m2() { printf '"AppState"\n{\n\t"appid"\t\t"7"\n\t"name"\t\t"Big Game"\n\t"StateFlags"\t\t"%s"\n}\n' "$1" > "$L2/steamapps/appmanifest_7.acf"; }
run2() { env -u GAME_NOTIFY_LIBS GAME_NOTIFY_STATE="$T/state2" GAME_NOTIFY_VDFS="$T/libraryfolders.vdf" GAME_NOTIFY_CMD="$T/notify" bash host/game-notify.sh; }
before=$(sent)
m2 1026; run2; m2 4; run2
check "it is told when the game there is done" "$(grep -c 'Big Game finished' "$T/sent")" "1"
check "  once" "$(( $(sent) - before ))" "1"

echo "5. the pieces are in place"
check "the installer puts the timer on" "$(grep -c 'enable --now game-notify.timer' host/install-watchdog.sh)" "1"
check "  and the build checks it"       "$(grep -c 'game-notify.timer' lib/bootstrap.d/15-watchdog.sh)" "1"
check "  and the service loads the notify settings" "$(grep -c 'EnvironmentFile=-/etc/cg-notify.conf' host/game-notify.service)" "1"

echo "game-notify: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
