# Commands

`cg` is the only entry point. It dispatches into `lib/setup` and `lib/game`, which keep working on
their own - the odd-looking lines in those scripts are scars from real failures, so `cg` calls them
rather than reimplementing them.

## Every command

`cg` is the front door. It dispatches into `setup` and `game`, which both keep working - the
odd-looking lines in those scripts are scars from real failures, so `cg` calls them rather than
reimplementing them.

| Command | What it does |
|---|---|
| `cg init` | Build everything; reuses an existing box. **Costs money** |
| `cg open` | Start, stream, stop on exit. **Costs money** |
| `cg stop` | Mirror the games to S3, then stop the instance - ends hourly billing |
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
| `cg destroy` | Mirror the games to S3, then delete the box. **Refuses if the mirror fails**. Keeps the budget |
| `cg destroy --force` | Destroy even if the mirror failed - **loses the games** |
| `cg destroy --no-push` | Destroy and leave the archive exactly as it is - locks it first |
| `cg destroy --all` | The box **and the whole account footprint** - archive, bucket, IAM, budget. Asks you to type `DESTROY-ALL` |
| `cg check` | Every preflight check, creates nothing |
| `cg cost` | Month-to-date spend and what still bills |
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

## Running a command twice

Everything is safe to run again. The ones worth knowing:

| Command | Second run |
|---|---|
| `cg init` | Reuses the instance and skips what is done - **but it starts a stopped box, so it costs money** |
| `cg open` | Connects again if already running |
| `cg stop` | Says "already stopped" |
| `cg clean` | Frees less each time; needs the box running |
| `cg destroy` | No-op. The first run keeps nothing and asks nothing |
| `cg cost` | Each run makes one Cost Explorer call ($0.01) |

**The two that cost money unprompted** are `cg init` and `cg open` - both start a stopped
instance. Everything else is read-only or asks first.

**The one that cannot be undone** is `cg destroy`: it runs immediately, with no confirmation,
and keeps nothing. To keep the installed desktop, `cg snapshot` first.
