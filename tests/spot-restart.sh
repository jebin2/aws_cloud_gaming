#!/usr/bin/env bash
# A spot instance you stopped yourself cannot be started again.
#
# Stopping a spot instance disables its persistent request, and AWS refuses to
# start an instance whose request is not active. This was tested and written up
# in docs/troubleshooting.md, and then `cg open` met it as a raw API error:
#
#   IncorrectSpotRequestState ... the associated Spot Instance request is not
#   in an appropriate state to support start
#
# Knowing a thing and handling it are different. The behaviour was documented
# for weeks while the command that runs into it said nothing useful - and said
# nothing at all about the stopped box still billing for its root volume.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/lib"
cp "$REPO/lib/game" "$T/lib/game"
cp "$REPO/lib/common.sh" "$T/lib/common.sh"
cat > "$T/.env" <<EOF
GAME_INSTANCE_ID=i-test
GAME_REGION=ap-south-2
GAME_TS_HOST=gamevps
EOF

# LIFECYCLE=spot|none, SPOT_STATE=active|disabled|cancelled, STATE=stopped|running
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "aws $args" >> "$LOG"
case "$args" in
  *InstanceLifecycle*)   echo "${LIFECYCLE:-none}" ;;
  *SpotInstanceRequests*) echo "${SPOT_STATE:-active}" ;;
  *"start-instances"*)   echo '{}' ;;
  *State.Name*)          echo "${STATE:-stopped}" ;;
  *describe-instances*)  echo "${STATE:-stopped}" ;;
  *)                     echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"
# Everything after the start call - not what this file is about.
for c in tailscale moonlight ssh scp; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"
done

run() {
  rm -f "$T/log"
  ( cd "$T" && LOG="$T/log" PATH="$T/bin:$PATH" \
      LIFECYCLE="${LIFECYCLE:-none}" SPOT_STATE="${SPOT_STATE:-active}" \
      STATE="${STATE:-stopped}" timeout 25 bash ./lib/game up 2>&1 )
}
did() { grep -q "$1" "$T/log" 2>/dev/null && echo yes || echo no; }

echo "1. spot instance, request disabled: refuse and explain"
out=$(LIFECYCLE=spot SPOT_STATE=disabled STATE=stopped run)
check    "never called start-instances" "$(did 'start-instances')" "no"
contains "says it cannot start"     "$out" "cannot be started again"
contains "names the request state"  "$out" "'disabled'"
contains "says there is no undo"    "$out" "no way to re-enable"
contains "mentions the wasted cost" "$out" "bills for its root volume"
contains "gives the rebuild path"   "$out" "cg destroy && cg init"
contains "gives the on-demand path" "$out" "GAME_SPOT=0 cg init"

echo "2. spot instance, request cancelled: same refusal, state named correctly"
out=$(LIFECYCLE=spot SPOT_STATE=cancelled STATE=stopped run)
check    "never called start-instances" "$(did 'start-instances')" "no"
contains "names the request state"  "$out" "'cancelled'"

echo "3. spot instance with an ACTIVE request: it may start"
out=$(LIFECYCLE=spot SPOT_STATE=active STATE=stopped run)
check    "called start-instances"   "$(did 'start-instances')" "yes"

echo "4. an on-demand instance never consults the spot request at all"
out=$(LIFECYCLE=none STATE=stopped run)
check    "called start-instances"   "$(did 'start-instances')" "yes"
check    "did not query spot"       "$(did 'SpotInstanceRequests')" "no"

echo "5. an already-running box is untouched"
out=$(LIFECYCLE=spot SPOT_STATE=disabled STATE=running run)
contains "says so"                  "$out" "already running"
check    "no start call"            "$(did 'start-instances')" "no"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
