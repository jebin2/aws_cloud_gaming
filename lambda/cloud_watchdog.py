"""Layer 3: the cloud watchdog. An AWS Lambda, run every 5 minutes by an
EventBridge rule, that ends a game instance nobody is using.

It exists for the cases the other layers cannot cover:
  - the on-host watchdog dies with the box it protects - a wedged instance
    takes its own watchdog with it
  - nothing else watches from outside the box, in a session or out of one

It runs inside the account on an IAM role, so no long-lived key exists for it
anywhere, and there is no second machine to keep alive.

It KEEPS NO STATE. It reads the last 30 minutes of metrics on every run and
decides from those rather than counting idle checks, so a missed or repeated
invocation cannot corrupt a counter, and a dry run changes nothing.

It never pulls the plug first. Terminating (spot) or stopping (on demand)
through the API is a GRACEFUL OS shutdown, which is where the box mirrors its
games to S3 (cg-library-shutdown.service, up to 30 minutes). Only an instance
still stuck going down an hour later is forced, whichever guard started it.

Every decision is printed with the numbers behind it, prefixed "cg-watchdog:",
which is what `cg watchdog logs` filters on.
"""
import os
import re
from datetime import datetime, timedelta, timezone

TS_HOST = os.environ.get("CG_TS_HOST", "gamevps")
IDLE_MINUTES = int(os.environ.get("CG_IDLE_MINUTES", "30"))
BOOT_GRACE_MINUTES = int(os.environ.get("CG_BOOT_GRACE_MINUTES", "20"))
STUCK_MINUTES = int(os.environ.get("CG_STUCK_MINUTES", "60"))
# Bytes in + out per 5-minute period that count as use. Streaming at 20 Mbps
# moves ~750 MB a period, so 10 MB is comfortably idle.
THRESHOLD = int(os.environ.get("CG_THRESHOLD_BYTES", "10485760"))
PERIOD = 300
# Written on an instance going down with no timestamp in its state reason (an
# in-guest `shutdown -h`), so the next run can tell how long it has been stuck.
SINCE_TAG = "cg-going-down-since"


def say(msg):
    print("cg-watchdog: " + msg, flush=True)


def handler(event, context):
    import boto3  # in the Lambda runtime; the tests pass fakes to run() instead
    dry = isinstance(event, dict) and bool(event.get("dry_run"))
    return run(boto3.client("ec2"), boto3.client("cloudwatch"),
               datetime.now(timezone.utc), dry)


def error_code(exc):
    return getattr(exc, "response", {}).get("Error", {}).get("Code", "")


def mb(n):
    return "%.1f MB" % (n / 1048576)


def minutes(delta):
    return int(delta.total_seconds() // 60)


def run(ec2, cw, now, dry=False):
    # "Could not ask" must never read as "nothing there": a blind watchdog that
    # reports all clear is worse than none. Raise, so the invocation counts as
    # an error and `cg watchdog` shows it.
    try:
        resp = ec2.describe_instances(Filters=[
            {"Name": "tag:Name", "Values": [TS_HOST]},
            {"Name": "instance-state-name",
             "Values": ["pending", "running", "stopping", "shutting-down"]}])
    except Exception as exc:
        say("CANNOT QUERY AWS - this watchdog is blind: %s" % exc)
        raise
    instances = [i for r in resp.get("Reservations", []) for i in r.get("Instances", [])]
    if not instances:
        say("no running instance tagged %s - nothing to do" % TS_HOST)
        return {"decisions": []}

    decisions, failed = [], []
    for inst in instances:
        iid = inst.get("InstanceId", "?")
        # One instance failing must not stop the others being handled.
        try:
            decisions.append(decide(ec2, cw, inst, now, dry))
        except Exception as exc:
            say("%s FAILED: %s" % (iid, exc))
            decisions.append({"instance": iid, "action": "error", "reason": str(exc)})
            failed.append(iid)
    if failed:
        raise RuntimeError("could not handle %s" % ", ".join(failed))
    return {"decisions": decisions}


def decide(ec2, cw, inst, now, dry):
    iid = inst["InstanceId"]
    state = inst["State"]["Name"]
    if state in ("stopping", "shutting-down"):
        return going_down(ec2, inst, now, dry)
    if state == "pending":
        say("%s pending - nothing to judge yet" % iid)
        return {"instance": iid, "action": "none", "reason": "pending"}

    age = minutes(now - inst["LaunchTime"])
    # A box that has just come up is still building, and a fresh instance has
    # no metrics yet, which would otherwise read as idle.
    if age < BOOT_GRACE_MINUTES:
        say("%s up %dm - inside the %dm boot grace" % (iid, age, BOOT_GRACE_MINUTES))
        return {"instance": iid, "action": "none", "reason": "boot grace"}

    points = traffic(cw, iid, now)
    peak = max(points.values()) if points else 0
    # in + out, because streaming is outbound and a game download is inbound,
    # and watching one direction ends the box in the middle of the other.
    if peak >= THRESHOLD:
        say("%s busy: %s in+out in a 5-minute period (>= %s) - leaving it"
            % (iid, mb(peak), mb(THRESHOLD)))
        return {"instance": iid, "action": "none", "reason": "busy"}

    # Quiet, but it has to have been judged for the whole window, not just the
    # minutes since the grace ended.
    watched = age - BOOT_GRACE_MINUTES
    if watched < IDLE_MINUTES:
        say("%s quiet (peak %s per 5 min), but watched for only %dm of the %dm needed"
            % (iid, mb(peak), watched, IDLE_MINUTES))
        return {"instance": iid, "action": "none", "reason": "quiet, not long enough"}

    verb = "terminate" if inst.get("InstanceLifecycle") == "spot" else "stop"
    if points:
        why = "quiet for %dm: peak %s per 5 min over %d periods, under %s" % (
            IDLE_MINUTES, mb(peak), len(points), mb(THRESHOLD))
    else:
        # Running, past the grace, publishing nothing: the wedged case. Counted
        # as idle rather than as an absence of evidence.
        why = "running but publishing NO metrics for %dm (wedged?)" % IDLE_MINUTES

    if dry:
        say("%s %s - WOULD %s (dry run; %s)" % (iid, why, verb, permission(ec2, verb, iid)))
        return {"instance": iid, "action": "would-" + verb, "reason": why}

    # Graceful: the OS shuts down, and the box pushes its games as it goes.
    call(ec2, verb, iid)
    say("%s %s - %s issued; the box mirrors its games to S3 as it shuts down"
        % (iid, why, verb))
    return {"instance": iid, "action": verb, "reason": why}


def traffic(cw, iid, now):
    """Bytes in + out per 5-minute period over the idle window."""
    window_start = now - timedelta(minutes=IDLE_MINUTES)
    totals = {}
    for metric in ("NetworkIn", "NetworkOut"):
        resp = cw.get_metric_statistics(
            Namespace="AWS/EC2", MetricName=metric,
            Dimensions=[{"Name": "InstanceId", "Value": iid}],
            StartTime=window_start - timedelta(seconds=PERIOD), EndTime=now,
            Period=PERIOD, Statistics=["Sum"])
        for p in resp.get("Datapoints", []):
            ts = p["Timestamp"]
            # A period that ENDED before the window began says nothing about it.
            if ts + timedelta(seconds=PERIOD) <= window_start:
                continue
            totals[ts] = totals.get(ts, 0) + p.get("Sum", 0)
    return totals


def going_down(ec2, inst, now, dry):
    """An instance already stopping or shutting down: leave it an hour, then force it."""
    iid, state = inst["InstanceId"], inst["State"]["Name"]
    since = transition_time(inst.get("StateTransitionReason", "")) or tag_time(inst)
    if since is None:
        # An in-guest shutdown leaves no timestamp. Record when this was first
        # seen, so the next run can measure from it.
        if not dry:
            ec2.create_tags(Resources=[iid],
                            Tags=[{"Key": SINCE_TAG, "Value": now.strftime("%Y-%m-%dT%H:%M:%SZ")}])
        say("%s %s - first seen going down; forced if still stuck in %dm"
            % (iid, state, STUCK_MINUTES))
        return {"instance": iid, "action": "none", "reason": "going down, first seen"}

    took = minutes(now - since)
    if took < STUCK_MINUTES:
        say("%s %s for %dm - letting it finish (the games are mirrored on the way down; forced at %dm)"
            % (iid, state, took, STUCK_MINUTES))
        return {"instance": iid, "action": "none", "reason": "going down"}

    verb = "terminate" if state == "shutting-down" else "stop"
    why = "stuck %s for %dm" % (state, took)
    if dry:
        say("%s %s - WOULD force %s (dry run)" % (iid, why, verb))
        return {"instance": iid, "action": "would-force-" + verb, "reason": why}
    call(ec2, verb, iid, force=True)
    say("%s %s - FORCED %s, skipping the OS shutdown" % (iid, why, verb))
    return {"instance": iid, "action": "force-" + verb, "reason": why}


def call(ec2, verb, iid, force=False):
    if not force:
        if verb == "terminate":
            ec2.terminate_instances(InstanceIds=[iid])
        else:
            ec2.stop_instances(InstanceIds=[iid])
        return
    # SkipOsShutdown is recent. A runtime whose boto3 predates it rejects the
    # parameter before anything is sent - fall back to what that boto3 has:
    # Force for a stop, and a plain repeat for a terminate.
    try:
        if verb == "terminate":
            ec2.terminate_instances(InstanceIds=[iid], SkipOsShutdown=True)
        else:
            ec2.stop_instances(InstanceIds=[iid], Force=True, SkipOsShutdown=True)
    except Exception as exc:
        if "SkipOsShutdown" not in str(exc):
            raise
        if verb == "terminate":
            ec2.terminate_instances(InstanceIds=[iid])
        else:
            ec2.stop_instances(InstanceIds=[iid], Force=True)


def permission(ec2, verb, iid):
    """Proves the role may act on this instance, without acting."""
    try:
        call_dry = ec2.terminate_instances if verb == "terminate" else ec2.stop_instances
        call_dry(InstanceIds=[iid], DryRun=True)
    except Exception as exc:
        code = error_code(exc)
        if code == "DryRunOperation":
            return "permission to %s: ok" % verb
        if code == "UnauthorizedOperation":
            return "permission to %s: DENIED - the role policy is wrong" % verb
        return "permission to %s: unknown (%s)" % (verb, exc)
    return "permission to %s: unknown (no dry-run response)" % verb


def transition_time(reason):
    # "User initiated (2026-09-15 10:02:03 GMT)" - set by a stop or terminate
    # through the API.
    m = re.search(r"\((\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) GMT\)", reason or "")
    if not m:
        return None
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)


def tag_time(inst):
    for tag in inst.get("Tags", []):
        if tag.get("Key") != SINCE_TAG:
            continue
        try:
            t = datetime.strptime(tag["Value"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (KeyError, ValueError):
            return None
        # From an EARLIER shutdown of an on-demand box that has since been
        # started again: measuring from it would force a fresh stop at once.
        launched = inst.get("LaunchTime")
        if launched is not None and t < launched:
            return None
        return t
    return None
