# Commands

`cg` is the only entry point. It dispatches into `lib/setup` and `lib/game`, which keep working on
their own - the odd-looking lines in those scripts are scars from real failures, so `cg` calls them
rather than reimplementing them.

## Every command

| Command | What it does |
|---|---|
| `cg init` | Build everything; reuses an existing box. **Costs money** |
| `cg open` | Start, stream, and on exit offer to end the box. **Costs money** |
| `cg stop` | Mirror the games to S3, then end the box - destroy on spot (a spot box cannot be stopped), stop on demand |
| `cg status` | Instance, disks, guards, tailnet, game library, local tools |
| `cg status --json` | The same facts as data, for a program - see [app-design.md](app-design.md) |
| `cg library` | What is on the box vs in S3, and what the archive costs |
| `cg library list --json` | The archive per game, its orphans and what fits on the box, as data |
| `cg library push` | Mirror the games to S3 now (`--verify` for a full comparison) |
| `cg library pull` | Restore the games from S3 now |
| `cg games` | What Steam has: installed, downloading (with progress), running, archived |
| `cg games --volume` | The **old** EBS volume, if you still have one, and its monthly cost |
| `cg snapshot` | Save an AMI of the box. **Bills monthly** |
| `cg snapshot --list` | What images exist and what they cost |
| `cg snapshot --delete <id>` | Delete an image **and its backing snapshots** |
| `cg clean` | Free space: apt caches, logs, `/scratch/tmp`. Games are not touched |
| `cg pair` | Redo the Moonlight handshake - no rebuild needed |
| `cg destroy` | Mirror the games to S3, then delete the box. **Refuses if the mirror fails**. Keeps the budget |
| `cg destroy --force` | Destroy even if the mirror failed - **loses the games** |
| `cg destroy --no-push` | Destroy and leave the archive exactly as it is - locks it first |
| `cg destroy --all` | The box **and the whole account footprint** - archive, bucket, IAM, budget. Asks you to type `DESTROY-ALL` |
| `cg check [--fix]` | Every preflight check, creates nothing. `--fix` first installs what the laptop is missing - AWS CLI v2, Tailscale, Moonlight, OpenSSH, curl, python3 - and signs in to Tailscale and AWS, after asking once. Any missing `.env` setting is asked for with its default shown and saved there |
| `cg cost [--daily]` | Month-to-date spend and what still bills; `--daily` adds a day-by-day table, from the same single API call |
| `cg cost --json` | The same call as data: per day, per usage type, hours, egress, what still bills |
| `cg --version` | The commit, and the version of the event contract a program can rely on |
| `cg log [what] [--watch]` | `build` \| `steam` \| `watchdog` \| `disk` \| `sunshine` |
| `cg ssh [cmd]` | Shell on the box - resolves the suffixed tailnet name for you |
| `cg watcher [--watch]` | Every guard, and whether each is genuinely armed - including what the cloud watchdog last decided, and when |
| `cg watcher --json` | The same guards as data: armed, what each catches, its last decision |
| `cg watchdog [status\|check\|logs\|install\|remove]` | The cloud watchdog: schedule and recent decisions; `check` runs it now as a dry run |
| `cg machines` | What GPU shapes this region rents, their specs, and what each costs on spot and on demand. Reads only; costs nothing |
| `cg machines --all` | The same, including shapes no quota covers |
| `cg machines --json` | The same table as data - the app's instance picker is fed from this |
| `cg machines <region>` | The same table for a region you are not in |
| `cg sweep` | **Every AWS region**, scored for whether it can run this rig at all: measured latency, AWS's own spot capacity score, and your quota there. Reads only; costs nothing |
| `cg sweep --all` | The same, listing the regions excluded for latency and how far they are |
| `cg sweep --cached --json` | The LAST scan, instantly, without running one. This is what the desktop app reads when it opens; a scan takes about 90 seconds and no screen waits on one |
| `cg regions` | The regions your account has enabled. One `describe-regions` call |
| `cg notify` | Send a test push notification to `GAME_NTFY_URL` |
| `cg ping [--watch]` | Latency, and **direct vs DERP relay** - the usual cause of a bad session |

`--region` and `--host` override `.env` without editing it; `--json` works on `ping`,
`machines`, `sweep`, `regions` and `snapshot --list`.

### Where the settings live

`.env` is resolved once, by [lib/env-file.sh](../lib/env-file.sh), first hit winning:

| | |
|---|---|
| `$CG_ENV_FILE` | said outright |
| `$CG_HOME/.env` | a chosen state directory |
| `<repo>/.env` | a checkout that already has one |
| `<repo>/.env` | a checkout cg can write to - the normal case |
| `~/.config/cg/.env` | otherwise: an installed, read-only copy |

A clone keeps its settings in itself, exactly as it always has. The fallback exists because an
installed app is read-only - an AppImage mounts squashfs - so there is nowhere in the install to
write. `cg config get GAME_REGION` and `cg status` report whichever file is in force.

### Choosing the machine

`cg machines` exists because the instance type used to be a constant, and a region running out
of capacity for that one shape meant no box at all. The table names the alternatives a quota
already covers, so the choice does not need a quota appeal first:

```
  TYPE           VCPU  GPU       VRAM     RAM     DISK     SPOT / ON DEMAND
  *g6.xlarge     4     L4        22.4 GB  16 GB   250 GB   INR 13   / INR 85
   g6e.xlarge    4     L40S      44.7 GB  32 GB   250 GB   INR 49   / INR 197
```

### Choosing the region

`cg machines` answers "what does this region rent", which is only the right question once the
region is settled. `cg sweep` asks the prior one, and exists because a week was lost retrying
`g6.xlarge` in `ap-south-2` on the assumption that spot capacity comes back - while
`get-spot-placement-scores`, free and available the whole time, scored `ap-south-2` at **1/10**
for every type this rig can use and `ap-south-1` at **9/10**.

```
  REGION           CITY        LATENCY TYPE          SCORE  QUOTA     SPOT / ON DEMAND
   ap-south-1      Mumbai      22 ms   g4dn.xlarge   9      ok/0      INR 18 / INR 51
   ap-southeast-5  Malaysia    48 ms   g6.xlarge     9      opt-in    - / INR 89
  *ap-south-2      Hyderabad   19 ms   g6.xlarge     1      ok/ok     INR 13 / INR 85
```

Three columns, because a region fails for three unrelated reasons and they need telling apart:

- **LATENCY** is measured now, not looked up. A coarse parallel pass shortlists, then a quiet
  second pass decides - ten simultaneous TLS handshakes inflate each other by 10ms or more, and
  filtering on the inflated number drops regions that qualify. The budget is 80ms, which is
  NVIDIA's own stated requirement for GeForce NOW; `CG_SWEEP_MAX_MS` moves it.
- **SCORE** is AWS's spot placement score, 1-10, and the only forward-looking number AWS
  publishes. A `1` has been a reliable "do not bother". A dash means AWS said nothing, which
  means the type was never on sale there - *not* that it has no capacity.
- **QUOTA** is on demand/spot. `0` means ask for quota; `opt-in` means the region is not
  enabled so the quota cannot be read yet. Different actions, so they are never one symbol.

Sorted by capacity rather than distance, on purpose: the nearest region is often the wrong
answer, and saying so is the entire point. Every call behind it is free, including the Pricing
API lookup that costs a region you have not opted into yet - the only number available before
enabling one.

A scan is remembered in `$XDG_CACHE_HOME/cg/sweep.json` (`~/.cache/cg/sweep.json`), because the
answer changes over hours, not seconds. Nothing ever requires it: every reader works when it is
missing, stale or unreadable, and `cg sweep` always scans afresh.

### The desktop app's Machine table

The app had three dropdowns - region, instance type, purchase model - and that was the
complaint. They are not three decisions: the question is which COMBINATION to run, most
combinations cannot launch, and a dropdown per axis hid exactly the comparison that decides it.

Settings now carries one table fed by `cg sweep --cached`, one row per region and machine, and
**picking a price sets all three settings together**. A price you cannot pick is disabled and
says why in the cell - `no quota`, `needs opt-in`, `no spot market` - because "why can I not
choose this" was the other half of the confusion. A spot cell showing `18-20` is the cheapest
and dearest zone; nothing pins the zone, so either is possible.

The Build screen deliberately has no copy of it. It states what will be built, warns when that
choice cannot launch, and offers **Change setup**, which goes to Settings and flashes the table.

**The archive does not follow a region change.** It is S3 in the region you are leaving, and
inter-region transfer is $0.1093/GB, so moving 163GB costs about INR 1,234 each way - more than
the compute. Data *into* EC2 is free, so the cheaper move is to reinstall from Steam in the new
region (about an hour of instance time) and delete the old archive once the new box works.

### Choosing the machine, continued

Two things the single hard-coded type used to hide. **A shape may not fit your quota at all** -
larger `g6`s are cheaper per hour on spot than `g6e.xlarge`, and all of them need a quota
increase, so they are listed separately rather than offered. And **the spot price is per zone**:
nothing pins the AZ any more, so the table shows the cheapest zone and the JSON carries the
dearest, which can be more than double.

Change it with `cg config set GAME_INSTANCE_TYPE <type>`, or from the dropdown on the app's
Build screen - which writes the same setting. It applies to the next `cg init`; a running box
is untouched.

## Terminal output

On a terminal, progress is drawn as boxed steps with an emoji, a symbol per line and a live
line while something is waited on:

             ╭─ 💾 mirroring the game library to S3 ..................... 23:19:03
    23:19:03 │  ✓ steam account: archived 21KB (login, controller config, cloud staging)
    23:19:03 │  · not archiving Proton Experimental (1493710) - a Steam tool
    23:19:04 │  ✓ pushed 1 game(s) in 8s
             ╰─ ✓ done in 8s

    ✓ done    ✗ failed    ! warning    ◌ waiting    ↺ kept    ▸ sub-step    · info

**Anywhere else it is the plain format, byte for byte** - a pipe, a redirect to a file, the test
suites. `cg destroy > destroy.log` stays greppable, with full ISO timestamps. That rule is also
what makes every existing test a regression test for the styling: they all capture output, so
they all see plain text, and `tests/ui.sh` covers the styled side with a real pty.

| Variable | Effect |
|---|---|
| `CG_COLOR=never` | Plain output even on a terminal |
| `CG_COLOR=always` | Styled output even into a pipe (e.g. `cg init | less -R`) |
| `NO_COLOR=1` | Plain output - the [no-color.org](https://no-color.org) convention |

The symbol on each line is chosen from its words, so the existing messages needed no changes. A
wrong guess costs a symbol, never a message: the text is printed exactly as written.

The reports - `cg status`, `cg cost`, `cg games` - and the restore picker at `cg init` get the same
treatment: each section is a box with an emoji, `[ok]`/`[--]` become ✓/✗, states are coloured
(running and installed green, disarmed and downloading yellow, missing and INCOMPLETE red) and
`<-` hints turn yellow. They are restyled from their finished text rather than rebuilt, and only
colour and a gutter are added, so every column keeps its position - `tests/ui.sh` strips both
from each row of real reports and checks the original comes back character for character.

Deleting an image deregisters it **and** deletes its backing snapshots. Deregistering alone
leaves those billing - the usual way to believe you deleted something and keep paying for it.

## Machine-readable output

For a GUI, a script or anything else driving `cg`, `CG_JSON=1` turns every progress helper into
**one NDJSON event per line**, so nothing has to scrape text written for people. The three streams
each have one job:

| Stream | Carries |
|---|---|
| **stderr** | the events |
| **stdout** | the command's own data - `cg ping --json`, a report you piped somewhere - and raw output from what `cg` ran (`aws`, `ssh`, tables) |
| **stdin** | answers to `ask` events, one line each |


    $ CG_JSON=1 cg init
    {"t":"step","at":"2026-09-25T22:26:22+05:30","text":"provisioning instance"}
    {"t":"line","at":"...","kind":"ok","text":"i-0abc launched"}
    {"t":"line","at":"...","kind":"cont","source":"box","text":"nvidia driver packages installed"}
    {"t":"step_end","at":"...","rc":0,"secs":19}

| Event | When | Fields |
|---|---|---|
| `step` | a step begins | `text` |
| `line` | a detail line | `kind` (`ok`, `fail`, `warn`, `wait`, `kept`, `skip`, `info`, `cont`), `text`, `source` (`box` when it came from the instance) |
| `step_end` | the step closes, including on exit or Ctrl+C | `rc`, `secs` |
| `report` / `block` | a whole report or notice | `title`, `text` (newline-escaped) |
| `ask` | a question. Answer with one line on stdin | `id`, `prompt`, `default`, `choices`, `secret` |
| `error` | `die` - the command then exits 1 | `text` |

Rules worth knowing:

- **A line that does not parse is raw output** from a command `cg` ran (`aws`, `ssh`, a table). Show
  it or ignore it, but do not parse it.
- **`CG_JSON=1` wins over `CG_COLOR=always`**, and whole escape sequences are stripped from event
  text, so no styling can ever reach the stream.
- **Every question is an `ask` event.** Reply with one line on stdin:

      → {"t":"ask","id":"terminate-box","prompt":"terminate? [y/N] ","default":"N","choices":""}
      ← y

  No reply, or end of input, leaves the default standing. A `secret` question - a key being
  pasted - is marked `"secret":1`, and its answer is never echoed back.
- **`CG_YES=1` answers every yes/no question with its default**, for a script that must not block.
  It does **not** answer a typed confirmation (`DESTROY-ALL`, `FORGET`, `CLEAN`, `DELETE`): typing
  the word is the confirmation, so there is nothing to assume. `cg destroy --all --force` remains
  the way to skip that one deliberately.
- **The game picker is not asked** in a driven run: set `GAME_APPS` in `.env` (a csv of appids,
  `all`, or `none`) and `cg init` uses it without prompting.
- The human formats are unchanged: this is a third mode beside styled and plain.

## Running a command twice

Everything is safe to run again. The ones worth knowing:

| Command | Second run |
|---|---|
| `cg init` | Reuses the instance and skips what is done - **but it starts a stopped box, so it costs money** |
| `cg open` | Refuses while a stream from this laptop is still open, and names the pid. Two Moonlight windows on one box share its GPU and spend egress twice |
| `cg stop` | On spot, offers destroy again; on demand, says "already stopped" |
| `cg clean` | Frees less each time; needs the box running |
| `cg destroy` | No-op. The first run keeps nothing and asks nothing |
| `cg cost` | Each run makes one Cost Explorer call ($0.01) - `--daily` included |

**The two that cost money unprompted** are `cg init` and `cg open` - both start a stopped
instance. Everything else is read-only or asks first.

**The one that cannot be undone** is `cg destroy`: it runs immediately, with no confirmation,
and keeps nothing. To keep the installed desktop, `cg snapshot` first.
