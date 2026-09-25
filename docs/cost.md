# What it costs

Every charge this rig can run up, measured where possible, and why spot is the default. How the
guards keep those charges bounded is in [cost-guards.md](cost-guards.md). Prices are for
`ap-south-2`, read from the AWS Pricing API on 2026-09-15; INR at 88 to the dollar.

## What things cost

Five separate charges. The third surprises people.

**Per hour running.** A spot `g6.xlarge` - the default - was **$0.19-0.21/hr** across the two
zones on 2026-09-15, and measured on a real bill at **INR 19.8/hr**. Spot prices move; on-demand
is a fixed **$0.9664/hr (INR 85)**. Either way add $0.005/hr for the public IPv4.

**Per hour the root volume exists.** gp3 is $0.0912/GB-month. `GAME_DISK_GB` defaults to
**50 GB: about $4.56/month (INR 400), or $0.0063/hr**. A spot box deletes its volume
with the box, so this bills only while it exists. An on-demand box keeps its volume **while
stopped**, so a stopped box bills the full month. EBS volumes cannot be shrunk, so choose the size
at launch.

**Per hour streaming.** Streaming video is data transfer out. At 20 Mbps you push ~9 GB/hour.
The first 100 GB/month is free - about 11 hours - and after that it is $0.1093/GB, or
**~$0.98/hr (INR 86)**. That is about what an on-demand box costs per hour, and **about five times
a spot box**, so past the free 100 GB it is the biggest charge. Lowering Moonlight's bitrate lowers
it proportionally.

**Per month, even with no box.** The game archive in S3 is $0.025/GB-month: a 160 GB game is
about **$4/month (INR 350)**, and it is the one thing that keeps billing after `cg destroy`. After
**14 days with no box, the cloud watchdog deletes it** - games, the saved Steam sign-in, and saves
of games without Steam Cloud. `GAME_ARCHIVE_EXPIRY_DAYS` sets the days, and `0` turns deletion
off. How it decides: [cost-guards.md](cost-guards.md#game-archive-expiry).

**Per request.** Two kinds of request bill; everything else this project calls is free.

- **Cost Explorer, $0.01 per request.** `cg cost` is the only command that makes one, so it costs
  about INR 0.88 to run. Measured on a real month:

      AWS Cost Explorer     25 requests    $0.25   (INR 22)

- **S3 requests: $0.005 per 1,000 PUT/LIST and $0.004 per 10,000 GET.** Measured over two days of
  pushing a ~140 GB game:

      2026-09-12   73,345 PUT/LIST   119,925 GET    $0.415  (INR 37)
      2026-09-13   52,304 PUT/LIST    26,550 GET    $0.273  (INR 24)

  About **INR 25 per full push** of a 140 GB game. An incremental push where nothing changed is
  near-free, because `--size-only` skips every matching file and the cost is mostly the LIST calls
  `sync` uses to compare. The count is high relative to the file count because of multipart: at
  `--part-size 16` MiB a large `.pak` becomes thousands of separate PUTs. Raising part-size would
  cut that roughly fourfold and multiply s5cmd's memory the same way, which is the trade that
  caused an OOM once - not worth INR 15 a push.

**Free at this volume:** EC2 describe/run/terminate, STS, IAM, the Pricing API, the Free Tier API,
AWS Budgets (the first two budgets), CloudWatch metrics (1 million API requests a month), and
everything the cloud watchdog uses - Lambda (1 million requests), EventBridge schedules and EC2
events, CloudWatch Logs (5 GB), SSM Parameter Store standard parameters, and CloudTrail's 90-day
event history. The Tailscale API and ntfy.sh are outside AWS and free.

**Data transfer between S3 and EC2 in the same region really is free**, in both directions:
`DataTransfer-In-Bytes` and `DataTransfer-Out-Bytes` both bill $0.000 across every push and
restore so far. The upload and the restore cost requests and nothing else.

## Seeing what you spend

`cg cost` is the authoritative view. Its **billed so far** section is Cost Explorer, broken down by
usage type: the real charges, but about a day behind. Above that, a **not yet billed** estimate
has no lag, because it counts CloudWatch's hourly datapoints for the current instance. That
estimate covers only the box that exists now: on a rig where every session is a new box, it
misses the month's earlier sessions. `cg cost` also lists **every** volume and snapshot, not just
the running instance's - orphaned volumes are the usual way people keep paying for a machine they
believe they deleted.

`cg cost`'s resources block also shows what the game archive costs a month and when the cloud
watchdog will delete it, from the watchdog's last decision - so the deadline is in front of you
while you are looking at the money.

`cg cost --daily` breaks the month into one row per day, with a column for each kind of charge -
compute, S3, disk, egress, API and everything else - plus the hours a box ran that day. Days with
nothing billed are left out and counted at the end. It asks Cost Explorer for daily figures and
renders the monthly summary from that same answer, so it costs the same $0.01 as `cg cost`:

    DATE          HRS  COMPUTE       S3     DISK   EGRESS      API    OTHER    TOTAL     INR
    2026-09-14    3.3     3.20     0.07        -        -     0.01        -     3.28     289
    2026-09-16    2.0     0.42        -     0.05        -        -     0.01     0.48      42

`cg status` shows traffic since the box booted, read straight off the interface counters - free,
and immediate:

    TRAFFIC (this boot only - see cg cost for the billed month)
      stream out      2.59 GB   avg 2.2 Mbps over 2.8 h
      total out       5.03 GB   <- what AWS bills (adds wireguard overhead, ssh, apt)
      total in      132.31 GB   (free - game downloads land here)
      (above is this boot only)
      monthly egress  9.3 GB used, ~91 GB of 100 GB free left  (as of 12 min ago)

Note the gap between the two "out" figures. Billed egress is what leaves the real NIC, so it
includes WireGuard overhead, ssh, and - measured at **~2.4 GB against a 132 GB download** - the
TCP acknowledgements a large download generates. Inbound is free, but it is not quite true that
downloading costs nothing.

The last line is the **month**, and it comes from Cost Explorer - the only place that knows it.
The box knows only its own boot, and every session is a new box, so subtracting boot counters
from a monthly allowance is wrong: it read "99 GB left" while Cost Explorer said 91. `cg status`
does not pay for a Cost Explorer call. It re-reads the figure `cg cost` last fetched, cached in
`.cg-cache/`, and stamps it with its age. Asking every time, 20 times a day, would be about
INR 530/month - more than the S3 archive it reports on.

`cg status` also answers the other question - what state everything is in:

    ACCOUNT      account id, plan type (a FREE plan cannot launch GPUs), credits
    QUOTAS       on-demand and spot GPU quota against what your instance type needs
    RESOURCES    instance, volumes, snapshots, images, elastic IPs, key pair,
                 security group and its inbound rules
    COST GUARDS  the budget, whether its alert emails are configured, and the game archive
    LOCAL        tailscale, moonlight, ssh key, auth key, tailnet node

Run it before a build to see what is missing, and after one to check the guards actually
armed - `budget alerts` in particular, since a budget with no subscribers looks fine until the
day you need it.

## Spot is the default

When `GAME_SPOT` is unset, `cg init` uses spot if your spot quota covers the instance, and
on-demand otherwise. Spot saves about **77%** on the box itself (INR 19.8 against 85 an hour,
measured). It shapes how the rig is used, because a spot instance here is **use-once**: there is
no stop, only destroy.

    cg init        build the box
    cg open        stream
    ...play...
    cg open's exit prompt  ->  [d] destroy (recommended)   [n] leave it running

Why there is no stop. A **one-time** spot request cannot be stopped at all - AWS only allows
stopping a *persistent* request's instance - and stopping a persistent one disables the request,
after which the box can never start again while its root volume keeps billing. Neither is a
useful "pause", so `cg stop` on a spot box offers destroy instead, and `cg open` refuses to
start a stranded one and explains why.

That is only acceptable because the games are in S3: destroying costs a rebuild and the S3
requests of the push, and nothing else. Under the old EBS-volume design, `stop` was the only way
to keep a library without paying for an instance, which is exactly why the old design used a
persistent request.

**The guards terminate now, not stop.** They previously had to issue a stop, because a persistent
request relaunches on termination and none of them can cancel a request first. Every guard firing
therefore stranded a box whose root volume kept billing. A one-time request cannot relaunch, so
they terminate, and `cg status`, `cg cost` and `cg watcher` flag any stranded box left over from
the old design with its monthly cost.

If you want stop/start back, run on demand: `GAME_SPOT=0 cg init`. Dearer per hour, restartable
as often as you like, and there the guards still stop rather than terminate.
