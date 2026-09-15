#!/usr/bin/env bash
# Turn off Tailscale key expiry for the box that just joined the tailnet.
#
# A node's key expires after ~180 days by default, and then the box drops off
# the tailnet and `cg open` hangs waiting for it. Stopping that used to be a
# manual step after every build: the admin console, the "..." menu, "Disable key
# expiry". The API token that already prunes stale nodes can do it instead.
#
# Only the CONNECTED node with exactly this MagicDNS name is touched. A stale,
# offline node from an earlier box shares the OS hostname, and is never the one
# being built.
#
#   exit 0  key expiry is off (now, or already)
#   exit 1  it could not be turned off - the reason is printed
#   exit 2  no TAILSCALE_API_KEY, so nothing was tried
set -uo pipefail
cd "$(dirname "$0")/.."

node="${1:?usage: lib/tailnet-expiry.sh <tailnet node name>}"
API="https://api.tailscale.com/api/v2"

[[ -n ${TAILSCALE_API_KEY:-} ]] || { echo "    no TAILSCALE_API_KEY in .env - key expiry left on"; exit 2; }

# -> sets BODY and CODE
list_devices() {
  local out
  out=$(curl -sS --max-time 20 -w $'\n%{http_code}' \
    -H "Authorization: Bearer $TAILSCALE_API_KEY" "$API/tailnet/-/devices" 2>/dev/null)
  CODE=$(tail -n1 <<<"$out"); BODY=$(sed '$d' <<<"$out")
}

# The connected node named $node, newest first: "<id>\t<true|false>".
pick() {
  printf '%s' "$BODY" | NODE="$node" python3 -c '
import json, os, sys
node = os.environ["NODE"]
try:
    devs = json.load(sys.stdin).get("devices", [])
except Exception:
    sys.exit(0)
# "name" is the MagicDNS name, which carries any -1 suffix; "hostname" is the
# OS hostname, which a live box and a stale one share.
live = [d for d in devs
        if (d.get("name") or "").split(".")[0] == node and d.get("connectedToControl") is True]
live.sort(key=lambda d: d.get("created") or "", reverse=True)
if live:
    d = live[0]
    print("%s\t%s" % (d["id"], "true" if d.get("keyExpiryDisabled") is True else "false"))'
}

list_devices
case $CODE in
  401|403)
    echo "    tailnet token rejected ($CODE) - key expiry left on"
    echo "    a new one: https://login.tailscale.com/admin/settings/keys"
    exit 1 ;;
  2*) : ;;
  *) echo "    could not reach api.tailscale.com ($CODE) - key expiry left on"; exit 1 ;;
esac

IFS=$'\t' read -r id disabled <<<"$(pick)"
if [[ -z ${id:-} ]]; then
  echo "    no connected tailnet node named '$node' - key expiry left on"
  exit 1
fi
if [[ $disabled == true ]]; then
  echo "    key expiry already off for '$node'"
  exit 0
fi

code=$(curl -sS -X POST --max-time 20 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TAILSCALE_API_KEY" -H "Content-Type: application/json" \
  -d '{"keyExpiryDisabled": true}' "$API/device/$id/key" 2>/dev/null)
if [[ $code != 2* ]]; then
  echo "    could not turn off key expiry ($code) - the token may lack write scope on devices"
  exit 1
fi

# Checked, not assumed: a 200 is the API accepting the request, not proof of
# the setting.
list_devices
IFS=$'\t' read -r id disabled <<<"$( [[ $CODE == 2* ]] && pick )"
if [[ ${disabled:-} == true ]]; then
  echo "    key expiry off for '$node' - it will not drop off the tailnet"
  exit 0
fi
echo "    the API accepted it, but '$node' still shows key expiry on"
exit 1
