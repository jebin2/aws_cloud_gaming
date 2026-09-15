#!/usr/bin/env bash
# Pruning stale tailnet nodes before a build.
#
# It used to happen only in `cg destroy`. The box now terminates itself when it
# goes idle, and nothing on the box can delete its own tailnet entry - that
# needs an API token, which deliberately never leaves the laptop. So every
# auto-terminated box leaked a node and the names crept: gamevps-1, -2, -3.
#
# The dangerous half of this is the DELETE call, so the assertions that matter
# are the negative ones: a CONNECTED node must never be touched.
#
# The fixture is the shape the API actually returns, captured live on
# 2026-09-14. The first version of this file invented an "online" field - the
# v2 devices API has none; the real one is connectedToControl - and the code was
# written against the same invention. Every case passed, and the prune deleted
# nothing in production, ever. It only surfaced once cg destroy stopped deleting
# nodes itself and a rebuild joined as gamevps-1.
#
# Note "hostname" is the box's OS hostname, so a live box and a dead one BOTH
# say "gamevps"; only "name" (the MagicDNS name) carries the -1 suffix.
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
 {"id":"111","nodeId":"n111","hostname":"gamevps","name":"gamevps.tail0000.ts.net","connectedToControl":false,"lastSeen":"2026-09-13T08:59:49Z"},
 {"id":"222","nodeId":"n222","hostname":"gamevps","name":"gamevps-1.tail0000.ts.net","connectedToControl":true,"lastSeen":"2026-09-13T13:43:20Z"},
 {"id":"333","nodeId":"n333","hostname":"gamevps-2","name":"gamevps-2.tail0000.ts.net","connectedToControl":false,"lastSeen":"2026-09-12T21:00:00Z"},
 {"id":"444","nodeId":"n444","hostname":"conflict200","name":"conflict200.tail0000.ts.net","connectedToControl":false,"lastSeen":"2026-09-10T10:00:00Z"},
 {"id":"555","nodeId":"n555","hostname":"laptop","name":"laptop.tail0000.ts.net","connectedToControl":true,"lastSeen":"2026-09-13T13:44:00Z"},
 {"id":"666","nodeId":"n666","hostname":"gamevps","name":"gamevps-3.tail0000.ts.net","lastSeen":"2026-09-13T13:40:00Z"}
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

echo "2. a CONNECTED node is never touched"
# This is the one that would break a live box mid-build - and it has the same
# hostname as the dead node it sits beside.
check "left the running box alone" "$(cnt 'DELETE 222')" "0"

echo "2b. a node whose connection state is not reported is left alone"
# If the API ever drops or renames the field again, the safe failure is pruning
# nothing, not deleting the tailnet identity of a box that may be up.
check "field absent: not deleted" "$(cnt 'DELETE 666')" "0"

echo "3. other machines on the tailnet are never touched"
check "left another server alone"  "$(cnt 'DELETE 444')" "0"
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
