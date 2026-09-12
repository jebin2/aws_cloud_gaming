#!/usr/bin/env bash
# A stopped spot instance can never restart, and still bills for its root
# volume. Every cost guard produces exactly that state - the on-host watchdog's
# `shutdown -h`, the CloudWatch ec2:stop action, the off-site StopInstances -
# and none of them can terminate instead, because a persistent spot request
# relaunches the moment its instance dies and no guard can cancel the request
# first.
#
# So stop is correct there, and this is the leak it leaves. Nothing reported it:
# `cg status` said "instance stopped", which reads as parked and recoverable.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
empty()    { if [[ -z ${2//[[:space:]]/} ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: expected nothing, got '$2'"; fail=$((fail+1)); fi; }

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"State.Name,InstanceLifecycle"*) printf '%s\t%s\n' "${STATE:-running}" "${LIFECYCLE:-spot}" ;;
  *SpotInstanceRequests*)           echo "${SPOT_STATE:-active}" ;;
  *VolumeId*)                       echo "vol-test" ;;
  *"describe-volumes"*)             echo "${GB:-50}" ;;
  *)                                echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"

run() {
  ( PATH="$T/bin:$PATH" STATE="${STATE:-running}" LIFECYCLE="${LIFECYCLE:-spot}" \
    SPOT_STATE="${SPOT_STATE:-active}" GB="${GB:-50}" \
    bash -c 'source lib/common.sh; stranded_spot_note ap-south-2 i-test' 2>&1 )
}

echo "1. stopped spot with a disabled request: the leak is reported"
out=$(STATE=stopped LIFECYCLE=spot SPOT_STATE=disabled GB=50 run)
contains "flags it as stranded"   "$out" "STRANDED"
contains "says it cannot start"   "$out" "can never start again"
contains "names the request state" "$out" "disabled"
contains "gives the size"         "$out" "50 GB"
contains "gives the monthly cost" "$out" "4.56"
contains "gives it in rupees"     "$out" "INR 401"
contains "says how to reclaim"    "$out" "cg destroy"

echo "2. a RUNNING spot box is not stranded"
out=$(STATE=running LIFECYCLE=spot SPOT_STATE=disabled run)
empty "says nothing" "$out"

echo "3. a stopped ON-DEMAND box is not stranded - it restarts fine"
out=$(STATE=stopped LIFECYCLE=none SPOT_STATE=disabled run)
empty "says nothing" "$out"

echo "4. a stopped spot box whose request is still ACTIVE is fine"
# Possible right after launch, before a stop has disabled anything.
out=$(STATE=stopped LIFECYCLE=spot SPOT_STATE=active run)
empty "says nothing" "$out"

echo "5. no instance id at all: silent, not an error"
out=$( PATH="$T/bin:$PATH" bash -c 'source lib/common.sh; stranded_spot_note ap-south-2 ""' 2>&1 )
empty "says nothing" "$out"

echo "6. the cost scales with the real volume, not a configured default"
out=$(STATE=stopped LIFECYCLE=spot SPOT_STATE=disabled GB=200 run)
contains "reports 200 GB"      "$out" "200 GB"
contains "and its cost"        "$out" "18.24"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
