# The game library

Games live on the instance's local NVMe and are archived per game to S3, so a box can be destroyed
after every session and rebuilt with its games - and its Steam login - intact.

## How the games persist

On **local NVMe** (`/scratch/steam`), mirrored to **S3**. The instance store is the fastest disk
on the box and costs nothing, and it is wiped on every *stop* - so the S3 archive is the durable
copy, and the box restores from it at boot.

The restore starts at the **top** of the build and runs in the background while everything else
installs, so it overlaps the NVIDIA driver rather than being a wait of its own. The readiness
marker waits for it, so `cg init` reports the box ready when the games are actually there.

    cg library              what is local, what is archived, what it costs
    cg library push         mirror now  (--verify for a full comparison)
    cg library pull         restore now
    cg library --bucket     the bucket name, answerable with the box gone

`cg destroy --no-push` exists for the case where the box's local copy is **worse** than what is
archived - a half-finished restore, a game mid-repair, a disk you do not trust. Skipping this
end's push is only half the job, because `cg-library-shutdown.service` runs on the box and fires
on any graceful shutdown, so `--no-push` **revokes the box's S3 write access** first. That works
even when the box is too busy to answer ssh, which is usually why you wanted it. Access is
restored immediately afterwards, and `cg init` rewrites the policy on every build in any case.

**The archive is the only copy.** It is written in three places, and not a fourth:

1. **`cg stop`** - and the "stop instance now?" prompt at the end of `cg open`
2. **`cg destroy`**
3. **`cg-library-shutdown.service`**, from `ExecStop`, as the machine goes down

(1) and (2) **refuse to proceed** if the push fails, rather than printing a warning next to the
thing that just lost your games; `--force` overrides and says what it costs.

(3) is not redundant cover. The box stops itself **two ways nobody typed** - the on-host idle
watchdog's `shutdown -h`, and the cloud watchdog, which asks
AWS to terminate the instance (stop, on demand), which AWS turns into a graceful OS shutdown. Both
arrive at `ExecStop`, so one unit covers them. Without it, every automatic stop would
wipe the instance store and lose whatever was installed since the last explicit stop.

That push is allowed **30 minutes** (`TimeoutStopSec=1800`). AWS may power off a box it was asked
to terminate before then, which is why the on-host watchdog pushes *before* it shuts down, where
no timeout applies, and why `cg destroy` pushes before it deletes anything. A box still going down
an hour later is forced by the cloud watchdog.

**Only one push runs at a time.** `cg-library push` takes a lock in `/var/lib/cg-library`, and a
second push waits for the first instead of racing it. Two can otherwise meet - AWS terminating the
box while the watchdog is mid-push, or `cg destroy` pushing at the same moment - and both would
upload the same files and rewrite `index.json` from their own stale copies, losing an entry. The
waiting push skips whatever the first already uploaded.

There is deliberately **no periodic timer**. An earlier version pushed every 10 minutes; nothing
should be uploading a game library, and propagating deletions while doing it, while you are
playing. The remaining exposure is a stop that is not graceful - a **spot interruption** gives
about two minutes, which will not upload a large library, and a hard power-off gives none.
`cg library push` takes a checkpoint whenever you want one, and `cg library check` asks whether
the disk matches the archive without uploading anything.

The explicit push is wired into `lib/game`'s `down()`, not into `cg stop`, because the "stop
instance now?" prompt at the end of `cg open` calls `down()` directly and never comes back
through `cg`. Putting the gate in the CLI would have meant two pushes on `cg stop` and none on
the path people actually use.

## Measured numbers

**Steam download rate: 379 Mbps**, measured off the idle watchdog's own interface counters
(2,710 MB/min inbound) while a game was downloading. So a 160 GB game re-downloads in about an
hour, not the ~3.7 h an earlier ~100 Mbps guess implied - that guess came from watching the
Steam *client* bootstrap, which is not the same thing as a game download and is far slower.

The archive still earns its keep at that rate: ~11 min to restore against ~60 min to
re-download, and the Proton prefix - save games, registry, shader cache - cannot be
re-downloaded at any speed.

On a `g6.xlarge` in `ap-south-2`:

| Shape | Direction | Rate |
|---|---|---|
| 10 GB in 10 x 1 GiB objects | archive | **508 MB/s** (4.1 Gbps) |
| 10 GB in 10 x 1 GiB objects | restore | **235 MB/s** (1.9 Gbps) |
| 2.9 GB in 13,271 real game files | archive | **140 MB/s** |

**Object shape matters more than bandwidth.** The same code moves 1 GiB objects at 508 MB/s and
a real game library at 140 MB/s, because 13,271 objects is 13,271 requests. Treat the big-object
numbers as an upper bound you will not see; a 140 GB library of mixed file sizes should land
somewhere between, which is why the restore is hidden inside the build rather than timed
precisely. The first benchmark here reported only the 1 GiB figure, and it was misleading in
both throughput *and* memory - see below.

## Why not an EBS volume

That is what this replaced. A 160 GB gp3 volume mounted at `/games` did survive a stop on its
own, and it cost:

- **$14.59/month (~INR 1,284)**, billed whether or not the box existed
- **one availability zone, forever** - EBS cannot cross AZs, so the volume's zone decided where
  every future instance launched, and `InsufficientInstanceCapacity` in that zone failed the
  launch outright

The same library in S3 Standard is **~INR 310/month** and pins nothing, which materially
improves the odds on a spot launch. The cost is the ~10 minute restore, which is why it was
worth the work to hide it inside the build.

If you still have that volume, it is **not** attached or mounted any more, and it is **not**
deleted either - `cg games --volume` shows what it still costs and `cg games --volume --delete` reclaims it.

## The guards, and why they exist

`push` propagates local deletions to S3 (`--delete`), and the local copy lives on a disk that
vanishes on stop. A push against an empty `/scratch` would therefore delete the archive. So:

- push **refuses** unless a restore completed on this boot. A failed restore writes no marker.
- push **refuses** when the local library is less than half the archive.
- pull **refuses** if `/scratch` is not a mountpoint, which would fill the root disk.
- the restore marker records **which boot** restored the library, so a marker left on the root
  volume by a previous boot cannot vouch for an instance store that has since been wiped.

`tests/library-guards.sh` and `tests/library-perapp.sh` cover them, against a stubbed `s5cmd`. It is worth
saying why that file is unusually paranoid: the first live test of this code **deleted a real
250 MB archive**. The object count was parsed from `s5cmd du`, whose output ends `... in 2
objects:` with a colon; the parser matched the bare word, read 0 forever, and the size guard was
conditioned on that count. The unit test passed because the stub emitted a format I had assumed
rather than the one s5cmd prints. Both were fixed: the guards key off *bytes*, and the stub is
now byte-for-byte the real output.

## One archive, one disk, and choosing between them

A `g6.xlarge` holds **229 GB**. Two modern titles do not fit together - Black Myth: Wukong is
~128 GB and Diablo IV ~160 GB - so the archive has to hold more than the disk does.

Each game is archived under its own prefixes, so **pushing one game never touches another**:

    steamapps/appmanifest_<id>.acf
    steamapps/common/<installdir>/
    steamapps/compatdata/<id>/        the Proton prefix: saves, registry
    steamapps/shadercache/<id>/

`--delete` is scoped inside each app's own prefix, so removing a file from a game still
propagates, and a game that is simply not installed is left alone. That makes "an empty disk
empties the archive" **impossible by construction**, where the whole-tree sync needed a size
guard to catch it - the same failure that removed Shakes & Fidget when it was uninstalled and
Proton when Steam moved it to another library.

`cg init` asks which to restore, before the instance launches - the restore runs at boot with no
terminal, and has to start early to overlap the build:

    Archive (209 GB selectable of 229 GB - 20 GB reserved for Proton, shaders, headroom):

      #   APPID      GAME                                  SIZE  ARCHIVED
      1   2344520    Diablo IV                         160.0 GB  2026-09-13 11:02
      2   2358720    Black Myth: Wukong                128.0 GB  2026-09-13 09:14
      3   438040     Shakes and Fidget                   2.5 GB  2026-09-12 20:44

    Restore which? (numbers or appids, comma separated | all | none)
    Enter = none
    > 1,2
      288 GB selected, 209 GB available - over by 79 GB.
      Diablo IV 160 GB + Black Myth: Wukong 128 GB
      These fit on their own: Diablo IV (160 GB), Black Myth: Wukong (128 GB)

    > 1
      160 GB selected, 49 GB spare. Restoring: Diablo IV

It **refuses and explains** rather than silently picking a subset: which game to drop is not a
decision a tool should make for you.

**Enter means `none`.** Enter is what people press to get past a prompt, and defaulting to `all`
would start a 158 GB transfer for a box they might have wanted empty. Restoring a game is cheap
to ask for and annoying to undo, so it costs one deliberate keystroke; the archive is untouched
either way and `cg library pull --apps <id>` fetches it later. The choice is still remembered in
`.env` as `GAME_APPS`, which is what non-interactive runs use.

The box enforces the same arithmetic independently, because `CG_APPS` can still say `all` from an
old `.env` or a run where the prompt never happened. It skips what will not fit and says so,
rather than filling `/scratch` mid-restore - which fails in the least legible way available, as a
half-restored game that Steam reports as installed.

    cg library list            what is archived, per game, and the monthly cost
    cg library pull --apps <csv|all|none>
    cg library forget <appid>  delete one game from the archive (type FORGET)

A push that dies leaves files with no manifest and no index entry - deliberately, so a
half-uploaded game is never mistaken for a complete one. Nothing could then *see* them:
`cg library list` read the index and reported an empty archive while 76 GB of a dead download
sat there costing INR 167/month, and `forget` could not reach it either. `cg library list` now
reports orphaned objects and `cg library clean` removes them, behind a typed `CLEAN`.

**The archive no longer shrinks on its own**, which is the price of never deleting an absent
game. `forget` is how a game leaves it - with a typed word, because there is no versioning behind
the bucket. Both games archived is 288 GB, **$7.20/month (INR 634)**; one is $4.00 (INR 352).

## Symlinks

S3 cannot store a symlink, and `--no-follow-symlinks` is what keeps the uploader from recursing
into `/` through a Proton prefix's `dosdevices/z:`. So `push` records every symlink in the
library into `.cg-symlinks.tsv` (`path<TAB>target`) before the sync, and `pull` recreates them
afterwards - additively, never overwriting anything already there.

This is not cosmetic. A restored game whose `dosdevices` is empty passes every check - manifest
`StateFlags 4`, nothing re-downloaded, library registered - and **will not launch**, because Wine
resolves every Windows path through those links. Steam rebuilds its own trees, so the Proton
runtime recovers on its own; a *game's* prefix has no such owner and never self-repairs.

## Proton and the Steam runtime are deliberately not mirrored

Steam installs compatibility tools into whichever library it likes - usually the client's own,
on the root disk, which `cg destroy` deletes. They are therefore re-downloaded on each rebuild
rather than restored from S3.

This was measured and left alone: **under a minute**. Mirroring them would add ~2 GB to the
archive to save less time than the NVIDIA driver install already takes in parallel. The game,
its Proton prefix (save games and registry) and the shader cache - the parts nothing else will
rebuild for you - are all mirrored.

If Steam happens to place the tools in `/scratch/steam` on some build, **push skips them.** This
became necessary on 2026-09-14, when one push archived four of them as if they were games:

    1493710    Proton Experimental                 1.8 GB
    1391110    Steam Linux Runtime 2.0 (soldier)   0.6 GB
    4183110    Steam Linux Runtime 4.0             0.6 GB
    3086180    Proton Voice Files                  0.1 GB

The old whole-tree sync would have deleted them again the next time they were absent. Per-game
archiving deliberately never removes an app that is not installed - the property that stops an
empty disk emptying the archive - so once in, they would have stayed. They were removed with
`cg library forget`, and `is_steam_tool` in `host/cg-library` now keeps them out:

- installdir `Proton <anything>` or `SteamLinuxRuntime*` - with the space, so a game installed
  as `ProtonHunter` is still archived
- appids 228980 (Steamworks Common Redistributables), 1826330 (Proton EasyAntiCheat Runtime),
  1161040 (Proton BattlEye Runtime)

Push logs each skip (`not archiving Proton Experimental (1493710) - a Steam tool`). If a new tool
ever slips through, extend that function and `cg library forget` its appid.

## The Steam login is not in the library

The games are on `/scratch`. The login is on the **root disk**, which is destroyed with the
instance:

    ~/.local/share/Steam/local.vdf                MachineUserConfigStore -> ConnectCache: the
                                                  encrypted refresh token (1,024 hex chars)
    ~/.local/share/Steam/config/config.vdf        settings and the account list - NO token
    ~/.local/share/Steam/config/loginusers.vdf    the remembered account
    ~/.steam/registry.vdf                         AutoLoginUser
    ~/.local/share/Steam/userdata/                per-user config, controller bindings

These go to `steam/account/steam-account.tgz` - a tarball rather than an `s5cmd sync`, because
the file modes matter and a tarball lands atomically.

**The first version archived the wrong file, and said it worked.** It assumed the token was in
`config.vdf` and guarded on that file being non-empty. A signed-out Steam writes a 21 KB
`config.vdf` all the same, so the archive held the account list without a token, the check
passed, and the next box asked for a login. The token was found on 2026-09-14 by marking the
time, signing in, and listing what Steam wrote: `ConnectCache` appeared only in `local.vdf`.
The push now refuses unless `local.vdf` contains `ConnectCache`.

**It carries over to a new instance - verified.** On 2026-09-14 a login archived from one box
was restored onto a freshly launched one - a different instance, so a different
`/etc/machine-id`, hostname and MAC - and Steam started signed in without asking. Nothing
public documents how the token is encrypted (the most direct answer found was "no
publicly-known method" of reusing it elsewhere), so this was settled by trying it rather than
by reading about it. If a future Steam update binds the token to the machine, the symptom is a
login prompt on the next rebuild and nothing worse: a token that fails to decrypt is ignored.

Rules that still hold:

**It is pushed even when the game push refuses.** The restored-this-boot guard exists to stop a
half-restored *game* overwriting a complete archive. The login has no such hazard.

**A signed-out box does not overwrite a saved login** - that is exactly what the `ConnectCache`
check is for.

**`userdata/` is the only directory walked**, so it is where the cache excludes and the symlink
handling earn their place. Links are stored as links, and the tar is bounded by `timeout`.

The token is a credential in your bucket. It is private and reached through the instance role,
but anyone who can read the bucket holds an encrypted copy of your Steam session.
`cg destroy --no-push` skips it along with everything else.

## Comparison is size-only

`s5cmd sync` compares modification times by default, and a freshly restored file is always
*newer* than the S3 object it came from - so the next push would re-upload the entire library,
every session. Both directions use `--size-only`, which makes them idempotent (verified: a push
straight after a pull transfers nothing).

The trade-off is real: a game patch that rewrites a file to exactly the same length is not
noticed. `cg library push --verify` does a full comparison; run it after a big game update if
you want certainty.

## What `/scratch` also holds

Browser downloads and temp files, in `/scratch/tmp` and `/scratch/downloads`. `cg clean` clears
**only those two directories** by name - it used to wipe everything directly under `/scratch`,
which was safe when the games were on a separate volume and is now the fastest way to delete a
140 GB library and have the mirror faithfully propagate the deletion.

The NVIDIA and DXVK shader caches sit on the root volume (`~/.cache`), so they survive a reboot
but not a destroy. The Fossilize cache that matters most is *inside* the library, at
`steamapps/shadercache`, and is mirrored with it.

## The archive expires after 14 days unused

With no box, the archive is the only thing that bills - about INR 350 a month for 160 GB. After
14 days with no box launched or running, the cloud watchdog empties and deletes the bucket. The
next `cg init` recreates it empty: Steam downloads the games fresh, and asks you to sign in again
because the saved login lived in the archive too. `GAME_ARCHIVE_EXPIRY_DAYS=0` in `.env` keeps it
forever. `cg status` shows the countdown. How it decides, and why it errs towards keeping:
[cost-guards.md](cost-guards.md#game-archive-expiry).
