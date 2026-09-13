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

### A test stub that invented its own output format, and the archive it deleted

The S3 game-library mirror refuses to push when the local copy is far smaller than the archive,
because push propagates deletions and the local copy lives on a disk that is wiped on every
stop. That guard was written, tested, and passed 30 assertions.

On its first run against real S3 it did not fire, and a real 250 MB archive was deleted.

`s5cmd du` prints:

    262144000 bytes in 2 objects: s3://bucket/prefix/*

The parser matched `$i == "objects"`. The real token is `objects:` - with a colon - so the count
read **0 forever**, and the guard was written as `if (( remote_objects > 0 ))`. Zero objects
meant "the archive is empty, nothing to protect", so every push was waved through.

The unit test passed because the stub emitted `TOTAL: N bytes in M objects` - a format I had
assumed rather than one I had ever run. **The stub validated the parser against itself.** A
stub's output is only evidence if it was copied from the real thing; anything else tests that
the code agrees with the assumption it was written from.

Both halves were fixed:

- the stub is now byte-for-byte the observed output, colon included
- both words are matched with an optional colon, `/^objects:?$/`
- and the guards key off **bytes**, not the object count - so a parse change on the more
  decorated of the two fields cannot silently switch a safety check off again

The last point is the general one. Two fields were available and only one was needed; the guard
had been wired to the one that was easier to get wrong, for no reason other than that it read
more naturally. A safety check should depend on the least decorated input that can express it.

Two further cases were added: one asserting the count is parsed out of the real format, and one
feeding a deliberately unparseable count (`in ?? widgets:`) to prove the refusal still happens.

### A Proton prefix contains a symlink to `/`, and it OOM-killed the uploader

The first real push of a game library - 2.9 GB, one small game - was killed by the OOM killer
with a 12 GB resident set, on a box with 16 GB and Steam running next to it.

The first diagnosis was wrong. `s5cmd` holds roughly `numworkers x concurrency x part-size` in
transfer buffers, and the defaults (256 x 5 x 50 MB) do want tens of GB, so the flags were
tuned down to `16 x 4 x 16 MB` - about 1 GB by that arithmetic. **It OOM-killed again at exactly
the same 12 GB.** Two controlled runs then showed worker count was not the lever at all:

    numworkers 4,  concurrency 2, part-size 5   -> 92s, peak  287 MB
    numworkers 64, concurrency 4, part-size 16  -> 18s, peak  391 MB

Both fine - because both synced `steamapps/common/` only. Syncing the **whole** library blew up
regardless of flags, with or without `--delete`. The difference was `steamapps/compatdata`:

    compatdata/438040/pfx/dosdevices/z: -> /
    compatdata/438040/pfx/dosdevices/s: -> /scratch/steam/steamapps

A Wine prefix maps drive letters as symlinks, and `Z:` is conventionally the **root of the
filesystem**. `S:` here pointed back into the library being walked. s5cmd follows symlinks by
default, so enumerating the library descended into the entire root filesystem *and* into itself,
without end. The memory was the file list, not the transfer buffers - which is why tuning the
buffers changed nothing.

`--no-follow-symlinks` fixed it: the same push then completed in **21s with a peak of 323 MB**.

Two things worth taking from this:

- **The measurement that justified the flags could not have reproduced the bug.** The 10 GB
  benchmark used ten 1 GiB objects, so at most ten workers were ever live and no prefix was
  involved. It was used to choose `--numworkers 32` on a memory argument it had never tested,
  and it also over-reported throughput by 3.6x against real game files (508 MB/s vs 140 MB/s).
  A benchmark is evidence about the shape it measured and nothing else.
- **When tuning a resource does not move the resource, stop tuning it.** The second OOM landed
  on the same 12 GB as the first. That number not moving was the whole clue, and it was
  available before any further flag changes.

The cost of the fix is that the ~1,350 symlinks in a prefix are skipped rather than stored. S3
has no symlink concept, and dereferencing them would upload a copy of the Proton runtime into
every game's prefix. Proton rebuilds `dosdevices` and its DLL links when it next starts the
prefix, and the save games under `drive_c/users/steamuser` are ordinary files that mirror
normally.

### Editing a script while it is running

    2026-09-13T00:01:05  ==> removing tailnet nodes
          no gamevps nodes on the tailnet - nothing to remove
    ./cg: line 784: /scratch/tmp: No such file or directory

Nothing is wrong with `/scratch/tmp`, and line 784 is a line of help text. `cg destroy` spends
about five minutes waiting for an instance to terminate, and `cg` was **rewritten during that
wait**.

Bash does not load a script into memory. It reads, executes, and comes back for more input at a
**byte offset**. Replace the file underneath a running instance and the next read resumes at that
offset in the *new* contents - which is a different place entirely. Here it landed inside the
help heredoc, so a line of documentation was executed as a command.

The failure is loud but arbitrary: it depends on where the interpreter happened to be. It can
equally resume mid-word, skip a cleanup step, or run a branch that was never reachable. Every
step here had already completed, which was luck rather than design.

Three ways out, and the third is the one that actually holds.

Edit a copy and `mv` it into place - atomic, and it swaps the inode, so the running process keeps
reading the file it started with. Or do not edit while a long command is in flight. Both depend
on discipline, and discipline failed twice more in the same session, producing:

    ./cg: line 944: syntax error near unexpected token `;;'
    ./cg: line 956: syntax error near unexpected token `;'

Note the differing line numbers for the same edit - the signature of a shifting offset rather
than a real syntax error. Both landed *after* every step of the destroy had completed.

The structural fix: **end the script with an explicit `exit`.** Bash returns to read more input
once the final command finishes, and with a dispatch as the last construct that read happens
after a five-minute `cg destroy`. An `exit` means it never reads again. Measured, with a script
rewritten during its last command:

    no trailing exit     ->  syntax error near unexpected token ';;'   exit=2
    trailing 'exit 0'    ->  exit=0

This also explains why only some commands broke. `cg init` and `cg check` end in `exec`, which
replaces the process outright - those were never vulnerable. `destroy) cmd_destroy "$@" ;;`
returns to the dispatch, and to bash's next read.

One caveat found while applying it: `lib/setup`'s `case` is *not* its last construct. The
`check)` and `rebuild)` branches deliberately fall through past `esac` into the build flow, so
an `exit` after `esac` would have broken `cg init` entirely. It goes at the end of the file, not
the end of the dispatch. `tests/tail-exit.sh` checks all eight scripts and re-verifies the
underlying bash behaviour, so the rule carries its own evidence.

### `cg destroy --all` left a live access key behind, and status could not show it

After `--all` reported "everything deleted", an IAM audit by hand found:

    gamevps-watchdog    AKIA................    Active

The off-site watchdog's user, with an active long-lived key scoped to
`ec2:StopInstances` - held in `.env` and on an internet-facing VPS. Two separate reasons it
survived:

**It cost nothing.** Every other resource in `--all` was on the list because it billed: the
instance, the volume, the archive, the bucket. An IAM user bills nothing, so it was never on
the list. "Free" is a bad filter for what to clean up - a credential that can act on the
account outranks a bucket that merely sits there.

**Nothing listed it.** `cg status` showed instances, volumes, snapshots, images, EIPs, key
pairs, security groups, alarms and the budget - and no IAM whatsoever. A leftover that no
command displays is one nobody notices. Status now prints the instance role and the watchdog
key, including whether the key is `ACTIVE` and what it can do.

It also flags a key AWS still honours that `.env` no longer holds. That combination is the
worst of the three states: unusable, because the secret is gone, and unauditable, because
nothing local records it. It can only be revoked.

Writing the test for that orphan check found a third bug in the check itself:

    envk=$(grep -c '^GAME_WATCHDOG_AWS_KEY_ID=' .env || echo 0)
    [[ $envk == 0 ]] && printf 'orphaned...'

`grep -c` **prints `0` and exits `1`** when nothing matches. So `|| echo 0` appends a second
zero, `envk` becomes `"0\n0"`, and the comparison against `"0"` is never true - the warning
could not fire under any circumstances. The same duplicated count had already appeared in a
manual audit's output (`0` on one line, `  0` on the next) and was read as harmless formatting
rather than a signal.

`grep -c` needs no `|| echo 0`. It already reports the count; only its exit status needs
tolerating, and the comparison should be numeric (`-eq`), not string.

### The guard view claimed to show layer 4 and did not

`cg watcher` carried this comment:

    # Layers 3 and 4 live in AWS and survive the box being gone.

and then printed the CloudWatch alarm and the budget. Layer 4 - the off-site watchdog, the only
guard that keeps working when the box and the account resources are gone - was never printed at
all. The comment asserted the coverage; the code did not provide it.

That mattered because **only `cg init` ever checked it.** When its access key was revoked, the
watchdog correctly logged `CANNOT QUERY AWS - this watchdog is blind`, kept its timer active,
and no command surfaced that. `cg watcher` now reports the timer state, the last decision, and
an explicit BLIND warning with the fix.

Worth separating from a non-bug found in the same log:

    19:24:10  CANNOT QUERY AWS ... AuthFailure
    19:26:40  no running instance tagged gamevps - nothing to do

That reads like intermittent blindness being misreported as health, and it was initially
diagnosed as exactly that. It is not. Both lines fell within minutes of the key's deletion, and
IAM is eventually consistent - the later call genuinely succeeded with a key AWS had not
finished revoking, and genuinely found no instances. Re-running it afterwards gives `AuthFailure`
every time, `rc=254`. The watchdog reported what it observed on each run.

The lesson is about the diagnosis rather than the code: a guard printing reassurance next to a
failure is such a familiar shape in this project that it was assumed rather than checked. One
command (`run it again now`) separated propagation from a logic error, and it was available
before any of the reasoning about why the branch might flip.

### `--all` cleaned up AWS and left the other machine running

`cg destroy --all` grew a block to remove the off-site watchdog's IAM user, because that user's
long-lived key had survived "everything deleted". The block worked. It also reimplemented what
`cg watchdog remove` already did - and reimplemented only half of it.

`cg watchdog remove` handles the keys, the inline policy, the user, the `.env` entries, the
units on the remote host, and the credentials file there. The new block covered the first four.
So `--all` left a systemd timer running on an always-on VPS, firing every few minutes,
authenticating with a key that no longer existed, appending `AuthFailure` to a log forever.

Nothing detected it because nothing was looking at that machine. The destroy printed a line
saying the units still existed and suggesting the command to remove them - true, accurate, and
easy to read as housekeeping rather than as "a process is still running out there".

`--all` now calls `cg watchdog remove` in a subshell (it uses `die()`), with the IAM-only path
kept for the case where no host is configured but the user exists - an earlier setup, or an init
interrupted after `watchdog_ensure` created the credential and before anything launched. That
last case is not hypothetical: it is how a key with a different id turned up minutes after the
previous one was revoked.

The general point: when a destructive command grows to cover a new resource, the question is not
only "does this remove it" but "does something already remove it, and more completely". Two
places that delete the same thing will not stay in agreement, and the incomplete one wins
whenever it is the one that runs.

### A destroy that listed a resource and then never mentioned it again

    type DESTROY-ALL to confirm: DESTROY-ALL
    ...
      IAM            gamevps-box role, and the gamevps-watchdog user
                      (a long-lived key that can stop instances - it lives
                       in .env and on the off-site watchdog host)
    ...
    ==> removing the instance role gamevps-box
          role gamevps-box was already gone

The watchdog user is announced before the confirmation and never appears again. Nothing is
wrong: it had been deleted by an earlier run, so the removal block found nothing and printed
nothing. But that output cannot be told apart from three different situations:

- it was removed, quietly
- it was never there
- the step was skipped by a bug

The role line is the contrast. `role gamevps-box was already gone` is the same do-nothing
outcome, stated. That is all the difference between an audit trail and a guess.

Two fixes, and they are separate:

**List only what exists.** The summary printed the role and the watchdog user unconditionally,
including the parenthetical about a long-lived key on a remote host - when neither the user nor
the host existed. A confirmation prompt that overstates what it is about to delete trains people
to stop reading it, which is the one thing it cannot afford.

**Report an outcome on every path, including the empty one.** `nothing to remove` is a result. A
step that appears in the plan and produces no line in the log is a gap in the record, not
brevity.

This is the same shape as the empty-archive line in `cg status`, which printed a bucket name
whether it held 13,000 objects or nothing, and as `cg watcher` claiming to cover a layer it
never printed. Three separate places where the output described the intent rather than the
result.

### A RETURN trap is not scoped to the function that set it

    2026-09-13T01:08:19  off-site watchdog: no running instance tagged gamevps - nothing to do
    ./cg: line 540: pol: unbound variable

`cg init` armed the off-site watchdog, reported it working, and then died - before launching
anything. Line 540 is the closing `}` of `watchdog_ensure`, which has no variable called `pol`.

The cause is 80 lines earlier, in `watchdog_iam_ensure`:

    local pol; pol=$(mktemp); trap 'rm -f "$pol"' RETURN

A RETURN trap fires "each time a shell function finishes executing" - **any** function, not the
one that installed it. So the trap outlived `watchdog_iam_ensure`, fired when
`watchdog_ensure` returned, and evaluated `$pol` in a scope where the local no longer existed.
Under `set -u` an unset variable is fatal, so the script exited. The trap was doing its cleanup
job correctly and then doing it again forever.

The fix is to not need the file: `aws iam put-user-policy --policy-document` takes JSON inline,
so the temp file, the trap and the whole class of problem go away together.

**Why it survived so long.** That branch only runs when the scoped IAM user does not exist - a
first-ever `cg init`, or the first one after `cg destroy --all`. Every init in between found the
user, took an early `return 0` before the trap was ever installed, and worked perfectly. The bug
was introduced with the function and became reachable again only when `--all` started deleting
that user.

That is the shape worth remembering: a latent fault on a rarely-taken branch, exposed by an
unrelated change that made the branch ordinary. `tests/init-watchdog.sh` now covers it, and was
checked against the reverted code to confirm it actually fails - its "existing credential" case
passes even with the bug present, which is the whole reason nobody noticed.

If a RETURN trap is genuinely wanted, `local -` inside the function restores `set` options and
traps on return; but the simpler answer is almost always to avoid the temp file.

### `|| echo` after a command that prints on failure, three times

    off-site watchdog inactive
    unreachable  on 203.0.113.10

One field, two values. `systemctl is-active` **prints** `inactive` and **exits non-zero**, so:

    wst=$(ssh host 'systemctl is-active x.timer' || echo unreachable)

appends the fallback to a perfectly good answer instead of replacing a missing one. `|| echo` is
only correct after a command that prints *nothing* when it fails - `aws ... 2>/dev/null || echo
'?'` is fine, because a failed aws call with stderr suppressed produces no stdout.

Commands in this repo that print AND exit non-zero: `systemctl is-active`, `systemctl
is-enabled` (`not-found`, `disabled`), `grep -c` (`0`).

This was already documented in `cmd_watchdog status`:

    # is-enabled prints "not-found" AND exits non-zero, so a `|| echo` prints
    # both. Take the first word and normalise it.

and it was still written three more times in one sitting - `grep -c` in `iam_lines`, then
`is-active` in the off-site line of `cg watcher`, then `is-active` in the on-host line right
above it, the last two *after* fixing the first. A comment at the one site that got it right
does not generalise; the knowledge has to be attached to the pattern, not to a location.

The shape to look for is a substitution whose fallback could be *appended* rather than
substituted. The fix is always the same: tolerate the exit status, keep the text, and treat only
empty output as failure.

    wst=$(ssh host 'systemctl is-active x.timer' 2>/dev/null) || true
    wst=${wst//[$'\r\n']/}
    echo "${wst:-unreachable}"

### The restored game would not start: S3 cannot hold a symlink

A full round trip worked on paper. 13,295 objects restored in 3s, `appmanifest_438040.acf` said
`StateFlags 4`, `BytesDownloaded` was 494 KB against 2.6 GB on disk - Steam accepted the library
and re-downloaded nothing. The game still would not launch.

    $ ls compatdata/438040/pfx/dosdevices/
    (empty)

A Wine prefix maps drive letters as symlinks, and with `dosdevices` empty nothing can resolve a
single Windows path. `--no-follow-symlinks` - added to stop the uploader recursing into `/` via
`dosdevices/z:` - had done its job: the links were skipped, and S3 has no way to represent them
anyway.

Restoring `c: -> ../drive_c` and `z: -> /` by hand was enough; Proton then rebuilt `s:` and
`com1`-`com4` itself and the game started.

**Why only that one directory.** Counting symlinks after the restore:

    2446  common/SteamLinuxRuntime_4     Steam rebuilt these
    1892  common/Proton - Experimental   Steam rebuilt these
    1348  compatdata/1493710             Proton's own prefix, created fresh
       1  compatdata/438040              the game's prefix - nobody rebuilt this

Steam repairs its own trees, so the runtime and Proton recovered on their own and hid the
problem. A *game's* prefix has no such owner: Proton reads `.update-timestamp` and `version`,
concludes the prefix is current, and never touches `dosdevices` again. The one place with no
repair mechanism was the one place the loss mattered.

**The fix.** `push` writes `.cg-symlinks.tsv` - every symlink in the library as `path<TAB>target`
- before the sync, so it travels as an ordinary file with no extra upload step and `--delete`
cannot strip it. `pull` recreates from it afterwards, and only ever *adds*: anything already
present, real file or link Steam rebuilt, is left alone. 5,815 links, 913 KB, one object.

Tarring `compatdata` instead would also preserve the links, but would re-upload the whole prefix
on every push and would only cover the case that happened to be found.

The pattern worth keeping: **every verification passed.** Object counts, manifest state,
`BytesDownloaded`, the registered library path, the restore rate. All true, all green, and the
game did not run. The checks measured the transfer, and the transfer was never the thing that
was broken - the archive format simply could not represent part of what was being stored.

### Documented for weeks, unhandled in code

    $ ./cg open
    starting i-0405e5236b1f9ca12 ...
    aws: [ERROR]: An error occurred (IncorrectSpotRequestState) when calling the
    StartInstances operation: You can't start the Spot Instance ... because the
    associated Spot Instance request is not in an appropriate state to support start

The cause was already in this file, several sections up: stopping a spot instance yourself moves
its persistent request to `disabled`, and AWS will not start an instance whose request is not
active. That had been tested deliberately and written down.

And `cg open` still met it as a raw API error. The message names no cause, offers no way
forward, and says nothing about the part that costs money - the box is now permanently
unstartable while its root volume keeps billing, so the worst outcome is not the failed command
but the resource left behind by it.

**Knowing a behaviour and handling it are different things, and a note in a document is not a
handled case.** The distance between them here was one `describe-spot-instance-requests` call
before `start-instances`.

Two changes, and the second matters more:

- `cg open` checks the request state first and prints the cause, the cost, and both routes out
  (`cg destroy && cg init`, or `GAME_SPOT=0 cg init` for a restartable box).
- the "stop instance now?" prompt at the end of `cg open` now offers **destroy as the default**
  on a spot instance. Handling the error well still leaves you with a wasted box; not creating
  one is better. This is only reasonable because the games are in S3 - under the old EBS design,
  stop was the only way to keep them without paying for an instance.

`tests/spot-restart.sh` covers both request states, an active request, an on-demand instance
(which must not consult the spot API at all), and an already-running box.

### Every cost guard produced a dead-but-billing box

Stopping a spot instance disables its request, after which the box can never start again while
its root volume keeps charging - 50 GB of gp3 is ~INR 400/month for a machine that cannot run.

That was not an edge case. It was what **all three cost guards did**, every time they fired:

| Layer | Action |
|---|---|
| on-host watchdog | `shutdown -h` with `instance-initiated-shutdown-behavior=stop` |
| CloudWatch alarm | `arn:aws:automate:REGION:ec2:stop` |
| off-site watchdog | `ec2 stop-instances` |

And they could not simply terminate instead, because the spot request was **persistent**, and a
persistent request relaunches the moment its instance dies. Terminating from a guard would have
started a fresh instance immediately - an unbounded cost loop, the exact opposite of the guard's
purpose. None of the three can cancel the request first: the on-host watchdog holds no AWS
credentials by design, a CloudWatch alarm action cannot cancel a request, and the off-site user
was scoped to `StopInstances` only.

So stop was correct, and the leak was structural.

**The fix was upstream of all of it.** The persistent request existed for one reason: the games
lived on the instance store, so terminating meant losing them. That stopped being true when the
library moved to S3, and nobody revisited the decision it had justified.

A **one-time** request cannot relaunch, which makes terminate safe, which lets every guard
actually remove the thing it is guarding against:

- `SpotInstanceType=one-time`, and `InstanceInterruptionBehavior` dropped (one-time only supports
  terminate, which is now fine - a stop wipes the instance store anyway)
- `instance-initiated-shutdown-behavior=terminate` on spot, `stop` on demand
- the alarm action and the off-site watchdog's verb both follow the instance lifecycle, read from
  the same `describe-instances` call that found the instance
- the off-site IAM user gained `ec2:TerminateInstances`, still tag-scoped. A real widening, and
  a smaller blast radius than before: the worst an attacker on that VPS can now do is cost a
  six-minute rebuild, where the same access under the old design would have destroyed a 140 GB
  library.

Two smaller things fell out of it. `lib/aws-setup.sh` demanded `stop` unconditionally and then
excused spot with "set at launch, cannot be modified after" - so its FATAL check could never
protect a spot instance at all; it now asserts the value that matches the lifecycle. And an
unknown lifecycle falls back to `stop`, the reversible verb, so a response the parser does not
understand cannot cause a guard to destroy something.

**The general lesson.** A constraint was removed - games left the instance store - and the
design that had been built around it stayed. The persistent request, the stop-on-interruption
behaviour, the guards' inability to clean up, and the stranded volumes were all downstream of
one assumption that had quietly stopped being true. It is worth asking, after any change of that
size, which earlier decisions existed only to satisfy what just changed.

### Three numbers that were locally true and globally wrong

    budget          $57 limit, $0.00 spent so far
    free egress     ~99 GB left of 100 GB/month
    month to date:  compute  2.0 hrs

All three were wrong, none was a calculation error, and each was accurate about something
narrower than its label claimed.

**`$0.00 spent`** is what the AWS Budgets API returns. `CalculatedSpend` is populated up to 24
hours *after a budget is created*, and `cg init` recreates this budget on every build - so it
reads zero essentially always. Printed bare, next to a real month of $12.17, it said "nothing
has been spent" from the one component whose entire job is noticing spend. It now says AWS has
not calculated it yet and points at `cg cost`.

**`~99 GB left`** came from the box's NIC counters *since that box booted*, subtracted from the
100 GB monthly allowance. Every session is a new box, so the figure resets each time. Cost
Explorer said 91 GB left. The line is gone; the traffic block already says "this boot only" and
now refers the month to `cg cost`.

**`compute 2.0 hrs`** counts CloudWatch CPUUtilization datapoints for **one instance id** - the
current one - under a heading that read "month to date". The comment above it even claimed "a
terminated instance keeps its metrics, so this still reports the month", which is true of the
metrics and false of the query: it only ever asks about one instance. The real month was 15
hours across six instances. Each line is now labelled with its own scope, and the heading says
what the section is: *not yet billed (Cost Explorer lags about a day)*.

The shared mistake is scope. A number is computed from what happens to be at hand - this boot,
this instance, this API's view - and then presented under a heading describing something larger.
Nothing looks wrong in the code, because each calculation is correct; the error is entirely in
the label. It is the same failure as a step verifying that it ran rather than that it worked,
moved into arithmetic: **the value answers a question nobody asked.**

Worth noting that none of these were found by tests. They were found by a user reading two
outputs side by side and asking why they disagreed. A number that is never compared against an
independent source can be wrong indefinitely - which is an argument for printing the source
(`cg cost` reads Cost Explorer, `cg status` reads the box) rather than a single blended figure.

### The budget guard had never been able to fire

    budget          $57 limit, $0.00 spent so far

against a real month of $12.17. The first fix was to say AWS had not calculated it yet. That was
true and still missed the point:

    cg destroy  ->  aws budgets delete-budget
    cg init     ->  aws budgets create-budget

AWS Budgets populates `CalculatedSpend` up to **24 hours after a budget is created**. This rig is
destroyed and rebuilt several times a day, so the budget was deleted and recreated before it
could ever populate. It was not lagging - it was being reset. **The alert had never once been in
a position to fire**, across the whole life of the project.

A budget is not an instance resource. It guards the account, it costs nothing to keep (AWS bills
nothing for the first two), and the moment it matters most is precisely the one `destroy` used to
remove it in: no instance running, nobody watching. It now survives `cg destroy` and dies only
with `cg destroy --all`.

Two things about how this was found. It came from a user asking "budget is for per month cycle
right?" - a question about semantics, not a bug report. And the earlier fix, which explained the
lag, would have made the symptom *more* palatable while leaving the guard dead. **An explanation
that makes a broken thing look reasonable is worse than the bare wrong number**, because the
number invites the next question and the explanation closes it.

`tests/destroy-budget.sh` exercises the real `lib/setup destroy` rather than a stub, so it checks
the actual API calls. Writing it surfaced a stub bug worth repeating: returning `None` from
`describe-instances` made destroy treat "None" as an instance id and wait for it to terminate, so
the run never reached the code under test and three assertions failed for an unrelated reason. A
stub must return what the real thing returns for *absence* - here, nothing at all.

### A test deleted a real SSH key

`tests/destroy-budget.sh` needed to check which AWS calls `cg destroy` makes, so it runs the
**real** `lib/setup destroy` with `aws` and `tailscale` stubbed on `PATH`. That covered every API
call and none of the filesystem, and destroy contains:

    rm -f "$HOME/.ssh/${TS_HOST}.pem"

`rm` was not stubbed and `$HOME` was the real home, so the test deleted the private key for a
running instance. Unrecoverably - AWS shows a key pair's public half and never the private one.

The box kept streaming, because Moonlight reaches Sunshine over Tailscale and needs no SSH, and
the library still mirrored on shutdown, because that runs from a unit on the box rather than
over SSH. What broke was every laptop-side operation: `cg ssh`, the disk and library sections of
`cg status`, and the pre-destroy push.

There was a second trap behind it. `provision.sh` creates a key pair only when AWS does not
already have one, so the *next* `cg init` would have happily reused the orphaned `gamevps` pair
and built another box nobody could log into. The AWS key pair has to be deleted too, so the pair
is regenerated together.

**Stubbing the API is not sandboxing.** A test that executes a real script inherits every side
effect the stubs do not cover, and `$HOME` is the one that bites, because nothing in the command
line mentions it - there is no `--home` flag to notice you have not set. Every test here that
runs a real script now sets `HOME="$T/home"`, and `destroy-budget.sh` asserts it: the sandboxed
key is deleted, an unrelated file beside it survives, and `$HOME` is not the real one.

The narrower lesson is about which tests deserve suspicion. Nine of the ten test files drive
pure logic through stubs and can do no damage. This one executes a script whose entire purpose
is deletion. That difference should have been obvious while writing it.

### Two games, one disk: what the redesign found

Buying a second 160 GB game made the archive need to be bigger than the disk, which the
whole-tree sync could not do - it mirrored the disk with `--delete`, so installing one game
deleted the other from S3. Moving to per-game prefixes turned up four things worth recording.

**A prompt that could never have worked.** The chooser asked its question through

    python3 - "$idx" "$avail" <<'PY'

which makes python read its *program* from stdin - so `input()` saw the end of the program text
and raised `EOFError` on the first keystroke. It printed the table and gave up. It was written to
`/dev/tty`, which reads naturally and cannot be tested, so nothing caught it. The prompt is now a
file, `lib/choose-games.py`, with prompts on stderr and only the answer on stdout: testable
through a pty, and stdin left alone for the human.

**An infinite loop behind that.** With the default selection larger than the disk, an EOF meant
re-ask, re-refuse, re-ask. It now exits and lets the caller decide, and `cg init` falls back to
whatever `.env` already said rather than to `all` - "all" is only safe while the archive is
smaller than the disk, which is precisely what stopped being true.

**68 bytes of user-data left.** The host bundle rode along as base64 inside user-data: 9,572
bytes of a 16,384 budget, 58%, and base64 of a gzip does not compress, so every byte cost a full
byte while the modules around it cost about 40% of one. It is uploaded to S3 now and fetched with
a presigned URL valid two hours - the box has no credentials at that point in the build, so
presigning is what makes it possible. **8,012 bytes free** instead of 68.

**A guard quietly dropped in the rewrite.** The whole-tree push refused when the local library was
under half the archive. Per-app prefixes make the catastrophic version of that impossible, so the
check looked redundant and went - but a *single* game can still be half-present locally and
overwrite its own complete copy. It is back, scoped to one game, and pointing at
`cg library forget` for the case where the removal was deliberate.

The pattern in the last one is worth naming. Removing a guard because the architecture changed is
usually right; the mistake is assuming the guard only ever covered the case you just eliminated.

### An archive that lied about being complete

    BlackMythWukong/ in S3        33.87 GB
    appmanifest_2358720.acf       "StateFlags" "4"   "SizeOnDisk" "149864365377"

A manifest saying *fully installed, 149.9 GB* beside 23% of the files. Restoring that hands Steam
a game it believes is complete, which then fails at launch - and the repair is a verify pass that
re-downloads all 150 GB. Worse than having nothing archived, because nothing archived is at least
true.

The push was interrupted. The manifest is a single small file and the game is tens of thousands,
so whichever order they upload in, an interruption lands between them - and the manifest going
first means the archive claims more than it holds for the entire remainder of the transfer.

**The manifest is now written last**, after every file it describes, and withheld entirely if any
part of the file sync failed - along with a `rm` of any stale copy. An interrupted push therefore
leaves orphaned files and no manifest, which the index does not list and `pull` skips with a
reason. Wasted storage until the next push completes it, which is a bill, not a trap.

`pull` enforces the same rule from the other side: no manifest means the game was never fully
pushed, so it is skipped and said out loud rather than restored as a directory Steam will not
acknowledge.

The general shape: **when a transfer cannot be atomic, order it so the interrupted state is
recognisably incomplete rather than plausibly complete.** The manifest is the thing that makes
the rest of the bytes meaningful, so it goes last - the same reason a marker file is written
after the work it vouches for, which this project already does for the restore marker and then
did not do here.
