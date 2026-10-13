#!/usr/bin/env bash
# Whether a new box restores the archived Steam login: a SETTING, not a prompt.
#
# It was a build-time question for one afternoon. It is the wrong shape: you
# answer it once and it stays true for every rebuild, which is what Settings is
# for - and a prompt in front of a 10-20 minute build is one more thing to read
# when you want to play. So GAME_STEAM_LOGIN is a dropdown next to the region
# and the instance type, and cg init asks nothing.
#
# "fresh" deletes and edits nothing. It SKIPS the pull on the box, so the
# archived login stays where it is for the next build. Throwing the archive
# away is a separate, deliberate act (cg library account forget).
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

echo "1. cg init does not ask"
cgsrc=$(cat cg); prov=$(cat lib/provision.sh)
contains "it goes straight to setup"   "$cgsrc" "choose_games; cg_exec lib/setup"
lacks    "  with no login chooser"     "$cgsrc" "choose_login"

echo "2. it is a dropdown in Settings"
# kind=choice is what makes the settings row render a <select>; without the
# label it renders as the raw GAME_STEAM_LOGIN, which is how it looked while
# the only way to answer was the prompt.
cfg=$(cat lib/config.sh); app=$(cat app/renderer/app.js)
contains "the registry calls it a choice" "$cfg" "GAME_STEAM_LOGIN|choice|use|use,fresh|"
contains "  with both values"             "$cfg" "use,fresh"
# The name belongs to the registry, not to the window: the app used to keep
# its own table, so a setting cg grew showed up as a raw GAME_SHOUTING_KEY.
contains "the registry names it"          "$cfg" "Steam sign-in"
contains "  and files it with the build settings" "$cfg" "Steam sign-in|The box"
contains "  and labels what it chose"     "$app" "use: 'use the archived login'"
contains "  including the other value"    "$app" "fresh: 'sign in fresh on the box'"

echo "3. the setting reaches the box"
contains "provision passes it"         "$prov"  'CG_LOGIN="${GAME_STEAM_LOGIN:-use}"'
contains "  and substitutes the token" "$prov"  '"CG_APPS", "CG_LOGIN"'
contains "  refusing to ship it unsubstituted" "$prov" '"__CG_APPS__", "__CG_LOGIN__"'
contains "the module forwards it" "$(cat lib/bootstrap.d/22-library.sh)" "'__CG_APPS__' '__CG_LOGIN__'"
inst=$(cat host/install-library.sh)
contains "install-library takes it"   "$inst" 'CG_LOGIN="${4:-${CG_LOGIN:-use}}"'
contains "  and writes it to the conf" "$inst" 'CG_LOGIN=${CG_LOGIN:-use}'

echo "4. the box honours it, and 'use' stays the default"
lib=$(cat host/cg-library)
contains "the default is use"      "$lib" 'LOGIN="${CG_LOGIN:-use}"'
contains "fresh skips the pull"    "$lib" 'if [[ $LOGIN == fresh ]]; then'
contains "  and says why"          "$lib" "not restoring the archived login"
contains "  and that nothing was lost" "$lib" "archived login is untouched"
contains "  naming the way back"   "$lib" "cg library account pull"
# The gate is a skip, not a delete: nothing may remove or rewrite the archive.
gate=$(awk '/if \[\[ \$LOGIN == fresh \]\]/,/^  fi$/' host/cg-library)
lacks "the gate deletes nothing"   "$gate" "s3 rm"
lacks "  and edits nothing"        "$gate" "sed -i"
# An explicit request is not a build-time preference and must still work.
contains "an explicit pull ignores the setting" "$lib" "pull|restore) account_pull ;;"

echo "5. this file's own needles are safe"
bad=$(sed 's/\\\$//g' "$0" | grep -nE '^(contains|lacks|check) +"[^"]*" +"[^"]*" +"[^"]*(\$\{|\$\()' || true)
if [[ -z $bad ]]; then echo "  ok   every needle with a \$ is single-quoted"; pass=$((pass+1))
else echo "  FAIL double-quoted needles bash will expand:"; echo "$bad"; fail=$((fail+1)); fi

echo ""
echo "steam-login-setting: $pass passed, $fail failed"
(( fail == 0 ))
