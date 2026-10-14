# Desktop app: what each screen shows, and where it comes from

A design record for a desktop app over `cg`. The mockups in `stitch_design/` are the look; this
page is the contract. Every field on a screen names the command that produces it, whether that
command is free, and how often it may run.

## The rule that keeps this honest

**The scripts are the engine; the app is a viewer.**

- The app ships **no AWS logic**: no SDK, no bucket names, no IAM, no prices.
- It runs `cg` with `CG_JSON=1` and renders the [event stream](commands.md#machine-readable-output).
- New behaviour lands in `cg` first, with a test. The app then learns a new event or field.
- If a screen wants data no command exposes, the fix is a `--json` field in `cg`, never parsing the
  human tables.

## Refresh rules, because one command bills

| Command | Cost | May the app run it |
|---|---|---|
| `cg status`, `cg watcher`, `cg watchdog status`, `cg library list`, `cg games` | free | yes - on open, and on a timer while the window is focused (30 s is plenty) |
| `cg cost`, `cg cost --daily` | **$0.01 per run** | **only when the person clicks**, behind a button labelled with the price. Twenty polls a day is INR 530 a month, more than the archive it reports on |
| `cg init`, `cg open`, `cg destroy`, `cg watchdog install` | changes AWS | only on an explicit action, one job at a time |

The last figures from a paid call are cached in `.cg-cache/` with their age; the app shows the age
rather than asking again.

## Opening the window: the first-run pipeline

The dashboard, on a laptop that is not ready, **is** the setup flow: six stages in the order they
have to be met, one of them active, and a pane beside it carrying cg's own output. When the last
stage is met the pipeline collapses to a line and the cards take over.

| Stage | met when | what it offers |
|---|---|---|
| the tools | `cg deps` finds them all | **Install them** - runs `cg deps install` in the pane; the password prompt is the OS's own, once |
| the AWS CLI | `cg creds` has a CLI to ask with | same button, and the row is hidden while the tools stage is unmet - one job, one button |
| the key | `cg creds` says AWS accepts it | **Add your key**, or **Try again** when cg reports `reason: unreachable` |
| this laptop on the tailnet | `cg creds tailscale` says signed in | **Sign in** - runs in the pane, which carries the sign-in link while cg waits for the browser |
| a key for the box | a key is stored, or cg can mint one | **Paste a key**. A laptop whose API token can mint one never sees this stage |
| billing alerts | `EMAIL_ALERTS` is set | **Add an address**. Mandatory: a build sets a budget alarm and cannot leave it with nowhere to go |
| where it runs | `cg machines` says the configured region rents something that fits | **Choose where** - a dialog of every measured location, its latency and its rupee rates |

The dashboard has three phases, and it only ever moves forwards:

| phase | what is on screen |
|---|---|
| `setup` | the pipeline. The cards (`#d-main`) are hidden - a box, an archive and a bill are not worth showing to someone who cannot build one yet, and they used to sit underneath saying "No box" as though that were the news |
| `handover` | all six ticked, "Your rig is ready / Opening your dashboard…", held for `ONB_HANDOVER_MS` (900 ms). Without the beat, a laptop that is already set up flashes six ticks for 200 ms, which reads as a glitch |
| `dashboard` | the cards, with one line where the pipeline was |

A prerequisite that breaks later in the session does **not** drop back into setup - that is the
banner's to report. Pulling a setup flow up out from under someone who is using the app would be
worse than the problem.

Rules it holds to:

- **One active stage.** Everything unmet below it is `locked` and has no button, so you cannot
  start in the middle. A stage that is already met is ticked wherever it sits. A stage whose read
  is still in flight says `checking…`; one that came back broken, or whose prerequisite is unmet,
  shows `?`. Those are three different sentences and they used to be one.
- **The stages are `prereqs()`**, the same list the banner reads, and a stage uses the rung's own
  button. That table used to carry its own labels, which is how the stage for a laptop that could
  not *reach* AWS offered "add your key" instead of "try again".
- **The pane is permanent furniture**, not something that appears: empty before anything runs,
  cg's words while it does, the last thing it said afterwards. It replaced the header's
  `running: cg machines, cg refresh`, which is gone. It follows the output to the bottom - an
  install prints for minutes and the pane is a few lines tall - but only when that is already
  where you are: scroll up to read something and it leaves you there. Measured before the line is
  appended, since appending to a box at the bottom moves the bottom.
- **A dialog is only ever for text you have to type** - the key, an address, an auth key - or for a
  choice, which is what *where it runs* is. Progress is never a dialog.
- **Where it runs is judged on what AWS will let you launch**, not on whether a button was pressed.
  A region that is switched on but has no GPU quota looks completely set up and cannot build; that
  read as a broken app rather than as a step.
- **No engine at all** (`cg:engine` says so) replaces the whole pipeline with one failed stage
  naming the path it looked at, and **Try again**.
- The banner stays for a problem that turns up mid-session, and steps aside only on the dashboard,
  where the pipeline is already saying it. It sits above every other screen, which the pipeline
  does not.

What this replaced, in order: a banner naming one problem at a time with no sense of how many there
were; a modal popup over a window you could not use yet; that popup moved into a corner so it would
stop blocking; buttons on the popup; fewer buttons on the popup. All five were ways of avoiding the
fact that four screens were designed and every one of them assumes the rig already works.

## Dashboard

| Field | Source | Free | Notes |
|---|---|---|---|
| Box state (No box / Building / Ready / Shutting down) | `cg status` → `RESOURCES` instance line | yes | while a build runs, the state comes from the job's own event stream instead |
| Instance type, purchase model, region | `.env` (`GAME_INSTANCE_TYPE`, `GAME_SPOT`, `GAME_REGION`) and `cg status` | yes | |
| Hourly rate | `cg cost` (`$/hr` lines) | **$0.01** | cached; never fetched on a timer |
| Uptime | `cg status` box lines | yes | |
| Month-to-date spend | `cg cost` total | **$0.01** | show the cached value and its age |
| Daily sparkline | `cg cost --daily` | **$0.01** | same call as `cg cost`, so no extra charge when the person refreshes |
| "nothing is billing - no box" | `cg cost` resources block | **$0.01** | |
| Archive size, object count, monthly cost | `cg status` / `cg cost` game-library line, or `cg library list` | yes (`library list`) | prefer `cg library list`: free, and it lists games |
| Archive countdown ("deleted in 4d 1h") | `cg watchdog status` / `cg status` game-archive line | yes | comes from the watchdog's last hourly decision, with its age |
| Guard pills (4) | `cg watcher` | yes | session guard, on-host watchdog, cloud watchdog, budget |
| Play / Streaming | `cg status` → `session` | yes | a `cg open` running on this laptop holds a lock; the app asks cg rather than looking for Moonlight, so a stream it never started still disables Play |
| Recent activity | the app's own job history, plus the watchdog's last decision from `cg watcher` | yes | the durable record is the watchdog's log, shown on Guards |
| Instance stage (No box / Building / Ready) | `cg status` state, plus whether a `cg init` is running in this window | yes | never "Ready" while a build is in flight |
| Spend control card | `cg cost --json` | **$0.01** | only from its Fetch button, which carries the price; the sparkline is the same `days` array the Cost table uses |

## Build

| Field | Source | Free | Notes |
|---|---|---|---|
| Machine strip: vCPU, RAM, GPU, VRAM | `cg status --json` → `spec` | yes | one `describe-instance-types` call, shared with the quota check - nothing about the type is written into the app |
| Archived games: appid, name, size, archived date | `cg library list` | yes | the real archive today holds **one** game (Diablo IV, 160.2 GB) |
| "160 GB selected of 209 GB available" | `cg library list` footer (229 GB disk, 209 GB selectable) | yes | the arithmetic that refuses an over-large selection lives in `lib/choose-games.py` and must stay there. With no `selectable_gb` in the answer the app says the disk is not known - it never fills in a plausible 209 |
| Build progress steps | the `cg init` event stream: `step`, `step_end` | - | the six steps in the mockup are the real ones: provision, tailnet, driver, restore, desktop, pair |
| Confirmations (destroy, image, clean) | `ask` events, answered on stdin | - | render the prompt, send back one line. Typed words (`DESTROY-ALL`) must be typed by the person |
| Live restore line ("28 of 160 GB, ~10 min left") | `line` events with `source: box` | - | already emitted during the build |
| Raw log panel | `raw` lines (anything that is not an event) | - | |
| "Build (10-20 min)" | runs `cg init` | **spends money** | the app must pass the chosen games, so the picker prompt never appears - see gaps below |
| Cancel build | kill the job | - | ask first: killing a build mid-restore wastes the hours already spent |

## Cost

| Field | Source | Free | Notes |
|---|---|---|---|
| This month, credits left, today | `cg cost` | **$0.01** | one call fills the whole screen |
| Daily table (date, hours, compute, S3, disk, egress, API, other, total, INR) | `cg cost --daily` | same call | days with nothing billed are hidden and counted, as the CLI does |
| "What still bills with no box" | `cg cost` resources block | same call | the archive, its monthly cost and its countdown |
| Projected month end, and the budget bar | `cg cost --json` → `month.projected_usd` / `projected_inr` | same call | cg divides the month-to-date by the days the answer covers; the app renders the number and works out no dates of its own |
| Streaming allowance (29.3 of 100 GB, hours left) | `cg cost` egress lines | same call | |
| Refresh button | `cg cost --daily` | **$0.01** | label it with the price, always |

## Guards and settings

| Field | Source | Free | Notes |
|---|---|---|---|
| Three guard cards, armed state, last decision | `cg watcher --json` → `guards[]` | yes | one card per layer cg reports, never a layer the app knows about - reaction times come from the field, not the markup |
| "N of M armed" | the same array | yes | layer 1 has `armed: null` (it either runs or it does not), so it is not counted; counting it read as a missing guard |
| The knobs behind the guards | `cg config --json`, edited with `cg config set` | yes | idle and stuck minutes, archive expiry, budget, ntfy, alert email - the same rows as Settings |
| Dry-run evaluation | `cg watchdog check` | yes | runs the Lambda once, changing nothing |
| Budget, spend against cap, alert address | `cg status` COST GUARDS, `.env` `EMAIL_ALERTS` | yes | the budget **emails**; it does not block launches |
| Root disk, archive expiry, notifications, API token | `.env` | yes | the app shows set / not set, never the value |
| Edit a setting | writes `.env` through `cg`'s own rules | yes | expiry and disk changes apply at the next `cg init`; the app should say so |

## What the mockups get wrong

Recorded so the errors are not carried into code. The designs were generated from a prompt, and the
tool invented AWS detail.

| Mockup | Reality |
|---|---|
| "Game archive **EBS snapshot**", `snap-…`, "cold block archive", "EBS lifecycler" | S3 objects, deleted by the cloud watchdog. No snapshots |
| Restore "from snapshot to `/mnt/games`", "EBS IOPS" | `s5cmd` from S3 to `/scratch`, the instance-store NVMe |
| Budget "hard lock blocks fresh EC2 launches" | the budget only emails. Showing a lock that does not exist is worse than showing nothing |
| "Session Run Guard - 4 h hard cap" | layer 1 is `cg open`, which ends the session when Moonlight exits |
| On-host watchdog "Win32 GetLastInputInfo, cloudrig-agent.exe" | a bash watchdog on Linux reading interface byte counters |
| Cloud watchdog "< 150 KB/s egress" | 10 MB **in + out** per 5-minute period - inbound is what stops a download reading as idle |
| "SMS via AWS SNS", a phone number | ntfy push to a topic, free. SNS SMS is billed per message |
| "Auto-failover to a secondary region" | does not exist |
| Spot "~$0.38/hr" | ~$0.21/hr, INR 19.8 measured |
| Three games in the archive | one, today |
| IAM user and account id in the sidebar | mask by default: these end up in screenshots |
| "Keep (+30 d)" | no such command. It should open the archive-expiry setting |

## What `cg` still owes the app

1. ~~Flags or `ask` events for the prompts.~~ **Done.** Every question is a `cg_ask` call, so under
   `CG_JSON=1` it arrives as an `ask` event and the answer is one line on stdin. `CG_YES=1` takes
   each yes/no default; typed confirmations still require the word; the game picker reads
   `GAME_APPS`. See [commands.md](commands.md#machine-readable-output).
2. ~~`--json` for the reports.~~ **Done** for `status`, `cost`, `library list` and `watcher` - each
   renders from the same facts as its report, so the two cannot drift. `games` still prints text
   only; the app does not use it yet.
3. ~~`cg --version`.~~ **Done**: it prints the commit and the event-contract version.

## Where it is now

`app/` is an Electron app with seven screens, built on the Stitch design: its Tailwind config,
fonts and icons are vendored, so nothing is fetched at runtime.

| Screen | Reads | Does |
|---|---|---|
| Dashboard | `cg status --json` | Build (to the Build screen), Play, Destroy - each confirms first |
| Build | `cg library list --json` | picks games against the disk's capacity, runs `cg init` with `GAME_APPS`, shows the steps live |
| Library | `cg library list --json` | lists the archive per game, with orphans and what fits |
| Guards | `cg watcher --json` | a card per layer: what it catches, its reaction, its last decision |
| Cost | `cg cost --json` | tiles, the daily table, what still bills, the egress allowance - one $0.01 call, only on click |
| Settings | `cg status --json` | shows what `.env` decides; secrets as set / not set, never values |
| Logs | any run | the live event stream |

`tests/app.sh` enforces the rules below, and `app/test/` tests the runner against a fake `cg`.

## Safety rules for the app

- **Never display a secret.** The Tailscale keys, the ntfy topic and the Sunshine password stay in
  `.env`; screens show set / not set.
- **Mask identifiers by default** - account id, instance id, bucket name - with a reveal control.
- **Every button that spends money says so**, in the label: `$0.01`, or "spends money".
- **One job at a time**, and quitting mid-job asks, because killing `cg destroy` during its final
  upload is how games are lost.

## What the app may not know

`cg --contract` publishes the few facts the window would otherwise have to copy: which commands must
run alone (cg takes the locks), which ask ids cg may ask under, and the event-format version. Each
one was written down in the app as well, and each disagreed with cg at least once - silently, since
a command that is never started looks exactly like one that returned nothing, and a pre-answer that
no longer matches its id just puts a modal in the middle of a build. The app reads the contract at
startup, assumes the worst if it cannot, and names the ids it knows in one table (`ASK`) that is
checked against cg's list.

Prices, disk sizes, exchange rates and projections are cg's too. Where an answer is missing the
screen says it is not known; it never fills in a number that reads like an answer.
