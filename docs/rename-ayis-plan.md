# Plan: rename the project to Ayis

**Ayis: All Yours, Instantly Streamed.**

Status (2026-11-10): plan only, on branch `rename-ayis`. Nothing is renamed yet.

The project is `aws_cloud_gaming` on GitHub, "Cloud Gaming" in the app's header and README, `cg`
as the program and package, and `cloud_gaming` / `cloud-gaming` / `cg-` / `cg:` in many
places nobody sees. The new name only has to replace **what a person sees and types**. A name
nobody sees can stay, and most of them must: they are keys that find things which already exist.

## Cost

**INR 0 on AWS, provided the rule below is kept.** Nothing in AWS is created, renamed or deleted.
If the archive bucket's name changed, cg would derive a new, empty bucket. The old one would
keep billing every month by size, with nothing pointing at it, and the games would have to be
re-downloaded from Steam. That is the one way this rename can cost money, and the plan rules it
out.

## The rule: rename what people see, keep what finds things

Every name in the repo falls into one of three groups:

| Group | What it is | Decision |
|---|---|---|
| **A. Seen or typed** | product name, command, packages, repo, README, app title, help text, docs | **rename** |
| **B. Looked up** | AWS names and tags, the bucket prefix, SSM paths, files on a running box, local state paths | **keep** - or migrate with a fallback where users would notice |
| **C. Internal code names** | `window.cg`, `CG_*` variables, the `cg` Go package, localStorage keys | **keep for now** - renaming them gains nothing a user sees |

Group B is where every risk is. The region move broke four things, each a global resource
pointing at a regional one (see the region-move notes). A rename that touches lookup keys breaks
things the same way: an old name sits on a live resource, and new code searches for the new name.

---

## Everything found, by area

Counts are from `git grep` on 2026-11-10 (471 tracked files).

### 1. Go module path - rename (mechanical)

- `go.mod`: `module github.com/jebin2/aws_cloud_gaming` -> `github.com/jebin2/ayis`
- **479 import lines** across `internal/`, `cmd/` and `embed.go`.
- The root package is imported as `cg` (`cg.Files.ReadFile("host/...")`, which embeds `host/`,
  `lib/` and `lambda/`). The package name can stay `cg`. Only the import path changes.
- Do it with `go mod edit -module github.com/jebin2/ayis` plus one `sed` over `*.go`, then
  `gofmt -l .` and `go vet ./...`. Commit it on its own so the diff is easy to read.
- Depends on step 9 (GitHub repo rename) only for `go install`. Builds use local paths.

### 2. The command: `cg` -> `ayis`

- `cmd/cg/` -> `cmd/ayis/`. CI builds `./cmd/cg` (`.github/workflows/test.yml:85`).
- `app/scripts/build-cg.js` writes `cg` / `cg.exe`. `app/main/repo.js:17` looks for `cg`.
  `app/package.json` `extraResources` copies `../cg` to `resources/cg/cg`.
- **Keep `cg` working as an alias.** Every doc, script and habit says `./cg`. Option: the
  build writes `ayis` and a `cg` symlink, the packages ship both, and `repo.js` accepts either.
  Drop the alias at 1.0, or never.
- Help and usage text: `internal/` has **1,058** whole-word `cg` hits. Most are comments. The
  user-facing ones are usage strings, `Say/Log/Die` messages ("written by cg init",
  "run `cg check --fix`") and the `contract` events the app shows. Change the visible strings to
  `ayis`, and leave comments alone unless a file is being edited anyway.
- `tests/` has **439** hits, mostly `./cg ...` calls and expected output. They follow the
  binary rename. With the alias, old calls keep passing during the change.
- `testdata/`: 1 hit.

### 3. The desktop app - rename, with migration

`app/package.json`:

| Field | Now | New |
|---|---|---|
| `name` | `cg-app` | `ayis-app` |
| `description`, `linux.synopsis`, `linux.description` | "Desktop viewer for cg..." | "Ayis: All Yours, Instantly Streamed" + one line |
| `build.appId` | `dev.cg.desktop` | `dev.ayis.desktop` |
| `build.productName` | `cg` | `Ayis` |
| `executableName` | `cg` | `ayis` |
| `artifactName` (mac, win) | `cg-${version}-...` | `ayis-${version}-...` |
| `homepage`, `repository.url` | `.../aws_cloud_gaming` | `.../ayis` |
| `version` | `0.1.0` | `0.2.0` (the rename is a release) |

Other visible text: `app/renderer/index.html:9,21` ("Cloud Gaming" title and header),
`app/main/index.js:246` (window title `'cg'`), and `app/renderer/app.js:6650-6654` (the
"Cloud Gaming requires its scripts" message and its `git clone` line).

**Trap 1: Electron's data folder moves with `productName`.** `app.getPath('userData')` is
`~/.config/cg` today. As `Ayis` it becomes `~/.config/Ayis`, and three things would silently
reset:
- localStorage: `cg.billChanges`, `cg.lastCost`, `cg-disk-removed`. These drive the bill-change
  notices and the "disk removed" memory.
- `logs/` (`app/main/index.js:96-197`)
- Electron's own state (window size and so on)

Fix: before `app.whenReady`, if `~/.config/Ayis` does not exist and `~/.config/cg` does, call
`app.setPath('userData', ~/.config/cg)`. Pinning the old folder is simpler and safer than
copying it, and it is the same folder cg uses (see 5). Add a test in `app/test/`.

**Trap 2: an upgrade installs alongside the old package.** The `.deb`/`.pacman` package name
follows `name`/`productName`. `ayis` does not replace `cg`, so a user ends up with two apps and
two `/opt` folders. Fix: in `app/package.json`, `deb.fpm: ["--replaces=cg", "--conflicts=cg"]`
and `pacman.fpm: ["--replaces=cg", "--conflicts=cg"]` for a few releases. Test both on a real
upgrade from the 0.1.x package. Say it in the release notes too:
"remove `cg` first if your package manager keeps both".

**Keep:** the `window.cg` bridge (`preload.js:6`, ~32 uses in `app.js`), the localStorage keys
(pinning the folder keeps them, and renaming them would lose them), and `CG_GPU`.

**Icon:** `app/build/icon.png` can stay for now. A new icon is a separate task.

### 4. Packaging and releases (`.github/workflows/desktop-release.yml`)

- Asset globs (`app/dist/*.deb`, `*.pacman`) follow the new names on their own.
- The release body has text to update: line 274 (`./cg-*.AppImage`), and the install table
  repeated from the README (lines 265-266).
- `security.yml` and `test.yml`: comments say "cg", and `go build ./cmd/cg` -> `./cmd/ayis`.
- **`internal/provision/launch.go:463` `SteamClientURL`** is hard-coded to
  `github.com/jebin2/aws_cloud_gaming/releases/download/steam-client`, and every new box
  downloads it. GitHub redirects a renamed repo's release downloads, but only until something
  else takes the old name. Change it to `.../ayis/...` in the same release as the repo rename.
  `steam-client.yml` keeps publishing under the same tag.

### 5. Local state on the laptop - keep the paths, read both

| Path | Holds | Decision |
|---|---|---|
| `$XDG_CONFIG_HOME/cg/.env` (`internal/config/env.go:66`) | every setting and key, for the installed app | **keep `cg`**, or read `ayis/` first and fall back to `cg/` |
| `$XDG_CONFIG_HOME/cg/hosts.json` (`internal/hosts/hosts.go:21`) | your own machines, **with their Sunshine logins** | same; losing it means re-adding and re-pairing every machine |
| `~/.cache/cg/` (built in 8 places: `boxcmd/new.go:42`, `cost/run.go:145`, `hostcmd`, `initcmd`, `librarycmd`, `machines`, `quota`, `status`) | account cache, `built-<id>` markers, price cache | keep; a cache, but the `built-` markers matter |
| `~/.ssh/<host>.pem` | the box key | host-named, so not affected |
| `$TMPDIR/cg-session-<uid>.pid`, `cg-ts-*`, `cg-askpass-*` | temporary files | keep (internal) |
| `~/cloud_gaming` checkout (`app/main/repo.js:32`) | where the app finds a source checkout | add `~/ayis` as a candidate, keep `~/cloud_gaming` |
| `$CG_HOME`, `$CG_REPO` | overrides | keep; add `AYIS_HOME` / `AYIS_REPO` only if wanted |

Recommendation: **keep every `cg` path in this release.** Users never see them, and Electron's
data folder (3) is pinned to the same `~/.config/cg`. If an `ayis` path is wanted later, it should
be one helper (`statedir()`) that reads the new path and falls back to the old one. Today the
cache path is built separately in 8 places, so that helper should come first either way.

### 6. AWS - keep everything

Nothing here is renamed. Each name below is how cg **finds** something that already exists:

| Name | Where | Why it must stay |
|---|---|---|
| tag key `cg:host` | `box/box.go:173`, `boxcmd/destroy.go:306`, `boxcmd/disk.go:385` | finds instances, volumes and images; a new key would make live resources invisible to Stop, Delete and the watchdog |
| bucket `cg-library-<sha>` | `internal/bucket/bucket.go:15,22`, `lambda/cloud_watchdog.py:817,830` | derived, never stored by choice; a new prefix means a **new empty bucket** and an orphaned, billing archive |
| SSM `/cloud-gaming/<host>/...` | `lambda/cloud_watchdog.py:623`, Go `"/cloud-gaming/%s/..."` | kept-game records and archive state |
| instance tags `cg-going-down-since`, `cg-slow-noted`, `cg-forced`, `cg-stopped-since`, `cg-stopped-warned` | `lambda/cloud_watchdog.py:55-64`, `internal/watchdog/definition.go:112` | watchdog state on live instances, and in the IAM policy condition |
| `<host>-box`, `<host>-cloud-watchdog`, `<host>-sg`, `<host>-monthly`, `<host>-games`, `<host>-image` | IAM, Lambda, EC2, Budgets | named from `GAME_TS_HOST`, not from "cg", so already fine |
| Lambda env `CG_*` (`CG_TS_HOST`, `CG_BUCKET`, ...) | `watchdog/install.go`, `cloud_watchdog.py:45-96` | the deployed function reads them |
| `cg-watchdog:` log prefix | `watchdog/run.go:126` filters CloudWatch logs by it | old log lines would stop matching |
| EventBridge descriptions "for the cloud_gaming watchdog", rule IDs `cg-schedule`, `cg-state` | `watchdog/install.go:217-219` | the description is cosmetic but rewrites the rule on the next install; leave it |
| SDK app ID `cg` | `awscfg.go:23`, `creds/set.go:44` | user agent only; can become `ayis` safely, and is the only AWS-side change allowed |

**`GAME_TS_HOST` keeps its default `gamevps`.** Every AWS name above is built from it. If the
default became `ayis`, any `.env` without that line would quietly point at a different set of
resources.

### 7. The box and own servers - keep everything

Paths on a machine, read by the laptop over ssh:

- `/opt/cloud-gaming-host`, `/var/log/cloud-gaming-bootstrap.log`,
  `/var/lib/cloud-gaming-bootstrap.rc`, `/var/lib/cloud-gaming-ready` (`host/cg-build:52-56`)
- `/usr/local/bin/cg-library`, `/etc/cg-library.conf`, `/var/lib/cg-library/`,
  `cg-library-{restore,shutdown}.service`, `cg-extra-library.service`, `cg-build`, `cg-notify`,
  `/etc/cg-idle.conf`, `cg-wallpaper`, `~/.config/cg-wallpaper-set`
- own servers: **`~/.config/cg/sunshine-login`** (`internal/ownhost/ownhost.go:73,338`),
  which is how a server's Sunshine login is read back

A stopped machine keeps its disk, so a laptop on the new version can talk to a box built by the
old one. Renaming any of these would break that box, or an own server set up before the
rename. **Keep them.** The 23 files in `host/` keep their names too. They are not user-facing.

The desktop wallpaper `lib/assets/gamepc-help.png` is user-facing on the box. Check it for
"cg" or "Cloud Gaming" text and remake it if it has any.

The Tailscale auth-key description `"cg <host>"` (`internal/tskey/tskey.go:115`) shows in the
Tailscale admin page. Changing it to `"ayis <host>"` is safe. Update the expected string in
`tskey_test.go:75` with it.

### 8. Docs - rename visible text, leave history alone

- `README.md`: title "Cloud Gaming" -> "Ayis", tagline, clone URLs (lines 12, 42-43),
  `cd aws_cloud_gaming/app`.
- `cg.md` (26 hits): rename to `ayis.md` (or keep it as the CLI page, with `ayis` commands and
  a note that `cg` still works).
- `docs/` (846 hits): `commands.md`, `getting-started.md`, `streaming.md`, `troubleshooting.md`,
  `architecture.md`, `cost.md`, `cost-guards.md`, `destroy.md`, `game-library.md`,
  `aws-account-setup.md`, `app-design.md`, `testing.md`, `own-machine-plan.md`: commands
  become `ayis`. On-box paths stay as they are, because they really are still `cloud-gaming-*`.
- **Leave as history:** `docs/migration/go-plan.md` and `docs/cost-audit-report.md`. They
  describe the code as it was (the second even links `file:///home/jebin/cloud_gaming/...`).
- `.env.example` (21 hits): wording only. The variable names stay.
- `stitch_design/` (4 hits): design mockups; update or leave.
- `LICENSE`: check the copyright line names a person, not the project.

### 9. GitHub

- Rename the repo `jebin2/aws_cloud_gaming` -> `jebin2/ayis` (Settings -> General). GitHub
  redirects the old web, git and release URLs **until a repo with the old name is created**.
  Never create one.
- Update the local remote: `git remote set-url origin git@github.com:jebin2/ayis.git`.
- Repo description and topics: "Ayis: All Yours, Instantly Streamed - play your games from a
  GPU on AWS or your own Linux server". Topics: `cloud-gaming`, `sunshine`, `moonlight`,
  `tailscale`, `linux-gaming`.
- Check first that `github.com/ayis` and the AUR / Flathub names are free. That check was
  stopped earlier and never finished.

### 10. This machine's checkout and Claude's memory

- The checkout is `~/cloud_gaming`. **It does not need renaming.** The app finds it at that path,
  and Claude's project memory is keyed by it
  (`~/.claude/projects/-home-homeserver-cloud-gaming/`). Renaming the folder would start memory
  from empty unless that folder is copied to the new key.
- After the rename, update the memory notes that name the repo or `cg` commands
  (`cg sweep` in gpu-capacity-shortage, the go-migration-branch note).

---

## Order of work (branch `rename-ayis`)

One commit per step. Each step leaves the tests green.

1. **State-dir helper** (no behavior change): one function for `~/.cache/cg` and
   `~/.config/cg`, used by the 8 call sites in 5. Tests: the existing ones, plus one for the helper.
2. **Go module path** (1): `go mod edit`, `sed` over the imports, `gofmt`, `go vet`, `go test ./...`.
3. **Binary `ayis` with the `cg` alias** (2): `cmd/ayis`, `build-cg.js` -> `build-ayis.js` writing
   both, `repo.js` accepting both, CI `go build ./cmd/ayis`. Tests: `tests/run-all.sh`, which
   still calls `./cg` through the alias.
4. **Visible CLI text** (2): usage, help and messages say `ayis`. Update the expected output in
   `tests/` and `testdata/` in the same commit.
5. **App** (3): `package.json` fields, window title, header, scripts-missing message,
   the `userData` pin to `~/.config/cg` with a test, and the `fpm` replaces/conflicts.
   Run `npm test` here and the 4 DOM suites on GitHub (they hang under the local Brave shim).
6. **Small AWS-side cosmetics** (6, 7): SDK app ID, Tailscale key description. Nothing else.
7. **Docs** (8): README, `cg.md`, `docs/`, `.env.example`, the release body in
   `desktop-release.yml`. Write the 0.2.0 release notes: the rename, that `cg` still works, and
   that nothing in AWS changed.
8. **Release checks before merging:**
   - Install the 0.2.0 `.deb` over 0.1.x on Mint/Ubuntu, and `.pacman` over 0.1.x on Arch.
     Expect one app afterwards, and settings, own machines and bill notices all still there.
   - Run `ayis status` and `cg status` against the current AWS setup (free, read only).
   - Run `ayis host open` against the existing own server without re-pairing.
   - Optional, costs one session: Play and then Stop on AWS, to show that a box built by 0.1.x
     works with 0.2.0.
9. **Merge to main** (only on an explicit ask, as always) -> **rename the GitHub repo** ->
   `SteamClientURL` and the clone/homepage URLs point at `jebin2/ayis` -> tag the 0.2.0 release.

## Open decisions

1. **The `cg` alias**: keep it forever, or drop it at 1.0? (Recommended: keep it until 1.0.)
2. **Local paths**: stay `~/.config/cg` for good, or move to `~/.config/ayis` with a fallback later?
   (Recommended: stay for now.)
3. **Environment variables**: keep `CG_*` only, or also accept `AYIS_*`? (Recommended: only the
   documented ones, `CG_HOME`, `CG_REPO`, `CG_JSON`, `CG_YES`, get `AYIS_` aliases, if any.)
4. **Product name casing**: `Ayis` in the app, `ayis` for the command and packages.
5. **Icon**: keep it for 0.2.0, or make a new one first?
