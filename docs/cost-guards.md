# Cost guards

What stops a GPU instance billing when you forget it: three layers and a budget that
emails you. What each charge actually is lives in [cost.md](cost.md).

## The three layers

Numbered by **independence** - how likely each one is to survive the failure it exists to catch.
Layer 1 is the fastest and the least reliable; layer 3 is the slowest to react but the hardest
to take down.

| # | Mechanism | Dies with | Catches | Reaction |
|---|-----------|-----------|---------|----------|
| 1 | `cg open` | your laptop, your network | normal use | on Moonlight exit |
| 2 | on-host watchdog | the box it protects | forgotten disconnect, client crash | 15 min idle |
| 3 | cloud watchdog (Lambda) | a deleted or disabled schedule | a wedged box, a box left running outside a session, a box stuck going down | 30 min idle; forced after 1 h stuck |

The **AWS budget is not in that list**, because it stops nothing - it emails you. It is the
backstop for everything the three layers miss, not a layer.

They are **armed in roughly the reverse order**: the budget and the cloud watchdog before
anything launches, and the on-host watchdog during the build. A guard that only exists after
the build cannot protect the build.

Worst-case leak with all three armed is about 30 minutes of runtime.

## Layer 3: the cloud watchdog

An AWS Lambda, `<host>-cloud-watchdog`, run every 5 minutes by an EventBridge schedule. It covers
what the other layers structurally cannot:

- **layer 2 dies with the box it protects.** A wedged instance takes its own watchdog with it.
- **nothing else watches from outside the box**, in a session or out of one. A box left running
  after `cg init`, or after "leave it running", would bill until the budget emailed you.
- **a guard should explain itself.** A CloudWatch alarm once stopped a box mid-build here and
  said nothing about why; that had to be inferred.

**What it decides**, for each instance tagged with your host name:

| The instance is | Decision |
|---|---|
| launched under 20 minutes ago | nothing - it is still building |
| used in the last 30 minutes: any 5-minute period with 10 MB or more in + out | nothing |
| quiet, but watched for less than 30 minutes | nothing yet |
| quiet for 30 minutes, or publishing no metrics at all (wedged) | **terminate** (spot) or **stop** (on demand) |
| `shutting-down` or `stopping` for under an hour | nothing - it is mirroring its games |
| `shutting-down` or `stopping` for an hour or more | **force it**, skipping the OS shutdown |

Terminate and stop are **graceful**: AWS shuts the OS down, and `cg-library-shutdown.service`
mirrors the games to S3 on the way, with up to 30 minutes to do it. The one-hour force is for a
box that never finishes going down, **whichever guard started it** - by then the push has had its
30 minutes.

It **keeps no state**. Every run reads the last 30 minutes of `NetworkIn` and `NetworkOut`, so a
missed or repeated run cannot corrupt a counter, and a dry run changes nothing. The only thing it
writes is a `cg-going-down-since` tag, on an instance going down with no timestamp to measure from
(an in-guest `shutdown -h` leaves none).

**Every decision is logged with the numbers behind it:**

    cg-watchdog: i-0abc quiet for 30m: peak 0.1 MB per 5 min over 6 periods, under 10.0 MB - terminate issued; the box mirrors its games to S3 as it shuts down

EC2 publishes those metrics every 5 minutes and a few minutes late, so the newest minutes are not
seen yet. That only matters if you start playing on a box that had already sat idle for half an
hour with the on-host watchdog broken.

`cg init` arms it **before it launches anything**; there is no manual step. When nothing changed,
init makes one parallel round of read-only calls - code hash, settings, schedule, target, invoke
permission, role policy, log group - and shows the last decision and its age rather than
redeploying. Anything that drifted is put back: changed code or settings, a schedule disabled by
hand, an edited policy. After any change it runs once as a **dry run**, which reads your account
with its own role and, for a running box, proves it may end it without doing so.

    cg watchdog status      schedule, function and recent decisions
    cg watchdog check       run it now, as a dry run
    cg watchdog logs        what it decided (--watch to follow)
    cg watchdog install     deploy or repair it by hand
    cg watchdog remove      delete the function, schedule, role and logs

`GAME_WATCHDOG_IDLE_MIN` (default 30, at least 10) and `GAME_WATCHDOG_STUCK_MIN` (default 60, at
least 40 - never inside the push's 30 minutes) change the two limits; the next `cg init` applies
them.

**The role it runs on** can end only the tagged box, and holds no key to leak:

```json
{"Version":"2012-10-17","Statement":[
 {"Sid":"Look","Effect":"Allow",
  "Action":["ec2:DescribeInstances","cloudwatch:GetMetricStatistics"],"Resource":"*"},
 {"Sid":"EndOnlyTheTaggedBox","Effect":"Allow",
  "Action":["ec2:StopInstances","ec2:TerminateInstances"],
  "Resource":"arn:aws:ec2:REGION:ACCOUNT:instance/*",
  "Condition":{"StringEquals":{"ec2:ResourceTag/Name":"gamevps"}}},
 {"Sid":"MarkWhenFirstSeenGoingDown","Effect":"Allow","Action":"ec2:CreateTags",
  "Resource":"arn:aws:ec2:REGION:ACCOUNT:instance/*",
  "Condition":{"StringEquals":{"ec2:ResourceTag/Name":"gamevps"},
               "ForAllValues:StringEquals":{"aws:TagKeys":["cg-going-down-since"]}}},
 {"Sid":"OwnLogs","Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:REGION:ACCOUNT:log-group:/aws/lambda/gamevps-cloud-watchdog:*"}
]}
```

IAM Access Analyzer reports no findings for it. It cannot launch anything, read the game archive,
or touch IAM.

**Cost: nothing.** About 8,640 runs a month against Lambda's always-free 1 million requests and
400,000 GB-seconds, a few MB of logs (kept 14 days) against 5 GB, and EventBridge schedules are
free.

Two guards may both end the box. That is harmless: ending an instance that is already shutting
down is a no-op, and it still shuts down - and pushes - once.

The guards are armed as early as each one can be: the **budget before anything launches** (it
is account-level and needs no instance), and the **on-host watchdog during the build** rather
than over ssh afterwards. That window used to be unguarded - a `Ctrl+C`, a dropped laptop or a
stalled build left a GPU instance running with nothing to stop it. The watchdog is safe that
early because it has a 20-minute boot grace and counts inbound bytes as activity, so it cannot
shut down a build in progress.

**Why not a CloudWatch alarm.** An earlier version had one as a separate layer. CloudWatch will not
take an EC2 action on `NetworkIn + NetworkOut`:

    ValidationError: EC2 actions are not available for Metric Math monitors

so the alarm watched outbound traffic only, and read a game download as an idle box. That forced
it to be armed only during a session - where it duplicated this watchdog on half the traffic -
and it terminated two boxes mid-download before it was. It was removed once the cloud watchdog
covered everything it did.

The budget is an **AWS Budget**, not a CloudWatch `EstimatedCharges` alarm. That alarm needs
"Receive Billing Alerts" switched on by the *root* user, for which there is no API, plus an SNS
subscription every recipient must confirm by email. Miss either and it sits in
`INSUFFICIENT_DATA` forever - armed in appearance only, which is worse than no alarm. A budget
emails its subscribers directly and works the moment it is created.

## Game archive expiry

With no box, the only thing that bills is the S3 game archive: about **$4 a month (INR 350)** for
160 GB. Everything else left behind - the cloud watchdog, the budget, IAM roles, the security group
and key pair - costs nothing. So after **14 days with no box**, the cloud watchdog deletes the
archive.

| `.env` | Effect |
|---|---|
| unset | 14 days |
| `GAME_ARCHIVE_EXPIRY_DAYS=30` | 30 days |
| `GAME_ARCHIVE_EXPIRY_DAYS=3` | 3 days - any number is used as written, so check it |
| `GAME_ARCHIVE_EXPIRY_DAYS=0` | **off**: kept forever, and the role loses every delete permission |

The next `cg init` applies a change. `cg status`, `cg init` and `cg watchdog status` show what the
check last decided, in its own words:

    game archive    kept - last used 3d ago; deleted in 11d unless a box is launched  (checked 12 min ago)

**What is lost.** Every archived game, which Steam then downloads fresh; the saved Steam login, so
the next box asks for Steam Guard; and saves of any game without Steam Cloud. `cg init` recreates
the empty bucket by itself.

**How it decides.** Once an hour, and deleting only when two independent records agree:

1. A `gamevps` instance exists in any state, stopped included: **kept**, and the last-seen mark is
   set to now.
2. S3's daily size metric shows no archive: nothing to do.
3. No last-seen mark yet: **kept**, and counting starts now.
4. The mark is under 14 days old: **kept**, with the countdown.
5. CloudTrail's free 90-day history shows a successful `RunInstances` of an instance tagged
   `gamevps` in the window: **kept**, and the mark moves to that launch.
6. One more look for an instance, then: **deleted** - objects, abandoned multipart uploads, and the
   bucket.

**It fails closed.** A CloudTrail error, a history too long to read in full, an unreadable event or
mark, or S3 refusing a delete all stop it with nothing removed - and the invocation is recorded as an
error, which `cg watchdog status` shows. A dry run (`cg watchdog check`) runs every step and deletes
nothing.

**It costs nothing until it deletes.** The last-seen mark and the warning are SSM Parameter Store
standard parameters under `/cloud-gaming/<host>/`, which are free. Whether an archive exists comes
from S3's `BucketSizeBytes` metric, which S3 publishes daily at no charge and which is read inside
CloudWatch's free API allowance. The only S3 requests are the few listings made once, when it
actually deletes - S3 does not charge for the deletes themselves.

**The permissions it adds**, only while expiry is on: `cloudtrail:LookupEvents`, reading and writing
its own parameters under `/cloud-gaming/<host>/`, and list, delete and abort-upload on **the one
archive bucket**. It still cannot touch IAM, the budget, or anything else in the account.

**Why "a box", not "an access".** Seeing every S3 read would need CloudTrail data events, which are
billed. A box launched or running is the free signal that the archive is still wanted, and a box
kept running longer than 14 days holds the archive the whole time.

## Notifications

Push notifications through [ntfy](https://ntfy.sh), **off unless `GAME_NTFY_URL` is set** in
`.env` - a topic name, or a full URL for a self-hosted ntfy. `cg notify` sends a test.

| Event | Sent by |
|---|---|
| an idle box terminated or stopped | the cloud watchdog |
| an idle box shutting down, and whether its games were mirrored | the on-host watchdog |
| its upload before shutdown still running after an hour - then hourly | the on-host watchdog |
| the upload on the way down failing, or cut off by the shutdown timeout | the box, as it goes down |
| a shutdown still going after 30 minutes - once | the cloud watchdog |
| a stuck shutdown forced - once | the cloud watchdog |
| a box still stuck an hour after forcing - then hourly | the cloud watchdog |
| the game archive 24 hours from deletion - once per countdown | the cloud watchdog |
| the game archive deleted | the cloud watchdog |
| the box confirmed gone - however it ended - and what S3 still bills for the games | the cloud watchdog, from EC2's events |
| a spot box about to be reclaimed - AWS's 2-minute warning | the cloud watchdog, from EC2's events |
| the cloud watchdog failing - at most once an hour | the cloud watchdog |
| a build finished, or failed | `cg init` |

**Never load-bearing.** A notification that cannot be sent is logged and ignored: it never
changes what a guard decides, and a dry run sends nothing. Delivery is best effort, so nothing
relies on one arriving.

**The topic is a secret.** On ntfy.sh, anyone who knows a topic can read and post to it. Use a
long random name, keep it in `.env` (gitignored), and never commit it; `cg` never prints it. The
messages carry nothing sensitive - the host name, an instance id, what happened. For a private
channel, self-host ntfy and set its URL instead.

**How it reaches each sender.** The cloud watchdog gets it as an environment variable, so the
next `cg init` or `cg watchdog install` applies a change. The box gets it inside its private host
bundle, as a root-only `/etc/cg-notify.conf`; `cg init` refreshes it, and removing the setting
removes the file. The 24-hour warning is recorded as a free SSM parameter, so the
hourly check sends it once, and retries next hour if the send failed.
The confirmation that a box is gone comes from a second EventBridge rule,
`<host>-cloud-watchdog-state`, which hands EC2's state changes and spot interruption warnings to
the same function; it ignores every state that is not an end. The box cannot report its own end.
A shutdown's notices are recorded as tags on the instance, stamped with when that shutdown began,
so each is sent once and an earlier shutdown's never counts. None of this adds a cost: EC2's own
events, the extra invocations, the tags and the requests all fall inside AWS's free allowances.
