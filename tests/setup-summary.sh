#!/usr/bin/env bash
# The end of cg init: a summary of what the box ended up with, then only the
# steps that are genuinely left.
#
# What matters here: every row states a fact that was checked (the Steam login
# is on the box, the games are installed), an automatic step is not listed as a
# chore, a step that did not happen still is - and the Sunshine password is
# never printed, because this output gets pasted into chats.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output contains '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
# The box: prints FACTS (tab-separated, as the real remote script does), or does
# not answer at all.
cat > "$T/bin/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null                                   # the remote script, on stdin
[[ ${BOX_DOWN:-0} == 1 ]] && exit 255
printf '%b' "$FACTS"
FAKE
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"events describe-rule"*) [[ ${RULE:-ENABLED} == none ]] && exit 254; echo "${RULE:-ENABLED}" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$T/bin"/*

GOOD='login\tyes\nlibrary\tyes\ngame\t2344520\t171985878943\tDiablo® IV\ngame\t1493710\t1200000000\tProton Experimental\ngame\t1628350\t600000000\tSteam Linux Runtime 3.0 (sniper)\n'

summary() { # summary  (state via environment)
  ( PATH="$T/bin:$PATH" CG_COLOR="${CG_COLOR:-never}" \
    TS_HOST=gamevps TS_NODE=gamevps IP=100.64.0.7 REGION=ap-south-2 TYPE=g6.xlarge \
    GAME_INSTANCE_ID=i-0123456789abcdef0 GAME_SPOT="${GAME_SPOT:-1}" GAMES_LIB=/scratch/steam \
    SUNSHINE_USER=admin SUNSHINE_PASS=super-secret-pass-123 \
    C_OPEN="cg open" C_STATUS="cg status" SSH="$T/bin/fake-ssh ubuntu@gamevps" \
    PAIRED="${PAIRED:-1}" EXPIRY_OFF="${EXPIRY_OFF:-1}" STEAM_MSG="${STEAM_MSG:-installed}" \
    FACTS="${FACTS-$GOOD}" BOX_DOWN="${BOX_DOWN:-0}" RULE="${RULE:-ENABLED}" \
    GAME_NTFY_URL="${GAME_NTFY_URL-}" GAME_ARCHIVE_EXPIRY_DAYS="${GAME_ARCHIVE_EXPIRY_DAYS-}" \
    GAME_BUDGET_INR=5000 \
    bash -c 'source lib/common.sh; source lib/cloud-watchdog.sh; source lib/summary.sh; init_summary' 2>&1 )
}

echo "1. everything automatic: a summary, no chores"
out=$(summary)
contains "the box, purchase model and region" "$out" "Box          i-0123456789abcdef0 · g6.xlarge spot · ap-south-2"
contains "that it is billing"          "$out" "billing by the hour - end it with: cg destroy"
contains "tailnet name, IP, expiry off" "$out" "Tailscale    gamevps · 100.64.0.7 · key expiry off"
contains "moonlight paired"            "$out" "Moonlight    paired with Sunshine"
contains "sunshine web UI"             "$out" "Sunshine     https://100.64.0.7:47990"
contains "the user, and where the password is" "$out" "user admin · password: SUNSHINE_PASS in .env"
lacks    "the password itself is NEVER printed" "$out" "super-secret-pass-123"
contains "steam signed in, checked on the box" "$out" "Steam        signed in"
contains "library registered"          "$out" "library /scratch/steam registered"
contains "the game, with its size"     "$out" "Diablo® IV"
contains "  160.2 GB"                  "$out" "160.2 GB"
lacks    "Proton is not a game"        "$out" "Proton Experimental"
lacks    "nor is the Steam runtime"    "$out" "Steam Linux Runtime"
contains "guards"                      "$out" "Guards       on-host 15 min · cloud watchdog 30 min"
contains "archive expiry"              "$out" "game archive deleted after 14 days with no box"
contains "budget and notifications"    "$out" "budget \$57 · notifications off (set GAME_NTFY_URL)"
lacks    "no action steps"             "$out" "ACTION NEEDED"
lacks    "no finished chores listed"   "$out" "DONE automatically"
contains "what to do next"             "$out" "cg open to play · cg status · cg destroy when done"

echo "2. not paired: the pairing step is shown, and counted"
out=$(PAIRED=0 summary)
contains "moonlight row says so"       "$out" "Moonlight    NOT paired - see below"
contains "the step"                    "$out" "STEP - pair Moonlight   [ACTION NEEDED]"
contains "  with the command"          "$out" "moonlight pair 100.64.0.7"
lacks    "no expiry step"              "$out" "stop the Tailscale key expiring"

echo "3. key expiry still on: that step is shown"
out=$(EXPIRY_OFF=0 summary)
contains "tailscale row says so"       "$out" "key expiry ON - see below"
contains "the step"                    "$out" "STEP - stop the Tailscale key expiring   [ACTION NEEDED]"
out=$(CG_COLOR=always PAIRED=0 EXPIRY_OFF=0 summary)
contains "styled title counts both"    "$out" "Ready · 2 steps left"
out=$(CG_COLOR=always EXPIRY_OFF=0 summary)
contains "styled title counts one"     "$out" "Ready · 1 step left"
out=$(CG_COLOR=always summary)
contains "styled title, nothing left"  "$out" "Ready · gamevps"
contains "styled rows get an emoji"    "$out" "📦 Games"

echo "4. what the box says, as it says it"
out=$(FACTS='login\tno\nlibrary\tno\n' summary)
contains "not signed in"               "$out" "not signed in - sign in once, and the next push saves it"
contains "library not registered"      "$out" "library NOT registered - add /scratch/steam"
contains "no games"                    "$out" "Games        none installed"
out=$(BOX_DOWN=1 summary)
contains "box silent: steam unknown"   "$out" "Steam        unknown - the box did not answer"
contains "box silent: games unknown"   "$out" "Games        unknown - the box did not answer"
out=$(STEAM_MSG="still installing - check ~/steam-prewarm.log on the box." summary)
contains "steam still installing"      "$out" "Steam        still installing - check: cg log steam"

echo "5. guards and settings, as configured"
out=$(RULE=none summary)
contains "watchdog not armed"          "$out" "cloud watchdog NOT armed - run: cg watchdog install"
out=$(GAME_ARCHIVE_EXPIRY_DAYS=0 summary)
contains "archive expiry off"          "$out" "game archive kept forever"
out=$(GAME_NTFY_URL=some-topic summary)
contains "notifications on"            "$out" "notifications on"
lacks    "  without the topic"         "$out" "some-topic"
out=$(GAME_SPOT=0 summary)
contains "on demand"                   "$out" "g6.xlarge on-demand"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
