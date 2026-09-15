# Architecture

A Linux desktop with a GPU, built on AWS when you want to play and destroyed when you stop. You
reach it only through a private Tailscale network, stream it with Moonlight, and keep your games
in S3 between sessions.

## The big picture

**How you connect.** Everything goes through one encrypted Tailscale tunnel; the box has no other
way in.

```mermaid
flowchart LR
  subgraph laptop["💻 Your laptop"]
    ml["Moonlight"]
    cg["cg CLI"]
  end

  tunnel(["🔒 Tailscale tunnel<br/>WireGuard · UDP 41641"])

  subgraph box["🖥️ EC2 g6.xlarge · NVIDIA L4"]
    sun["Sunshine<br/>X11 capture → NVENC"]
    desk["XFCE desktop<br/>Steam + Proton"]
    sshd["ssh"]
  end

  ml -->|"video down · input up"| tunnel
  cg -->|"commands"| tunnel
  tunnel --> sun
  tunnel --> sshd
  sun --- desk
```

**What runs where.** The box is disposable; S3 keeps your games, and a cloud watchdog
terminates a box nobody is using.

```mermaid
flowchart LR
  cg["💻 cg on your laptop"]
  ec2["🖥️ EC2 box<br/>one-time spot · ap-south-2"]
  s3[("🪣 S3<br/>games + Steam login")]
  bud["💰 AWS Budget"]
  lam["⚡ Lambda<br/>cloud watchdog"]

  cg -->|"launch · terminate"| ec2
  ec2 <-->|"restore at boot<br/>push on destroy"| s3
  lam -.->|"terminate if idle"| ec2
  lam -.->|"delete after 14 days<br/>with no box"| s3
  bud -.->|"email"| cg
  ntfy(["📱 ntfy · your phone"])
  lam -.->|"notifications"| ntfy
  ec2 -.->|"notifications"| ntfy
```

The other guard, a watchdog on the box itself, is in [Flow 4](#flow-4---you-forget-the-box).
Nothing on the box is reachable from the internet: the security group allows one inbound port,
UDP 41641, and that is Tailscale's.

## The stack

| Layer | Uses | Runs on | Why this |
|---|---|---|---|
| Control | `cg` (bash) and `lib/`, tested offline in `tests/` | laptop | one command per job; risky paths proven with stubs |
| Compute | EC2 `g6.xlarge` - 4 vCPU, NVIDIA L4 | AWS `ap-south-2` | the only GPU type there that fits a 4 vCPU quota |
| Purchase | one-time spot, terminated on shutdown | AWS | ~INR 20/hour against ~INR 85 on demand |
| Build | Ubuntu 24.04, configured by user-data in 16 stages (`lib/bootstrap.d/`) | box | a clean box every session, no image to maintain |
| Network | Tailscale (WireGuard); one security-group rule | laptop + box | no public ports, no Elastic IP |
| GPU | NVIDIA driver 610 (open), DRM KMS off | box | KMS on blocks screen capture |
| Display | headless Xorg at a fixed 1920x1080, LightDM autologin, XFCE | box | the L4 has no monitor outputs |
| Streaming | Sunshine: X11 capture, NVENC encode, `packet_size 1024` | box | Tailscale's MTU is 1280 |
| Client | Moonlight | laptop, phone | hardware decode on the device |
| Audio | PipeWire with a virtual sink | box | there is no sound card to play into |
| Games | Steam (Valve's `.deb`) and Proton | box | Windows games on Linux |
| Game storage | local NVMe at `/scratch`, archived per game to S3 with `s5cmd` | box + S3 | fast and free locally, durable in S3 |
| S3 access | EC2 instance role | box | no access key on the box to leak |
| Guards | on-host watchdog, cloud watchdog (Lambda + EventBridge), AWS Budget | box, AWS | two independent ways to stop a forgotten box, and an email |
| Notifications | ntfy (optional, `GAME_NTFY_URL`) | box, Lambda, laptop | push to a phone with no account and nothing to confirm |
| Spend | Cost Explorer (for `cg cost`) | AWS | the only billed API here, $0.01 a call |

## Where things live

```mermaid
flowchart TB
  subgraph box["🖥️ EC2 box - deleted by cg destroy"]
    root["Root EBS · 50 GB gp3<br/>Ubuntu · NVIDIA driver<br/>Sunshine · Steam client<br/>Steam login"]
    nvme["Local NVMe · /scratch<br/>229 GB<br/>games · shader caches<br/>downloads"]
  end
  s3[("S3 · cg-library-…<br/>one archive per game<br/>index.json<br/>steam-account.tgz")]
  nvme <-->|"pull at boot<br/>push on destroy"| s3
  root -->|"Steam login<br/>archived on push"| s3
```

| | Lives on | Survives `cg destroy`? |
|---|---|---|
| OS, driver, Sunshine, Steam client | root EBS | no - rebuilt by the next `cg init` |
| Your games, their saves and shader caches | NVMe, archived to S3 | **yes**, in S3 - deleted after 14 days with no box ([why](cost-guards.md#game-archive-expiry)) |
| Steam login | root EBS, archived to S3 | **yes**, in S3 |
| Proton and the Steam runtime | NVMe | no - Steam re-downloads them in under a minute |
| Security group, key pair, budget | AWS | **yes** - free, reused |

The root disk size is `GAME_DISK_GB`: 100 GB by default, set to 50 here in `.env`. The NVMe is
wiped whenever the instance stops, which is why S3 holds the durable copy. Details:
[game-library.md](game-library.md).

## Flow 1 - `cg init`: build a box

```mermaid
sequenceDiagram
  autonumber
  actor You
  participant cg as cg (laptop)
  participant AWS
  participant EC2 as EC2 box
  participant S3
  participant TS as Tailscale API

  You->>cg: ./cg init
  cg->>AWS: is the cloud watchdog current? arm or repair it
  cg->>You: which archived games to restore?
  cg->>AWS: preflight - plan, GPU quota, region
  cg->>TS: prune offline nodes of earlier boxes
  cg->>AWS: budget, bucket and role, launch one-time spot with user-data
  EC2->>EC2: install Tailscale, join the tailnet
  cg->>TS: turn off key expiry for the new node
  EC2->>S3: start restoring games in the background
  EC2->>EC2: desktop, NVIDIA driver, Xorg, Steam, Sunshine
  S3-->>EC2: games and Steam login land on the NVMe
  EC2->>EC2: reboot for the driver, restore resumes
  cg->>EC2: follow the build log over ssh
  cg->>EC2: create the Sunshine account, pair Moonlight
  cg-->>You: summary - box, games, Steam login, guards (10 to 20 min)
```

The game restore runs **alongside** the build, so a 160 GB game is usually on disk by the time
the desktop is. The box is only reported ready once the restore has finished.

## Flow 2 - `cg open`: play

```mermaid
sequenceDiagram
  autonumber
  actor You
  participant cg as cg (laptop)
  participant EC2 as EC2 box

  You->>cg: ./cg open
  cg->>EC2: wait for Tailscale and Sunshine
  cg->>EC2: moonlight stream Desktop
  You->>EC2: play - video down, input up, over WireGuard
  You->>cg: quit Moonlight
  cg-->>You: [d] destroy (recommended) or [n] leave it running
```

On a spot box there is no stop, only destroy - a stopped one-time spot instance can never start
again. With `GAME_SPOT=0` the box is on demand, and `cg open` starts it if it is stopped.

## Flow 3 - `cg destroy`: save and delete

```mermaid
sequenceDiagram
  autonumber
  actor You
  participant cg as cg (laptop)
  participant EC2 as EC2 box
  participant S3
  participant AWS

  You->>cg: ./cg destroy
  cg->>EC2: cg-library push (ssh)
  EC2->>S3: Steam login
  EC2->>S3: changed game files only
  cg->>AWS: cancel the spot request, terminate the instance
  EC2->>S3: shutdown push - nothing left to send
  AWS-->>cg: terminated, root disk deleted
  Note over cg,AWS: Kept for next time - S3 archive (14 days with no box),<br/>budget, security group, key pair
```

If the push fails, `cg destroy` stops and deletes nothing. What it removes and keeps:
[destroy.md](destroy.md).

## Flow 4 - you forget the box

```mermaid
flowchart TB
  idle["Box left running<br/>with no traffic"]

  idle --> g2["On-host watchdog<br/>checks every minute<br/>15 idle minutes<br/>under 200 KB/min"]
  idle --> g4["Cloud watchdog<br/>Lambda, every 5 min<br/>30 idle minutes<br/>in + out under 10 MB"]

  g2 --> p2["push games to S3<br/>then shutdown -h"]
  g4 -->|"its own IAM role"| api["AWS terminates the instance"]

  p2 --> os["Graceful OS shutdown"]
  api --> os
  os --> push["cg-library-shutdown.service<br/>pushes games to S3<br/>up to 30 minutes"]
  push --> gone["Instance terminated<br/>games safe in S3"]
  push -.->|"still stuck<br/>after 1 hour"| force["Cloud watchdog forces it<br/>skipping the OS shutdown"]
  force -.-> gone

  bud["AWS Budget · $57 a month"] -.->|"email at 80% spent<br/>and 100% forecast"| you["You"]
```

Both guards end in the **same place**: a graceful OS shutdown, where
`cg-library-shutdown.service` pushes the games to S3 before the machine goes down. The on-host
watchdog also pushes before it calls `shutdown`, so its shutdown push finds nothing left to send;
the cloud watchdog runs outside the box and can only ask AWS to terminate it, which AWS turns into
that same graceful shutdown. Two pushes never run at once - a second one waits for the first.

The shutdown push is allowed 30 minutes (`TimeoutStopSec=1800`). When AWS itself terminates the
box it may cut the power sooner than that, and a spot interruption gives only two minutes, so
`cg destroy` - which pushes first and deletes nothing if that fails - stays the safe way out.

Each guard is independent, so one failing is caught by the other. Both wait 20 minutes after
boot before they arm, so a build is never mistaken for idleness. A box still going down an hour later -
whichever guard started it - is forced by the cloud watchdog. The budget stops nothing - it is the
backstop that tells you. Details: [cost-guards.md](cost-guards.md).

## Flow 5 - nobody plays for two weeks

```mermaid
flowchart TB
  tick["Cloud watchdog<br/>once an hour"] --> off{"GAME_ARCHIVE_EXPIRY_DAYS<br/>set to 0?"}
  off -->|yes| forever["Kept forever"]
  off -->|no| box{"A gamevps box exists?<br/>running or stopped"}
  box -->|yes| stamp["Kept<br/>last-seen mark set to now"]
  box -->|no| bucket{"S3 size metric:<br/>an archive?"}
  bucket -->|no| none["Nothing to do"]
  bucket -->|yes| mark{"Last-seen mark<br/>in SSM"}
  mark -->|missing| start["Kept<br/>counting starts now"]
  mark -->|under 14 days old| count["Kept<br/>countdown in cg status"]
  mark -->|14 days or older| trail{"CloudTrail: a gamevps<br/>launch in 14 days?"}
  trail -->|yes| moved["Kept<br/>mark moves to that launch"]
  trail -->|no| again{"One last look:<br/>a box now?"}
  again -->|yes| kept["Kept"]
  again -->|no| del["Empty and delete<br/>the S3 bucket"]
  del --> next["Next cg init: empty bucket,<br/>Steam downloads games,<br/>sign in to Steam again"]

  err["Any error, gap or<br/>unreadable answer"] -.->|"stops the check"| safe["Kept - nothing deleted"]
```

With no box, the S3 archive is the only thing still billing, so it is deleted after 14 days
unused. That deletes the only copy of every game, so both records must agree first - the mark the
watchdog keeps fresh while a box exists, and CloudTrail's launch history - and anything uncertain
keeps it. Until it deletes, it makes no S3 request at all: its marks are free SSM parameters, and
whether there is an archive comes from S3's free daily size metric. `cg watchdog check` runs every
step as a dry run. Details, and what is lost:
[cost-guards.md](cost-guards.md#game-archive-expiry).

## Notifications - what reaches your phone

```mermaid
flowchart LR
  subgraph box["🖥️ EC2 box"]
    ohw["On-host watchdog"]
    sp["Shutdown upload"]
  end
  subgraph aws["☁️ AWS"]
    ev["EventBridge<br/>EC2's own events"]
    lam["⚡ Cloud watchdog"]
  end
  cg["💻 cg init"]
  ntfy(["🔔 ntfy topic"])
  phone["📱 Your phone"]

  ev -->|"box gone<br/>spot warning"| lam
  lam -->|"idle box ended · slow or stuck shutdown<br/>archive expiring · watchdog failing"| ntfy
  ohw -->|"idle shutdown<br/>upload hanging"| ntfy
  sp -->|"upload failed<br/>or cut off"| ntfy
  cg -->|"box ready<br/>build failed"| ntfy
  ntfy --> phone
```

Off unless `GAME_NTFY_URL` is set. A notification is never load-bearing: one that cannot be sent
is logged and ignored, and it never changes what a guard decides. The box cannot report its own
end, so "box gone" comes from EC2's own events rather than from the box. None of it costs
anything - EC2's events, the extra invocations and the requests are all inside AWS's free
allowances. The full list: [cost-guards.md](cost-guards.md#notifications).

## Key decisions

- **Tailscale is the only way in.** Each machine gets a stable `100.x` address that survives the
  AWS public IP changing, so there is no Elastic IP to pay for. The single inbound rule, UDP 41641,
  is what lets Tailscale build a direct path: without it, traffic falls back to a relay at
  43-71 ms instead of 16 ms, and nothing errors - it just feels slow.
- **A monitor that does not exist.** The L4 has no display outputs, so `xorg.conf` starts X with
  `AllowEmptyInitialConfiguration` and a virtual `DFP-0` at a fixed 1920x1080. LightDM logs in
  automatically so there is a desktop to capture.
- **The resolution never changes.** Switching the X mode at runtime left capture broken for every
  later session, so the box stays at 1920x1080 and Moonlight scales. See
  [streaming.md](streaming.md).
- **X11 capture, GPU encode.** NvFBC is NVIDIA's fast capture path, but it failed after the first
  session on this box. X11 capture grabs frames on the CPU - about one core at 1080p60 - while
  encoding still runs on the L4's NVENC.
- **Sunshine tuned for the tunnel.** `packet_size = 1024` because Tailscale's MTU is 1280 and
  Sunshine's default of 1392 fragments into stutter; `csrf_allowed_origins` so its web UI accepts
  requests from the tailnet.
- **Games on local NVMe, kept in S3.** The instance store is the fastest disk on the box and free,
  and S3 pins no availability zone. It replaced an EBS volume costing INR 1,284 a month. See
  [game-library.md](game-library.md).
- **One-time spot that terminates.** With the games in S3 there is nothing on the box worth
  keeping, so every guard terminates rather than stops:

  | Purchase model | On shutdown | Why |
  |---|---|---|
  | on demand (`GAME_SPOT=0`) | `stop` | a misfiring watchdog parks the box and you restart it |
  | spot (default) | `terminate` | a stopped spot box can never start again, and its root disk would bill forever |

- **Roles, not keys.** The box reads and writes its bucket through an instance role, and the
  cloud watchdog runs on a Lambda role allowed only to describe, stop or terminate the
  `gamevps`-tagged instance. Nothing holds a long-lived AWS secret. See
  [cost-guards.md](cost-guards.md).

## Go deeper

| Want to know | Read |
|---|---|
| How to get an AWS account able to launch this | [aws-account-setup.md](aws-account-setup.md) |
| Every command | [commands.md](commands.md) |
| What each piece costs | [cost.md](cost.md) |
| How the games and Steam login persist | [game-library.md](game-library.md) |
| Why something is built the way it is | [troubleshooting.md](troubleshooting.md) |
