# Plan: play on your own machine, not only AWS

Status (2026-10-18): **step 1 built** - the Linux CLI, `cg host add | setup |
status | open | list | remove` (lib/host.sh, tests/host.sh). Not yet run against a
real machine: tested against a fake one. Windows (step 2) and the app (step 3)
are not built. Costs nothing on AWS.

## The idea

Besides an AWS machine, cg can stream from a machine you already have: a home
gaming PC or a spare box. Prerequisites: **Linux or Windows already installed,
and ssh access to it.** cg sets up only what streaming needs and touches nothing
else.

## What carries over and what does not

| Part | AWS only? | On your own machine |
|---|---|---|
| Moonlight over Tailscale, pairing, Play, `cg ping` | no | works as is - Sunshine's API is the same on Linux and Windows |
| Setup (driver, desktop, Sunshine, Steam) | partly | today it is AWS user-data; the streaming part runs over ssh instead |
| Build / delete, spot, quotas, regions, chooser | yes | not needed - the machine is always there |
| Saved games in S3 | yes | not needed - games stay on its own disk |
| Spending, budget, credits | yes | hidden (no AWS bill) |
| Cloud watchdog (Lambda) | yes | not needed; the on-host idle stop could suspend instead of delete |

## How it would work

1. **Add it:** `cg host add mypc --ssh user@192.168.1.20`
   Connects over ssh, detects Linux or Windows and the GPU (NVIDIA, AMD or
   Intel - Sunshine encodes on all three). Uses your ssh keys and config; never
   asks for or stores a password.

2. **Set it up:** `cg host setup mypc`, over ssh, adding only what is missing.
   Safe to run again.

   | Step | Linux | Windows |
   |---|---|---|
   | Tailscale | install, join the tailnet (skipped if already on it) | `winget install Tailscale` |
   | Sunshine | the distro's official Sunshine package | `winget install LizardByte.Sunshine` |
   | Sunshine login | created, saved here first, checked (as for AWS) | same |
   | Steam | checked, never installed or changed | checked |
   | Moonlight pairing | via Sunshine's API | same |

   It does **not** touch the desktop, autologin, display settings or games.

3. **Play:** the Machine page gets a choice: **AWS** or **mypc**. For mypc it
   shows online on Tailscale / Sunshine running / paired, and Play streams from
   it. The AWS-only pieces hide for it.

## Things that must be right

- **The Tailscale node must not expire or vanish.** AWS boxes are throwaway; a
  home PC is not. Turn off key expiry (as `lib/tailnet-expiry.sh` does), never
  join it with an ephemeral key, and make sure the stale-node pruning
  (`lib/tailnet-prune.sh`) can never match it.
- **A desktop must be signed in.** Sunshine streams a running session, so the
  machine needs a logged-in desktop, or a dummy display plug when headless.
  Setup checks and says so.
- **Windows** needs Windows 10/11's built-in OpenSSH server switched on; the
  setup commands are PowerShell.
- **Linux distributions:** start with Ubuntu/Debian and Arch (CachyOS), and
  refuse plainly on anything else rather than guess.

## Later, separately

- Wake-on-LAN on Play, and suspend when idle (needs something always-on at home
  to send the wake packet).
- More than one own machine.
- Other cloud providers (each needs its own launch / delete / price / storage).

## Build order

1. CLI: `cg host add | setup | status`, Linux first. Testable against a real
   Linux machine over ssh - this laptop itself can be the test host.
2. Windows setup steps. Needs a Windows machine to try; none is available here.
3. App: the AWS / own-machine choice, and the pages that change with it.

## How step 1 behaves (as built)

- Machines are kept in `~/.config/cg/hosts.json`, mode 0600 (it holds each
  one's Sunshine login).
- Every remote command runs through `sh -c`, so the login shell on the machine
  (fish on CachyOS) does not matter. ssh is given stdin only for data piped on
  purpose, so it cannot swallow an answer the app sends cg.
- Sunshine is installed from LizardByte's latest release, the file picked by
  the distribution's own os-release (`+ubuntu24.04_amd64.deb`, `+debiantrixie`,
  `-x86_64.pkg.tar.zst`, `.fc43.x86_64.rpm`) - no version written down.
- A sudo password, when the machine needs one, is asked once per setup and
  handed to sudo on the machine's stdin; never saved, never on a command line.
  The Tailscale auth key goes in a 0600 temp file on the machine, not argv.
- The Sunshine login uses the same code as the AWS build (lib/sunshine-login.sh):
  saved first, checked, set again on the machine when they disagree.
- A name that the AWS clean-up could match (`gamevps`, `gamevps-2`) is refused.

## Open questions

- Which Windows machine can the Windows steps be tried on?
