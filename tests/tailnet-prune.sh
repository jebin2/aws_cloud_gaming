#!/usr/bin/env bash
# Pruning stale tailnet nodes before a build.
#
# It used to happen only in `cg destroy`. The box now terminates itself when it
# goes idle, and nothing on the box can delete its own tailnet entry - that
# needs an API token, which deliberately never leaves the laptop. So every
# auto-terminated box leaked a node and the names crept: gamevps-1, -2, -3.
#
# The dangerous half of this is the DELETE call, so the assertions that matter
# are the negative ones: an ONLINE node must never be touched.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
cnt() { local n; n=$(grep -c "$1" "$T/log" 2>/dev/null) || true; echo "${n:-0}"; }

mkdir -p "$T/bin"
# CODE sets the list response status; DELETE calls are logged.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
args="$*"
if [[ $args == *"-X DELETE"* ]]; then
  id="${args##*/device/}"; id="${id%% *}"
  echo "DELETE $id" >> "$LOG"
  printf '200'
  exit 0
fi
echo "LIST" >> "$LOG"
cat "$DEVICES"
printf '\n%s' "${CODE:-200}"
FAKE
chmod +x "$T/bin/curl"

cat > "$T/devices.json" <<'JSON'
{"devices":[
 {"id":"111","hostname":"gamevps","online":false,"lastSeen":"2026-09-13T08:59:49Z"},
 {"id":"222","hostname":"gamevps","online":true,"lastSeen":"2026-09-13T13:43:20Z"},
 {"id":"333","hostname":"gamevps-2","online":false,"lastSeen":"2026-09-12T21:00:00Z"},
 {"id":"444","hostname":"conflict200","online":false,"lastSeen":"2026-09-10T10:00:00Z"},
 {"id":"555","hostname":"laptop","online":true,"lastSeen":"2026-09-13T13:44:00Z"}
]}
JSON

run() {
  rm -f "$T/log"
  LOG="$T/log" DEVICES="$T/devices.json" CODE="${CODE:-200}" PATH="$T/bin:$PATH" \
  GAME_TS_HOST=gamevps TAILSCALE_API_KEY="${KEY-tskey-api-x}" \
    bash lib/tailnet-prune.sh 2>&1
}

echo "1. offline nodes for this host are pruned"
out=$(run)
check    "pruned the stale gamevps"   "$(cnt 'DELETE 111')" "1"
check    "pruned the stale gamevps-2" "$(cnt 'DELETE 333')" "1"
contains "said which, and when"       "$out" "last seen 2026-09-13T08:59:49"

echo "2. an ONLINE node is never touched"
# This is the one that would break a live box mid-build.
check "left the running box alone" "$(cnt 'DELETE 222')" "0"

echo "3. other machines on the tailnet are never touched"
check "left the off-site VPS alone" "$(cnt 'DELETE 444')" "0"
check "left the laptop alone"       "$(cnt 'DELETE 555')" "0"

echo "4. no API token: silent no-op, not an error"
# A token is optional; a build must not fail for want of housekeeping.
out=$(KEY= run); rc=$?
check "exits 0"        "$rc" "0"
check "called nothing" "$(cnt 'LIST')" "0"

echo "5. an expired token says so instead of looking like a clean tailnet"
out=$(CODE=403 run)
contains "names the rejection" "$out" "token rejected (403)"
contains "says what to do"     "$out" "login.tailscale.com"
check    "deleted nothing"     "$(cnt 'DELETE')" "0"

echo "6. an unreachable API is reported, not silently skipped"
out=$(CODE=000 run)
contains "says it could not reach" "$out" "could not reach"
check    "deleted nothing"         "$(cnt 'DELETE')" "0"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
