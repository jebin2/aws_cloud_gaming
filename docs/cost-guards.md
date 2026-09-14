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
| 4 | off-site watchdog (optional) | only that third machine | a wedged box, a deleted or disarmed alarm | 30 min idle |

The **AWS budget is not in that list**, because it stops nothing - it emails you. It is the
backstop for everything the four layers miss, not a layer.

They are **armed in roughly the reverse order**: the budget and the off-site watchdog before
anything launches, the on-host watchdog during the build, the CloudWatch alarm at the end of
`cg init`. A guard that only exists after the build cannot protect the build.

Worst-case leak with all four armed is about 30 minutes of runtime.

## Layer 4: a watchdog somewhere that is always on

Optional, and it covers what the others structurally cannot:

- **layer 2 dies with the box it protects.** A wedged instance takes its own watchdog with it.
- **layer 3 can be wrong or absent.** The alarm can be deleted, disarmed, or pointed at the
  wrong metric - it watched egress only until recently, which read a download as idleness.
- **neither explains itself.** The CloudWatch alarm stopped a box mid-build early in this
  project and said nothing about why; that had to be inferred.

So layer 4 runs the same idea on a host that is always on, and **writes down every decision with
the numbers behind it**:

    2026-09-12T18:40:02+05:30 i-0abc quiet: in=41232B out=9112B total=50344B < 10485760B idle=4/6
    2026-09-12T18:45:02+05:30 i-0abc idle limit reached - stopping i-0abc

    GAME_WATCHDOG_HOST=ubuntu@my-vps      # in .env - cg init does the rest
    GAME_WATCHDOG_KEY=~/oci.key
    GAME_WATCHDOG_AWS_KEY_ID=AKIA...      # the scoped user, not yours
    GAME_WATCHDOG_AWS_SECRET=...

`cg init` arms it **before it launches anything**, so there is no manual step. On later runs it
reinstalls **only if something changed**: the host keeps a fingerprint of the files and config it
was given, and one `ssh` compares it, reads the timer state and fetches the last decision. When
nothing changed, init shows that decision and its age rather than running a new check - a check
on an idle box counts towards stopping it, so running one on every init was an idle tick. It
also warns if the last decision is older than the 5-minute timer allows. All ssh to that host
shares one connection. The first line used to take ~7 s to appear; the unchanged path is ~1 s.
The commands are there for when you want them:

    cg watchdog install                   # systemd timer, survives a reboot
    cg watchdog status                    # timer state and recent decisions
    cg watchdog logs --watch              # follow it live

**`cg init` creates that IAM user for you.** It makes `<host>-watchdog` with the policy below,
issues a key, saves it to `.env` (gitignored, chmod 600) and pushes it to the box over stdin.
`cg watchdog remove` deletes the user, its keys, and the copy on that host. If your own
credentials cannot manage IAM, it says so and skips layer 4 rather than failing the build.

The scope is verified with AWS's own policy simulator, not by reading the JSON:

    ec2:DescribeInstances            allowed
    cloudwatch:GetMetricStatistics   allowed
    ec2:StopInstances (tag=gamevps)  allowed
    ec2:StopInstances (other tag)    implicitDeny
    ec2:TerminateInstances           implicitDeny
    ec2:RunInstances                 implicitDeny
    iam:CreateUser                   implicitDeny

**The policy it attaches.** It is always on and probably internet-facing, so it
should be able to do only this and nothing else:

```json
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow",
    "Action": ["ec2:DescribeInstances", "cloudwatch:GetMetricStatistics"],
    "Resource": "*" },
  { "Effect": "Allow", "Action": "ec2:StopInstances",
    "Resource": "*",
    "Condition": { "StringEquals": { "ec2:ResourceTag/Name": "gamevps" } } }
]}
```

`cg watchdog install` compares that host's caller identity against your own and **warns loudly
if they match** - handing an always-on box your full access would be the worst decision in this
design. It cannot detect an over-broad policy, only an identical one, so check the policy
yourself.

Two watchdogs may both issue a stop. That is harmless: stopping an already-stopping instance is
a no-op.

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
