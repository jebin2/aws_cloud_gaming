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
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' contains '$3'"; fail=$((fail+1)); fi; }

# case <python describing the scenario>  -> "<actions> | <calls> | <log>"
case_() {
  # No __pycache__ left in lambda/ - it is a source directory, not a build one.
  PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'PY' 2>&1
import sys, io, contextlib
from datetime import datetime, timedelta, timezone
sys.path.insert(0, "lambda")
import cloud_watchdog as w
w.IDLE_MINUTES, w.BOOT_GRACE_MINUTES, w.STUCK_MINUTES, w.THRESHOLD = 30, 20, 60, 10485760
w.NTFY_URL = ""; SEND_FAILS = False
def fake_send(url, title, message, priority, tags):
    if SEND_FAILS: raise Exception("network down")
    calls.append("notify:" + title)
w.send = fake_send

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

# --- archive expiry ------------------------------------------------------------
# It deletes the only copy of every game, so every branch that keeps the archive
# has a case, and every uncertainty must keep it too. It must also cost nothing
# until it deletes: its marks are SSM parameters and whether an archive exists is
# S3's daily CloudWatch metric - the S3 fake records every billed request made to it.
# Default scenario: no box, 160 GB measured yesterday, a last-seen mark 20 days
# old, nothing in CloudTrail, 2,500 objects and one abandoned upload - the one that
# DOES delete.
arch_() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'PY' 2>&1
import sys, io, json, contextlib
from datetime import datetime, timedelta, timezone
sys.path.insert(0, "lambda")
import cloud_watchdog as w
w.TS_HOST, w.BUCKET, w.EXPIRY_DAYS, w.TRAIL_PAGES = "gamevps", "cg-library-test", 14, 3
w.NTFY_URL = ""; SEND_FAILS = False
def fake_send(url, title, message, priority, tags):
    if SEND_FAILS: raise Exception("network down")
    calls.append("notify:" + title)
w.send = fake_send
NOW = datetime(2026, 9, 15, 12, 0, 0, tzinfo=timezone.utc)
def ago(days=0, hours=0, minutes=0): return NOW - timedelta(days=days, hours=hours, minutes=minutes)
def iso(t): return t.strftime("%Y-%m-%dT%H:%M:%SZ")
class AwsError(Exception):
    def __init__(s, code):
        super().__init__(code); s.response = {"Error": {"Code": code}}
calls = []; s3_requests = []
class EC2:
    def __init__(s, *batches, fail_idle=False):
        s.batches, s.fail_idle = list(batches) or [[]], fail_idle
    def describe_instances(s, Filters):
        states = [f for f in Filters if f["Name"] == "instance-state-name"][0]["Values"]
        if "stopped" not in states:        # the idle check's query
            if s.fail_idle: raise AwsError("AuthFailure")
            return {"Reservations": []}
        b = s.batches.pop(0) if len(s.batches) > 1 else s.batches[0]
        return {"Reservations": [{"Instances": [{"InstanceId": i, "State": {"Name": st}} for i, st in b]}]}
class CWStub:
    def __init__(s, gb=160.0, measured_days_ago=1, fails=False):
        s.gb, s.days, s.fails = gb, measured_days_ago, fails
    def get_metric_statistics(s, Namespace=None, MetricName=None, **kw):
        if Namespace != "AWS/S3": return {"Datapoints": []}
        if s.fails: raise AwsError("Throttling")
        if s.gb is None: return {"Datapoints": []}
        day = (NOW - timedelta(days=s.days)).replace(hour=0, minute=0, second=0)
        return {"Datapoints": [{"Timestamp": day, "Average": s.gb * 1073741824}]}
class SSM:
    def __init__(s, **marks):
        s.p, s.fails = {}, False
        for k, v in marks.items():
            s.p["/cloud-gaming/gamevps/archive-" + k.replace("_", "-")] = v if isinstance(v, str) else iso(v)
    def get_parameter(s, Name):
        if s.fails: raise AwsError("AccessDeniedException")
        if Name not in s.p: raise AwsError("ParameterNotFound")
        return {"Parameter": {"Value": s.p[Name]}}
    def put_parameter(s, Name, Value, Type, Overwrite):
        s.p[Name] = Value
        calls.append("%s=%s" % (Name.rsplit("/", 1)[1].replace("archive-", ""), Value))
class S3:
    def __init__(s, objects=0, uploads=0, delete_errors=False, gone=False):
        s.objects, s.uploads, s.delete_errors, s.gone = objects, uploads, delete_errors, gone
    def __getattr__(s, name):          # any S3 call not modelled here is still a request
        def call(**kw):
            s3_requests.append(name); return {}
        return call
    def list_objects_v2(s, Bucket, MaxKeys=1000):
        s3_requests.append("list")
        if s.gone: raise AwsError("NoSuchBucket")
        n = min(MaxKeys, s.objects)
        return {"Contents": [{"Key": "k%d" % i} for i in range(n)]} if n else {}
    def delete_objects(s, Bucket, Delete):          # DELETE requests are free
        if s.delete_errors: return {"Errors": [{"Key": "k0"}]}
        n = len(Delete["Objects"]); s.objects -= n; calls.append("delete-objects:%d" % n); return {}
    def list_multipart_uploads(s, Bucket):
        s3_requests.append("list-uploads")
        return {"Uploads": [{"Key": "u", "UploadId": "x"}]} if s.uploads else {}
    def abort_multipart_upload(s, **kw):
        s.uploads -= 1; calls.append("abort")
    def delete_bucket(s, Bucket): calls.append("delete-bucket")
class Trail:
    def __init__(s, events=(), fails=False, pages=1, junk=False):
        s.events, s.fails, s.pages, s.junk, s.served = list(events), fails, pages, junk, 0
    def lookup_events(s, **kw):
        calls.append("lookup")
        if s.fails: raise AwsError("ThrottlingException")
        s.served += 1
        evs = []
        if s.served == 1:
            for name, days, err in s.events:
                d = {"eventName": "RunInstances", "requestParameters": {"tagSpecificationSet": {"items": [
                    {"resourceType": "instance", "tags": [{"key": "Name", "value": name}]}]}}}
                if err: d["errorCode"] = err
                evs.append({"EventTime": ago(days=days), "CloudTrailEvent": "{not json" if s.junk else json.dumps(d)})
        out = {"Events": evs}
        if s.served < s.pages: out["NextToken"] = "t%d" % s.served
        return out
ec2 = EC2([]); cw = CWStub(); ssm = SSM(last_seen=ago(days=20)); s3 = S3(objects=2500, uploads=1)
trail = Trail(); dry = False; now = NOW; mode = "archive"
exec(sys.argv[1])
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    try:
        if mode == "archive": res = w.expire_archive(ec2, s3, ssm, cw, trail, now, dry)
        else: res = w.run_all(ec2, cw, s3, ssm, trail, now, dry)
    except Exception as e:
        res = "RAISED"
        print("error: %s" % e)
print("%s | %s | %s | s3:%s" % (res, ",".join(calls) or "-", buf.getvalue().replace("\n", " / ").strip(),
                               ",".join(s3_requests) or "none"))
PY
}

echo "20. expiry off: nothing is looked at"
r=$(arch_ 'w.EXPIRY_DAYS = 0')
check "no result, no calls" "$(field 1 "$r")|$(field 2 "$r")|$(field 4 "$r")" "None|-|s3:none"

echo "21. hourly: outside the first 5 minutes of the hour, a real run does nothing"
r=$(arch_ 'now = NOW + timedelta(minutes=17)')
check "no result, no calls" "$(field 1 "$r")|$(field 2 "$r")|$(field 4 "$r")" "None|-|s3:none"

echo "22. a box exists: kept, and its last-seen mark refreshed - in SSM"
r=$(arch_ 'ec2 = EC2([("i-a", "running")])')
check "kept, marked now" "$(field 1 "$r")|$(field 2 "$r")" "in-use|last-seen=2026-09-15T12:00:00Z"
contains "says why" "$r" "archive: kept - a box exists (i-a)"
r=$(arch_ 'ec2 = EC2([("i-a", "running")]); ssm = SSM(last_seen=ago(minutes=30))')
check "a mark under an hour old is not rewritten" "$(field 2 "$r")" "-"
r=$(arch_ 'ec2 = EC2([("i-a", "stopped")])')
check "a STOPPED box keeps it too" "$(field 1 "$r")" "in-use"

echo "23. no archive measured: nothing to do"
r=$(arch_ 'cw = CWStub(gb=None)')
check "no size measured: absent, nothing deleted" "$(field 1 "$r")|$(field 2 "$r")" "absent|-"
r=$(arch_ 'cw = CWStub(gb=0)')
check "an empty bucket is no archive" "$(field 1 "$r")" "absent"
r=$(arch_ 'ssm = SSM(last_seen=ago(days=20), deleted=ago(hours=5))')
check "a size measured before the last deletion is the deleted archive" "$(field 1 "$r")|$(field 2 "$r")" "absent|-"
r=$(arch_ 'ssm = SSM(last_seen=ago(days=20), deleted=ago(days=30))')
check "a deletion long ago does not hide a new archive" "$(field 1 "$r")" "deleted"

echo "24. no last-seen mark yet: counting starts, nothing deleted"
r=$(arch_ 'ssm = SSM()')
check "started, marked now" "$(field 1 "$r")|$(field 2 "$r")" "started|last-seen=2026-09-15T12:00:00Z"

echo "25. last used 3 days ago: kept, with the countdown, CloudTrail not asked"
r=$(arch_ 'ssm = SSM(last_seen=ago(days=3))')
check "kept, no calls" "$(field 1 "$r")|$(field 2 "$r")" "kept|-"
contains "counts down" "$r" "kept - last used 3d ago; deleted in 11d unless a box is launched"

echo "26. mark is old, but CloudTrail shows a launch: kept, and the mark moved to it"
r=$(arch_ 'trail = Trail([("gamevps", 5, None)])')
check "kept" "$(field 1 "$r")|$(field 2 "$r")" "kept|lookup,last-seen=2026-09-10T12:00:00Z"
contains "names the evidence" "$r" "a box was launched 5d ago (CloudTrail)"

echo "27. mark is old AND CloudTrail agrees: emptied, uploads aborted, deleted, remembered"
r=$(arch_ '')
check "deleted, in order" "$(field 1 "$r")|$(field 2 "$r")" \
  "deleted|lookup,delete-objects:1000,delete-objects:1000,delete-objects:500,abort,delete-bucket,deleted=2026-09-15T12:00:00Z"
contains "says so" "$r" "unused for 20d - DELETED s3://cg-library-test (2500 objects)"
r=$(arch_ 's3 = S3(gone=True)')
check "already gone when deleting: absent, and remembered" "$(field 1 "$r")|$(field 2 "$r")" "absent|lookup,deleted=2026-09-15T12:00:00Z"

echo "28. another host's launch, or a FAILED launch of this one, does not keep it"
r=$(arch_ 'trail = Trail([("other-box", 1, None), ("gamevps", 2, "Client.InsufficientInstanceCapacity")])')
check "deleted" "$(field 1 "$r")" "deleted"

echo "29. anything uncertain deletes NOTHING"
for spec in 'trail = Trail(fails=True)' \
            'trail = Trail(pages=5)' \
            'trail = Trail([("gamevps", 1, None)], junk=True)' \
            'ssm = SSM(last_seen="yesterday")' \
            'ssm.fails = True' \
            'cw = CWStub(fails=True)'; do
  r=$(arch_ "$spec")
  check "raised: $spec" "$(field 1 "$r")" "RAISED"
  lacks "  and deleted nothing" "$(field 2 "$r")" "delete"
done
r=$(arch_ 's3 = S3(objects=5, delete_errors=True)')
check "S3 refusing deletes: raised" "$(field 1 "$r")" "RAISED"
contains "  at the first refusal, and says so" "$r" "S3 refused to delete"
lacks "  and the bucket itself kept" "$(field 2 "$r")" "delete-bucket"
r=$(arch_ 'ec2 = EC2([], [("i-b", "pending")])')
check "a box appearing mid-check keeps it" "$(field 1 "$r")" "in-use"
lacks "  and deleted nothing" "$(field 2 "$r")" "delete"

echo "30. a dry run looks at any minute, and changes nothing"
r=$(arch_ 'dry = True; now = NOW + timedelta(minutes=17)')
check "would delete, no writes" "$(field 1 "$r")|$(field 2 "$r")" "would-delete|lookup"
contains "says so" "$r" "WOULD DELETE s3://cg-library-test (dry run)"
r=$(arch_ 'dry = True; ssm = SSM()')
check "no mark written in a dry run" "$(field 1 "$r")|$(field 2 "$r")" "started|-"

echo "31. the archive check still runs when the idle check fails"
r=$(arch_ 'mode = "all"; ec2 = EC2([("i-a", "running")], fail_idle=True)')
check "the run still errors" "$(field 1 "$r")" "RAISED"
contains "but the archive was checked" "$r" "archive: kept - a box exists"

echo "31b. it costs nothing until it deletes: no S3 request on any path that keeps the archive"
for spec in 'ec2 = EC2([("i-a", "running")])' 'ssm = SSM()' 'ssm = SSM(last_seen=ago(days=3))' \
            'trail = Trail([("gamevps", 5, None)])' 'cw = CWStub(gb=None)' 'dry = True' \
            'w.NTFY_URL = "u"; w.EXPIRY_DAYS = 1; ssm = SSM(last_seen=ago(hours=3))'; do
  r=$(arch_ "$spec")
  check "no S3 request: $spec" "$(field 4 "$r")" "s3:none"
done
r=$(arch_ '')
check "deleting: only the listings are billed requests" "$(field 4 "$r")" "s3:list,list,list,list,list-uploads,list-uploads"

echo "32. the watchdog names the archive bucket exactly as library-aws.sh creates it"
# Two copies of one formula. If they drift, expiry watches a bucket that does not
# exist and never deletes the real one - or, worse, is granted another bucket.
formula=$(grep -E '^  suffix=\$\(printf' lib/library-aws.sh)
lib_name=$(ACCOUNT=123456789012 TS_HOST=gamevps bash -c "$formula; echo cg-library-\$suffix")
cw_name=$(TS_HOST=gamevps GAME_S3_BUCKET= bash -c 'source lib/cloud-watchdog.sh; cw_bucket 123456789012')
check "same name" "$cw_name" "$lib_name"
check "GAME_S3_BUCKET wins, as it does there" \
  "$(TS_HOST=gamevps GAME_S3_BUCKET=my-bucket bash -c 'source lib/cloud-watchdog.sh; cw_bucket 123456789012')" "my-bucket"

echo "33. the off switch, and values used as written"
days() { TS_HOST=gamevps GAME_ARCHIVE_EXPIRY_DAYS="$1" bash -c 'source lib/cloud-watchdog.sh; cw_expiry_days'; }
check "0 is off"            "$(days 0)" "0"
check "3 is 3, not raised"  "$(days 3)" "3"
check "1 is 1"              "$(days 1)" "1"
check "30 is 30"            "$(days 30)" "30"
check "unset is 14"         "$(days '')" "14"
pol() { TS_HOST=gamevps REGION=ap-south-2 GAME_S3_BUCKET=b GAME_ARCHIVE_EXPIRY_DAYS="$1" bash -c 'source lib/cloud-watchdog.sh; cw_policy 123456789012'; }
check "off: the role cannot delete a thing" "$(pol 0 | grep -cE 'DeleteBucket|DeleteObject|cloudtrail' || true)" "0"
check "on: delete is scoped to that bucket" "$(pol 14 | grep -c '"Resource":"arn:aws:s3:::b/\*"')" "1"
check "on: no bucket tagging - the marks are SSM parameters" "$(pol 14 | grep -c 'BucketTagging' || true)" "0"
check "on: SSM limited to this host's marks" "$(pol 14 | grep -c '"Resource":"arn:aws:ssm:ap-south-2:123456789012:parameter/cloud-gaming/gamevps/\*"')" "1"
pol 14 | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && { echo "  ok   on: the policy is valid JSON"; pass=$((pass+1)); } \
  || { echo "  FAIL on: the policy is not valid JSON"; fail=$((fail+1)); }

echo "34. notifications from the idle check - only when a URL is set"
r=$(case_ 'w.NTFY_URL = "https://ntfy.sh/t"; ec2 = EC2([inst(spot=True)]); cw = CW(QUIET)')
check "terminated, then notified" "$(field 2 "$r")" "terminate:i-a,notify:gamevps: idle box terminated"
r=$(case_ 'ec2 = EC2([inst(spot=True)]); cw = CW(QUIET)')
lacks "no URL: no notification" "$(field 2 "$r")" "notify"
r=$(case_ 'w.NTFY_URL = "https://ntfy.sh/t"; ec2 = EC2([inst(spot=False)]); cw = CW(QUIET)')
check "on demand says stopped" "$(field 2 "$r")" "stop:i-a,notify:gamevps: idle box stopped"
r=$(case_ 'w.NTFY_URL = "https://ntfy.sh/t"; ec2 = EC2([inst()]); cw = CW(QUIET); dry = True')
lacks "a dry run never notifies" "$(field 2 "$r")" "notify"
r=$(case_ 'w.NTFY_URL = "https://ntfy.sh/t"; ec2 = EC2([inst(state="shutting-down", reason="User initiated (2026-09-15 10:00:00 GMT)")]); cw = CW()')
check "forced, then notified, and recorded" "$(field 2 "$r")" "terminate:i-a+SkipOsShutdown,notify:gamevps: stuck shutdown forced,tag:i-a=2026-09-15T10:00:00Z/2026-09-15T12:00:00Z"
r=$(case_ 'w.NTFY_URL = "https://ntfy.sh/t"; SEND_FAILS = True; ec2 = EC2([inst()]); cw = CW(QUIET)')
check "a failed send changes nothing" "$(field 1 "$r")|$(field 2 "$r")" "terminate|terminate:i-a"
contains "  and is logged" "$r" "notification not sent (ignored)"

echo "35. the 24-hour archive warning - once per countdown, recorded in SSM"
MARK='ssm = SSM(last_seen=ago(hours=3))'
r=$(arch_ "w.NTFY_URL = 'u'; w.EXPIRY_DAYS = 1; $MARK")
check "warned, and recorded against the deletion time" "$(field 1 "$r")|$(field 2 "$r")" \
  "kept|notify:gamevps: game archive deleted in 21h,warned=2026-09-16T09:00:00Z"
r=$(arch_ "w.NTFY_URL = 'u'; w.EXPIRY_DAYS = 1; ssm = SSM(last_seen=ago(hours=3), warned=ago(hours=-21))")
check "already warned for this deletion: silent" "$(field 2 "$r")" "-"
# Warned under 1 day, then the days were raised: the same mark, a later deletion.
r=$(arch_ "w.NTFY_URL = 'u'; w.EXPIRY_DAYS = 14; ssm = SSM(last_seen=ago(days=13, hours=3), warned=ago(days=12, hours=3))")
contains "days changed after a warning: warned again" "$(field 2 "$r")" "notify:gamevps: game archive deleted in 21h"
r=$(arch_ "w.NTFY_URL = 'u'; w.EXPIRY_DAYS = 1; ssm = SSM(last_seen=ago(hours=3), warned=ago(days=9))")
contains "a warning for an OLD mark does not count" "$(field 2 "$r")" "notify:gamevps: game archive deleted in 21h"
r=$(arch_ "w.NTFY_URL = 'u'; ssm = SSM(last_seen=ago(days=3))")
check "more than 24h left: silent" "$(field 2 "$r")" "-"
r=$(arch_ "w.NTFY_URL = 'u'; SEND_FAILS = True; w.EXPIRY_DAYS = 1; $MARK")
check "a failed send is not recorded, so the next hour retries" "$(field 2 "$r")" "-"
r=$(arch_ "w.EXPIRY_DAYS = 1; $MARK")
check "no URL: no warning, no mark" "$(field 2 "$r")" "-"
r=$(arch_ "w.NTFY_URL = 'u'; dry = True; w.EXPIRY_DAYS = 1; $MARK")
check "a dry run: no warning, no mark" "$(field 2 "$r")" "-"

echo "36. archive deleted, and a failing watchdog, are notified"
r=$(arch_ "w.NTFY_URL = 'u'")
contains "deleted, remembered, then notified" "$(field 2 "$r")" "delete-bucket,deleted=2026-09-15T12:00:00Z,notify:gamevps: game archive deleted"
r=$(arch_ "w.NTFY_URL = 'u'; mode = 'all'; ec2 = EC2([('i-a', 'running')], fail_idle=True)")
contains "failing: notified" "$(field 2 "$r")" "notify:gamevps: cloud watchdog failing"
r=$(arch_ "w.NTFY_URL = 'u'; mode = 'all'; now = NOW + timedelta(minutes=17); ec2 = EC2([('i-a', 'running')], fail_idle=True)")
lacks "but at most once an hour" "$(field 2 "$r")" "notify"

# --- the box confirmed gone ----------------------------------------------------
state_() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'PY' 2>&1
import sys, io, contextlib
sys.path.insert(0, "lambda")
import cloud_watchdog as w
w.TS_HOST, w.NTFY_URL = "gamevps", "https://ntfy.sh/t"
calls = []
def fake_send(url, title, message, priority, tags):
    calls.append("notify:" + title); print("sent: " + message)
w.send = fake_send
from datetime import datetime, timezone
NOW = datetime(2026, 9, 15, 12, 0, 0, tzinfo=timezone.utc)
w.BUCKET, w.EXPIRY_DAYS = "cg-library-test", 14
class AwsError(Exception):
    def __init__(s, code):
        super().__init__(code); s.response = {"Error": {"Code": code}}
class EC2:
    def __init__(s, name="gamevps", fails=False): s.name, s.fails = name, fails
    def describe_instances(s, InstanceIds=None, Filters=None):
        calls.append("describe:%s" % (InstanceIds or ["by-filter"])[0])
        if s.fails: raise AwsError("InvalidInstanceID.NotFound")
        return {"Reservations": [{"Instances": [{"InstanceId": InstanceIds[0],
                "Tags": [{"Key": "Name", "Value": s.name}]}]}]}
def event(state, iid="i-a"):
    return {"source": "aws.ec2", "detail-type": "EC2 Instance State-change Notification",
            "detail": {"instance-id": iid, "state": state}}
def spot(iid="i-a"):
    return {"source": "aws.ec2", "detail-type": "EC2 Spot Instance Interruption Warning",
            "detail": {"instance-id": iid, "instance-action": "terminate"}}
class CWS:
    def __init__(s, gb=160.0, fails=False): s.gb, s.fails = gb, fails
    def get_metric_statistics(s, **kw):
        calls.append("metric")
        if s.fails: raise AwsError("Throttling")
        if s.gb is None: return {"Datapoints": []}
        return {"Datapoints": [{"Timestamp": datetime(2026, 9, 14, tzinfo=timezone.utc), "Average": s.gb * 1073741824}]}
class SSMS:
    def __init__(s): s.fails = False
    def put_parameter(s, Name, Value, Type, Overwrite):
        if s.fails: raise AwsError("AccessDeniedException")
        calls.append("%s=%s" % (Name.rsplit("/", 1)[1].replace("archive-", ""), Value))
ec2 = EC2(); cw = CWS(); ssm = SSMS(); ev = event("terminated"); mode = "direct"
exec(sys.argv[1])
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    try:
        if mode == "handler":
            made = []
            class Boto3:
                def client(s, name):
                    made.append(name)
                    return ec2 if name == "ec2" else cw if name == "cloudwatch" else ssm if name == "ssm" else object()
            sys.modules["boto3"] = Boto3()
            res = w.handler(ev, None)
            calls.append("clients:" + "+".join(made))
        else:
            res = w.state_changed(ec2, ev, cw, NOW, ssm)
        res = res.get("state", "-")
    except Exception as e:
        res = "RAISED"; print("error: %s" % e)
print("%s | %s | %s" % (res, ",".join(calls) or "-", buf.getvalue().replace("\n", " / ").strip()))
PY
}

echo "37. the box confirmed gone, from EC2's own state-change event"
r=$(state_ '')
check "terminated: notified" "$(field 1 "$r")|$(field 2 "$r")" "terminated|describe:i-a,last-seen=2026-09-15T12:00:00Z,metric,notify:gamevps: box terminated"
r=$(state_ 'ev = event("stopped")')
check "stopped: notified" "$(field 2 "$r")" "describe:i-a,last-seen=2026-09-15T12:00:00Z,metric,notify:gamevps: box stopped"
r=$(state_ 'ec2 = EC2(name="someone-else")')
check "another instance in the account: silent" "$(field 1 "$r")|$(field 2 "$r")" "not-ours|describe:i-a"
r=$(state_ 'ec2 = EC2(fails=True)')
check "cannot describe it: silent" "$(field 1 "$r")|$(field 2 "$r")" "unknown|describe:i-a"
contains "  and says why" "$r" "could not be described"
r=$(state_ 'ev = event("running")')
check "a state that is not an end: ignored" "$(field 1 "$r")|$(field 2 "$r")" "ignored|-"
r=$(state_ 'w.NTFY_URL = ""')
check "no URL: logged, nothing sent" "$(field 2 "$r")" "describe:i-a,last-seen=2026-09-15T12:00:00Z,metric"
contains "  logged" "$r" "i-a terminated - compute no longer bills."
r=$(state_ 'mode = "handler"')
# The handler uses the real clock, so the mark's value is not asserted here.
contains "the handler routes it, and runs no idle or archive check" "$(field 2 "$r")" "describe:i-a,last-seen="
contains "  with its clients" "$(field 2 "$r")" "notify:gamevps: box terminated,clients:ec2+cloudwatch+ssm"

r=$(state_ 'ev = spot()')
check "a spot interruption warning: notified" "$(field 1 "$r")|$(field 2 "$r")" "interruption|describe:i-a,notify:gamevps: spot box being reclaimed"
r=$(state_ 'ev = spot(); ec2 = EC2(name="someone-else")')
check "another instance's warning: silent" "$(field 1 "$r")|$(field 2 "$r")" "not-ours|describe:i-a"
r=$(state_ 'ev = spot(); mode = "handler"')
check "the handler routes a warning too" "$(field 2 "$r")" "describe:i-a,notify:gamevps: spot box being reclaimed,clients:ec2+cloudwatch+ssm"

echo "37c. the archive countdown starts when the box really ended"
r=$(state_ '')
contains "terminated: last-seen set to that moment" "$(field 2 "$r")" "last-seen=2026-09-15T12:00:00Z"
r=$(state_ 'ev = event("stopped")')
contains "stopped: the same" "$(field 2 "$r")" "last-seen=2026-09-15T12:00:00Z"
r=$(state_ 'w.EXPIRY_DAYS = 0')
lacks "expiry off: nothing written" "$(field 2 "$r")" "last-seen"
r=$(state_ 'ec2 = EC2(name="someone-else")')
lacks "another instance: nothing written" "$(field 2 "$r")" "last-seen"
r=$(state_ 'ev = spot()')
lacks "a spot warning is not an end" "$(field 2 "$r")" "last-seen"
r=$(state_ 'ssm.fails = True')
contains "SSM refusing: said" "$r" "could not record when the box ended"
contains "  and the notification still sent" "$(field 2 "$r")" "notify:gamevps: box terminated"

echo "37b. 'box gone' says what still bills in S3 - from the free size metric"
r=$(state_ '')
contains "size, month cost and INR" "$r" "S3 still holds about 160 GB of games (as of 2026-09-14): about \$4.00 a month (INR 352)."
contains "  and when it expires"     "$r" "Deleted after 14 days with no box, around 2026-09-29."
r=$(state_ 'cw = CWS(gb=None)')
contains "no archive: nothing else bills" "$r" "No game archive is measured in S3, so nothing else bills."
r=$(state_ 'w.EXPIRY_DAYS = 0')
contains "expiry off: kept until deleted" "$r" "Kept until you delete it: cg destroy --all."
r=$(state_ 'cw = CWS(gb=0.5)')
contains "a small archive keeps a decimal" "$r" "about 0.5 GB of games"
r=$(state_ 'cw = CWS(fails=True)')
contains "size unreadable: says so"  "$r" "size could not be read"
contains "  and still notifies"      "$(field 2 "$r")" "notify:gamevps: box terminated"
r=$(state_ 'ev = event("stopped")')
contains "stopped: the disk still bills" "$r" "its disk still does. S3 still holds"

echo "38. a slow, then a stuck, shutdown - each said once, then hourly while it lasts"
SD="inst(state='shutting-down', reason='User initiated (2026-09-15 11:25:00 GMT)'"
r=$(case_ "w.NTFY_URL = 'u'; ec2 = EC2([$SD)]); cw = CW()")
check "35 min: a heads-up, recorded against this shutdown" "$(field 2 "$r")" "notify:gamevps: shutdown slow,tag:i-a=2026-09-15T11:25:00Z"
r=$(case_ "w.NTFY_URL = 'u'; ec2 = EC2([$SD, tags=[{'Key': 'cg-slow-noted', 'Value': '2026-09-15T11:25:00Z'}])]); cw = CW()")
check "  already sent for this shutdown: silent" "$(field 2 "$r")" "-"
r=$(case_ "w.NTFY_URL = 'u'; ec2 = EC2([$SD, tags=[{'Key': 'cg-slow-noted', 'Value': '2026-09-01T08:00:00Z'}])]); cw = CW()")
contains "  a mark from an EARLIER shutdown does not count" "$(field 2 "$r")" "notify:gamevps: shutdown slow"
r=$(case_ "w.NTFY_URL = 'u'; ec2 = EC2([inst(state='shutting-down', reason='User initiated (2026-09-15 11:45:00 GMT)')]); cw = CW()")
check "15 min: nothing yet" "$(field 2 "$r")" "-"
r=$(case_ "w.NTFY_URL = 'u'; dry = True; ec2 = EC2([$SD)]); cw = CW()")
check "a dry run: no heads-up, no tag" "$(field 2 "$r")" "-"
r=$(case_ "ec2 = EC2([$SD)]); cw = CW()")
check "no URL: no heads-up, no tag" "$(field 2 "$r")" "-"
FD="inst(state='shutting-down', reason='User initiated (2026-09-15 10:00:00 GMT)', tags=[{'Key': 'cg-forced', 'Value': '2026-09-15T10:00:00Z/2026-09-15T12:00:00Z'}])"
r=$(case_ "w.NTFY_URL = 'u'; NOW = NOW + timedelta(minutes=3); ec2 = EC2([$FD]); cw = CW()")
check "forced again 3 min later: silent" "$(field 2 "$r")" "terminate:i-a+SkipOsShutdown"
r=$(case_ "w.NTFY_URL = 'u'; NOW = NOW + timedelta(minutes=30); ec2 = EC2([$FD]); cw = CW()")
check "still stuck half an hour later: silent" "$(field 2 "$r")" "terminate:i-a+SkipOsShutdown"
r=$(case_ "w.NTFY_URL = 'u'; NOW = NOW + timedelta(minutes=60); ec2 = EC2([$FD]); cw = CW()")
check "an hour after forcing: the hourly reminder" "$(field 2 "$r")" "terminate:i-a+SkipOsShutdown,notify:gamevps: box still stuck after forcing"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
