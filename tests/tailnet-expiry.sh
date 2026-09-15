#!/usr/bin/env bash
# Turning off Tailscale key expiry for the box that just joined.
#
# It replaces a manual step after every build. The call that matters is the
# write, so the assertions that matter are about WHICH node gets it: only the
# connected node with that MagicDNS name - never a stale, offline node from an
# earlier box, which shares the OS hostname.
#
# The fake API keeps state, so "the setting really changed" is checked the way
# the script checks it: by listing the devices again. Its device shape is the
# live v2 response's, fields checked 2026-09-15.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
# DEVICES: the device list as JSON. LIST_CODE / POST_CODE: HTTP status to answer
# with. STICKS=0: accept the write but do not change anything.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
log = open(os.environ["LOG"], "a")
state = os.environ["STATE"]
devs = json.load(open(state))
if "-X" in a and a[a.index("-X") + 1] == "POST":
    url = a[-1]; dev = url.split("/device/")[1].split("/")[0]
    body = a[a.index("-d") + 1]
    log.write("POST %s %s\n" % (dev, body))
    code = os.environ.get("POST_CODE", "200")
    if code.startswith("2") and os.environ.get("STICKS", "1") == "1":
        for d in devs:
            if d["id"] == dev: d["keyExpiryDisabled"] = json.loads(body)["keyExpiryDisabled"]
        json.dump(devs, open(state, "w"))
    sys.stdout.write(code)
else:
    log.write("LIST\n")
    code = os.environ.get("LIST_CODE", "200")
    sys.stdout.write(json.dumps({"devices": devs}) + "\n" + code)
FAKE
chmod +x "$T/bin/curl"

dev() { # dev <id> <magicdns-name> <connected> <expiry-disabled> <created>
  printf '{"id":"%s","nodeId":"n%s","hostname":"gamevps","name":"%s.tailnet-example.ts.net","connectedToControl":%s,"keyExpiryDisabled":%s,"expires":"2027-03-14T09:31:36Z","created":"%s"}' \
    "$1" "$1" "$2" "$3" "$4" "$5"
}
tailnet() { printf '[%s]' "$(IFS=,; echo "$*")" > "$T/state.json"; }
run() { # run <node>  -> "<output>|rc=<n>"
  rm -f "$T/log"; touch "$T/log"
  local out rc
  out=$(LOG="$T/log" STATE="$T/state.json" PATH="$T/bin:$PATH" TAILSCALE_API_KEY="${KEY-tskey-api-test}" \
        bash lib/tailnet-expiry.sh "$1" 2>&1); rc=$?
  printf '%s|rc=%s' "$out" "$rc"
}
posts() { grep '^POST' "$T/log" | tr '\n' ';'; }

echo "1. the connected box: expiry turned off, then confirmed"
tailnet "$(dev 111 gamevps true false 2026-09-15T07:51:00Z)"
out=$(run gamevps)
check    "one write, to that node, turning expiry off" "$(posts)" 'POST 111 {"keyExpiryDisabled": true};'
contains "confirmed by listing again"  "$out" "key expiry off for 'gamevps'"
contains "exit 0"                      "$out" "|rc=0"
check    "listed before and after"     "$(grep -c '^LIST' "$T/log")" "2"

echo "2. already off: nothing written"
out=$(run gamevps)
check    "no write"                    "$(posts)" ""
contains "says so, exit 0"             "$out" "already off for 'gamevps'"
contains "  rc"                        "$out" "|rc=0"

echo "3. a stale OFFLINE node of the same name is never touched"
tailnet "$(dev 222 gamevps false false 2026-09-01T00:00:00Z)" "$(dev 333 gamevps true false 2026-09-15T07:51:00Z)"
out=$(run gamevps)
check    "only the connected one written" "$(posts)" 'POST 333 {"keyExpiryDisabled": true};'
tailnet "$(dev 222 gamevps false false 2026-09-01T00:00:00Z)"
out=$(run gamevps)
check    "offline alone: no write"     "$(posts)" ""
contains "  and says there is no connected node" "$out" "no connected tailnet node named 'gamevps'"
contains "  exit 1"                    "$out" "|rc=1"

echo "4. the suffixed name is matched exactly, not by prefix"
tailnet "$(dev 444 gamevps true false 2026-09-01T00:00:00Z)" "$(dev 555 gamevps-1 true false 2026-09-15T07:51:00Z)"
out=$(run gamevps-1)
check    "gamevps-1 means gamevps-1"   "$(posts)" 'POST 555 {"keyExpiryDisabled": true};'

echo "5. no token: nothing tried, exit 2"
tailnet "$(dev 111 gamevps true false 2026-09-15T07:51:00Z)"
out=$(KEY= run gamevps)
check    "no calls at all"             "$(cat "$T/log")" ""
contains "says why"                    "$out" "no TAILSCALE_API_KEY"
contains "exit 2"                      "$out" "|rc=2"

echo "6. every failure says why, and exits 1"
out=$(LIST_CODE=401 run gamevps)
contains "rejected token"              "$out" "tailnet token rejected (401)"
check    "  no write"                  "$(posts)" ""
out=$(LIST_CODE=503 run gamevps)
contains "API unreachable"             "$out" "could not reach api.tailscale.com (503)"
out=$(POST_CODE=403 run gamevps)
contains "write refused"               "$out" "could not turn off key expiry (403)"
contains "  exit 1"                    "$out" "|rc=1"
out=$(STICKS=0 run gamevps)
contains "accepted, but did not take"  "$out" "still shows key expiry on"
contains "  exit 1"                    "$out" "|rc=1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
