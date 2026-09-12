# How it connects

Three independent layers. Understanding the split is what makes failures diagnosable - almost
every problem belongs to exactly one of them.

```
your machine                         AWS
┌──────────────┐                    ┌──────────────────┐
│ moonlight    │                    │ Sunshine         │
│  ↕ decode    │                    │  ↕ NVENC (L4)    │
│ 100.x.x.x    │◄── WireGuard ────► │ 100.x.x.x        │
│              │  UDP 41641 direct  │ Xorg :0 (virtual)│
└──────────────┘      ~16ms         │ XFCE autologin   │
                                    └──────────────────┘
```

## 1. Tailscale is the network

Both machines run `tailscaled` and authenticate to Tailscale's coordination server, which acts
as a matchmaker: it hands each peer the other's public key and current endpoint, then steps
aside while they build a direct WireGuard tunnel.

Each machine gets a stable `100.x` address. **That address is the box, permanently.** It
survives the AWS public IP changing on every stop/start, which is exactly why this design needs
no Elastic IP - and AWS bills idle public IPv4, so avoiding one matters.

The security group has exactly **one** inbound rule: UDP 41641. Sunshine's own ports are not
reachable from the internet at all. Everything reaches them *through* the tunnel, which is why
you address the box by its `100.x` address and never its public IP.

That single rule is not optional. Tailscale is outbound-only for connectivity, but it must be
able to *receive* UDP to negotiate a direct path. Without the rule it still works - by falling
back to a DERP relay, at 43-71 ms instead of 16 ms. It never errors; it just feels sluggish.

## 2. Sunshine captures a desktop nobody is sitting at

The L4 is a datacenter GPU with **no display outputs**, so there is no monitor for X to attach
to. `xorg.conf` tells the NVIDIA driver to start anyway with
`AllowEmptyInitialConfiguration`, against a virtual 2560x1600 screen. LightDM auto-logs in so
an XFCE session actually exists to capture.

Sunshine encodes that session with the L4's NVENC hardware encoder and serves it. Two settings
matter:

- `packet_size = 1024`, because Tailscale's MTU is 1280 and Sunshine defaults to 1392. The
  mismatch fragments packets and reads as stutter.
- `csrf_allowed_origins`, because Sunshine's web UI trusts only `localhost` by default and
  rejects every request arriving over the tailnet.

## 3. Moonlight decodes it

Pairing swaps certificates - that is what the challenge/secret handshake does, and why it is
one-time and survives stop/start. Video comes down as H.265 and is decoded in hardware on the
client; input goes back up the same tunnel.

`global_prep_cmd` runs `set-resolution.sh` on connect, which uses `xrandr` to match the
desktop to whatever the client asked for. That is what lets one machine serve a phone, a
tablet and a laptop without reconfiguration.

## Storage

Two disks, deliberately:

- **Root EBS volume** (default 50 GB) - the OS, drivers, Sunshine, Steam client, Tailscale
  identity. Persists across stops. Bills whether or not the instance runs, and **cannot be
  shrunk once grown**.
- **Instance store** (232 GB on `g6.xlarge`) mounted at `/scratch` - games, downloads, shader
  caches. Free, local NVMe, much faster than EBS. **Wiped on every stop**, filesystem included,
  so it is reformatted at each boot.

- **S3 bucket** (`cg-library-<hash>`) - the durable copy of the game library. Regional, so it
  pins no availability zone, and ~INR 310/month for 140 GB against INR 1,284 for the EBS volume
  it replaced.

`/scratch/steam` is registered as a Steam **library folder**, so the client persists on the
root volume while games do not. This is why the root volume stays clean no matter what you
install.

The instance store being wiped on stop is survivable only because of the S3 mirror, which is a
fourth thing that has to be right:

- `cg-library-restore.service` pulls at boot, started at the **top** of the build with
  `--no-block` so a ~10 minute restore overlaps the ~10 minute NVIDIA driver install rather
  than following it. The readiness marker is ordered after it.
- The **explicit push** runs from `lib/game`'s `down()` - reached by `cg stop`, by the "stop
  instance now?" prompt at the end of `cg open`, and by the pre-image stop in destroy - and from
  `cg destroy`. Both gate on it: a failed push aborts the stop or the destroy rather than
  warning beside it.
- `cg-library-shutdown.service` pushes from `ExecStop`. This is the layer that makes the
  **automatic** stops safe: layers 2, 3 and 4 all stop the box without anyone typing a command,
  and all three end in a graceful OS shutdown, so all three arrive here.
- There is **no periodic timer**, by choice - nothing uploads while you are playing. The
  remaining exposure is a stop that is not graceful: a spot interruption gives about two minutes,
  a hard power-off gives none.

The box reaches S3 through an **EC2 instance role**, not an access key: it is the one machine
here that can borrow an identity from AWS, so there is no secret to leak or rotate. The role is
scoped to that single bucket. The off-site watchdog still uses a long-lived key because it runs
outside AWS and has no role to borrow.

## Where cost control sits

Four layers, described in the main README. They are deliberately independent: layer 1 is the
`game` script, layer 2 runs on the box itself, layers 3 and 4 run in AWS. A failure in any one
is caught by the next.

The single most important setting is `instance-initiated-shutdown-behavior`, and **its correct
value depends on the purchase model.** The on-host watchdog acts by running `shutdown -h`, so
this attribute decides what that means:

| Purchase model | Value | Why |
|---|---|---|
| on demand | `stop` | A misfiring watchdog parks the box; you restart it. `terminate` would delete the machine and its root disk. |
| spot (one-time) | `terminate` | A *stopped* spot instance can never start again - the stop disables its request - and would bill for its root volume forever. Terminating is safe because a one-time request cannot relaunch. |

This inverted when the games moved to S3. The old design used a **persistent** spot request with
`InstanceInterruptionBehavior=stop`, because the library lived on the instance store and
terminating meant losing it. That had two consequences:

- a persistent request **relaunches** the moment its instance is terminated, so nothing could
  terminate the box without cancelling the request first - and no guard can do that (the on-host
  watchdog holds no credentials at all, and a CloudWatch alarm action cannot cancel a request)
- so all three guards had to *stop*, and every one of them therefore produced a box that could
  never start again while its 50 GB root volume kept billing ~INR 400/month

With the library in S3 there is nothing on the instance worth preserving, so the request is now
**one-time** and every guard terminates. The alarm action, the off-site watchdog's verb, and the
shutdown behaviour all follow the lifecycle rather than being fixed - and `lib/aws-setup.sh`
asserts the one that matches, where it previously demanded `stop` unconditionally and then
excused spot with "cannot be modified after", which meant that check could never protect a spot
instance at all.
