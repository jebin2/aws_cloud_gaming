# Plan: rename the project to Ayis

**Ayis: All Yours, Instantly Streamed.**

Status (2026-11-10): **steps 1-8 done** on branch `rename-ayis`. The grep gate is clean, `go test`, `npm test` and the 24 local shell suites pass, and the 20 browser suites still have to run on GitHub. Step 0 (teardown with the old program) and step 9 (go live) are not done.

**Decision: rename everything, with no aliases.** The project is in beta and has no users other
than its author, so nothing needs to stay compatible. `cg`, `cloud_gaming`, `cloud-gaming`,
`aws_cloud_gaming`, "Cloud Gaming", `cg-*`, `cg:*`, `CG_*` and the `gamevps` default all go.
Instead of migrating the old state, it is **torn down with the old program and built fresh with
the new one.**

## Cost

**About INR 0, plus one ordinary session if you test Play.** Measured on 2026-11-10 with `cg status`
(read only):

| What exists in AWS (ap-south-1) | Size or cost now | What happens |
|---|---|---|
| instance, volumes, snapshots, images, EIPs | none | nothing |
| game archive `s3://cg-library-83d90324e407` | 1 object, 69 B, $0.00/mo, expires in about 13 days anyway | deleted |
| saved Steam login (in the archive) | 29 KB | deleted, so **the first new box asks you to sign in to Steam once** |
| `gamevps-box` role, `gamevps-cloud-watchdog` Lambda, role and schedule, `gamevps` security group and key pair, `gamevps-monthly` budget, `/cloud-gaming/gamevps/` parameters | free | deleted, then rebuilt as `ayis-*` |
| quotas (4 vCPU on-demand and spot, ap-south-1) | - | **untouched**: quotas belong to the account, not to names |
| account plan, credits ($115.68), budget alerts | - | untouched (the budget is rebuilt with the same $53 limit) |

The rebuild (bucket, role, watchdog, budget) is created by the first `ayis init` and costs nothing
until a box runs. Tearing down first matters: if the new program ran against the old state, the
old resources would sit there unseen. They cost nothing today, but an archive with games in it
would bill every month.

---

## Everything that changes

Counts are from `git grep` on 2026-11-10 (471 tracked files).

### 1. Go

- **Module path** (`go.mod`): `github.com/jebin2/aws_cloud_gaming` -> `github.com/jebin2/ayis`.
  479 import lines. Use `go mod edit -module` plus one `sed`, then `gofmt -l .` and `go vet ./...`.
- **Root package** `cg` (`embed.go`, used as `cg.Files.ReadFile(...)`) -> `ayis`.
- **Command** `cmd/cg` -> `cmd/ayis`. The binary is `ayis` / `ayis.exe`.
- **User-facing text**: usage, help, every `Say/Log/Die` message and the `contract` event text that
  names `cg` (1,058 whole-word hits in `internal/`, most of them comments). Comments change too,
  so a later grep for `cg` comes back clean.
- **Environment variables** `CG_*` -> `AYIS_*`. That covers every one: `CG_JSON`, `CG_YES`,
  `CG_HOME`, `CG_REPO`, `CG_COLOR`, `CG_AWS_ENDPOINT`, the rate knobs (`CG_S3_USD_GB_MONTH`,
  `CG_INR_PER_USD`, ...), the sweep knobs, the Lambda's (`CG_TS_HOST`, `CG_BUCKET`, ...), and the
  box's (`CG_APPS`, `CG_EXTRA_APPS`, `CG_LIB_DIR`, `CG_WALLPAPER*`, ...). `GAME_*` settings in
  `.env` keep their names: they describe the game machine, not the program.
- **SDK app ID** `cg` -> `ayis` (`awscfg.go:23`, `creds/set.go:44`).

### 2. AWS names

| Now | New | Where |
|---|---|---|
| tag key `cg:host` | `ayis:host` | `box/box.go:173`, `boxcmd/destroy.go:306`, `boxcmd/disk.go:385` |
| bucket `cg-library-<sha>` | `ayis-library-<sha>` | `internal/bucket/bucket.go:15,22`, `lambda/cloud_watchdog.py:817,830` |
| SSM `/cloud-gaming/<host>/` | `/ayis/<host>/` | Go `"/cloud-gaming/%s/..."`, `cloud_watchdog.py:623,807`, the IAM policies that grant it |
| instance tags `cg-going-down-since`, `cg-slow-noted`, `cg-forced`, `cg-stopped-since`, `cg-stopped-warned` | `ayis-...` | `cloud_watchdog.py:55-64`, `watchdog/definition.go:112` (IAM condition) |
| log prefix `cg-watchdog:` | `ayis-watchdog:` | `cloud_watchdog.py:103`, `watchdog/run.go:126`, `watchdog.go:36`, `install.go:172` |
| EventBridge IDs `cg-schedule`, `cg-state`, descriptions "cloud_gaming watchdog" | `ayis-schedule`, `ayis-state`, "Ayis watchdog" | `watchdog/install.go:217-219` |
| IAM policy and role descriptions "cloud_gaming box: ...", "cloud_gaming layer 3 ..." | "Ayis box: ..." | provision / watchdog definitions |
| `lambda/cloud_watchdog.py` | `lambda/ayis_watchdog.py` (or keep the file name; the function name comes from the host) | Lambda packaging in `internal/watchdog` |

**`GAME_TS_HOST` default `gamevps` -> `ayis`.** Every host-named resource follows it:
`ayis-box`, `ayis-cloud-watchdog`, `ayis-sg`, `ayis-monthly`, `ayis-games`, `ayis-image`, key pair
`ayis` and `~/.ssh/ayis.pem`, and the tailnet node `ayis`. `.env` does not set `GAME_TS_HOST`, so
the default is what applies. The old `gamevps` resources must be gone first (step 0).

Also update the help image `lib/assets/gamepc-help.png` (file name, and its text if it says
"gamevps", "cg" or "Cloud Gaming").

### 3. The box and own servers

| Now | New |
|---|---|
| `/opt/cloud-gaming-host` | `/opt/ayis-host` |
| `/var/log/cloud-gaming-bootstrap.log`, `/var/lib/cloud-gaming-bootstrap.rc`, `/var/lib/cloud-gaming-ready` | `/var/log/ayis-bootstrap.log`, `/var/lib/ayis-bootstrap.rc`, `/var/lib/ayis-ready` |
| `host/cg-build`, `cg-build.service` | `host/ayis-build`, `ayis-build.service` |
| `host/cg-library`, `/usr/local/bin/cg-library`, `/etc/cg-library.conf`, `/var/lib/cg-library/` | `ayis-library` throughout |
| `cg-library-restore.service`, `cg-library-shutdown.service`, `cg-extra-library.service`, `cg-restore-play-<t>` | `ayis-...` |
| `host/cg-notify`, `cg-shutdown-push.sh`, `cg-wallpaper.{sh,desktop}`, `~/.config/cg-wallpaper-set` | `ayis-...` |
| `/etc/cg-idle.conf` | `/etc/ayis-idle.conf` |
| own server: `~/.config/cg/sunshine-login` (`internal/ownhost/ownhost.go:73,338`) | `~/.config/ayis/sunshine-login` |
| Tailscale key description `"cg <host>"` (`tskey.go:115`, test at `tskey_test.go:75`) | `"ayis <host>"` |

Names without `cg` stay: `idle-watchdog`, `game-notify`, `disk-monitor`, `steam-add-extra-library`,
`steam-client-fetch`, `install-*.sh`.

Grep every renamed file name in `internal/` (`cg.Files.ReadFile("host/...")`), in
`lib/bootstrap.d/*.sh`, in `host/install-*.sh`, and in the `tests/` suites that stage them
(`library-*.sh`, `shutdown-push.sh`, `wallpaper.sh`, `extra-library.sh`, `bootstrap-order.sh`,
...).

### 4. The laptop

| Now | New |
|---|---|
| `$XDG_CONFIG_HOME/cg/.env` (`config/env.go:66`) | `$XDG_CONFIG_HOME/ayis/.env` |
| `$XDG_CONFIG_HOME/cg/hosts.json` (`hosts/hosts.go:21`) | `$XDG_CONFIG_HOME/ayis/hosts.json` |
| `~/.cache/cg/` (built separately in 8 places) | `~/.cache/ayis/`, built by **one helper** that all 8 call |
| `$TMPDIR/cg-session-<uid>.pid`, `cg-ts-*`, `cg-askpass-*`, `.cg-w-*`, `$f.cg` | `ayis-...` |
| `~/cloud_gaming` checkout (`app/main/repo.js:32`) | `~/ayis` |
| "hosts.json is locked by another cg" and similar messages | "another ayis" |

`.env` in the checkout keeps its place. Only `GAME_S3_BUCKET`, which names the old bucket, has to
go, and step 0 removes it.

### 5. Desktop app

`app/package.json`:

| Field | Now | New |
|---|---|---|
| `name` | `cg-app` | `ayis` |
| `description`, `linux.synopsis`, `linux.description` | "Desktop viewer for cg..." | "Ayis: All Yours, Instantly Streamed" + one line |
| `build.appId` | `dev.cg.desktop` | `dev.ayis.desktop` |
| `build.productName` | `cg` | `Ayis` |
| `executableName` | `cg` | `ayis` |
| `extraResources` | `../cg` -> `cg/cg`, `../.env.example` -> `cg/.env.example` | `../ayis` -> `ayis/ayis`, and the same for `.env.example` |
| `artifactName` (mac, win) | `cg-${version}-...` | `ayis-${version}-...` |
| `homepage`, `repository.url` | `.../aws_cloud_gaming` | `.../ayis` |
| `version` | `0.1.0` | `0.2.0` |
| script `build:cg`, `scripts/build-cg.js`, `CG_GOOS`, `CG_GOARCH` | `build:ayis`, `build-ayis.js`, `AYIS_GOOS`, `AYIS_GOARCH` |

Also:
- `app/main/repo.js`: `resources/ayis`, binary `ayis`, `AYIS_REPO`, `~/ayis`.
- `app/main/runner.js`: `AYIS_JSON=1`. `app/main/index.js`: window title `'Ayis'`, `AYIS_GPU`,
  and the log path comments.
- **Pin Electron's data folder to `~/.config/ayis`** with `app.setPath('userData', ...)` before
  ready. Otherwise `productName: Ayis` would put it in `~/.config/Ayis`, beside the CLI's
  `~/.config/ayis` (on Linux those are two folders). Today both happen to be `~/.config/cg`.
- `preload.js`: `exposeInMainWorld('cg', ...)` -> `'ayis'`, and every `window.cg` in
  `renderer/app.js` (about 32).
- localStorage `cg.billChanges`, `cg.lastCost`, `cg-disk-removed` -> `ayis.*`. The old values
  reset, which is fine.
- `renderer/index.html:9,21` "Cloud Gaming" -> "Ayis". `app.js:6650-6654`: the scripts-missing
  message and its `git clone https://github.com/jebin2/ayis ~/ayis` line. Then the remaining
  ~350 `cg` mentions in the renderer: visible text says `ayis`, and code names change too.
- `app/test/*.mjs` (15 hits, e.g. `runner.test.mjs:93` `/home/me/cloud_gaming`) and
  `app/README.md`.
- Icon `app/build/icon.png`: kept for 0.2.0. A new icon is a separate task.

### 6. CI and releases

- `test.yml`: `go build -o /dev/null ./cmd/ayis`, and comments.
- `desktop-release.yml`: release body (`./ayis-*.AppImage`, the install table), comments.
- `security.yml`, `steam-client.yml`: comments.
- **`internal/provision/launch.go:463` `SteamClientURL`** -> `github.com/jebin2/ayis/releases/download/steam-client`.
  It only works once the repo is renamed (step 9). Until then the old URL redirects, so make this
  change in the same merge as the rename.
- `tests/run-all.sh` and the 47 suites: `./ayis`, `AYIS_*`, new on-box paths. The 4 DOM suites
  run on GitHub only (they hang under the local Brave shim).

### 7. Docs

- `README.md`: title, tagline, install table, clone URLs, `cd ayis/app`.
- `cg.md` -> `ayis.md`.
- `docs/*.md` (846 hits): commands, paths, env vars, resource names (`ayis-box`, `/ayis/<host>/`,
  `/var/log/ayis-bootstrap.log`). The `gamevps` examples become `ayis`.
- `.env.example`: wording, `#GAME_TS_HOST=ayis`, the `AYIS_*` names.
- `docs/migration/go-plan.md` and `docs/cost-audit-report.md` are history. Leave their contents
  alone, apart from a one-line note at the top that the project is now Ayis.
- `stitch_design/` (4 hits), `LICENSE` ("Copyright (c) 2026 Jebin", already fine).

### 8. GitHub, this checkout, Claude's memory

- Rename the repo `jebin2/aws_cloud_gaming` -> `jebin2/ayis`, then
  `git remote set-url origin git@github.com:jebin2/ayis.git`. Never create a new repo with the old
  name: that would break GitHub's redirects.
- Repo description: "Ayis: All Yours, Instantly Streamed - play your games from a GPU on AWS or
  your own Linux server." Topics: `cloud-gaming`, `sunshine`, `moonlight`, `tailscale`,
  `linux-gaming`.
- Check that `ayis` is free on the AUR and Flathub, and the domain you want. That check never
  finished earlier.
- Rename the checkout `~/cloud_gaming` -> `~/ayis` **last**, outside a Claude session. Then copy
  `~/.claude/projects/-home-homeserver-cloud-gaming/` to `~/.claude/projects/-home-homeserver-ayis/`
  so the project memory follows, and update the memory notes that name `cg` commands or the repo.

---

## Order of work

### Step 0 - tear down with the OLD program (on `main`, before anything new runs)

Deletes things in AWS, so it runs only on an explicit go-ahead. It costs nothing.

1. `./cg destroy --all` deletes the box resources, the watchdog (function, schedule, role, logs),
   the archive bucket and the budget, and removes `GAME_S3_BUCKET` from `.env`. Read what it lists
   before confirming.
2. `./cg status` should show nothing left in ap-south-1 except the quotas. Delete any leftover
   `/cloud-gaming/gamevps/*` parameters by hand.
3. Delete the offline `gamevps` node in the Tailscale admin page if `destroy --all` did not.
4. Own servers: none are registered on the laptop (`cg host list` is empty). On this server,
   `~/.config/cg/sunshine-login` is left over from testing; delete it. The server is set up again
   with `ayis host add` later.
5. Uninstall the 0.1.x `cg` desktop package from any computer that has it.

### Steps 1-8 - the rename, one commit each, tests green after each

1. **Go module path and root package** (1). `go test ./...`.
2. **Command and environment variables**: `cmd/ayis`, `AYIS_*`, the one cache helper, local
   paths (1, 4). `go test ./...`, `tests/run-all.sh`.
3. **AWS names and `GAME_TS_HOST=ayis`** (2), Lambda included (`tests/lambda-watchdog.sh`).
4. **Box and own-server paths** (3): file renames in `host/`, `lib/bootstrap.d`, the embeds.
   `tests/run-all.sh`.
5. **User-facing text and comments** across `internal/`, `host/`, `lib/` and `tests/`, with the
   expected output updated in the same commit.
6. **Desktop app** (5). `npm test`, then the DOM suites on GitHub.
7. **CI, release body, docs** (6, 7), and the 0.2.0 release notes.
8. **The grep gate**: `git grep -nwiE 'cg|cloud_gaming|cloud-gaming|aws_cloud_gaming|gamevps|CG_[A-Z]'`
   must return only the two history docs and the third-party names it matches by accident
   (check each one).

### Step 9 - go live

1. Merge `rename-ayis` into `main` (only on an explicit ask).
2. Rename the GitHub repo, update the remote, and confirm `SteamClientURL` downloads.
3. Tag `v0.2.0` and let Desktop Release build it (it runs the tests first).
4. **Rebuild**: install the 0.2.0 package, then run `ayis check --fix` and `ayis init`. Init
   creates `ayis-library-*`, `ayis-box`, the watchdog and the budget, and the first box asks for
   Steam sign-in once. **This is one normal session at about INR 19.8/hr on spot.** Press Stop
   when done.
5. `ayis host add` for the home server, then Play from it.
6. Rename the checkout and move Claude's memory (8).

## Open decisions

1. **Casing**: `Ayis` in the app and titles, `ayis` for the command, packages, paths and AWS names.
2. **Lambda file name**: rename `cloud_watchdog.py` to `ayis_watchdog.py`, or keep it?
   (Recommended: rename; nothing outside the repo refers to it.)
3. **Icon**: keep it for 0.2.0, or make a new one first?
