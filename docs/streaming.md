# Streaming

Client and Steam settings that make a session better, and what the hardware can and cannot do.

## Resolution

**Resolution follows whatever Moonlight asks for.** The host switches to match at the start of
each session, so set Moonlight to 1920x1080 for the box's native mode.

## Moonlight client settings

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

## One thing to turn off in Steam

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

## Limits

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
