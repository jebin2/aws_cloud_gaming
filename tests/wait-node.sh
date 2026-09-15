#!/usr/bin/env bash
# wait_new_node: how `cg init` recognises the box it just launched on the tailnet.
#
# It exists because of one run. The previous box had terminated itself, leaving
# an offline node called "gamevps". init listed the node NAMES, then the build's
# prune deleted that offline node - freeing the name - and the new box joined as
# plain "gamevps" 47 seconds after launch. Its name was already in the list, so
# nothing "new" ever appeared, and init waited out its 30 minutes on a healthy
# box. Case 1 is that run. Nodes are now compared by KEY.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
# `tailscale status --json` shaped like the real thing: Peer keyed by node key,
# DNSName carrying the tailnet name (which is what ssh and Moonlight use).
cat > "$T/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
[[ ${TS_FAIL:-0} == 1 ]] && exit 1
[[ $* == "status --json" ]] || exit 1
cat "$TS_JSON"
FAKE
chmod +x "$T/bin/tailscale"

tailnet() { # tailnet <key:name[:online]>...  -> writes the fake status
  python3 - "$@" > "$T/status.json" <<'PY'
import json, sys
peers = {}
for spec in sys.argv[1:]:
    key, name = spec.split(":")[:2]
    peers["nodekey:" + key] = {"PublicKey": "nodekey:" + key, "HostName": name.split("-")[0],
                               "DNSName": name + ".tailnet-example.ts.net.", "Online": True}
print(json.dumps({"Self": {"DNSName": "laptop.tailnet-example.ts.net."}, "Peer": peers}))
PY
}
snapshot() { # the list init takes before launching
  ( PATH="$T/bin:$PATH" TS_JSON="$T/status.json" bash -c 'source lib/common.sh; tailnet_node_keys' ) > "$T/before"
}
wait_for() { # wait_for <timeout>  -> "<name>|<rc>"
  local out rc
  out=$( PATH="$T/bin:$PATH" TS_JSON="$T/status.json" TS_HOST=gamevps CG_COLOR=never \
         TS_FAIL="${TS_FAIL:-0}" bash -c 'source lib/common.sh; wait_new_node "$1" "$2" 2>/dev/null' _ "$T/before" "$1" )
  rc=$?
  printf '%s|%s' "$out" "$rc"
}

echo "1. the new box takes the NAME of a node pruned after the snapshot"
tailnet "aaa:gamevps" "ppp:phone"; snapshot
tailnet "bbb:gamevps" "ppp:phone"            # stale aaa pruned, new box joined as gamevps
check "found at once, under the reused name" "$(wait_for 1800)" "gamevps|0"

echo "2. a name still held by another node: the box joins suffixed"
tailnet "aaa:gamevps"; snapshot
tailnet "aaa:gamevps" "bbb:gamevps-1"
check "found as gamevps-1" "$(wait_for 1800)" "gamevps-1|0"

echo "3. an empty tailnet before the launch"
: > "$T/status.json"; tailnet; snapshot
tailnet "bbb:gamevps"
check "found" "$(wait_for 1800)" "gamevps|0"

echo "4. an unrelated device joining meanwhile is NOT the box"
tailnet "aaa:gamevps"; snapshot
tailnet "aaa:gamevps" "ccc:phone"
check "keeps waiting, then times out" "$(wait_for 5)" "|1"

echo "5. nothing changed: times out rather than picking an old node"
tailnet "aaa:gamevps"; snapshot
check "times out" "$(wait_for 5)" "|1"

echo "6. tailscale failing is a timeout, not a crash or a false match"
tailnet "aaa:gamevps"; snapshot
tailnet "bbb:gamevps"
check "times out" "$(TS_FAIL=1 wait_for 5)" "|1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
