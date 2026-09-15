# What it costs

Every charge this rig can run up, measured where possible, and why spot is the default. How the
guards keep those charges bounded is in [cost-guards.md](cost-guards.md).

## What things cost

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
IAM, the Pricing API (where the S3 per-GB figure comes from), CloudWatch metrics
(1M requests free), AWS Budgets (first two free), and the Free Tier API.

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
    COST GUARDS  the budget, and whether its alert emails are configured
    LOCAL        tailscale, moonlight, ssh key, auth key, tailnet node

Run it before a build to see what is missing, and after one to check the guards actually
armed - `budget alerts` in particular, since a budget with no subscribers looks fine until the
day you need it.

## Spot is the default

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

That is only acceptable because the games are in S3: destroying costs a 10-20 minute rebuild
and nothing else. Under the old EBS-volume design, `stop` was the only way to keep a library without
paying for an instance, which is exactly why the old design used a persistent request.

**The guards terminate now, not stop.** They previously had to issue a stop, because a persistent request
relaunches on termination and none of them can cancel a request first. Every guard firing
therefore stranded a box at ~INR 400/month. A one-time request cannot relaunch, so they
terminate, and `cg status` / `cg watcher` flag any stranded box left over from the old design
with its monthly cost.

If you want stop/start back, run on demand: `GAME_SPOT=0 cg init`. Dearer per hour, restartable
as often as you like, and there the guards still stop rather than terminate.
