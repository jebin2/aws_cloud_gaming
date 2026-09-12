# Everything that went wrong, and why

Real failures from building this, with the reasoning behind each fix. They are recorded because
the fix is rarely obvious from the code alone, and because most of them cost real money or
hours to diagnose.

## Getting a GPU instance to launch at all

### There are three independent gates, not one

1. **Service quota** - `Running On-Demand G and VT instances` (`L-DB2E81BA`), per region. Took
   three days to approve.
2. **Account plan** - a new-style AWS **Free Plan** account cannot launch GPU instances *at
   all*, whatever the quota says. `RunInstances` fails with `not eligible for Free Tier`,
   because the plan permits only free-tier-eligible *instance types*. Credits are irrelevant:
   they decide who pays, not what you may run. Check with
   `aws freetier get-account-plan-state`; it needs a Paid Plan.
3. **Spot quota** - `All G and VT Spot Instance Requests` (`L-3819A6DF`) is a *separate* quota
   that defaults to 0. Having on-demand approved tells you nothing; the launch fails with
   `MaxSpotInstanceCountExceeded`.

### `--dry-run` catches none of them

`run-instances --dry-run` validates permissions only. It reported "Request would have
succeeded" immediately before two different real failures. **A passing dry-run is not evidence
a launch will work.**

### Quota requests filed from the CLI are auto-denied

`aws service-quotas request-service-quota-increase` has no use-case parameter, so Service
Quotas files the case with the placeholder `This support case was created by Service Quotas`
and no justification. The spot request was refused on exactly that basis.

File quota requests through the console with a real use case. The strongest argument for a
spot increase is that on-demand quota is *already approved*, so it does not raise maximum
concurrent capacity - it only changes the purchase model.

### Region and instance type are not free choices

`ap-south-2` offers no `g4dn` at all, only `g6`/`g6e`, and `g6.xlarge` is the only one that
fits a 4 vCPU quota. Check `describe-instance-type-offerings` before assuming a type exists in
your region.

## Building the box

### Install Tailscale first, not last

Originally Tailscale was installed at the end of `bootstrap.sh`, after the driver and desktop.
When the script died partway there was no route in at all - and because the security group has
no SSH rule, recovering meant temporarily opening port 22 from the console.

Tailscale now installs **first**, so a failed build is still reachable.

### `--ssh` makes Tailscale worse, not better

`tailscale up --ssh` makes tailscaled **intercept port 22** on the tailnet interface. Without
an `ssh` section in the tailnet ACL those connections just hang - so the flag that looks like
it grants access actually removes it.

Dropped. Plain `sshd` over the tailnet works with the EC2 key and needs **no inbound rule at
all**, because tunnelled traffic is decapsulated inside the host and never passes the security
group. Recover an existing box with `sudo tailscale set --ssh=false`.

### Do not infer a dead script from CPU metrics

A near-zero CPU reading looked like a hang in the driver install. The driver had installed
fine; the script had died later, at the Sunshine download. Read the actual log
(`/var/log/cloud-gaming-bootstrap.log`) before concluding anything.

### Sunshine's release asset name embeds the version

There is no stable `latest/download/sunshine-ubuntu-24.04-amd64.deb`; the real name is
`sunshine_<version>-1+ubuntu24.04_amd64.deb`. Guessing it 404s. Resolve the URL from the
GitHub release API.

### Sunshine's systemd unit is not called `sunshine.service`

It is `app-dev.lizardbyte.app.Sunshine.service`. Glob for it rather than assuming, and enable
it by symlinking into `default.target.wants` - there is no user session to talk to at
cloud-init time, so `systemctl --user enable` does not work.

### Sunshine's CSRF protection blocks the tailnet

The web UI trusts only `localhost` and rejects every request arriving over Tailscale with a
CSRF error. Both the MagicDNS name and the raw IP must be listed, since the check is against
whatever you typed in the browser.

### `gamescope` does not exist on Ubuntu 24.04

It has no installation candidate, and apt fails the **entire transaction** over one missing
package - so it silently took `steam-installer` down with it and nothing installed. Steam's own
Big Picture covers the console UI.

Steam also prompts for EULA acceptance, which hangs cloud-init forever. Preseed it with
`debconf-set-selections`.

### `apt install steam` installs no Steam

Ubuntu's `steam-installer` is a **stub**. It ships no client: on first run its launcher puts up
a zenity licence dialog, and only after you click Install does it download the bootstrap. A
headless first boot cannot answer that dialog, so the launcher reported `Installation
cancelled` and left nothing behind - while `apt` had reported success and
`test -x /usr/games/steam` passed. Another case of a step that verifies its own execution
rather than its effect.

The first fix was to do by hand what the dialog does: read `version=` and `sha256=` out of
`/usr/games/steam`, download `steam_${VER}.tar.gz` from Valve's archive, check the digest,
unpack `bootstraplinux_ubuntu12_32.tar.xz`, and copy the icons out of the tarball. It worked,
but it was ~60 lines reimplementing a package.

**Use Valve's own `.deb` instead** -
`https://repo.steampowered.com/steam/archive/stable/steam_latest.deb`:

- it **ships** `/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz` inside the package, and its
  launcher extracts it with no prompt
- it has **no debconf templates at all**, so there is no EULA question to preseed
- it installs the real `hicolor` icons (16/24/32/48/256) system-wide, which is what makes the
  dock launcher show the Steam logo instead of a generic package icon
- it `Provides`/`Replaces` `steam-installer`, so it is a drop-in

One trap: Valve only **Recommends** `steam-libs-i386` / `steam-libs-amd64`, and on Valve's own
repo at that. Installing the bare `.deb` therefore leaves the 32-bit runtime out - and the
bootstrap client is 32-bit, so it will not start. Ubuntu carries the same package names in
multiverse; install them explicitly.

Install with `apt-get install -y ./steam_latest.deb`, not `dpkg -i` - the latter does not
resolve the package's dependency tree.

### `steamdeps` blocks the build on a dialog nobody can see

Swapping to Valve's `.deb` removed the zenity licence dialog and replaced it with a different
one. The launcher runs `steamdeps` unconditionally on every start, and `steamdeps` re-execs
itself into a terminal whenever `DISPLAY` is set:

    gnome-terminal --wait -t "Package Install" -- sh -c '...
      printf "\nPress return to continue: "; read line'

On a headless desktop nobody presses return, so the build froze at 74 MB with no error - the
same shape of failure, one layer further in.

Two fixes, both needed. Install the deps it asks for (`libc6:i386`, `libegl1:i386`,
`libgbm1:i386`, `libgl1-mesa-dri:i386`, `libgl1:i386`, `steam-libs-amd64`, `steam-libs-i386`,
and `libnvidia-gl-<driver>:i386` - derive that version from the installed driver, do not pin
it). Then `chmod -x /usr/bin/steamdeps`, because the launcher only logs and carries on when it
fails:

    if ! "$STEAMDEPS"; then log "Unable to install Steam dependencies ..."; fi

Removing the exec bit is therefore a clean permanent opt-out. Note the bootstrap runs under
`set -e`, so write it as `[[ -e X ]] && chmod -x X || true` - the bare form aborts the whole
build when the file is absent.

### The library was never registered on a fresh client

The real cause of "storage is showing internal only", and it outlived two earlier fixes.

Steam writes `config/libraryfolders.vdf` only after a user signs in. On a never-signed-in
client the file does not exist - and the registration loop guarded each file with
`[[ -f $F ]] || continue`, so it skipped both, wrote nothing, and the adoption pass then
adopted nothing. Every step "succeeded".

Seed the skeleton first, with the default library as entry `"0"`, then append `/scratch/steam`
as entry `"1"`.

### The library vanishes on the first stop/start

`/scratch` is reformatted at every start, which destroys
`/scratch/steam/steamapps/libraryfolder.vdf` - the marker Steam uses as proof a library is
real. The *entry* survives on the root volume, so Steam finds an entry with no marker and
prunes it: the NVMe library disappears silently and games go back to the 50 GB root disk.

`mount-scratch.sh` therefore recreates the marker on every boot, reusing the `contentid`
already recorded in `libraryfolders.vdf` so Steam sees the same library it adopted.

Verify without stopping the box:

    rm -f /scratch/steam/steamapps/libraryfolder.vdf
    sudo /usr/local/bin/mount-scratch.sh
    cat /scratch/steam/steamapps/libraryfolder.vdf   # same contentid as the vdf entry

### Why the library registration is an invariant, not an install step

It lived inside `steam-prewarm.sh`, behind the one-shot `~/.steam-prewarmed` marker. That was
wrong in a way that only shows up later: the registration has to keep holding after **every**
stop (which reformats `/scratch` and destroys the marker) and after the **first sign-in** (when
Steam rewrites `libraryfolders.vdf` from its own state and can drop an entry it does not
believe in). Behind a one-shot marker, a library that broke could never repair itself - and the
marker was set even when registration had failed, which nailed the door shut.

So it is now `steam-ensure-library.sh`, run by `steam-library.service` on every graphical boot,
and idempotent:

- if the vdf entry and the in-library marker exist **and their contentids agree**, it exits
  without starting Steam at all - the normal case costs nothing
- otherwise it repairs whatever is missing, reusing whichever contentid already exists so Steam
  sees the library it adopted rather than a competing new one
- it then proves the repair the only way that means anything: run Steam, stop it, and check the
  entry *survived*. Up to three attempts.

It refuses to touch the config while Steam is running, because Steam rewrites that file on exit
and would throw the edit away.

Test it without spending a build:

    ./tests/steam-library.sh

That extracts the script straight out of `lib/bootstrap.d/90-steam-prewarm.sh` and runs it
against a faked Steam install - including a fake client that prunes any library whose marker is
missing, which is the behaviour the whole design defends against.

### A desktop with no browser

XFCE reports "failed to execute default browser" the first time anything opens a link. Setting
`xdg-settings` alone does not fix it: `exo-open` reads its own `~/.config/xfce4/helpers.rc`.
Set the `x-www-browser` alternative, `helpers.rc`, and the xdg defaults.

## Cost control

### Arming an idle alarm stops the box instantly

A new CloudWatch alarm is evaluated against the **previous** 30 minutes immediately. During
setup that window is the software install, which looks exactly like an idle one - so the alarm
fired its stop action seconds after creation and killed the box mid-setup.

`set-alarm-state --state-value OK` does **not** fix this: CloudWatch re-evaluates the same
history and returns to `ALARM`. The stop action is therefore left disarmed by `aws-setup.sh`
and armed by `game up`, when a session actually starts - the only time this layer is meant to
be watching.

### The idle watchdog must watch downloads too, not just the stream

The watchdog originally measured only **outbound** bytes on `tailscale0` - streaming traffic.
That is correct while games live on a persistent disk, but wrong once they live on ephemeral
storage:

> Connect, start a 35-minute game download, disconnect Moonlight to do something else. Fifteen
> minutes later the watchdog sees no outbound stream traffic, calls the machine idle, and shuts
> it down mid-download. Because `/scratch` is wiped on stop, the partial download is **lost, not
> resumed** - so the next attempt starts from zero and dies the same way.

A download is *inbound* traffic on the *public* interface, which the original check could not
see at all. The watchdog now treats the machine as busy if either is true:

- outbound on the tunnel above `THRESHOLD` (200 KB/min) - someone is streaming
- inbound on the default-route interface above `RX_THRESHOLD` (10 MB/min) - something is
  downloading

The inbound threshold is deliberately high. Idle Linux chatter is a few hundred KB/min, so a
low threshold would keep the box alive forever and defeat the whole layer.

### Use an AWS Budget, not a CloudWatch billing alarm

`AWS/Billing EstimatedCharges` **publishes nothing** unless "Receive Billing Alerts" is
switched on, which is off by default and settable only by the root user at
<https://console.aws.amazon.com/billing/home#/preferences>.

Until then the alarm sits in `INSUFFICIENT_DATA` forever and the layer is decorative.

There is also a second trap: the alarm needs an SNS topic, and **every subscriber must confirm
by email**. An unconfirmed subscription delivers nothing, silently.

Both problems disappear with **AWS Budgets**, which emails subscribers directly - no root
toggle, no confirmation, effective immediately, and the first two budgets are free. That is
what `lib/aws-setup.sh` now creates. Check it with `cg status`.

### Zero inbound rules silently costs half your latency

Covered in [architecture.md](architecture.md): without UDP 41641 open, Tailscale falls back to
a relay at 43-71 ms instead of 16 ms, and never reports an error. Check with
`tailscale ping <host>` - it must say *direct*, not *via DERP*.

### Persistent spot requests are safe with this design

`InstanceInterruptionBehavior=stop` preserves the disk on reclaim but requires a *persistent*
request, which raises the question of whether AWS will relaunch a box the watchdog deliberately
stopped. Tested: **it will not.** A user-initiated stop moves the request to `disabled`, and it
only re-arms when you start the instance yourself.

    active/marked-for-stop -> active/instance-stopped-by-user -> disabled/instance-stopped-by-user

When tearing down a spot instance, **cancel the request before terminating** - otherwise AWS
launches a replacement.

### Measure bandwidth against the source that matters

An early conclusion that games could not be re-downloaded per session came from measuring
against GitHub and Ubuntu's archive (~10 MB/s). Steam's CDN measured **62 MB/s** from the same
instance - six times faster, and enough to change the design. Measure the actual source.

## Rebuilding

### A destroyed box cannot reclaim its Tailscale node

A node's identity lives in `/var/lib/tailscale`, on the disk that gets deleted. A rebuild
authenticates as a *new* node, finds the name taken, and registers as `<host>-1` - which
`game` will not find, hanging at "waiting for tailscale".

Delete the stale node at <https://login.tailscale.com/admin/machines> before rebuilding, or set
`GAME_TS_HOST` to match the new name.

### Sunshine reports "active" but nothing is listening

On a headless cloud instance there is no sound card, and Sunshine's Ubuntu build
initialises audio through PipeWire. With PipeWire absent it spins forever:

    pw.thread-loop: 0x...: iterate error -22 (Invalid argument)

and never binds 47984/47989/47990 - while `systemctl --user is-active` still reports
`active`, because the process is running, just stuck. The web UI simply refuses the
connection with no clue why.

The fix is `pipewire`, `pipewire-pulse`, `wireplumber`, plus a **null audio sink** so there
is a device to capture on a machine with no `/dev/snd`. Diagnose with:

    ss -tlnp | grep 479          # nothing listening = this bug
    journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -n 20

### `~/.config` ends up owned by root

`install -d -o user -g user ~/.config/sunshine` applies ownership to the **leaf only** -
`~/.config` itself is created as root. Anything later writing a per-user config into it
fails with "Permission denied", including the PipeWire fix above.

`bootstrap.sh` now chowns the whole tree at the end.

### CSRF blocks the web UI after a name collision

`csrf_allowed_origins` was written from the hostname `bootstrap.sh` *requested*, not the one
the node actually got. When the name was already taken and Tailscale joined as `<host>-1`,
browsing to that real name was rejected - with a CSRF error that says nothing about hostnames.

`bootstrap.sh` now asks Tailscale what the node is called
(`tailscale status --json` -> `.Self.DNSName`) and lists the short name, the full MagicDNS
name, the tailnet IP and localhost. Fix an existing box by rewriting that line and restarting
Sunshine.

### 409 "A pairing session with this uniqueid already exists"

An abandoned pairing attempt leaves a session open, and Sunshine refuses a second one from the
same client. Restart Sunshine to clear it:

    systemctl --user restart app-dev.lizardbyte.app.Sunshine.service

### Black screen: Sunshine silently falls back to software encoding

The stream connects, audio may work, and the picture is black. The cause is in Sunshine's log:

    Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0
    The minimum required Nvidia driver for nvenc is 610.00 or newer
    ...
    Found H.264 encoder: libx264 [software]

Sunshine's bundled ffmpeg needs **NVENC API 13.1, i.e. driver 610 or newer**. When the driver
is older it works down the list - nvenc, vulkan, vaapi - and lands on **libx264**, which four
vCPUs cannot sustain at desktop resolutions. Nothing errors; the picture is just black.

`ubuntu-drivers install` chooses the distro's *recommended* driver, which lagged at 595 even
though `nvidia-driver-610-open` was sitting in the same repos. `bootstrap.sh` now picks the
highest `nvidia-driver-NNN-open` apt offers instead of trusting "recommended".

Check which encoder is actually in use:

    journalctl --user -u app-dev.lizardbyte.app.Sunshine.service | grep 'Found H.264 encoder'

`[software]` means this bug. It should say `h264_nvenc`.

The virtual display also defaults to 1920x1080 rather than the full virtual size, so a
software fallback degrades to "slow" instead of "black", and `set-resolution.sh` still raises
it when a client asks for more.

### Games were installing to the root disk, not the NVMe

Two mistakes here, and the second is subtler than the first.

**Wrong path.** The first attempt linked `~/.local/share/Steam/steamapps` to `/scratch`. That is
the Valve/Flatpak layout; the Debian-packaged client uses `~/.steam/steam` ->
`~/.steam/debian-installation` and never creates that directory at all. The link was silently
never made, `/scratch` sat empty, and games would have filled the 50 GB root volume.

**Symlinking steamapps does not work anyway.** Steam calculates a library's free space from the
library's `path`, not from `path/steamapps`. With the symlink in place Steam still reported the
*root disk's* 36 GB and would refuse a game that fits comfortably on the 217 GB NVMe.

The fix is to register `/scratch/steam` as a genuine **library folder** - a directory containing
`steamapps/` - by adding an entry to `config/libraryfolders.vdf`. Steam then shows both
libraries with correct sizes and installs where you choose. Verified the entry survives a full
Steam start/quit cycle, which is worth checking because Steam rewrites that file on exit.

Confirm what Steam believes:

    grep '"path"' ~/.steam/steam/config/libraryfolders.vdf
    df -h /scratch/steam        # should be the NVMe, with the space Steam reports

### user-data outgrew the 16 KB EC2 limit

`bootstrap.sh` reached 17 KB and `RunInstances` rejects anything larger. cloud-init detects
gzip magic bytes and decompresses automatically, so `provision.sh` now ships it compressed -
17378 bytes becomes 6869, which restores plenty of headroom. Note this needs `fileb://`
(binary) rather than `file://`.

### The stream connects, decodes one frame, then dies

Moonlight negotiates fine, reports `Video stream is 1280x720x60`, decodes a single frame and
then:

    Control stream received unexpected disconnect event
    Connection terminated: -1
    No video traffic was ever received from the host!

It looks like a network fault. It is not. Sunshine's side says:

    Info:  Executing Do Cmd: [/usr/local/bin/set-resolution.sh]
    Error: Failed to start capture session: Cannot create capture session:
           the display server is in modeset

Sunshine runs the resolution prep command and starts **NvFBC capture the instant it exits**.
If X is still mid-modeset, capture fails outright - so the session connects, sends no video at
all, and the client is dropped a second later.

Mode changes also failed outright at that point, with:

    xrandr: Configure crtc 0 failed
    X Error of failed request: BadMatch

- including setting the mode X was already in. That looked like a limit of the headless config.
It was not: **DRM KMS was holding the CRTCs** (see below). Turning it off fixed both symptoms at
once - NvFBC can capture, and xrandr can reconfigure - so the display does follow whatever
resolution the client asks for.

`set-resolution.sh` now: returns immediately when the requested size already matches (the
common case at 1080p); uses the mode X already advertises rather than creating a duplicate
modeline (`--newmode` on an existing name fails `BadName`, then `--addmode` fails `BadMatch`);
and **gives up the moment the server refuses**, logging why to `/var/log/set-resolution.log`.
Sunshine then captures at 1080p and the client scales, which costs nothing.

The defensive behaviour is still worth keeping: it costs nothing when the mode already matches,
and it fails fast rather than stalling a session if a server ever does refuse.

**But that was not the real cause.** The same failure happened on a session where
`set-resolution.sh` was never called at all - no `Executing Do Cmd` line, nothing in its log.
The actual culprit:

    /etc/modprobe.d/nvidia-graphics-drivers-kms.conf:  options nvidia_drm modeset=1

Ubuntu's driver package enables NVIDIA DRM kernel modesetting, and **NvFBC cannot create a
capture session while DRM KMS owns the display** - it reports the display server as permanently
"in modeset". Nothing has to be changing for this to happen; it is the steady state.

The box has no physical display and needs nothing KMS provides, so `40-nvidia.sh` writes
`options nvidia_drm modeset=0 fbdev=0` and rewrites Ubuntu's file, before the build's final
reboot. Confirm with:

    sudo cat /sys/module/nvidia_drm/parameters/modeset    # must be N

Note that reading that file needs root - as a normal user it fails with "Permission denied" and
an empty value, which looks exactly like "the parameter does not exist".

With KMS off, `xrandr` mode changes work again, so the host follows the client's requested
resolution. Set Moonlight to 1920x1080 to stream at the box's native mode.

### Changing resolution breaks NvFBC until X restarts

The deeper version of the problem above, found after the KMS fix made mode changes actually
work. Once `xrandr` changes the mode at runtime, NvFBC reports the display server as
**permanently** "in modeset" and cannot create a capture session again - not for that session,
and not for any later one:

    CLIENT CONNECTED
    Screencasting with NvFBC
    Failed to start capture session: Cannot create capture session: the display server is in modeset

No script needs to be involved. The evidence is stark: a freshly restarted X captures fine, the
first session that switches mode works, and **every session after it fails** until lightdm is
restarted. On the client that looks like a black window that closes after a few seconds.

So `global_prep_cmd` is empty. The box stays at the `xorg.conf` mode (1920x1080) and the client
scales if it asked for something else, which costs nothing - Sunshine encodes what it captures
either way. `set-resolution.sh` is still installed for manual use, just not wired into a
session.

**Set Moonlight to 1920x1080** to match the host and avoid scaling entirely.

If a stream ever goes black and drops, check for that error and restart the display stack:

    sudo systemctl restart lightdm     # note: this kills the desktop session, so Steam too

### NvFBC could not capture at all; X11 capture works

After several wrong turns, this is the conclusion: **NvFBC does not work reliably on this
setup.** The error is always the same -

    Failed to start capture session: Cannot create capture session:
    the display server is in modeset

and it appeared under every condition that was supposed to rule it out: on a freshly built box
with nothing touching the display, at the stock 1920x1080, immediately after a Sunshine
restart, and with `global_prep_cmd` empty. Only the first session after a **full X restart**
would capture; every session after it failed.

Things that were wrong along the way, recorded because each one looked convincing:

1. *The resolution prep command races capture.* A real race, worth fixing - but the failure
   recurred on sessions where the script was never called.
2. *DRM KMS is the cause.* Necessary (`nvidia_drm modeset=0`, see `40-nvidia.sh`) but not
   sufficient - and it made mode changes start working, which made things worse.
3. *Changing resolution breaks capture permanently.* Fitted the evidence, then was contradicted
   by a failure at an unchanged 1920x1080.
4. *NvFBC state leaks between sessions, so restart Sunshine.* Predicted the next session would
   work. It did not.

`capture = x11` was stable on the first attempt. The cost is real - the frame grab moves to the
CPU, roughly one core at 1080p60 on 4 vCPUs - but NVENC still does the encoding, which is the
expensive half. To retry NvFBC later, set `capture = nvfbc` and watch the **second** session.

### A black screen is not always a capture failure

Separately: a stream can connect, decode frames, and still show nothing, because the desktop
itself is not painting. The two look identical from the client, and they are unrelated.

Tell them apart without guessing - a uniform image compresses to almost nothing:

    xwd -root | wc -c          # raw size
    xwd -root | gzip -9 | wc -c

Under ~0.2% of raw means the root window is genuinely flat (black) and capture is reporting the
truth. A desktop that is drawing compresses far less well. Sunshine's keyframe size says the
same thing: an 880-byte 1080p IDR frame is a flat image, not a desktop.

The cause here was self-inflicted: restarting `lightdm` and then launching applications by hand
over ssh leaves a session those applications cannot draw into. `xfdesktop` and `xfce4-panel`
were running, and nothing was painting. The fix is to restart the display manager and let
autologin build the whole session itself, launching nothing manually.

### The desktop appears in the top-left corner, black elsewhere

X11 capture grabs the **whole X screen**, so a screen larger than the active mode puts the
desktop in the top-left of the frame and fills the rest with black:

    Screen 0:  current 2560 x 1600     <- captured
    DVI-D-0:   1920x1080+0+0           <- where the desktop draws

`xorg.conf` asked for `Virtual 3840 2160`, and the NVIDIA driver silently clamped it to its own
mode pool maximum, 2560x1600 - against a 1920x1080 mode. NvFBC had been capturing only the
active output, which hid the mismatch until capture moved to X11.

`Virtual` and `Modes` must match. Fix live without restarting X (a game survives this):

    xrandr --fb 1920x1080

Sunshine reads the geometry at session start, so reconnect for it to take effect.

### Shader compilation crawls on 4 vCPUs

Two separate causes, and both matter on a `g6.xlarge`:

**Steam compiles shaders in the background** while the game compiles its own at launch. Two
CPU-bound jobs plus a core for capture, on four cores:

    load 7.50, steam 87-95%, GameThread 144%     <- background processing ON
    load 3.38, steam 56%,    GameThread 150%     <- OFF

Those numbers are a CPU measurement, not a launch-time one. The run after switching it off was
also replaying shaders the previous run had already compiled - `/scratch` survives a game
restart, only a *stop* wipes it - so the two effects were confounded. What is established is
that it frees close to a core; the launch-time share is unmeasured.

Turn it off: Steam > Settings > Downloads > Shader Pre-Caching > "Allow background processing of
Vulkan shaders". Valve's pre-built caches still download; only local background compilation
stops. Not scriptable - Steam exposes no config key for it.

**The cache that matters was on ephemeral disk.** For a Vulkan game under Proton it is Steam's
Fossilize cache at `<library>/steamapps/shadercache`, *inside* the library - so on `/scratch`,
wiped every stop. The GL cache (`__GL_SHADER_DISK_CACHE_PATH`) is irrelevant to such games: it
sat at 1 MB while the Fossilize cache passed 490 MB.

`mount-scratch.sh` now symlinks it to `~/.cache/steam-shadercache` on the root volume, so the
minutes of saturated CPU are paid once rather than every session.

The quota ceiling is worth knowing: shader compilation is CPU-bound, `g6.2xlarge` would halve
it, and a 4 vCPU GPU quota cannot launch one. There is no tuning around that.

### The root volume is EBS too, so "find the EBS disk" picks the wrong one

The game library volume has to be located by inspection, because on Nitro EBS does not appear
as the `/dev/sdf` it was attached as - it shows up as an NVMe device, alongside the instance
store and the root volume:

    nvme0n1   50G  Amazon Elastic Block Store        <- root
    nvme1n1  233G  Amazon EC2 NVMe Instance Storage  <- /scratch
    nvme2n1  160G  Amazon Elastic Block Store        <- the game volume

The first attempt excluded the root disk by stripping the partition suffix from `findmnt`:

    src=${src%p[0-9]}   # /dev/nvme0n1p1 -> /dev/nvme0n1
    src=${src%[0-9]}    # -> /dev/nvme0n   WRONG, stripped twice

So the comparison never matched, the loop took the **first** EBS disk it found - the root - and
tried to mount it at `/games`. Use `lsblk -no PKNAME` to get a partition's parent disk instead
of stripping digits.

**The lesson worth keeping:** the `mkfs` guard was extracted and unit-tested against four
cases, and it was never reached. Device *selection* is upstream of it, so a bug there bypasses
the guard completely - the only reason nothing was destroyed is that the root disk happens to
have a filesystem. Test the code that chooses the target, not just the code that protects it.

Selection now prefers a device already labelled `games`, and otherwise takes the first EBS disk
that is neither the root nor carrying any filesystem or partition. Verified on a real box with
all three device types present, and verified idempotent: 50 MB written, volume unmounted,
script re-run, checksum unchanged.

### The screen goes black after about 15 idle minutes and never comes back

The hardest one in this project to see, because every component reports success.
Sunshine logs **zero capture errors**, Moonlight receives and decodes frames, the desktop
processes are all running and correctly sized - and the picture is black.

The tell is in `xset q`:

    Standby: 600    Suspend: 0    Off: 900
    DPMS is Enabled
    Monitor is Off          <- here

X blanked the virtual display. On a headless box there is no monitor to wake, so **the
framebuffer never comes back**: `xset dpms force on` restores the state but not the picture, and
`xrefresh` cannot repaint it. Nothing recovers it except restarting the session - which is
exactly why it looked like an intermittent capture bug that "fixed itself" on any restart.

Confirm it with a compression test rather than by eye, since a uniform image compresses to
almost nothing:

    xwd -root | wc -c ; xwd -root | gzip -9 | wc -c     # under ~0.2% means flat

**`xorg.conf` alone does not fix this.** ServerFlags `BlankTime`/`OffTime`/`NoPM` are parsed -
the X log proves it - and then **xfce4-power-manager re-enables DPMS** once the session starts.
`light-locker` will also blank and lock, and a locked screen on a box with no keyboard cannot be
recovered over a stream.

So three places, all of them needed:

1. `xorg.conf` ServerFlags: `BlankTime 0`, `StandbyTime 0`, `SuspendTime 0`, `OffTime 0`, `NoPM`
2. `xfce4-power-manager.xml`: `dpms-enabled=false`, `blank-on-ac=0`, both `dpms-on-ac-*=0`
3. `light-locker` autostart set to `Hidden=true`, plus an `xset s off -dpms` autostart

Recovering a box that has already blanked:

    sudo systemctl restart lightdm     # kills the desktop session, so Steam too

### NVMe device names are not stable across reboots

Observed on one box, across a single session restart:

    before:  nvme1n1 = instance store (/scratch)   nvme2n1 = EBS games volume
    after:   nvme1n1 = EBS games volume (/games)   nvme2n1 = instance store (/scratch)

Nothing broke, because the mount scripts never look at device names: `mount-games.sh` finds its
volume by filesystem **LABEL** and falls back to "an EBS disk that is not the root and carries no
data", and `mount-scratch.sh` matches the **model string** "Amazon EC2 NVMe Instance Storage".

This is worth recording because it turns an earlier precaution into a demonstrated necessity.
Had `/games` been identified by device name, that reboot would have pointed it at the instance
store - and the only thing standing between that and a wiped 140 GB game library would have
been the `mkfs` guard. Which, incidentally, is the same guard that a device-selection bug had
already bypassed once.

An ad-hoc measurement written during the same session *did* hardcode `nvme2n1` and reported
nonsense (zero disk writes during an active download). Convenience scripts deserve the same
identification discipline as the real ones.
