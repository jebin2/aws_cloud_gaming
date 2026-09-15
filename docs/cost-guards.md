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
