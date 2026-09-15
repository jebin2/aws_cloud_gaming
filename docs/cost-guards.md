# Cost guards

What stops a GPU instance billing when you forget it: four independent layers and a budget that
emails you. What each charge actually is lives in [cost.md](cost.md).

## The four layers

Numbered by **independence** - how likely each one is to survive the failure it exists to catch.
Layer 1 is the fastest and the least reliable; layer 4 is the slowest to write but the hardest
to take down.

| # | Mechanism | Dies with | Catches | Reaction |
|---|-----------|-----------|---------|----------|
| 1 | `cg open` | your laptop, your network | normal use | on Moonlight exit |
| 2 | on-host watchdog | the box it protects | forgotten disconnect, client crash | 15 min idle |
| 3 | CloudWatch alarm on NetworkIn+**Out** | a wrong metric, a disarmed action | hung OS, dead watchdog, closed laptop | 30 min idle |
| 4 | cloud watchdog (Lambda) | a deleted or disabled schedule | a wedged box, a box left running outside a session, a box stuck going down | 30 min idle; forced after 1 h stuck |

The **AWS budget is not in that list**, because it stops nothing - it emails you. It is the
backstop for everything the four layers miss, not a layer.

They are **armed in roughly the reverse order**: the budget and the cloud watchdog before
anything launches, the on-host watchdog during the build, the CloudWatch alarm at the end of
`cg init`. A guard that only exists after the build cannot protect the build.

Worst-case leak with all four armed is about 30 minutes of runtime.

## Layer 4: the cloud watchdog

An AWS Lambda, `<host>-cloud-watchdog`, run every 5 minutes by an EventBridge schedule. It covers
what the other layers structurally cannot:

- **layer 2 dies with the box it protects.** A wedged instance takes its own watchdog with it.
- **layer 3 is armed only during `cg open`.** A box left running after `cg init`, or after
  "leave it running", has no alarm at all.
- **neither explains itself.** The CloudWatch alarm stopped a box mid-build early in this
  project and said nothing about why; that had to be inferred.

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

Layer 3 can only watch **NetworkOut**, and that is a CloudWatch limitation rather than a choice.
An alarm on `NetworkIn + NetworkOut` is the obviously correct measure - a Steam download is
almost entirely inbound - but AWS refuses it:

    ValidationError: EC2 actions are not available for Metric Math monitors

The `ec2:stop` action cannot be attached to a math expression, and composite alarms cannot take
EC2 actions either. So this layer watches one direction, and is armed **only for the duration of
a session**: outside one, low egress is a normal state, and a game downloading with nobody
connected looks exactly like an idle box. Layers 2 and 4 both count traffic in both directions
and are armed the whole time, which is what actually covers downloads.

It does use `treat-missing-data breaching`, deliberately. An instance wedged hard enough to stop
publishing metrics is invisible to the default `notBreaching` - every guard stays green while it
bills indefinitely. A false positive costs a two-minute restart; a miss costs money.

Layer 3 is also not armed *during* the build, because a freshly created alarm is
evaluated against the previous 30 minutes and would otherwise stop the box mid-build - see
[docs/troubleshooting.md](troubleshooting.md).

The budget is an **AWS Budget**, not a CloudWatch `EstimatedCharges` alarm. That alarm needs
"Receive Billing Alerts" switched on by the *root* user, for which there is no API, plus an SNS
subscription every recipient must confirm by email. Miss either and it sits in
`INSUFFICIENT_DATA` forever - armed in appearance only, which is worse than no alarm. A budget
emails its subscribers directly and works the moment it is created.
