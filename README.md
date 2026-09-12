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
> they are software and software fails. `./setup` creates an **AWS Budget** that emails you,
> and `./setup cost` shows what you have actually spent - check it. No warranty, see
> [LICENSE](LICENSE).
>
> Two things the guards do *not* catch. The root volume bills **even while the instance is
> stopped**, so stopping is not free - only `./setup destroy` reaches zero. And **egress is
> billed but not counted** by `./setup cost`; streaming can cost as much again as the instance.

---

## Quickstart

    git clone git@github.com:jebin2/aws_cloud_gaming.git
    cd aws_cloud_gaming
    cp .env.example .env      # edit: Tailscale key, alert email, region
    ./cg init

`./setup` checks every prerequisite before it spends a cent and tells you exactly what is
missing. It provisions the instance, arms the cost guards, installs the watchdog, and hands you
a pairing URL. After that, `./game` is the whole workflow.

Use `./setup check` to run every check and stop before anything is created.

The build takes 10-20 minutes and streams its progress, so a slow step looks slow rather than
hung:

    ==> building the box - live progress below (10-20 min)
        installing base packages
        installing desktop (several minutes)
        installing nvidia driver (the slowest step, ~10 min)
        (host rebooting - reconnecting)
        build complete (17m)

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
  a *separate* quota (`L-3819A6DF`); approval of one says nothing about the other.

And locally:

- **Tailscale**, installed and up (`sudo tailscale up`), plus a
  [pre-auth key](https://login.tailscale.com/admin/settings/keys)
- **Moonlight** (`moonlight-qt`) - only needed to stream, so `setup` warns rather than stops
- `aws` CLI v2 configured, `python3`, `curl`, and OpenSSH (`ssh`/`scp`)

#### AWS credentials

If `aws configure` has already been run, nothing to do. Otherwise the console hands you an
access key as a **`.csv` download** rather than something you can paste, so `setup` accepts it
directly:

    AWS_KEY_CSV=~/Downloads/CLI_accessKeys.csv ./setup

With no path given it looks for one in your home directory and offers to import it. It picks
the first file that actually *parses* rather than the first matching name - the console also
issues a `*_credentials.csv` containing a sign-in **password** and no access key, and choosing
by filename would grab that instead.

**Delete the .csv once imported.** It is a plaintext secret, and anyone who reads it has your
account. `*.csv` is gitignored here so a stray copy in the repo cannot be committed, but that
does not help it sitting in `~/Downloads`.

### Configuration

Everything lives in `.env` - see [.env.example](.env.example), which documents every variable.
`setup` prompts for the Tailscale key and alert email if they are absent, so the minimum is a
working AWS profile and a Tailscale account.

## Commands

`cg` is the front door. It dispatches into `setup` and `game`, which both keep working - the
odd-looking lines in those scripts are scars from real failures, so `cg` calls them rather than
reimplementing them.

| Command | What it does |
|---|---|
| `cg init` | Build everything; reuses an existing box. **Costs money** |
| `cg open` | Start, stream, stop on exit. **Costs money** |
| `cg stop` | Stop the instance - ends hourly billing |
| `cg status` | Instance, disks, guards, tailnet, local tools |
| `cg snapshot` | Save an AMI of the box. **Bills monthly** |
| `cg snapshot --list` | What images exist and what they cost |
| `cg snapshot --delete <id>` | Delete an image **and its backing snapshots** |
| `cg clean` | Free space: apt caches, logs, `/scratch`. **Deletes installed games** |
| `cg destroy` | Delete everything. No confirmation |
| `cg check` | Every preflight check, creates nothing |
| `cg cost` | Month-to-date spend and what still bills |
| `cg log [what] [--watch]` | `build` \| `steam` \| `watchdog` \| `disk` \| `sunshine` |
| `cg ssh [cmd]` | Shell on the box - resolves the suffixed tailnet name for you |
| `cg watcher [--watch]` | All four guards, and whether each is genuinely armed |
| `cg ping [--watch]` | Latency, and **direct vs DERP relay** - the usual cause of a bad session |

`--region` and `--host` override `.env` without editing it; `--json` works on `ping` and
`snapshot --list`.

Deleting an image deregisters it **and** deletes its backing snapshots. Deregistering alone
leaves those billing - the usual way to believe you deleted something and keep paying for it.

### The underlying scripts

| Command | What it does | Run it twice? |
|---|---|---|
| `./setup` | Build everything: instance, desktop, guards, watchdog, Sunshine account, Moonlight pairing | Safe. Reuses the instance, skips what is done. **But it starts a stopped box, so it costs money.** |
| `./setup check` | Every preflight check, creates nothing | Safe, free, read-only |
| `./setup status` | Account, quotas, resources, guards, local tools | Safe, free, read-only |
| `./setup cost` | Month-to-date spend and what is still billing | Safe. Each run makes one Cost Explorer call ($0.01) |
| `./setup clean` | Frees space: apt caches, logs, `/scratch` | Safe. Needs the box **running**; frees less each time |
| `./setup rebuild` | Destroy and build fresh (~20 min) | Asks first. Each run is another full rebuild |
| `./setup destroy` | Delete **everything** - instance, disk, images, key, budget | **No confirmation, runs immediately.** Second run is a no-op |
| `./game` | Start if stopped, stream, offer to stop on exit | Safe. Connects again if already running |
| `./game stop` | Stop the instance - this is what ends the billing | Safe. Says "already stopped" |
| `./game status` | Instance state plus OS and NVMe usage | Safe, free, read-only |
| `./game clean` | Wipe `/scratch` - removes every installed game | Asks first. Needs the box running |
| `./game destroy` | Terminate the machine, optionally saving an image | Asks twice. Second run says "already terminated" |

`game` is for playing; `setup` is for administering the machine and its bill.

**The two that cost you money unprompted:** `./setup` starts a stopped instance, and `./game`
starts one too. Everything else is either read-only or asks first.

**The one that cannot be undone:** `./setup destroy` runs immediately with no confirmation and
keeps nothing. `./game destroy` is the gentler version - it asks, and offers to save an image
first.

## Everyday use

Run `./game`. It starts the instance if stopped, waits for Tailscale and Sunshine, arms the
idle alarm, and opens the stream. When you quit Moonlight it prints the session length and
asks `stop instance now? [Y/n]` - pressing Enter is what actually stops the billing.

Run it from a real terminal; that prompt needs one. A cold start takes 1-2 minutes.

Pairing is one-time and survives stop/start. On first run, open `https://<tailscale-ip>:47990`,
set a Sunshine username and password, then enter the PIN Moonlight shows. The self-signed
certificate warning is expected - the traffic is already encrypted by WireGuard before TLS
applies.

## Cost control

| # | Mechanism | Catches | Reaction |
|---|-----------|---------|----------|
| 1 | `game` script | normal use | on Moonlight exit |
| 2 | on-host watchdog | forgotten disconnect, client crash | 15 min idle |
| 3 | CloudWatch NetworkOut alarm | hung OS, dead watchdog | 30 min idle |
| 4 | AWS budget | everything else | email |

Worst-case leak with all four armed is about 30 minutes of runtime.

Layer 3 is armed by `game up` rather than at setup time, because a freshly created alarm is
evaluated against the previous 30 minutes and would otherwise stop the box mid-build - see
[docs/troubleshooting.md](docs/troubleshooting.md).

Layer 4 is an **AWS Budget**, not a CloudWatch `EstimatedCharges` alarm. That alarm needs
"Receive Billing Alerts" switched on by the *root* user, for which there is no API, plus an SNS
subscription every recipient must confirm by email. Miss either and it sits in
`INSUFFICIENT_DATA` forever - armed in appearance only, which is worse than no alarm. A budget
emails its subscribers directly and works the moment it is created.

### What things cost

Three separate charges, and the third surprises people.

**Per hour running.** `g6.xlarge` in `ap-south-2` is $0.9664/hr plus $0.005/hr for the public
IPv4 while it runs.

**Per month regardless.** A gp3 volume is $0.0912/GB-month: 50 GB is about **$4.50/month,
charged while the instance is stopped**. `GAME_DISK_GB` is the only lever, and it is far easier
to choose at launch than to resize later - EBS volumes cannot be shrunk.

**Per hour streaming.** Streaming video is data transfer out. At 20 Mbps you push ~9 GB/hour.
The first 100 GB/month is free - about 11 hours - and after that it is $0.1093/GB, or
**~$0.98/hr, roughly doubling the hourly cost**. Lowering Moonlight's bitrate lowers this
proportionally, and past a point saves more than any pricing plan will.

Check actual spend with `./setup cost`, which measures runtime from CloudWatch datapoints
rather than billing data, so it has no lag. It reports **every** volume and snapshot, not just
the running instance's - orphaned volumes are the usual way people keep paying for a machine
they believe they deleted.

`./setup status` answers the other question - what state everything is in:

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

Roughly a quarter of the price ($0.23/hr against $0.97 when measured), at the cost of AWS being
able to reclaim the instance with two minutes' notice. Since games live on ephemeral storage
that a stop wipes anyway, a reclaim costs about what a normal stop does.

Spot needs **its own quota** (`L-3819A6DF`), separate from on-demand and **0 on a new
account** - so with `GAME_SPOT` unset, `setup` prefers spot and falls back to on-demand when
the quota cannot cover the instance, logging that it did. Force either one explicitly:

    GAME_SPOT=0 ./setup      # on-demand, whatever the quota says
    GAME_SPOT=1 ./setup      # spot, fail loudly if the quota is short

Savings Plans and Reserved Instances are the wrong tool here: they commit you to a yearly $/hr
spend whether you use it or not, and only pay off above roughly 15 hours of use *per day*.

## Games live on ephemeral storage, on purpose

The instance ships local NVMe (232 GB on `g6.xlarge`) that costs nothing extra and is far
faster than EBS. `/scratch/steam` is registered as a **Steam library folder**, so the install
dialog offers it alongside the root disk and reports its real free space. Firefox downloads
there too, so the root volume stays clean whatever you install.

Pick the NVMe library the first time you install a game - Steam remembers the choice.

The trade: `/scratch` is wiped on every *stop*, filesystem included. Every session starts with
no games installed. Re-downloading is not slow - Steam's CDN measured **62 MB/s** from the
instance, so about 8 minutes for a 30 GB game and 35 for a 130 GB one.

Game storage therefore costs **nothing, ever**, at the price of a wait when you sit down to
play. If you would rather not wait, attach a persistent EBS volume for a game library instead.

**Anything you want to keep must live outside `/scratch`, including Firefox downloads.**

## Layout

    cg                 the front door - every command
    setup, game        what cg dispatches into
    lib/               provisioning and cloud-init internals
    host/              units deployed to the instance (watchdog, disk monitor)
    tests/             offline tests for the fiddly host-side logic
    docs/              architecture and troubleshooting

`./tests/steam-library.sh` checks the Steam library registration - the part that has broken
most often - against a faked Steam install, so it can be verified without spending a build.

## Further reading

- [docs/architecture.md](docs/architecture.md) - how the three layers fit together
- [docs/troubleshooting.md](docs/troubleshooting.md) - every failure hit while building this,
  and why the fix works. Read this before debugging anything.

## Caveats

- **Anti-cheat.** Many competitive multiplayer titles use kernel-level anti-cheat that refuses
  to run on Linux or in virtualised environments. Single-player and Proton-friendly titles are
  generally fine; check ProtonDB for specific games.
- **The L4 is a datacenter GPU**, not a gaming card. It runs games well but has lower clocks
  than a comparable GeForce part.
- **Tested on one setup only**: Ubuntu 24.04 on `g6.xlarge` in `ap-south-2`, streamed to an
  Arch-based Linux client. Other regions, instance types and clients should work but are
  unverified.
