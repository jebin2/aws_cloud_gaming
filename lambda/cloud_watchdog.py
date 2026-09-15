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
last-seen mark - a free SSM parameter - refreshed while a box exists, and CloudTrail's
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
# Notifications about one shutdown, recorded on the instance so each is sent once.
# Their value starts with when that shutdown began, so an earlier one never counts.
SLOW_MINUTES = 30
SLOW_TAG = "cg-slow-noted"
FORCED_TAG = "cg-forced"

STATE_EVENT = "EC2 Instance State-change Notification"
SPOT_EVENT = "EC2 Spot Instance Interruption Warning"

# Archive expiry, in days with no box. 0 turns it off.
BUCKET = os.environ.get("CG_BUCKET", "")
EXPIRY_DAYS = int(os.environ.get("CG_ARCHIVE_EXPIRY_DAYS", "0") or 0)
# The expiry check's marks are SSM Parameter Store standard parameters - which cost
# nothing - under /cloud-gaming/<host>/, not bucket tags, which are billed S3
# requests. Whether an archive exists comes from S3's free daily size metric.
S3_USD_PER_GB = float(os.environ.get("CG_S3_USD_PER_GB", "0.025"))
INR_PER_USD = 88

# ntfy push notifications. Off unless cg passed a URL.
NTFY_URL = os.environ.get("CG_NTFY_URL", "")
# A launch history longer than this is treated as unreadable, not as empty.
TRAIL_PAGES = 40
DELETE_ROUNDS = 1000


def say(msg):
    print("cg-watchdog: " + msg, flush=True)


def send(url, title, message, priority, tags):
    import urllib.request
    req = urllib.request.Request(url, data=message.encode("utf-8"), method="POST",
                                 headers={"Title": title, "Priority": priority, "Tags": tags})
    with urllib.request.urlopen(req, timeout=5) as resp:
        resp.read()


def notify(title, message, priority="default", tags=""):
    """Best effort. A notification that cannot be sent is logged and ignored: it
    must never change what a guard decides or does."""
    if not NTFY_URL:
        return False
    try:
        send(NTFY_URL, "%s: %s" % (TS_HOST, title), message, priority, tags)
        return True
    except Exception as exc:
        say("notification not sent (ignored): %s" % exc)
        return False


def handler(event, context):
    import boto3  # in the Lambda runtime; the tests pass fakes instead
    # EC2's own state-change events, from the second EventBridge rule. Nothing
    # else runs for these: they answer "is the box really gone", not "is it idle".
    if isinstance(event, dict) and event.get("detail-type") in (STATE_EVENT, SPOT_EVENT):
        return state_changed(boto3.client("ec2"), event, boto3.client("cloudwatch"),
                             datetime.now(timezone.utc), boto3.client("ssm"))
    dry = isinstance(event, dict) and bool(event.get("dry_run"))
    return run_all(boto3.client("ec2"), boto3.client("cloudwatch"), boto3.client("s3"),
                   boto3.client("ssm"), boto3.client("cloudtrail"), datetime.now(timezone.utc), dry)


def state_changed(ec2, event, cw=None, now=None, ssm=None):
    """An instance finished stopping or terminating. The box cannot report its own
    end - by then it is gone - so this is the notification that says it really is,
    however it ended: a watchdog, cg destroy, a spot interruption, the console.
    EventBridge sends every instance in the region, so only this host's counts."""
    detail = event.get("detail") or {}
    iid = detail.get("instance-id", "")
    state = "interruption" if event.get("detail-type") == SPOT_EVENT else detail.get("state", "")
    # The rule delivers every state change; only an end, or a spot warning, matters.
    if not iid or state not in ("stopped", "terminated", "interruption"):
        return {"state": "ignored"}
    try:
        resp = ec2.describe_instances(InstanceIds=[iid])
    except Exception as exc:
        say("%s %s, but it could not be described - not notified: %s" % (iid, state, exc))
        return {"state": "unknown"}
    names = [t.get("Value") for r in resp.get("Reservations", []) for i in r.get("Instances", [])
             for t in i.get("Tags", []) if t.get("Key") == "Name"]
    if TS_HOST not in names:
        return {"state": "not-ours"}
    now = now or datetime.now(timezone.utc)
    if state in ("terminated", "stopped"):
        mark_gone(ssm, now)
    if state == "interruption":
        say("%s spot interruption warning - AWS reclaims it in about 2 minutes" % iid)
        notify("spot box being reclaimed",
               "AWS takes %s back in about 2 minutes. Games since the last push may not finish mirroring."
               % iid, "urgent", "warning")
    elif state == "terminated":
        # "No longer bills" was half true while the games sit in S3, so say what still does.
        note = archive_note(cw, now)
        say("%s terminated - compute no longer bills.%s" % (iid, note))
        notify("box terminated", "%s is gone - compute no longer bills.%s" % (iid, note),
               "default", "white_check_mark")
    else:
        note = archive_note(cw, now)
        say("%s stopped - compute no longer bills, its disk still does.%s" % (iid, note))
        notify("box stopped", "%s is stopped - compute no longer bills, its disk still does.%s" % (iid, note),
               "default", "white_check_mark")
    return {"state": state, "instance": iid}


def run_all(ec2, cw, s3, ssm, trail, now, dry=False):
    """The idle check, then the archive check. The second runs even when the
    first fails, and the invocation still counts as an error afterwards."""
    failure = None
    try:
        result = run(ec2, cw, now, dry)
    except Exception as exc:
        failure, result = exc, {"decisions": []}
    try:
        result["archive"] = expire_archive(ec2, s3, ssm, cw, trail, now, dry)
    except Exception as exc:
        say("archive: check FAILED - nothing deleted: %s" % exc)
        failure = failure or exc
    if failure:
        # At most hourly: a watchdog that is failing fails every 5 minutes.
        if not dry and now.minute < 5:
            notify("cloud watchdog failing", str(failure)[:300], "urgent", "rotating_light")
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
    notify("idle box %s" % ("terminated" if verb == "terminate" else "stopped"),
           "%s %s. Its games are mirrored to S3 as it shuts down." % (iid, why), "high", "zzz")
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
    mark = iso(since)
    if took < STUCK_MINUTES:
        say("%s %s for %dm - letting it finish (the games are mirrored on the way down; forced at %dm)"
            % (iid, state, took, STUCK_MINUTES))
        if not dry and took >= SLOW_MINUTES and tag_value(inst, SLOW_TAG) != mark:
            if notify("shutdown slow",
                      "%s has been %s for %dm - probably still mirroring its games. Forced at %dm."
                      % (iid, state, took, STUCK_MINUTES), "default", "hourglass"):
                ec2.create_tags(Resources=[iid], Tags=[{"Key": SLOW_TAG, "Value": mark}])
        return {"instance": iid, "action": "none", "reason": "going down"}

    verb = "terminate" if state == "shutting-down" else "stop"
    why = "stuck %s for %dm" % (state, took)
    if dry:
        say("%s %s - WOULD force %s (dry run)" % (iid, why, verb))
        return {"instance": iid, "action": "would-force-" + verb, "reason": why}
    # Forced again on every run while it stays stuck - that is harmless - but told
    # once, then hourly: the tag holds when this shutdown began and when it was
    # first forced.
    forced = (tag_value(inst, FORCED_TAG) or "").split("/")
    call(ec2, verb, iid, force=True)
    say("%s %s - FORCED %s, skipping the OS shutdown" % (iid, why, verb))
    if forced[0] != mark:
        if notify("stuck shutdown forced", "%s %s - forced %s, skipping the OS shutdown." % (iid, why, verb),
                  "high", "warning"):
            ec2.create_tags(Resources=[iid], Tags=[{"Key": FORCED_TAG, "Value": "%s/%s" % (mark, iso(now))}])
    elif len(forced) > 1 and now.minute < 5 and forced[1] <= iso(now - timedelta(hours=1)):
        notify("box still stuck after forcing",
               "%s has been %s for %dm, and forcing it has not ended it. Check the EC2 console - it may "
               "still bill." % (iid, state, took), "urgent", "rotating_light")
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


def tag_value(inst, key):
    return next((t.get("Value") for t in inst.get("Tags", []) if t.get("Key") == key), None)


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


def mark_name(name):
    return "/cloud-gaming/%s/%s" % (TS_HOST, name)


def mark_get(ssm, name):
    try:
        return ssm.get_parameter(Name=mark_name(name))["Parameter"]["Value"]
    except Exception as exc:
        if error_code(exc) == "ParameterNotFound":
            return None
        raise


def mark_put(ssm, name, value):
    ssm.put_parameter(Name=mark_name(name), Value=value, Type="String", Overwrite=True)


def mark_time(ssm, name):
    """A stored time, or None when there is none. Unreadable is not "never": refuse."""
    value = mark_get(ssm, name)
    if value is None:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise RuntimeError("unreadable %s mark %r" % (name, value))


def archive_size(cw, now):
    """(bytes, day measured) from S3's daily BucketSizeBytes metric, or (None, None)
    when nothing was measured in 3 days. Free to read, unlike any S3 request."""
    resp = cw.get_metric_statistics(
        Namespace="AWS/S3", MetricName="BucketSizeBytes",
        Dimensions=[{"Name": "BucketName", "Value": BUCKET},
                    {"Name": "StorageType", "Value": "StandardStorage"}],
        StartTime=now - timedelta(days=3), EndTime=now, Period=86400, Statistics=["Average"])
    points = sorted(resp.get("Datapoints", []), key=lambda p: p["Timestamp"])
    if not points:
        return None, None
    return points[-1].get("Average", 0), points[-1]["Timestamp"]


def archive_note(cw, now):
    """What still bills in S3, for the "box is gone" notification, from the free metric."""
    if not BUCKET or cw is None:
        return ""
    try:
        size, day = archive_size(cw, now)
    except Exception as exc:
        say("archive size could not be read: %s" % exc)
        return " The S3 game archive's size could not be read."
    if not size:
        return " No game archive is measured in S3, so nothing else bills."
    gb = size / 1073741824
    usd = gb * S3_USD_PER_GB
    note = (" S3 still holds about %s GB of games (as of %s): about $%.2f a month (INR %.0f)."
            % (("%.1f" if gb < 10 else "%.0f") % gb, day.strftime("%Y-%m-%d"), usd, usd * INR_PER_USD))
    if EXPIRY_DAYS > 0:
        note += " Deleted after %d days with no box, around %s." % (
            EXPIRY_DAYS, (now + timedelta(days=EXPIRY_DAYS)).strftime("%Y-%m-%d"))
    else:
        note += " Kept until you delete it: cg destroy --all."
    return note


def mark_gone(ssm, now):
    """The archive's countdown starts when the box really ended. Otherwise it starts at
    the last hourly check that happened to see it - up to an hour earlier. A write
    that fails is said and ignored: the hourly mark still stands."""
    if EXPIRY_DAYS <= 0 or not BUCKET or ssm is None:
        return
    try:
        mark_put(ssm, "archive-last-seen", iso(now))
    except Exception as exc:
        say("could not record when the box ended - the hourly mark stands: %s" % exc)


def warn_once(ssm, seen, idle, left):
    """The 24-hour warning, once per countdown. It is recorded against the last-seen
    mark it was sent for, so a new box - a new mark - arms it again, and a send that
    failed is retried at the next hourly check."""
    if not NTFY_URL:
        return
    if mark_get(ssm, "archive-warned") == iso(seen):
        return
    if notify("game archive deleted in %s" % span(left),
              "No box for %s. Launch one to keep the games, or set GAME_ARCHIVE_EXPIRY_DAYS=0."
              % span(idle), "high", "warning"):
        mark_put(ssm, "archive-warned", iso(seen))


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


def expire_archive(ec2, s3, ssm, cw, trail, now, dry=False):
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
            seen = mark_time(ssm, "archive-last-seen")
            if seen is None or now - seen >= timedelta(hours=1):
                mark_put(ssm, "archive-last-seen", iso(now))
        say("archive: kept - a box exists (%s)" % ", ".join(live))
        return "in-use"

    # Whether there is an archive at all, from S3's free daily size metric - not an
    # S3 request. A size measured on or before the last deletion is that archive.
    size, day = archive_size(cw, now)
    deleted = mark_time(ssm, "archive-deleted")
    if not size or (deleted is not None and day <= deleted):
        say("archive: none measured in s3://%s - nothing to expire" % BUCKET)
        return "absent"

    seen = mark_time(ssm, "archive-last-seen")
    if seen is None:
        if not dry:
            mark_put(ssm, "archive-last-seen", iso(now))
        say("archive: no last-seen mark yet - counting %d days from now" % EXPIRY_DAYS)
        return "started"
    if now - seen < window:
        left = window - (now - seen)
        say("archive: kept - last used %s ago; deleted in %s unless a box is launched"
            % (span(now - seen), span(left)))
        if not dry and left <= timedelta(hours=24):
            warn_once(ssm, seen, now - seen, left)
        return "kept"

    launched = last_launch(trail, now - window, now)
    if launched is not None:
        if not dry and launched > seen:
            mark_put(ssm, "archive-last-seen", iso(launched))
        say("archive: kept - a box was launched %s ago (CloudTrail)" % span(now - launched))
        return "kept"

    # Both records say unused. One last look, in case a box started meanwhile.
    if boxes(ec2):
        say("archive: kept - a box appeared during the check")
        return "in-use"
    if dry:
        say("archive: unused for %s - WOULD DELETE s3://%s (dry run)" % (span(now - seen), BUCKET))
        return "would-delete"
    # The only S3 requests this check ever makes are these, once, when it deletes.
    try:
        removed = empty_and_delete(s3)
    except Exception as exc:
        if error_code(exc) in ("NoSuchBucket", "404", "NotFound"):
            mark_put(ssm, "archive-deleted", iso(now))
            say("archive: s3://%s is already gone - nothing to expire" % BUCKET)
            return "absent"
        raise
    mark_put(ssm, "archive-deleted", iso(now))
    say("archive: unused for %s - DELETED s3://%s (%d objects)" % (span(now - seen), BUCKET, removed))
    notify("game archive deleted",
           "Unused for %s: %d objects removed from S3. The next cg init starts empty, and Steam "
           "downloads the games again." % (span(now - seen), removed), "high", "wastebasket")
    return "deleted"
