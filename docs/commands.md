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
| `cg library` | What is on the box vs in S3, and what the archive costs |
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
| `cg log [what] [--watch]` | `build` \| `steam` \| `watchdog` \| `disk` \| `sunshine` |
| `cg ssh [cmd]` | Shell on the box - resolves the suffixed tailnet name for you |
| `cg watcher [--watch]` | Every guard, and whether each is genuinely armed - including what the cloud watchdog last decided, and when |
| `cg watchdog [status\|check\|logs\|install\|remove]` | The cloud watchdog: schedule and recent decisions; `check` runs it now as a dry run |
| `cg notify` | Send a test push notification to `GAME_NTFY_URL` |
| `cg ping [--watch]` | Latency, and **direct vs DERP relay** - the usual cause of a bad session |

`--region` and `--host` override `.env` without editing it; `--json` works on `ping` and
`snapshot --list`.

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
**one NDJSON event per line**, so nothing has to scrape text written for people:

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
| `error` | `die` - the command then exits 1 | `text` on **stderr** |

Rules worth knowing:

- **A line that does not parse is raw output** from a command `cg` ran (`aws`, `ssh`, a table). Show
  it or ignore it, but do not parse it.
- **`CG_JSON=1` wins over `CG_COLOR=always`**, and whole escape sequences are stripped from event
  text, so no styling can ever reach the stream.
- **Prompts still go to the terminal.** A run driven this way should pass the flags that avoid
  them - `cg destroy --force`, `GAME_APPS` in `.env`, and so on.
- The human formats are unchanged: this is a third mode beside styled and plain.

## Running a command twice

Everything is safe to run again. The ones worth knowing:

| Command | Second run |
|---|---|
| `cg init` | Reuses the instance and skips what is done - **but it starts a stopped box, so it costs money** |
| `cg open` | Connects again if already running |
| `cg stop` | On spot, offers destroy again; on demand, says "already stopped" |
| `cg clean` | Frees less each time; needs the box running |
| `cg destroy` | No-op. The first run keeps nothing and asks nothing |
| `cg cost` | Each run makes one Cost Explorer call ($0.01) - `--daily` included |

**The two that cost money unprompted** are `cg init` and `cg open` - both start a stopped
instance. Everything else is read-only or asks first.

**The one that cannot be undone** is `cg destroy`: it runs immediately, with no confirmation,
and keeps nothing. To keep the installed desktop, `cg snapshot` first.
