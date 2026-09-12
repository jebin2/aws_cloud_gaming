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

`/scratch/steam` is registered as a Steam **library folder**, so the client persists on the
root volume while games do not.
This is why the root volume stays clean no matter what you install.

## Where cost control sits

Four layers, described in the main README. They are deliberately independent: layer 1 is the
`game` script, layer 2 runs on the box itself, layers 3 and 4 run in AWS. A failure in any one
is caught by the next.

The single most important setting is `instance-initiated-shutdown-behavior=stop`. The on-host
watchdog stops the box by running `shutdown -h`; if that attribute said `terminate`, the
watchdog would **delete the machine and its disk** instead of parking it.
