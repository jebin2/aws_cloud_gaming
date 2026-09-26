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
- **Logs** - the live event stream.

The design is the Stitch export in `../stitch_design`: its Tailwind config, fonts and icons are
vendored here, so the window loads nothing from the network. Rebuild the stylesheet with
`npm run build:css` (`npm start` does it for you).

Design notes, and the command behind every field: [../docs/app-design.md](../docs/app-design.md).
