#!/usr/bin/env bash
# cg watcher and cg ping: the guard summary and the tailnet path, as reports.
#
# watcher's rows went through log, which picks a symbol from a line's words -
# and "ALARM False  <- state, actions-enabled" contains "enabled", so an alarm
# whose actions were OFF showed a green tick. Its rows now state what they mean
# (log_as). The plain output is pinned to what it printed before that change,
# captured from the previous cg with the same stubs, so a styling edit cannot
# quietly change a redirected report.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$2") | head -8; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: must not contain '$3'"; fail=$((fail+1)); fi; }
ESC=$'\e'
strip() { sed -E "s/\r//g; s/${ESC}\[[0-9;]*[A-Za-z]//g"; }

mkdir -p "$T/bin" "$T/home/.ssh" "$T/host"
cp cg "$T/cg"; cp -r lib "$T/lib"
cat > "$T/.env" <<'EOF'
GAME_INSTANCE_ID=i-test
GAME_REGION=ap-south-2
GAME_TS_HOST=gamevps
GAME_WATCHDOG_HOST=ubuntu@203.0.113.10
EOF
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *describe-instances*)  exit 1 ;;
  *describe-alarms*)     printf '%s\t%s\n' "ALARM" "${ACTIONS:-False}" ;;
  *get-caller-identity*) echo 123456789012 ;;
  *describe-budgets*)    echo 57.0 ;;
  *)                     exit 1 ;;
esac
FAKE
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"is-active remote-watchdog"*) echo "${WD_STATE:-active}" ;;
  *"tail -1"*)                   echo "2026-09-14T19:11:45+00:00 no running instance tagged gamevps - nothing to do" ;;
  *) exit 1 ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"
chmod +x "$T/bin"/*
cg() { ( cd "$T" && HOME="$T/home" PATH="$T/bin:$PATH" COLUMNS=90 bash ./cg "$@" 2>&1 ); }
norm() { sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}/TS/'; }

echo "1. plain watcher output is exactly what it was before the styling"
check "byte-identical, timestamps normalised" "$(CG_COLOR=never cg watcher | norm)" "$(cat <<'BASE'

TS  ==> guards
TS      instance          none
TS      on-host watchdog  (box not reachable)

TS      off-site watchdog active  on 203.0.113.10
TS        last            no running instance tagged gamevps - nothing to do

TS      idle alarm        ALARM False  <- state, actions-enabled
TS      budget            57.0
BASE
)"

echo "2. styled: each row carries the meaning it states, not one read from its words"
out=$(CG_COLOR=always cg watcher | strip)
contains "actions off: information, and says so"  "$out" "· idle alarm        ALARM, disarmed (cg open arms it for a session)"
lacks    "  and never a tick"                     "$out" "✓ idle alarm"
contains "off-site watchdog active: a tick"       "$out" "✓ off-site watchdog active"
contains "budget present: a tick"                 "$out" "✓ budget            57.0"
out=$(CG_COLOR=always ACTIONS=True cg watcher | strip)
contains "actions on: a tick, armed"              "$out" "✓ idle alarm        ALARM, armed"
out=$(CG_COLOR=always WD_STATE=inactive cg watcher | strip)
contains "off-site watchdog inactive: a warning"  "$out" "! off-site watchdog inactive"

echo "3. styled: a gap inside the box keeps the gutter"
out=$(CG_COLOR=always cg watcher | strip)
inside=$(sed -n '/╭─/,/╰─/p' <<<"$out" | sed '1d;$d')
bare=$(grep -c '^$' <<<"$inside" || true)
check "no bare blank line between the box's edges" "${bare:-0}" "0"

echo "4. ping is a report box; its plain output is untouched"
printf '#!/usr/bin/env bash\ncase "$*" in *"ip -4"*) echo 100.64.0.1 ;; *) exit 0 ;; esac\n' > "$T/bin/tailscale"
out=$(CG_COLOR=always cg ping | strip)
contains "titled"                "$out" "╭─ 📡 connection to gamevps"
contains "rows inside the box"   "$out" "│   latency no reply"
check    "plain: unchanged"      "$(CG_COLOR=never cg ping)" "$(printf '\n  node    gamevps (100.64.0.1)\n  path    unknown\n  latency no reply')"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
