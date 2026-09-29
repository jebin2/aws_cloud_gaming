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
    npm run dist    # AppImage (Linux), dmg (macOS), nsis (Windows)

**The scripts are not bundled.** The app runs the `cg` in the repo it sits beside, found in this
order: `$CG_REPO`, the parent of `app/`, then `~/cloud_gaming`. A copy of the scripts inside the
package would be a second, stale source of truth - which is the one thing this design will not
have. So a packaged app still needs the checkout, and updating the rig means `git pull`, not a new
build.

Releases are built by tagging:

    git tag v0.2.0 && git push origin v0.2.0

`.github/workflows/desktop-release.yml` stamps the version from the tag, runs `tests/app.sh`,
builds on Linux, Windows and macOS, and opens a **draft** release with the artifacts attached -
look at it before publishing.

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
