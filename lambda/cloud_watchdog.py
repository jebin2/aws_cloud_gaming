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

It also expires the GAME ARCHIVE. Once no box has existed for EXPIRY_DAYS, the
S3 bucket - the only thing that bills while no box exists - is emptied and
deleted. Deleting the only copy of every game is not something to get wrong, so
the check fails closed: two independent records must both say "unused" - the
bucket's own last-seen mark, refreshed while a box exists, and CloudTrail's
RunInstances history - and any error, gap or unreadable answer keeps it.
"""
import json
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

# Archive expiry. 0 turns it off; cg floors any other value at 7 days.
BUCKET = os.environ.get("CG_BUCKET", "")
EXPIRY_DAYS = int(os.environ.get("CG_ARCHIVE_EXPIRY_DAYS", "0") or 0)
LAST_SEEN_TAG = "cg-last-seen"
# A launch history longer than this is treated as unreadable, not as empty.
TRAIL_PAGES = 40
DELETE_ROUNDS = 1000


def say(msg):
    print("cg-watchdog: " + msg, flush=True)


def handler(event, context):
    import boto3  # in the Lambda runtime; the tests pass fakes instead
    dry = isinstance(event, dict) and bool(event.get("dry_run"))
    return run_all(boto3.client("ec2"), boto3.client("cloudwatch"), boto3.client("s3"),
                   boto3.client("cloudtrail"), datetime.now(timezone.utc), dry)


def run_all(ec2, cw, s3, trail, now, dry=False):
    """The idle check, then the archive check. The second runs even when the
    first fails, and the invocation still counts as an error afterwards."""
    failure = None
    try:
        result = run(ec2, cw, now, dry)
    except Exception as exc:
        failure, result = exc, {"decisions": []}
    try:
        result["archive"] = expire_archive(ec2, s3, trail, now, dry)
    except Exception as exc:
        say("archive: check FAILED - nothing deleted: %s" % exc)
        failure = failure or exc
    if failure:
        raise failure
    return result


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
            d = decide(ec2, cw, inst, now, dry)
            # A dry run proves the permission on EVERY running box, not only on
            # one it would end. Otherwise `cg watchdog check` during a session -
            # a busy box, the one time anyone runs it - proves nothing about
            # whether this role can actually terminate the instance.
            if dry and d["action"] == "none" and inst["State"]["Name"] == "running":
                verb = "terminate" if inst.get("InstanceLifecycle") == "spot" else "stop"
                say("%s dry run: %s" % (iid, permission(ec2, verb, iid)))
            decisions.append(d)
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


# --- archive expiry ------------------------------------------------------------

def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def span(delta):
    hours = max(0, int(delta.total_seconds() // 3600))
    if hours < 24:
        return "%dh" % hours
    return "%dd" % (hours // 24) if hours % 24 == 0 else "%dd %dh" % (hours // 24, hours % 24)


def boxes(ec2):
    """Every instance of this host that still exists, stopped ones included."""
    resp = ec2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [TS_HOST]},
        {"Name": "instance-state-name",
         "Values": ["pending", "running", "shutting-down", "stopping", "stopped"]}])
    return [i["InstanceId"] for r in resp.get("Reservations", []) for i in r.get("Instances", [])]


def read_tags(s3):
    try:
        return s3.get_bucket_tagging(Bucket=BUCKET).get("TagSet", [])
    except Exception as exc:
        if error_code(exc) == "NoSuchTagSet":
            return []
        raise


def last_seen(tags):
    for tag in tags:
        if tag.get("Key") == LAST_SEEN_TAG:
            try:
                return datetime.strptime(tag["Value"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            except (KeyError, ValueError):
                # Unreadable is not "never": refuse rather than guess.
                raise RuntimeError("unreadable %s tag %r" % (LAST_SEEN_TAG, tag.get("Value")))
    return None


def stamp(s3, tags, when):
    # put_bucket_tagging REPLACES the whole set, so keep every other tag.
    kept = [t for t in tags if t.get("Key") != LAST_SEEN_TAG]
    s3.put_bucket_tagging(Bucket=BUCKET, Tagging={
        "TagSet": kept + [{"Key": LAST_SEEN_TAG, "Value": iso(when)}]})


def last_launch(trail, since, now):
    """When this host's box was last launched since `since`, or None. Raises when
    the history cannot be read in full - an unfinished lookup is not an empty one."""
    kwargs = {"LookupAttributes": [{"AttributeKey": "EventName", "AttributeValue": "RunInstances"}],
              "StartTime": since, "EndTime": now, "MaxResults": 50}
    for _ in range(TRAIL_PAGES):
        resp = trail.lookup_events(**kwargs)
        for event in resp.get("Events", []):
            try:
                detail = json.loads(event["CloudTrailEvent"])
            except (KeyError, TypeError, ValueError):
                raise RuntimeError("unreadable CloudTrail event")
            if detail.get("errorCode"):
                continue                      # a launch that failed launched nothing
            specs = ((detail.get("requestParameters") or {}).get("tagSpecificationSet") or {}).get("items", [])
            for spec in specs:
                if spec.get("resourceType", "instance") != "instance":
                    continue
                if any(t.get("key") == "Name" and t.get("value") == TS_HOST for t in spec.get("tags", [])):
                    return event["EventTime"]
        if not resp.get("NextToken"):
            return None
        kwargs["NextToken"] = resp["NextToken"]
    raise RuntimeError("CloudTrail launch history longer than %d pages" % TRAIL_PAGES)


def empty_and_delete(s3):
    removed = 0
    for _ in range(DELETE_ROUNDS):
        page = s3.list_objects_v2(Bucket=BUCKET, MaxKeys=1000)
        keys = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if not keys:
            break
        out = s3.delete_objects(Bucket=BUCKET, Delete={"Objects": keys, "Quiet": True})
        if out.get("Errors"):
            raise RuntimeError("S3 refused to delete %d objects" % len(out["Errors"]))
        removed += len(keys)
    else:
        raise RuntimeError("bucket still not empty after %d rounds" % DELETE_ROUNDS)
    # Incomplete multipart uploads appear in no listing and block the delete.
    for _ in range(DELETE_ROUNDS):
        uploads = s3.list_multipart_uploads(Bucket=BUCKET).get("Uploads", [])
        if not uploads:
            break
        for up in uploads:
            s3.abort_multipart_upload(Bucket=BUCKET, Key=up["Key"], UploadId=up["UploadId"])
    s3.delete_bucket(Bucket=BUCKET)
    return removed


def expire_archive(ec2, s3, trail, now, dry=False):
    if EXPIRY_DAYS <= 0 or not BUCKET:
        return None
    # Hourly: one invocation in twelve lands in the first 5 minutes of an hour.
    # A dry run always looks, so `cg watchdog check` can show the countdown.
    if not dry and now.minute >= 5:
        return None
    window = timedelta(days=EXPIRY_DAYS)

    live = boxes(ec2)
    if live:
        if not dry:
            try:
                tags = read_tags(s3)
                seen = last_seen(tags)
                if seen is None or now - seen >= timedelta(hours=1):
                    stamp(s3, tags, now)
            except Exception as exc:
                if error_code(exc) not in ("NoSuchBucket", "404", "NotFound"):
                    raise
        say("archive: kept - a box exists (%s)" % ", ".join(live))
        return "in-use"

    try:
        s3.head_bucket(Bucket=BUCKET)
    except Exception as exc:
        if error_code(exc) in ("404", "NoSuchBucket", "NotFound"):
            say("archive: none in s3://%s - nothing to expire" % BUCKET)
            return "absent"
        raise

    tags = read_tags(s3)
    seen = last_seen(tags)
    if seen is None:
        if not dry:
            stamp(s3, tags, now)
        say("archive: no last-seen mark yet - counting %d days from now" % EXPIRY_DAYS)
        return "started"
    if now - seen < window:
        say("archive: kept - last used %s ago; deleted in %s unless a box is launched"
            % (span(now - seen), span(window - (now - seen))))
        return "kept"

    launched = last_launch(trail, now - window, now)
    if launched is not None:
        if not dry and launched > seen:
            stamp(s3, tags, launched)
        say("archive: kept - a box was launched %s ago (CloudTrail)" % span(now - launched))
        return "kept"

    # Both records say unused. One last look, in case a box started meanwhile.
    if boxes(ec2):
        say("archive: kept - a box appeared during the check")
        return "in-use"
    if dry:
        say("archive: unused for %s - WOULD DELETE s3://%s (dry run)" % (span(now - seen), BUCKET))
        return "would-delete"
    removed = empty_and_delete(s3)
    say("archive: unused for %s - DELETED s3://%s (%d objects)" % (span(now - seen), BUCKET, removed))
    return "deleted"
