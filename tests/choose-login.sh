#!/usr/bin/env bash
# Choosing at build time whether a new box restores the archived Steam login.
#
# It has to be asked on the LAPTOP, before the instance launches, for the same
# reason the game picker is: the restore runs on the box at boot, started
# --no-block so it overlaps the build, and there is no terminal there to ask at.
# The answer travels in user-data as CG_LOGIN and lands in /etc/cg-library.conf.
#
# "fresh" deletes and edits nothing. It SKIPS the pull, so the archived login
# stays where it is for the next box - which is what makes this safe to offer
# on every build. Throwing the archive away is a separate, deliberate act
# (cg library account forget).
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

TWO='{"present":true,"bytes":22458,"accounts":[
  {"steamid":"1","account":"alice","most_recent":false,"last_used":1700000000},
  {"steamid":"2","account":"bob","most_recent":true,"last_used":1790000000}]}'
ONE='{"present":true,"bytes":22458,"accounts":[
  {"steamid":"9","account":"solo","most_recent":true,"last_used":1791000000}]}'
NONE='{"present":false,"accounts":[]}'
NAMELESS='{"present":true,"bytes":22458,"accounts":null}'

# The shipped function, with its collaborators stubbed. account_json is stubbed
# rather than aws, because what is under test is the DECISION, not the fetch -
# the fetch has its own tests in tests/steam-login.sh.
run() { # run <account-json> <answer> [GAME_STEAM_LOGIN already in .env]
  ANSWER="$2" PRESET="${3-}" JSON="$1" bash -c '
    set -uo pipefail
    say()  { echo "STEP $*"; }
    log()  { echo "$*"; }
    cg_ask() { echo "ASKED id=$1 default=$3 choices=$4" >&2; printf "%s" "$ANSWER"; }
    cg_env_set() { echo "ENV $1=$2"; }
    account_json() { printf "%s" "$JSON"; }
    [[ -n ${PRESET:-} ]] && GAME_STEAM_LOGIN="$PRESET"
    '"$(sed -n '/^choose_login() {/,/^}/p' cg)"'
    choose_login
    echo "RESULT ${GAME_STEAM_LOGIN:-unset}"' 2>&1
}

echo "1. a login is archived: the accounts are shown and 'use' is the default"
out=$(run "$TWO" 1)
contains "it is announced"          "$out" "STEP steam login"
contains "  both accounts listed"   "$out" "alice"
contains "  including the other"    "$out" "bob"
contains "  the one it signs in as" "$out" "signs in as this one"
contains "  with last-used dates"   "$out" "last used"
contains "  option 1 explained"     "$out" "comes up already signed in"
contains "  option 2 explained"     "$out" "sign in on the box"
# The archive is left alone either way, and saying so is what makes choosing
# "fresh" an easy decision rather than a scary one.
contains "  and that nothing is lost" "$out" "archive is left alone"
contains "the default is 1"         "$out" "default=1"
check    "answering 1 means use"    "$(grep -o 'RESULT .*' <<<"$out")" "RESULT use"
contains "  and it is remembered"   "$out" "ENV GAME_STEAM_LOGIN=use"

echo "2. answering 2 means fresh"
out=$(run "$TWO" 2)
check    "the choice is fresh"     "$(grep -o 'RESULT .*' <<<"$out")" "RESULT fresh"
contains "  it says what follows"  "$out" "ask you to sign in"
contains "  and is remembered"     "$out" "ENV GAME_STEAM_LOGIN=fresh"
# Typed words, not just the digit, because people type the word they just read.
check "the word works too" "$(grep -o 'RESULT .*' <<<"$(run "$TWO" fresh)")" "RESULT fresh"

echo "3. an empty answer takes the default"
# Enter is the commonest answer and must not change what a rebuild does.
check "empty means use" "$(grep -o 'RESULT .*' <<<"$(run "$TWO" '')")" "RESULT use"
check "anything unrecognised means use too" \
      "$(grep -o 'RESULT .*' <<<"$(run "$TWO" banana)")" "RESULT use"

echo "4. one archived account still asks, and names it"
out=$(run "$ONE" 1)
contains "the account is named" "$out" "solo"
contains "  and marked"         "$out" "signs in as this one"

echo "5. nothing archived: no question at all"
# There is nothing to choose between, and a prompt with one real answer is noise
# on a screen people are already waiting at.
out=$(run "$NONE" 1)
lacks    "not announced"        "$out" "STEP steam login"
lacks    "  and nothing asked"  "$out" "ASKED"
check    "  defaulting to use"  "$(grep -o 'RESULT .*' <<<"$out")" "RESULT use"

echo "6. an unreadable archive does NOT decide"
# A chooser that could not look must not choose. .env stands.
out=$(run "" 1 fresh)
lacks  "nothing asked"            "$out" "ASKED"
check  "  the .env value stands"  "$(grep -o 'RESULT .*' <<<"$out")" "RESULT fresh"
lacks  "  and nothing is written" "$out" "ENV GAME_STEAM_LOGIN"
out=$(run "" 1)
check  "  with no .env value it is use" "$(grep -o 'RESULT .*' <<<"$out")" "RESULT use"

echo "7. present but nameless: still asks, and admits the gap"
out=$(run "$NAMELESS" 1)
contains "it still asks"      "$out" "ASKED"
contains "  saying so"        "$out" "could not be read"

echo "8. the answer reaches the box"
cgsrc=$(cat cg); prov=$(cat lib/provision.sh)
contains "init asks before launching"  "$cgsrc" "choose_games; choose_login; cg_exec lib/setup"
contains "provision passes it"         "$prov"  'CG_LOGIN="${GAME_STEAM_LOGIN:-use}"'
contains "  and substitutes the token" "$prov"  '"CG_APPS", "CG_LOGIN"'
contains "  refusing to ship it unsubstituted" "$prov" '"__CG_APPS__", "__CG_LOGIN__"'
contains "the module forwards it" "$(cat lib/bootstrap.d/22-library.sh)" "'__CG_APPS__' '__CG_LOGIN__'"
inst=$(cat host/install-library.sh)
contains "install-library takes it"   "$inst" 'CG_LOGIN="${4:-${CG_LOGIN:-use}}"'
contains "  and writes it to the conf" "$inst" 'CG_LOGIN=${CG_LOGIN:-use}'

echo "9. the box honours it, and 'use' stays the default"
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

echo "10. it is a real setting, so it can be changed without a prompt"
contains "listed in config" "$(cat lib/config.sh)" "GAME_STEAM_LOGIN|choice|use|use,fresh|"

echo "11. this file's own needles are safe"
bad=$(sed 's/\\\$//g' "$0" | grep -nE '^(contains|lacks|check) +"[^"]*" +"[^"]*" +"[^"]*(\$\{|\$\()' || true)
if [[ -z $bad ]]; then echo "  ok   every needle with a \$ is single-quoted"; pass=$((pass+1))
else echo "  FAIL double-quoted needles bash will expand:"; echo "$bad"; fail=$((fail+1)); fi

echo ""
echo "choose-login: $pass passed, $fail failed"
(( fail == 0 ))
