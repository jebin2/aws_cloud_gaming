#!/usr/bin/env bash
# cg watcher and cg ping: the guard summary and the tailnet path, as reports.
#
# watcher's rows went through log, which picks a symbol from a line's words -
# and a row saying something was NOT enabled contains "enabled", so it showed a
# green tick. Its rows now state what they mean
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
EOF
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *describe-instances*)  exit 1 ;;
  *"events describe-rule"*) [[ ${RULE:-ENABLED} == none ]] && exit 254; echo "${RULE:-ENABLED}" ;;
  *filter-log-events*)   printf '%s\tcg-watchdog: %s\n' "$(( ($(date +%s) - 120) * 1000 ))" \
                           "${LAST:-no running instance tagged gamevps - nothing to do}" ;;
  *get-caller-identity*) echo 123456789012 ;;
  *describe-budgets*)    echo 57.0 ;;
  *)                     exit 1 ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/ssh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"
chmod +x "$T/bin"/*
cg() { ( cd "$T" && HOME="$T/home" PATH="$T/bin:$PATH" COLUMNS=90 bash ./cg "$@" 2>&1 ); }
norm() { sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}/TS/'; }

echo "1. plain watcher output is exactly what it was before the styling"
check "byte-identical, timestamps normalised" "$(CG_COLOR=never cg watcher | norm)" "$(cat <<'BASE'

TS  ==> guards
TS      instance          none
TS      on-host watchdog  (box not reachable)

TS      cloud watchdog    ENABLED  (Lambda gamevps-cloud-watchdog, every 5 min)
TS        last            2 min ago: no running instance tagged gamevps - nothing to do

TS      budget            57.0
BASE
)"

echo "2. styled: each row carries the meaning it states, not one read from its words"
out=$(CG_COLOR=always cg watcher | strip)
contains "cloud watchdog enabled: a tick"         "$out" "✓ cloud watchdog    ENABLED"
contains "budget present: a tick"                 "$out" "✓ budget            57.0"
lacks    "no CloudWatch alarm row"                "$out" "idle alarm"
out=$(CG_COLOR=always RULE=DISABLED cg watcher | strip)
contains "cloud watchdog disabled: a warning"     "$out" "! cloud watchdog    DISABLED"
out=$(CG_COLOR=always RULE=none cg watcher | strip)
contains "cloud watchdog absent: a warning"       "$out" "! cloud watchdog    not installed"
out=$(CG_COLOR=always LAST="CANNOT QUERY AWS - this watchdog is blind: AccessDenied" cg watcher | strip)
contains "a blind watchdog: a failure"            "$out" "✗   ^ it cannot act on your account"

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
