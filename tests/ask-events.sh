#!/usr/bin/env bash
# Every question cg asks goes through cg_ask, so a program can drive it.
#
# Three behaviours from one helper: a person gets the same `read -rp` as always,
# CG_JSON=1 turns the question into an `ask` event answered on stdin, and end of
# input leaves the default standing. A typed confirmation (DESTROY-ALL, FORGET)
# is never assumed for anyone - typing the word IS the confirmation.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

# ask '<code>' '<stdin>' - the library, then the code. CG_JSON / CG_YES pass through.
ask() {
  ( printf '%b' "${2-}" | env -i PATH="$PATH" HOME="$T" CG_COLOR=never \
      CG_JSON="${CG_JSON-0}" CG_YES="${CG_YES-0}" \
      bash -c 'source lib/common.sh; '"$1" ) 2>&1
}

echo "1. a person, or a pipe, answering"
check "the answer is taken"          "$(ask 'cg_ask id "q: " def' 'typed\n')" "typed"
check "Enter alone takes the default" "$(ask 'cg_ask id "q: " def' '\n')" "def"
check "end of input takes it too"     "$(ask 'cg_ask id "q: " def' '')" "def"
check "an answer with no newline still counts" "$(ask 'cg_ask id "q: " def' 'nonewline')" "nonewline"
check "no default, nothing said: empty" "$(ask 'cg_ask id "q: "' '')" ""

echo "2. yes or no"
check "y is yes"                     "$(ask 'cg_confirm id "q " N && echo YES || echo NO' 'y\n')" "YES"
check "yes is yes"                   "$(ask 'cg_confirm id "q " N && echo YES || echo NO' 'yes\n')" "YES"
check "n is no"                      "$(ask 'cg_confirm id "q " Y && echo YES || echo NO' 'n\n')" "NO"
check "Enter takes the default (Y)"  "$(ask 'cg_confirm id "q " Y && echo YES || echo NO' '\n')" "YES"
check "Enter takes the default (N)"  "$(ask 'cg_confirm id "q " N && echo YES || echo NO' '\n')" "NO"
check "anything else is no"          "$(ask 'cg_confirm id "q " N && echo YES || echo NO' 'maybe\n')" "NO"

echo "3. CG_YES=1 answers the default, and never a typed confirmation"
check "a Y-default question: yes"    "$(CG_YES=1 ask 'cg_confirm id "q " Y && echo YES || echo NO' '')" "YES"
check "an N-default question: no"    "$(CG_YES=1 ask 'cg_confirm id "q " N && echo YES || echo NO' '')" "NO"
check "a typed word is still required" \
      "$(CG_YES=1 ask 'cg_ask_typed id "type DESTROY-ALL: " DESTROY-ALL && echo GO || echo STOP' '')" "STOP"
check "  and accepted when typed"    "$(CG_YES=1 ask 'cg_ask_typed id "type DESTROY-ALL: " DESTROY-ALL && echo GO || echo STOP' 'DESTROY-ALL\n')" "GO"
check "  case matters"               "$(ask 'cg_ask_typed id "q " FORGET && echo GO || echo STOP' 'forget\n')" "STOP"

echo "4. CG_JSON=1: the question is an event, the answer is a line"
out=$(CG_JSON=1 ask 'v=$(cg_ask restore "which games? " none "all,none"); echo "answer=$v"' '2344520\n')
contains "an ask event"              "$out" '"t":"ask"'
contains "  with its id"             "$out" '"id":"restore"'
contains "  prompt"                  "$out" '"prompt":"which games? "'
contains "  default"                 "$out" '"default":"none"'
contains "  and choices"             "$out" '"choices":"all,none"'
contains "the answer came from stdin" "$out" "answer=2344520"
out=$(CG_JSON=1 ask 'v=$(cg_ask restore "which? " none); echo "answer=$v"' '')
contains "no answer: the default stands" "$out" "answer=none"
out=$(CG_JSON=1 ask 'v=$(cg_confirm c "go? " N && echo YES || echo NO); echo "r=$v"' 'y\n')
contains "confirm asks too"          "$out" '"id":"c"'
contains "  and reads the answer"    "$out" "r=YES"

echo "5. secrets"
out=$(CG_JSON=1 ask 'v=$(cg_ask_secret tskey "paste key: "); echo "len=${#v}"' 'tskey-auth-12345\n')
contains "marked as a secret"        "$out" '"secret":1'
contains "  and read whole"          "$out" "len=16"
lacks    "  never echoed back"       "$out" "tskey-auth-12345"

echo "6. every prompt goes through the helpers"
check "no bare read -rp outside lib/common.sh" \
      "$(grep -rn 'read -rp\|read -rsp\|read -r -p' cg lib/*.sh lib/setup lib/game | grep -vc '^lib/common.sh:')" "0"
for w in DESTROY-ALL FORGET CLEAN DELETE; do
  check "$w is a typed confirmation" "$(grep -c "cg_ask_typed [a-z-]* \"type $w" cg)" "1"
done
check "the session-end prompt asks"  "$(grep -c 'cg_ask session-end' lib/game)" "1"

echo "7. the settings prompts, driven"
mkdir -p "$T/repo"; cp -r lib lambda "$T/repo/"
out=$( cd "$T/repo" && printf '%b' 'tskey-auth-1\nme@example.com\n' \
  | env -i PATH="$PATH" HOME="$T" CG_JSON=1 CG_COLOR=never REGION=ap-south-2 TS_HOST=gamevps \
      TAILSCALE_API_KEY= GAME_NTFY_URL= GAME_DISK_GB=50 GAME_ARCHIVE_EXPIRY_DAYS=14 \
      bash -c 'source lib/common.sh; source lib/cloud-watchdog.sh; source lib/settings.sh; settings_prompts 1' 2>&1 )
contains "the auth key is asked as a secret" "$out" '"id":"tailscale-auth-key"'
contains "  and the email as a question"     "$out" '"id":"alert-email"'
check    "both were saved"                   "$(grep -c '^TAILSCALE_AUTH_KEY=tskey-auth-1$\|^EMAIL_ALERTS=me@example.com$' "$T/repo/.env")" "2"
lacks    "  the key is never echoed"         "$out" "tskey-auth-1\""

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
