# aws_cloud_gaming

Your own Linux desktop on an AWS GPU instance, streamed to any device over Tailscale, that runs
only while you are using it and is guaranteed to go back down.

    ./cg init    # once: build the box and arm every guard
    ./cg open    # start, stream, stop on exit
    ./cg stop    # stop - this is what ends the hourly billing

---

> ### ⚠️ This spends real money on your AWS account
>
> A `g6.xlarge` costs **about $1/hour while running**, and streaming adds roughly as much again
> in data-transfer charges once you pass the free 100 GB/month. An instance left running for a
> forgotten day is around **$25**.
>
> The whole point of this repo is the four independent guards that stop that happening, but
> they are software and software fails. `cg init` creates an **AWS Budget** that emails you,
> and `cg cost` shows what you have actually spent - check it. No warranty, see
> [LICENSE](LICENSE).
>
> Two things the guards do *not* catch. The root volume bills **even while the instance is
> stopped**, so stopping is not free - only `cg destroy` reaches zero. And **egress can cost as
> much again as the instance** once you pass the free 100 GB/month - `cg cost` now tracks how
> much of that allowance is left, because until it runs out egress bills at $0.00 and is
> invisible in every other view.

---

## Quickstart

    git clone git@github.com:jebin2/aws_cloud_gaming.git
    cd aws_cloud_gaming
    cp .env.example .env      # edit: Tailscale key, alert email, region
    ./cg init

`cg init` checks every prerequisite before it spends a cent and tells you exactly what is
missing. It provisions the instance, arms the cost guards, installs the watchdog, and hands you
a pairing URL. After that, `cg open` is the whole workflow.

Use `cg check` to run every check and stop before anything is created.

The build takes about 7 minutes and streams its progress, so a slow step looks slow rather than
hung. Each step asserts its *effect* rather than merely running, because nearly every failure
in this project has been something reporting success while broken:

    ==> building the box - live progress below
        installing nvidia driver (the slowest step)
          ok  nvidia driver packages installed
        disabling nvidia DRM KMS (NvFBC cannot capture with it on)
          ok  nvidia DRM KMS disabled
        installing steam
          ok  steam bootstrap shipped
          ok  steamdeps cannot block a headless boot
        setting up scratch disk
          ok  /scratch mounted on the instance store
        (host rebooting - reconnecting)
        build complete after 6m

A failed `verify` stops the build. That is deliberate: a box that provisions cleanly and then
cannot stream is a worse outcome than one that refuses to finish.

Anything that looks like an error is surfaced with a `!` prefix; the thousands of shell-trace
lines behind it are not. The full log lives at `/var/log/cloud-gaming-bootstrap.log` on the box.

### What you need first

Two of these take real time to obtain, so start them before anything else:

- **An AWS account on a paid plan.** The new-style Free Plan can only launch free-tier-eligible
  instance types - **no GPU instances at all**, whatever your quota says, and the error message
  does not explain this. Check with `aws freetier get-account-plan-state`.
- **An approved GPU quota** in your chosen region: `Running On-Demand G and VT instances`
  (`L-DB2E81BA`). Mine took three days. **File it from the console with a real use case** - a
  request submitted through the CLI carries no justification and is usually refused. Spot needs
  a *separate* quota (`L-3819A6DF`), which is **0 by default**; approval of one says nothing
  about the other, and spot is refused more often. Mine was denied first time and granted the
  next day on a re-file, so a denial is worth appealing. `cg init` prefers spot and falls back
  to on-demand when the quota cannot cover the instance.

  Note that "Resolved" on a support case means the case was **closed**, not that you got the
  quota. Compare the applied value against the default instead:

      aws service-quotas get-service-quota --region <r> --service-code ec2 --quota-code <code>
      aws service-quotas get-aws-default-service-quota --region <r> --service-code ec2 --quota-code <code>

And locally:

- **Tailscale**, installed and up (`sudo tailscale up`), plus a
  [pre-auth key](https://login.tailscale.com/admin/settings/keys)
- optionally a **Tailscale API access token** (a different credential, from the same page) as
  `TAILSCALE_API_KEY`. With it, `cg destroy` deletes the tailnet nodes it created, so rebuilds
  keep the clean hostname instead of climbing `gamevps-1`, `-2`, `-3`. Only nodes named exactly
  `<GAME_TS_HOST>` or `<GAME_TS_HOST>-<number>` are ever touched. These tokens expire after 90
  days; when one does, `cg destroy` says so plainly rather than skipping the cleanup silently
- **Moonlight** (`moonlight-qt`) - only needed to stream, so `setup` warns rather than stops
- `aws` CLI v2 configured, `python3`, `curl`, and OpenSSH (`ssh`/`scp`)

#### AWS credentials

If `aws configure` has already been run, nothing to do. Otherwise the console hands you an
access key as a **`.csv` download** rather than something you can paste, so `setup` accepts it
directly:

    AWS_KEY_CSV=~/Downloads/CLI_accessKeys.csv cg init

With no path given it looks for one in your home directory and offers to import it. It picks
the first file that actually *parses* rather than the first matching name - the console also
issues a `*_credentials.csv` containing a sign-in **password** and no access key, and choosing
by filename would grab that instead.

**Delete the .csv once imported.** It is a plaintext secret, and anyone who reads it has your
account. `*.csv` is gitignored here so a stray copy in the repo cannot be committed, but that
does not help it sitting in `~/Downloads`.

### Configuration

Everything lives in `.env` - see [.env.example](.env.example), which documents every variable.
`cg init` prompts for the Tailscale key and alert email if they are absent, so the minimum is a
working AWS profile and a Tailscale account.

## Commands

`cg` is the front door. It dispatches into `setup` and `game`, which both keep working - the
odd-looking lines in those scripts are scars from real failures, so `cg` calls them rather than
reimplementing them.

| Command | What it does |
|---|---|
| `cg init` | Build everything; reuses an existing box. **Costs money** |
| `cg open` | Start, stream, stop on exit. **Costs money** |
| `cg stop` | Mirror the games to S3, then stop the instance - ends hourly billing |
| `cg status` | Instance, disks, guards, tailnet, game library, local tools |
| `cg library` | What is on the box vs in S3, and what the archive costs |
| `cg library push` | Mirror the games to S3 now (`--verify` for a full comparison) |
| `cg library pull` | Restore the games from S3 now |
| `cg games` | What Steam has: installed, downloading (with progress), running, archived |
| `cg games --volume` | The **old** EBS volume, if you still have one, and its monthly cost |
| `cg snapshot` | Save an AMI of the box. **Bills monthly** |
| `cg snapshot --list` | What images exist and what they cost |
| `cg snapshot --delete <id>` | Delete an image **and its backing snapshots** |
| `cg clean` | Free space: apt caches, logs, `/scratch/tmp`. Games are not touched |
| `cg destroy` | Mirror the games to S3, then delete the box. **Refuses if the mirror fails**. Keeps the budget |
| `cg destroy --force` | Destroy even if the mirror failed - **loses the games** |
| `cg destroy --no-push` | Destroy and leave the archive exactly as it is - locks it first |
| `cg destroy --all` | The box **and the whole account footprint** - archive, bucket, IAM, budget. Asks you to type `DESTROY-ALL` |
| `cg check` | Every preflight check, creates nothing |
| `cg cost` | Month-to-date spend and what still bills |
| `cg log [what] [--watch]` | `build` \| `steam` \| `watchdog` \| `disk` \| `sunshine` |
| `cg ssh [cmd]` | Shell on the box - resolves the suffixed tailnet name for you |
| `cg watcher [--watch]` | All four guards, and whether each is genuinely armed - including whether the off-site one can actually see your account |
| `cg ping [--watch]` | Latency, and **direct vs DERP relay** - the usual cause of a bad session |

`--region` and `--host` override `.env` without editing it; `--json` works on `ping` and
`snapshot --list`.

Deleting an image deregisters it **and** deletes its backing snapshots. Deregistering alone
leaves those billing - the usual way to believe you deleted something and keep paying for it.

### Running a command twice

Everything is safe to run again. The ones worth knowing:

| Command | Second run |
|---|---|
| `cg init` | Reuses the instance and skips what is done - **but it starts a stopped box, so it costs money** |
| `cg open` | Connects again if already running |
| `cg stop` | Says "already stopped" |
| `cg clean` | Frees less each time; needs the box running |
| `cg destroy` | No-op. The first run keeps nothing and asks nothing |
| `cg cost` | Each run makes one Cost Explorer call ($0.01) |

**The two that cost money unprompted** are `cg init` and `cg open` - both start a stopped
instance. Everything else is read-only or asks first.

**The one that cannot be undone** is `cg destroy`: it runs immediately, with no confirmation,
and keeps nothing. To keep the installed desktop, `cg snapshot` first.

**The two that cost you money unprompted:** `cg init` starts a stopped instance, and `cg open`
starts one too. Everything else is either read-only or asks first.

**The one that cannot be undone:** `cg destroy` runs immediately with no confirmation and
keeps nothing. `cg destroy` is the gentler version - it asks, and offers to save an image
first.

## Everyday use

Run `cg open`. It starts the instance if stopped, waits for Tailscale and Sunshine, arms the
idle alarm, and opens the stream. When you quit Moonlight it prints the session length and
asks `stop instance now? [Y/n]` - pressing Enter is what actually stops the billing.

Run it from a real terminal; that prompt needs one. A cold start takes 1-2 minutes.

Pairing is automatic and needs no browser: `cg init` creates the Sunshine account and pairs
Moonlight itself, then saves the credentials to `.env`. Pairing is certificate-based, so it
survives stop/start and re-running `cg init`.

The web UI at `https://<tailscale-ip>:47990` is there if you want it. Its self-signed
certificate warning is expected - the traffic is already encrypted by WireGuard before TLS
applies.

**Resolution follows whatever Moonlight asks for.** The host switches to match at the start of
each session, so set Moonlight to 1920x1080 for the box's native mode.

## Cost control

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

### Layer 5: a watchdog somewhere that is always on

Optional, and it covers what the others structurally cannot:

- **layer 2 dies with the box it protects.** A wedged instance takes its own watchdog with it.
- **layer 3 can be wrong or absent.** The alarm can be deleted, disarmed, or pointed at the
  wrong metric - it watched egress only until recently, which read a download as idleness.
- **neither explains itself.** The CloudWatch alarm stopped a box mid-build early in this
  project and said nothing about why; that had to be inferred.

So layer 5 runs the same idea on a host that is always on, and **writes down every decision with
the numbers behind it**:

    2026-09-12T18:40:02+05:30 i-0abc quiet: in=41232B out=9112B total=50344B < 10485760B idle=4/6
    2026-09-12T18:45:02+05:30 i-0abc idle limit reached - stopping i-0abc

    GAME_WATCHDOG_HOST=ubuntu@my-vps      # in .env - cg init does the rest
    GAME_WATCHDOG_KEY=~/oci.key
    GAME_WATCHDOG_AWS_KEY_ID=AKIA...      # the scoped user, not yours
    GAME_WATCHDOG_AWS_SECRET=...

`cg init` arms it **before it launches anything**, and refreshes it on later runs, so there is
no manual step. The commands are there for when you want them:

    cg watchdog install                   # systemd timer, survives a reboot
    cg watchdog status                    # timer state and recent decisions
    cg watchdog logs --watch              # follow it live

**`cg init` creates that IAM user for you.** It makes `<host>-watchdog` with the policy below,
issues a key, saves it to `.env` (gitignored, chmod 600) and pushes it to the box over stdin.
`cg watchdog remove` deletes the user, its keys, and the copy on that host. If your own
credentials cannot manage IAM, it says so and skips layer 5 rather than failing the build.

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
[docs/troubleshooting.md](docs/troubleshooting.md).

Layer 4 is an **AWS Budget**, not a CloudWatch `EstimatedCharges` alarm. That alarm needs
"Receive Billing Alerts" switched on by the *root* user, for which there is no API, plus an SNS
subscription every recipient must confirm by email. Miss either and it sits in
`INSUFFICIENT_DATA` forever - armed in appearance only, which is worse than no alarm. A budget
emails its subscribers directly and works the moment it is created.

### What things cost

Four separate charges. The third surprises people, and the fourth is the only API that bills.

**Per hour running.** `g6.xlarge` in `ap-south-2` is $0.9664/hr plus $0.005/hr for the public
IPv4 while it runs.

**Per month regardless.** A gp3 volume is $0.0912/GB-month: 50 GB is about **$4.50/month,
charged while the instance is stopped**. `GAME_DISK_GB` is the only lever, and it is far easier
to choose at launch than to resize later - EBS volumes cannot be shrunk.

**Per hour streaming.** Streaming video is data transfer out. At 20 Mbps you push ~9 GB/hour.
The first 100 GB/month is free - about 11 hours - and after that it is $0.1093/GB, or
**~$0.98/hr, roughly doubling the hourly cost**. Lowering Moonlight's bitrate lowers this
proportionally, and past a point saves more than any pricing plan will.

`cg status` also shows traffic since the box booted, read straight off the interface counters -
free, and immediate, where `cg cost` lags a day:

    TRAFFIC (this boot only - see cg cost for the billed month)
      stream out      2.59 GB   avg 2.2 Mbps over 2.8 h
      total out       5.03 GB   <- what AWS bills
      total in      132.31 GB   (free - game downloads land here)
      (above is this boot only)
      monthly egress  9.3 GB used, ~91 GB of 100 GB free left  (as of 12 min ago)

The last line is the **month**, and it comes from Cost Explorer - the only place that knows it.
The box knows only its own boot, and every session is a new box, so subtracting boot counters
from a monthly allowance is wrong: it read "99 GB left" while Cost Explorer said 91. Since a
Cost Explorer call costs $0.01, `cg status` does not make one - it re-reads the figure `cg cost`
last paid for, cached in `.cg-cache/`, and stamps it with its age.

**Per API call.** One AWS API in this project is not free: **Cost Explorer, at $0.01 per
request**. `cg cost` is the only command that makes one, so it costs about INR 0.88 to run.
Measured on a real month:

    AWS Cost Explorer     25 requests    $0.25   (INR 22)

Everything else this project calls is free at this volume - EC2 describe/run/terminate, STS,
IAM, the Pricing API (where the S3 per-GB figure comes from), CloudWatch metrics and alarms
(1M requests and 10 alarms free), AWS Budgets (first two free), and the Free Tier API.

**S3 requests are small but not free**, and this claim used to say they were. Measured over two
days of pushing a ~140 GB game:

    2026-09-12   73,345 PUT/LIST   119,925 GET    $0.415  (INR 37)
    2026-09-13   52,304 PUT/LIST    26,550 GET    $0.273  (INR 24)

About **INR 25 per full push** of a 140 GB game. An incremental push where nothing changed is
near-free, because `--size-only` skips every matching file and the cost is mostly the LIST calls
`sync` uses to compare. The count is high relative to the file count because of multipart: at
`--part-size 16` MiB a large `.pak` becomes thousands of separate PUTs. Raising part-size would
cut that roughly fourfold and multiply s5cmd's memory the same way, which is the trade that
caused an OOM once - not worth INR 15 a push.

**Data transfer between S3 and EC2 in the same region really is free**, in both directions:
`DataTransfer-In-Bytes` and `DataTransfer-Out-Bytes` both bill $0.000 across every push and
restore so far. The upload and the restore cost requests and nothing else.

That $0.01 is why `cg status` caches rather than asks: run 20 times a day it would be about
INR 530/month, more than the S3 archive it reports on.

Note the gap between the two "out" figures. Billed egress is what leaves the real NIC, so it
includes WireGuard overhead, ssh, and - measured at **~2.4 GB against a 132 GB download** - the
TCP acknowledgements a large download generates. Inbound is free, but it is not quite true that
downloading costs nothing.

Check actual spend with `cg cost`, which measures runtime from CloudWatch datapoints
rather than billing data, so it has no lag. It reports **every** volume and snapshot, not just
the running instance's - orphaned volumes are the usual way people keep paying for a machine
they believe they deleted.

`cg status` answers the other question - what state everything is in:

    ACCOUNT      account id, plan type (a FREE plan cannot launch GPUs), credits
    QUOTAS       on-demand and spot GPU quota against what your instance type needs
    RESOURCES    instance, volumes, snapshots, images, elastic IPs, key pair,
                 security group and its inbound rules
    COST GUARDS  both alarm states, and whether alert emails are confirmed
    LOCAL        tailscale, moonlight, ssh key, auth key, tailnet node

Run it before a build to see what is missing, and after one to check the guards actually
armed - `budget alerts` in particular, since a budget with no subscribers looks fine until the
day you need it.

### Spot is the default

`GAME_SPOT=1` is the default and saves roughly 70%. It shapes how the rig is used, because a
spot instance here is **use-once**: there is no stop, only destroy.

    cg open        build/start, stream
    ...play...
    cg open's exit prompt  ->  [d] destroy (recommended)   [n] leave it running

Why there is no stop. A **one-time** spot request cannot be stopped at all - AWS only allows
stopping a *persistent* request's instance - and stopping a persistent one disables the request,
after which the box can never start again while its root volume keeps billing. Neither is a
useful "pause", so `cg stop` on a spot box offers destroy instead, and `cg open` refuses to
start a stranded one and explains why.

That is only acceptable because the games are in S3: destroying costs a ~6 minute rebuild and
nothing else. Under the old EBS-volume design, `stop` was the only way to keep a library without
paying for an instance, which is exactly why the old design used a persistent request.

**The guards terminate now, not stop.** All three - the on-host watchdog, the CloudWatch alarm,
and the off-site watchdog - previously had to issue a stop, because a persistent request
relaunches on termination and none of them can cancel a request first. Every guard firing
therefore stranded a box at ~INR 400/month. A one-time request cannot relaunch, so they
terminate, and `cg status` / `cg watcher` flag any stranded box left over from the old design
with its monthly cost.

If you want stop/start back, run on demand: `GAME_SPOT=0 cg init`. Dearer per hour, restartable
as often as you like, and there the guards still stop rather than terminate.


### Moonlight client settings

Two settings on the **client**, both easy to miss:

`cg open` now sets the first of these for you, so Alt+Tab works out of the box:

- **Input Settings → Capture system keyboard shortcuts** → on. Without it Alt+Tab and Super are
  swallowed by your own desktop and never reach the stream. This is the setting that matters -
  verified working on KDE Wayland in **borderless windowed**, so true fullscreen is not
  required, at least there. On a compositor that refuses the `keyboard-shortcuts-inhibit`
  request, try Fullscreen, and failing that an X11 session, where grabs are unconditional.

Two ways to trip over this:

`cg open` runs `moonlight stream <ip> Desktop`, which streams and exits without ever showing the
GUI - so there is no settings page to reach from it. Run `moonlight` on its own to change these.

And a running Moonlight does not notice config edits; it also rewrites the file on exit,
discarding them. Change the setting in the GUI, or close Moonlight before editing the file.

### One thing to turn off in Steam

**Steam → Settings → Downloads → Shader Pre-Caching → turn off "Allow background processing of
Vulkan shaders".**

On 4 vCPUs Steam otherwise compiles shaders in the background at ~90% of a core while a game
compiles its own at launch. Measured: `steam` dropped from 87-95% to ~55% of a core with it
off, and load average from 7.5 to ~3.4 on 4 cores, giving the game a clean 150%.

That is a real CPU saving, but do not read it as "launches twice as fast" - the launch after
turning it off was also replaying shaders already compiled by the previous attempt, so the two
effects were not separated. The honest claim is narrow: it frees close to a core.

It persists across stop/start (it lives on the root volume) but is lost on `cg destroy`, so
redo it after a rebuild. It cannot be scripted - Steam does not expose it as a config key.

## Where the games live

On **local NVMe** (`/scratch/steam`), mirrored to **S3**. The instance store is the fastest disk
on the box and costs nothing, and it is wiped on every *stop* - so the S3 archive is the durable
copy, and the box restores from it at boot.

The restore starts at the **top** of the build and runs in the background while everything else
installs, so it overlaps the NVIDIA driver rather than being a wait of its own. The readiness
marker waits for it, so `cg init` reports the box ready when the games are actually there.

    cg library              what is local, what is archived, what it costs
    cg library push         mirror now  (--verify for a full comparison)
    cg library pull         restore now
    cg library --bucket     the bucket name, answerable with the box gone

`cg destroy --no-push` exists for the case where the box's local copy is **worse** than what is
archived - a half-finished restore, a game mid-repair, a disk you do not trust. Skipping this
end's push is only half the job, because `cg-library-shutdown.service` runs on the box and fires
on any graceful shutdown, so `--no-push` **revokes the box's S3 write access** first. That works
even when the box is too busy to answer ssh, which is usually why you wanted it. Access is
restored immediately afterwards, and `cg init` rewrites the policy on every build in any case.

**The archive is the only copy.** It is written in three places, and not a fourth:

1. **`cg stop`** - and the "stop instance now?" prompt at the end of `cg open`
2. **`cg destroy`**
3. **`cg-library-shutdown.service`**, from `ExecStop`, as the machine goes down

(1) and (2) **refuse to proceed** if the push fails, rather than printing a warning next to the
thing that just lost your games; `--force` overrides and says what it costs.

(3) is not redundant cover. The box stops itself **three ways nobody typed** - the on-host idle
watchdog's `shutdown -h`, the CloudWatch alarm, and the off-site watchdog - and the last two call
`StopInstances`, which AWS turns into a graceful OS shutdown. All three arrive at `ExecStop`, so
one unit covers all of them. Without it, every automatic stop would wipe the instance store and
lose whatever was installed since the last explicit stop.

There is deliberately **no periodic timer**. An earlier version pushed every 10 minutes; nothing
should be uploading a game library, and propagating deletions while doing it, while you are
playing. The remaining exposure is a stop that is not graceful - a **spot interruption** gives
about two minutes, which will not upload a large library, and a hard power-off gives none.
`cg library push` takes a checkpoint whenever you want one, and `cg library check` asks whether
the disk matches the archive without uploading anything.

The explicit push is wired into `lib/game`'s `down()`, not into `cg stop`, because the "stop
instance now?" prompt at the end of `cg open` calls `down()` directly and never comes back
through `cg`. Putting the gate in the CLI would have meant two pushes on `cg stop` and none on
the path people actually use.

### Measured numbers

**Steam download rate: 379 Mbps**, measured off the idle watchdog's own interface counters
(2,710 MB/min inbound) while a game was downloading. So a 160 GB game re-downloads in about an
hour, not the ~3.7 h an earlier ~100 Mbps guess implied - that guess came from watching the
Steam *client* bootstrap, which is not the same thing as a game download and is far slower.

The archive still earns its keep at that rate: ~11 min to restore against ~60 min to
re-download, and the Proton prefix - save games, registry, shader cache - cannot be
re-downloaded at any speed.

On a `g6.xlarge` in `ap-south-2`:

| Shape | Direction | Rate |
|---|---|---|
| 10 GB in 10 x 1 GiB objects | archive | **508 MB/s** (4.1 Gbps) |
| 10 GB in 10 x 1 GiB objects | restore | **235 MB/s** (1.9 Gbps) |
| 2.9 GB in 13,271 real game files | archive | **140 MB/s** |

**Object shape matters more than bandwidth.** The same code moves 1 GiB objects at 508 MB/s and
a real game library at 140 MB/s, because 13,271 objects is 13,271 requests. Treat the big-object
numbers as an upper bound you will not see; a 140 GB library of mixed file sizes should land
somewhere between, which is why the restore is hidden inside the build rather than timed
precisely. The first benchmark here reported only the 1 GiB figure, and it was misleading in
both throughput *and* memory - see below.

### Why not an EBS volume

That is what this replaced. A 160 GB gp3 volume mounted at `/games` did survive a stop on its
own, and it cost:

- **$14.59/month (~INR 1,284)**, billed whether or not the box existed
- **one availability zone, forever** - EBS cannot cross AZs, so the volume's zone decided where
  every future instance launched, and `InsufficientInstanceCapacity` in that zone failed the
  launch outright

The same library in S3 Standard is **~INR 310/month** and pins nothing, which materially
improves the odds on a spot launch. The cost is the ~10 minute restore, which is why it was
worth the work to hide it inside the build.

If you still have that volume, it is **not** attached or mounted any more, and it is **not**
deleted either - `cg games --volume` shows what it still costs and `cg games --volume --delete` reclaims it.

### What `destroy` removes, and what `--all` removes

`cg destroy` removes the **box**. `cg destroy --all` removes the **account footprint**.

| | `cg destroy` | `--all` |
|---|---|---|
| Mirror the games to S3 first | **yes**, and refuses if it fails | no - they are being deleted |
| Instance (terminate + cancel the spot request) | gone | gone |
| Idle-stop alarm | gone | gone |
| Security group, key pair, `~/.ssh/<host>.pem` | gone | gone |
| Tailnet nodes | gone | gone |
| Untagged orphaned volumes | gone | gone |
| **Monthly budget** | **kept** | gone |
| **S3 archive and its bucket** | **kept** | gone |
| **`<host>-box` role + instance profile** | **kept** | gone |
| **`<host>-watchdog` user, its key, the `.env` entries** | **kept** | gone |
| **Off-site watchdog units on the VPS** | **kept** | gone |
| Old EBS game volume, if you still have one | **kept** | gone |

`--all` asks you to type `DESTROY-ALL`, because the archive is the only copy of the games and
there is no versioning behind it. It skips the mirror entirely, since pushing games to S3 and
then deleting the archive would be nonsense.

**The budget is kept by a plain destroy on purpose.** It guards the account rather than the
instance, it costs nothing, and it used to be deleted on every destroy - which meant it was
recreated on every `cg init`, and AWS Budgets populates its spend figure up to 24 hours *after*
a budget is created. On a rig rebuilt several times a day it never populated. It reported
`$0.00 spent` against a real month of $12.17 and had never once been in a position to alert.

It leaves nothing behind on purpose. An earlier version kept the empty bucket and the role,
reasoning that both are free and the names are deterministic - but that is an argument for a
leftover being harmless, not for a command called `--all` producing one. `cg init` recreates all
of it, and because the bucket name is derived from your account id it comes back identical.

One consequence of that identical name: S3 holds a deleted bucket name for a few minutes, and
recreating it fails with `OperationAborted` in the meantime. `library-aws.sh` waits that out
(8 attempts, 15s apart) rather than failing an init that would have worked on the second run.

### The guards, and why they exist

`push` propagates local deletions to S3 (`--delete`), and the local copy lives on a disk that
vanishes on stop. A push against an empty `/scratch` would therefore delete the archive. So:

- push **refuses** unless a restore completed on this boot. A failed restore writes no marker.
- push **refuses** when the local library is less than half the archive.
- pull **refuses** if `/scratch` is not a mountpoint, which would fill the root disk.
- the restore marker records **which boot** restored the library, so a marker left on the root
  volume by a previous boot cannot vouch for an instance store that has since been wiped.

`./tests/library.sh` covers all of them - 41 assertions against a stubbed `s5cmd`. It is worth
saying why that file is unusually paranoid: the first live test of this code **deleted a real
250 MB archive**. The object count was parsed from `s5cmd du`, whose output ends `... in 2
objects:` with a colon; the parser matched the bare word, read 0 forever, and the size guard was
conditioned on that count. The unit test passed because the stub emitted a format I had assumed
rather than the one s5cmd prints. Both were fixed: the guards key off *bytes*, and the stub is
now byte-for-byte the real output.

### One archive, one disk, and choosing between them

A `g6.xlarge` holds **229 GB**. Two modern titles do not fit together - Black Myth: Wukong is
~128 GB and Diablo IV ~160 GB - so the archive has to hold more than the disk does.

Each game is archived under its own prefixes, so **pushing one game never touches another**:

    steamapps/appmanifest_<id>.acf
    steamapps/common/<installdir>/
    steamapps/compatdata/<id>/        the Proton prefix: saves, registry
    steamapps/shadercache/<id>/

`--delete` is scoped inside each app's own prefix, so removing a file from a game still
propagates, and a game that is simply not installed is left alone. That makes "an empty disk
empties the archive" **impossible by construction**, where the whole-tree sync needed a size
guard to catch it - the same failure that removed Shakes & Fidget when it was uninstalled and
Proton when Steam moved it to another library.

`cg init` asks which to restore, before the instance launches - the restore runs at boot with no
terminal, and has to start early to overlap the build:

    Archive (209 GB selectable of 229 GB - 20 GB reserved for Proton, shaders, headroom):

      #   APPID      GAME                                  SIZE  ARCHIVED
      1   2344520    Diablo IV                         160.0 GB  2026-09-13 11:02
      2   2358720    Black Myth: Wukong                128.0 GB  2026-09-13 09:14
      3   438040     Shakes and Fidget                   2.5 GB  2026-09-12 20:44

    Restore which? (numbers or appids, comma separated | all | none)
    Enter = none
    > 1,2
      288 GB selected, 209 GB available - over by 79 GB.
      Diablo IV 160 GB + Black Myth: Wukong 128 GB
      These fit on their own: Diablo IV (160 GB), Black Myth: Wukong (128 GB)

    > 1
      160 GB selected, 49 GB spare. Restoring: Diablo IV

It **refuses and explains** rather than silently picking a subset: which game to drop is not a
decision a tool should make for you.

**Enter means `none`.** Enter is what people press to get past a prompt, and defaulting to `all`
would start a 158 GB transfer for a box they might have wanted empty. Restoring a game is cheap
to ask for and annoying to undo, so it costs one deliberate keystroke; the archive is untouched
either way and `cg library pull --apps <id>` fetches it later. The choice is still remembered in
`.env` as `GAME_APPS`, which is what non-interactive runs use.

The box enforces the same arithmetic independently, because `CG_APPS` can still say `all` from an
old `.env` or a run where the prompt never happened. It skips what will not fit and says so,
rather than filling `/scratch` mid-restore - which fails in the least legible way available, as a
half-restored game that Steam reports as installed.

    cg library list            what is archived, per game, and the monthly cost
    cg library pull --apps <csv|all|none>
    cg library forget <appid>  delete one game from the archive (type FORGET)

A push that dies leaves files with no manifest and no index entry - deliberately, so a
half-uploaded game is never mistaken for a complete one. Nothing could then *see* them:
`cg library list` read the index and reported an empty archive while 76 GB of a dead download
sat there costing INR 167/month, and `forget` could not reach it either. `cg library list` now
reports orphaned objects and `cg library clean` removes them, behind a typed `CLEAN`.

**The archive no longer shrinks on its own**, which is the price of never deleting an absent
game. `forget` is how a game leaves it - with a typed word, because there is no versioning behind
the bucket. Both games archived is 288 GB, **$7.20/month (INR 634)**; one is $4.00 (INR 352).

### Symlinks

S3 cannot store a symlink, and `--no-follow-symlinks` is what keeps the uploader from recursing
into `/` through a Proton prefix's `dosdevices/z:`. So `push` records every symlink in the
library into `.cg-symlinks.tsv` (`path<TAB>target`) before the sync, and `pull` recreates them
afterwards - additively, never overwriting anything already there.

This is not cosmetic. A restored game whose `dosdevices` is empty passes every check - manifest
`StateFlags 4`, nothing re-downloaded, library registered - and **will not launch**, because Wine
resolves every Windows path through those links. Steam rebuilds its own trees, so the Proton
runtime recovers on its own; a *game's* prefix has no such owner and never self-repairs.

### Proton and the Steam runtime are deliberately not mirrored

Steam installs compatibility tools into whichever library it likes - usually the client's own,
on the root disk, which `cg destroy` deletes. They are therefore re-downloaded on each rebuild
rather than restored from S3.

This was measured and left alone: **under a minute**. Mirroring them would add ~2 GB to the
archive to save less time than the NVIDIA driver install already takes in parallel. The game,
its Proton prefix (save games and registry) and the shader cache - the parts nothing else will
rebuild for you - are all mirrored.

If Steam happens to place the tools in `/scratch/steam` on some build, **push skips them.** This
became necessary on 2026-09-14, when one push archived four of them as if they were games:

    1493710    Proton Experimental                 1.8 GB
    1391110    Steam Linux Runtime 2.0 (soldier)   0.6 GB
    4183110    Steam Linux Runtime 4.0             0.6 GB
    3086180    Proton Voice Files                  0.1 GB

The old whole-tree sync would have deleted them again the next time they were absent. Per-game
archiving deliberately never removes an app that is not installed - the property that stops an
empty disk emptying the archive - so once in, they would have stayed. They were removed with
`cg library forget`, and `is_steam_tool` in `host/cg-library` now keeps them out:

- installdir `Proton <anything>` or `SteamLinuxRuntime*` - with the space, so a game installed
  as `ProtonHunter` is still archived
- appids 228980 (Steamworks Common Redistributables), 1826330 (Proton EasyAntiCheat Runtime),
  1161040 (Proton BattlEye Runtime)

Push logs each skip (`not archiving Proton Experimental (1493710) - a Steam tool`). If a new tool
ever slips through, extend that function and `cg library forget` its appid.

### The Steam login is not in the library

The games are on `/scratch`. The *login* is not - it is four things on the **root disk**, which
is destroyed with the instance:

    ~/.local/share/Steam/config/config.vdf        the refresh token
    ~/.local/share/Steam/config/loginusers.vdf    the remembered account
    ~/.steam/registry.vdf                         the machine identity Steam Guard checks
    ~/.local/share/Steam/userdata/                per-user config, controller bindings

So a rebuild restored 160 GB of game perfectly and then asked for Steam Guard again, which is
the wrong way round: the expensive thing came back and the cheap thing did not.

These now go to `steam/account/steam-account.tgz` - a tarball rather than an `s5cmd sync`,
because it is a handful of files whose **modes matter** (Steam rejects a `config.vdf` that other
users can read) and because a tarball lands **atomically**. A half-synced login directory is
worse than no login at all.

Three details that are not obvious:

**It is pushed even when the game push refuses.** The restored-this-boot guard exists to stop a
half-restored *game* overwriting a complete archive. The login has no such hazard, and the boot
most likely to carry a *new* login is the one that restored no games at all - the box used for
something else. Blocking it would lose a real login to an unrelated rule.

**A logged-out box does not overwrite a good saved login.** The guard is `config.vdf` existing
and being non-empty. Without it, booting a box, never signing in, and destroying it would
replace a working archived login with an empty one.

**`userdata/` is the only directory walked**, so it is where the cache excludes and the symlink
handling earn their place; `config/` is archived as two named files. Links are stored as links -
the same `--no-follow-symlinks` lesson that OOM-killed the library sync at 12 GB resident.

`cg library status` says which way it is:

      steam login archived - a new box starts signed in
      steam login NOT archived - a new box will ask for Steam Guard

The token is a credential. It lives in a private bucket the box reaches through its instance
role, and it is worth knowing it is there: anyone who can read that bucket can sign in as you.
`cg destroy --no-push` skips it along with everything else.

### Comparison is size-only

`s5cmd sync` compares modification times by default, and a freshly restored file is always
*newer* than the S3 object it came from - so the next push would re-upload the entire library,
every session. Both directions use `--size-only`, which makes them idempotent (verified: a push
straight after a pull transfers nothing).

The trade-off is real: a game patch that rewrites a file to exactly the same length is not
noticed. `cg library push --verify` does a full comparison; run it after a big game update if
you want certainty.

### What `/scratch` also holds

Browser downloads and temp files, in `/scratch/tmp` and `/scratch/downloads`. `cg clean` clears
**only those two directories** by name - it used to wipe everything directly under `/scratch`,
which was safe when the games were on a separate volume and is now the fastest way to delete a
140 GB library and have the mirror faithfully propagate the deletion.

The NVIDIA and DXVK shader caches sit on the root volume (`~/.cache`), so they survive a reboot
but not a destroy. The Fossilize cache that matters most is *inside* the library, at
`steamapps/shadercache`, and is mirrored with it.

## Layout

    cg                 the front door - every command
    setup, game        what cg dispatches into
    lib/               provisioning and cloud-init internals
    host/              units deployed to the instance (watchdog, disk monitor, S3 mirror)
    tests/             offline tests for the fiddly host-side logic
    docs/              architecture and troubleshooting

`./tests/run-all.sh` runs every suite and **exits non-zero if any fails** - which the obvious
`for t in tests/*.sh; do ... && echo PASS || echo FAIL; done` does not, because the last command
in the loop is the `echo`. That returned 0 on a red suite and a `&& git commit` chained after it
committed anyway.

`./tests/steam-library.sh` checks the Steam library registration - the part that has broken
most often - against a faked Steam install, so it can be verified without spending a build.
`./tests/library.sh` does the same for the S3 mirror's refusals, which is the code whose failure
mode is losing every game rather than an error message. `./tests/destroy-all.sh` covers
`cg destroy --all`, the one command that can delete the archive - proving that path with stubs
rather than by performing it, which is a lesson learned the hard way.

## Further reading

- [docs/architecture.md](docs/architecture.md) - how the three layers fit together
- [docs/troubleshooting.md](docs/troubleshooting.md) - every failure hit while building this,
  and why the fix works. Read this before debugging anything.

### The ones that cost the most time

Nearly all of them share a shape: **something reported success while broken.** That is why each
provisioning step now asserts its effect rather than its execution.

| Symptom | Actual cause |
|---|---|
| Stream connects, then `No video traffic was ever received from the host!` | Ubuntu ships `nvidia_drm modeset=1`. **NvFBC cannot capture while DRM KMS owns the display** - and it also blocks every `xrandr` mode change |
| `apt install steam` succeeds, no Steam exists | `steam-installer` is a stub; its first-run licence dialog cannot be answered headless. Use Valve's `.deb` |
| Steam downloads 74 MB and stops | Valve's launcher runs `steamdeps`, which re-execs into a **terminal prompt** whenever `DISPLAY` is set |
| Steam killed mid-update | "Size stopped growing" is not "finished" - Steam alternates downloading and installing. Gate on the unpacked client existing |
| "Storage is showing internal only" | Steam writes `libraryfolders.vdf` only after a sign-in, so on a fresh client there was nothing to append to and registration silently wrote nothing |
| NVMe library vanishes after a stop | `/scratch` is reformatted at every start, destroying the marker Steam uses as proof the library is real |
| Build hangs with no output, then "host rebooting" | A rebuilt box reclaims its hostname, and `known_hosts` still held the old key. ssh's stderr was being discarded, so a refusal looked like silence |
| Re-running `cg init` hangs 30 minutes | It waited for a *new* tailnet node against a box that joined long ago - gated on a 2s ping that a cold WireGuard path loses |
| CloudWatch alarm stops the box mid-build | A new alarm is evaluated against the previous 30 minutes, so it fires immediately. It is created **disarmed** and armed by `cg open` |
| Billing looks like zero while spending | Credits are booked as a matching negative line; without filtering to `RECORD_TYPE=Usage` every figure nets out |

## Caveats

- **Anti-cheat.** Many competitive multiplayer titles use kernel-level anti-cheat that refuses
  to run on Linux or in virtualised environments. Single-player and Proton-friendly titles are
  generally fine; check ProtonDB for specific games.
- **The L4 is a datacenter GPU**, not a gaming card. It runs games well but has lower clocks
  than a comparable GeForce part. Measured with Black Myth: Wukong at 1080p: **High preset plays
  smoothly** (GPU 83%, 67 W of its 72 W TDP, 81°C), Very High starts to judder. NVENC encoding
  costs almost nothing - the encoder sat at **2%** while the stream ran - and the CPU was a third
  idle, so the GPU is the limit, which is the right shape.
- **Tested on one setup only**: Ubuntu 24.04 on `g6.xlarge` in `ap-south-2`, streamed to an
  Arch-based Linux client. Other regions, instance types and clients should work but are
  unverified.
