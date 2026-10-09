# cg desktop app

A viewer for `cg`. It runs the scripts and renders what they say - it holds no AWS logic of its
own, and `tests/app.sh` fails if any appears.

    cd app
    npm install     # Electron only
    npm start

Screens:

- **Dashboard** - box state, the archive and its countdown, guards, this laptop. Play, Build and
  Destroy, each confirming first.
- **Build** - pick games against the disk's capacity, then watch `cg init` step by step.
- **Library** - the archive per game, orphans, and what fits on the box.
- **Guards** - a card per layer, with what it catches and what it last decided.
- **Cost** - tiles, the daily table, what still bills, the egress allowance. One Cost Explorer call
  per fetch, on the button labelled `$0.01`, never on a timer.
- **Settings** - what `.env` decides. Secrets show as set or not set, never as values.
- **Logs** - the live event stream, filtered and copyable, beside the cloud watchdog's own log.

## Building an app out of it

    npm run pack    # an unpacked build in dist/, to try
    npm run dist    # .pacman, .deb, .tar.gz and .AppImage

Four Linux formats, because one was not enough. The AppImage looks like the simplest - a single
file - but type-2 AppImages dlopen `libfuse.so.2`, and distributions have moved to fuse3; on Arch
it dies with "error loading libfuse.so.2" until `pacman -S fuse2`, which is a poor first
impression for something advertised as standalone. `.pacman` and `.deb` are native packages
for the two families, and `.tar.gz` extracts and runs with no dependency at all.

**The scripts travel with it.** `cg`, `lib/` and `lambda/` are copied into `resources/cg`, so a
download runs without a checkout. The app still holds no AWS logic: it shells out to those
scripts, which remain the only thing that decides anything.

It looks for them in this order: `$CG_REPO`, the parent of `app/`, the bundled copy in
`resources/cg`, then `~/cloud_gaming`. **A checkout beside the app wins over the bundle** - anyone
running from source is editing that one and must see their edits, not a stale copy. The same order
means `git pull` still updates a rig that has a checkout; only a plain download relies on the
bundle, and there a new build is the update.

This used to say the scripts could not be bundled, because a second copy would be a stale source
of truth. The copy is not a second source of truth - it is the same files, shipped - and the real
blocker was elsewhere: `.env` was a relative path, so a read-only install could not save a
setting. [lib/env-file.sh](../lib/env-file.sh) fixed that, and `tests/standalone.sh` holds it
there.

Releases are built by tagging:

    git tag v0.2.0 && git push origin v0.2.0

`.github/workflows/desktop-release.yml` stamps the version from the tag, runs `tests/app.sh`,
builds the AppImage and the .deb, and opens a **draft** release - look at it before publishing.
It builds **Linux only**: an untested .exe or .dmg is worse than none, and the matrix is one line
away from all three the day someone has actually run it there.

Both scripts were run here: `npm run pack` produces `dist/linux-unpacked/cg`, and its `app.asar`
holds `main/`, `renderer/` and `package.json` - no `cg`, no `lib/*.sh` (verified by packing it and
listing the archive). The packed binary starts and opens its window.

## Where it has actually run

Linux, X11 and Wayland. macOS should work and has not been tried.

**Windows is written but untested.** `main/runner.js` shells through `wsl.exe`, because the
scripts are bash and rewriting them in PowerShell would fork the engine. Stopping a job uses a
POSIX process group (`kill(-pid)`), which will not reach into WSL as it stands - expect Stop not
to work there until someone fixes it against a real machine.

The design is the Stitch export in `../stitch_design`: its Tailwind config, fonts and icons are
vendored here, so the window loads nothing from the network. Rebuild the stylesheet with
`npm run build:css` (`npm start` does it for you).

Design notes, and the command behind every field: [../docs/app-design.md](../docs/app-design.md).
