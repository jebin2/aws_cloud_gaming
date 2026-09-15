#!/usr/bin/env bash
# The cloud watchdog's decisions (lambda/cloud_watchdog.py), against fake EC2
# and CloudWatch clients. Its job is to end instances, so every branch that
# acts, and every branch that must not, has a case.
#
# boto3 is not needed: handler() imports it, and the tests call run() with
# fakes. Each case prints one line - "<action> | <calls made>" - which is what
# is asserted.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' lacks '$3'"; fail=$((fail+1)); fi; }

# case <python describing the scenario>  -> "<actions> | <calls> | <log>"
case_() {
  # No __pycache__ left in lambda/ - it is a source directory, not a build one.
  PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'PY' 2>&1
import sys, io, contextlib
from datetime import datetime, timedelta, timezone
sys.path.insert(0, "lambda")
import cloud_watchdog as w
w.IDLE_MINUTES, w.BOOT_GRACE_MINUTES, w.STUCK_MINUTES, w.THRESHOLD = 30, 20, 60, 10485760

NOW = datetime(2026, 9, 15, 12, 0, 0, tzinfo=timezone.utc)
def ago(m): return NOW - timedelta(minutes=m)

class AwsError(Exception):
    def __init__(self, code, msg=""):
        super().__init__(msg or code); self.response = {"Error": {"Code": code}}

calls = []
class EC2:
    def __init__(s, instances, deny=False, old_boto=False, describe_fails=False, fail_ids=()):
        s.instances, s.deny, s.old_boto, s.describe_fails, s.fail_ids = instances, deny, old_boto, describe_fails, fail_ids
    def describe_instances(s, Filters):
        if s.describe_fails: raise AwsError("AuthFailure", "AuthFailure: bad key")
        return {"Reservations": [{"Instances": s.instances}]}
    def _act(s, name, kw):
        if kw.get("DryRun"):
            calls.append(name + "(dry)")
            raise AwsError("UnauthorizedOperation" if s.deny else "DryRunOperation")
        if s.old_boto and "SkipOsShutdown" in kw:
            raise Exception('Parameter validation failed: Unknown parameter in input: "SkipOsShutdown"')
        if kw["InstanceIds"][0] in s.fail_ids: raise AwsError("UnauthorizedOperation", "denied")
        extra = "".join("+" + k for k in ("Force", "SkipOsShutdown") if kw.get(k))
        calls.append("%s:%s%s" % (name, kw["InstanceIds"][0], extra))
        return {}
    def terminate_instances(s, **kw): return s._act("terminate", kw)
    def stop_instances(s, **kw): return s._act("stop", kw)
    def create_tags(s, Resources, Tags):
        calls.append("tag:%s=%s" % (Resources[0], Tags[0]["Value"]))

class CW:
    def __init__(s, points=None, fails=False):
        s.points, s.fails = points or {}, fails   # {metric: [(minutes_ago, bytes)]}
    def get_metric_statistics(s, MetricName, **kw):
        if s.fails: raise AwsError("Throttling", "Rate exceeded")
        return {"Datapoints": [{"Timestamp": ago(m), "Sum": b} for m, b in s.points.get(MetricName, [])]}

def inst(iid="i-a", state="running", age=180, spot=True, reason="", tags=None):
    d = {"InstanceId": iid, "State": {"Name": state}, "LaunchTime": ago(age),
         "StateTransitionReason": reason, "Tags": tags or []}
    if spot: d["InstanceLifecycle"] = "spot"
    return d

QUIET = {"NetworkIn": [(m, 1000) for m in (5, 10, 15, 20, 25, 30)],
         "NetworkOut": [(m, 2000) for m in (5, 10, 15, 20, 25, 30)]}
ec2 = cw = None; dry = False
exec(sys.argv[1])
buf = io.StringIO(); err = ""
with contextlib.redirect_stdout(buf):
    try:
        res = w.run(ec2, cw, NOW, dry)
        acts = ",".join(d["action"] for d in res["decisions"]) or "-"
    except Exception as e:
        acts = "RAISED"
print("%s | %s | %s" % (acts, ",".join(calls) or "-", buf.getvalue().replace("\n", " / ").strip()))
PY
}
field() { cut -d'|' -f"$1" <<<"$2" | sed 's/^ *//; s/ *$//'; }

echo "1. no instance: nothing to do"
r=$(case_ 'ec2 = EC2([]); cw = CW()')
check "no action" "$(field 1 "$r")" "-"
contains "says so" "$r" "nothing to do"

echo "2. inside the boot grace"
r=$(case_ 'ec2 = EC2([inst(age=10)]); cw = CW()')
check "no action, no calls" "$(field 1 "$r")|$(field 2 "$r")" "none|-"

echo "3. quiet, but not yet watched for the whole window"
# 20 min grace + 30 min window: at 45 minutes old it has been judged for 25.
r=$(case_ 'ec2 = EC2([inst(age=45)]); cw = CW(QUIET)')
check "no action" "$(field 1 "$r")|$(field 2 "$r")" "none|-"
contains "says how long is left" "$r" "watched for only 25m of the 30m"

echo "4. busy: in and out are ADDED per period"
# 6 MB in + 6 MB out in one period is 12 MB of use; either alone is under 10.
r=$(case_ 'ec2 = EC2([inst()]); cw = CW({"NetworkIn": [(10, 6*1048576)], "NetworkOut": [(10, 6*1048576)]})')
check "left alone" "$(field 1 "$r")|$(field 2 "$r")" "none|-"
contains "names the traffic" "$r" "busy: 12.0 MB"

echo "5. exactly the threshold counts as use"
r=$(case_ 'ec2 = EC2([inst()]); cw = CW({"NetworkIn": [(10, 10485760)]})')
check "left alone" "$(field 1 "$r")" "none"

echo "6. quiet SPOT box past the window: terminated, gracefully"
r=$(case_ 'ec2 = EC2([inst(spot=True)]); cw = CW(QUIET)')
check "terminate, with no force" "$(field 1 "$r")|$(field 2 "$r")" "terminate|terminate:i-a"
contains "says the games are mirrored on the way" "$r" "mirrors its games to S3"

echo "7. quiet ON-DEMAND box: stopped, not terminated"
r=$(case_ 'ec2 = EC2([inst(spot=False)]); cw = CW(QUIET)')
check "stop" "$(field 1 "$r")|$(field 2 "$r")" "stop|stop:i-a"

echo "8. running but NO metrics at all (wedged): acts"
r=$(case_ 'ec2 = EC2([inst()]); cw = CW({})')
check "terminate" "$(field 1 "$r")" "terminate"
contains "calls it wedged" "$r" "wedged"

echo "9. traffic from BEFORE the window does not keep it alive"
# A period that ended 35 minutes ago is outside a 30-minute window.
r=$(case_ 'ec2 = EC2([inst()]); cw = CW({"NetworkIn": [(40, 50*1048576), (10, 1000)]})')
check "terminate" "$(field 1 "$r")" "terminate"
echo "9b. ...but a period that overlaps the window does"
r=$(case_ 'ec2 = EC2([inst()]); cw = CW({"NetworkIn": [(33, 50*1048576), (10, 1000)]})')
check "left alone" "$(field 1 "$r")" "none"

echo "10. a dry run acts on nothing, and proves the permission"
r=$(case_ 'ec2 = EC2([inst()]); cw = CW(QUIET); dry = True')
check "would terminate, only a DryRun call" "$(field 1 "$r")|$(field 2 "$r")" "would-terminate|terminate(dry)"
contains "permission ok" "$r" "permission to terminate: ok"
r=$(case_ 'ec2 = EC2([inst()], deny=True); cw = CW(QUIET); dry = True')
contains "a denied permission is reported" "$r" "DENIED"

echo "10b. a dry run proves the permission on a box it would NOT end"
# The case that matters in practice: `cg watchdog check` is run during a
# session, on a busy box - and used to say nothing about the permission.
r=$(case_ 'ec2 = EC2([inst()]); cw = CW({"NetworkIn": [(10, 50*1048576)]}); dry = True')
check "left alone, but the permission tested" "$(field 1 "$r")|$(field 2 "$r")" "none|terminate(dry)"
contains "and reported" "$r" "dry run: permission to terminate: ok"
r=$(case_ 'ec2 = EC2([inst(age=5, spot=False)]); cw = CW(); dry = True')
check "on demand, in the boot grace: stop tested" "$(field 1 "$r")|$(field 2 "$r")" "none|stop(dry)"
r=$(case_ 'ec2 = EC2([inst()], deny=True); cw = CW({"NetworkIn": [(10, 50*1048576)]}); dry = True')
contains "a denied permission on a busy box is reported" "$r" "DENIED"
echo "10c. a real run on a busy box makes no permission call"
r=$(case_ 'ec2 = EC2([inst()]); cw = CW({"NetworkIn": [(10, 50*1048576)]})')
check "no DryRun outside a dry run" "$(field 2 "$r")" "-"

echo "11. cannot read metrics: NOT idle - raise, act on nothing"
r=$(case_ 'ec2 = EC2([inst()]); cw = CW(fails=True)')
check "raised, no calls" "$(field 1 "$r")|$(field 2 "$r")" "RAISED|-"

echo "12. cannot describe instances: blind, and says so"
r=$(case_ 'ec2 = EC2([], describe_fails=True); cw = CW()')
check "raised" "$(field 1 "$r")" "RAISED"
contains "says it is blind" "$r" "CANNOT QUERY AWS"

echo "13. shutting down for 70 min (API timestamp): forced"
r=$(case_ 'ec2 = EC2([inst(state="shutting-down", reason="User initiated (2026-09-15 10:50:00 GMT)")]); cw = CW()')
check "forced terminate, OS shutdown skipped" "$(field 1 "$r")|$(field 2 "$r")" "force-terminate|terminate:i-a+SkipOsShutdown"

echo "14. shutting down for 20 min: left to finish its push"
r=$(case_ 'ec2 = EC2([inst(state="shutting-down", reason="User initiated (2026-09-15 11:40:00 GMT)")]); cw = CW()')
check "no action" "$(field 1 "$r")|$(field 2 "$r")" "none|-"
contains "says it is waiting" "$r" "letting it finish"

echo "15. an in-guest shutdown has no timestamp: tagged, then forced an hour later"
r=$(case_ 'ec2 = EC2([inst(state="stopping", spot=False, reason="")]); cw = CW()')
check "tags when first seen" "$(field 1 "$r")|$(field 2 "$r")" "none|tag:i-a=2026-09-15T12:00:00Z"
r=$(case_ 'ec2 = EC2([inst(state="stopping", spot=False, tags=[{"Key": w.SINCE_TAG, "Value": "2026-09-15T10:55:00Z"}])]); cw = CW()')
check "forced stop 65 min later" "$(field 1 "$r")|$(field 2 "$r")" "force-stop|stop:i-a+Force+SkipOsShutdown"

echo "16. a tag left from an EARLIER shutdown is ignored"
# An on-demand box stopped last week and started again an hour ago: measuring
# from last week's tag would force it down the moment it began stopping.
r=$(case_ 'ec2 = EC2([inst(state="stopping", spot=False, age=60, tags=[{"Key": w.SINCE_TAG, "Value": "2026-09-08T10:00:00Z"}])]); cw = CW()')
check "re-tagged, not forced" "$(field 1 "$r")|$(field 2 "$r")" "none|tag:i-a=2026-09-15T12:00:00Z"

echo "17. a boto3 without SkipOsShutdown still forces"
r=$(case_ 'ec2 = EC2([inst(state="shutting-down", reason="User initiated (2026-09-15 10:00:00 GMT)")], old_boto=True); cw = CW()')
check "plain terminate" "$(field 2 "$r")" "terminate:i-a"
r=$(case_ 'ec2 = EC2([inst(state="stopping", spot=False, reason="User initiated (2026-09-15 10:00:00 GMT)")], old_boto=True); cw = CW()')
check "stop with Force" "$(field 2 "$r")" "stop:i-a+Force"

echo "18. one instance failing does not spare the other, and the run still errors"
r=$(case_ 'ec2 = EC2([inst("i-a"), inst("i-b")], fail_ids=("i-a",)); cw = CW(QUIET)')
check "raised, i-b still terminated" "$(field 1 "$r")|$(field 2 "$r")" "RAISED|terminate:i-b"
contains "names the failure" "$r" "i-a FAILED"

echo "19. pending: not judged"
r=$(case_ 'ec2 = EC2([inst(state="pending")]); cw = CW()')
check "no action" "$(field 1 "$r")|$(field 2 "$r")" "none|-"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
