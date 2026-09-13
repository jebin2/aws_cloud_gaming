#!/usr/bin/env bash
# Delete OFFLINE tailnet nodes named after this host, before a build.
#
# Pruning used to happen only in `cg destroy`. That was fine when destroy was
# how a session ended - but the box now terminates itself when it goes idle, and
# nothing on the box can delete its own tailnet entry (that needs an API token,
# which deliberately never leaves the laptop). So every auto-terminated box
# leaked a node, the next build found its name taken, and the tailnet crept to
# gamevps-1, gamevps-2, ...
#
# That is not cosmetic. A suffixed name means `.env` and Moonlight disagree about
# what the box is called, and a stale entry answers DNS for a machine that no
# longer exists - `ssh gamevps` hangs until it times out.
#
# Only OFFLINE nodes are touched. An online one is a box that exists, which this
# must never disturb - including the one being rebuilt beside it.
set -uo pipefail
cd "$(dirname "$0")/.."

TS_HOST="${GAME_TS_HOST:-gamevps}"
[[ -n ${TAILSCALE_API_KEY:-} ]] || exit 0        # nothing to do without a token

body=$(curl -sS --max-time 20 -w $'\n%{http_code}' \
  -H "Authorization: Bearer $TAILSCALE_API_KEY" \
  "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null)
code=$(tail -n1 <<<"$body"); body=$(sed '$d' <<<"$body")

case $code in
  401|403)
    # Said out loud: an expired token and a clean tailnet look identical
    # otherwise, and the cleanup just silently stops happening.
    echo "    tailnet token rejected ($code) - stale nodes will not be pruned"
    echo "    a new one: https://login.tailscale.com/admin/settings/keys"
    exit 0 ;;
  2*) : ;;
  *)  echo "    could not reach api.tailscale.com ($code) - skipping the prune"; exit 0 ;;
esac

stale=$(printf '%s' "$body" | TS_HOST="$TS_HOST" python3 -c '
import json, os, re, sys
host = os.environ["TS_HOST"]
pat = re.compile(r"^%s(-\d+)?$" % re.escape(host))
try:    devs = json.load(sys.stdin).get("devices", [])
except Exception: sys.exit(0)
for d in devs:
    name = (d.get("hostname") or "")
    # "online" is absent on some plans; treat only an explicit False as offline.
    if pat.match(name) and d.get("online") is False:
        print("%s\t%s\t%s" % (d["id"], name, (d.get("lastSeen") or "")[:19]))')

[[ -n ${stale//[[:space:]]/} ]] || exit 0

while IFS=$'\t' read -r id name seen; do
  [[ -n ${id:-} ]] || continue
  if curl -sS -X DELETE --max-time 20 -o /dev/null -w '%{http_code}' \
       -H "Authorization: Bearer $TAILSCALE_API_KEY" \
       "https://api.tailscale.com/api/v2/device/$id" 2>/dev/null | grep -q '^2'; then
    echo "    pruned stale tailnet node '$name' (last seen $seen)"
  else
    echo "    could not prune '$name' - the token may lack write scope"
  fi
done <<< "$stale"
exit 0
