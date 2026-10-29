# What destroy removes

`cg destroy` is the everyday end of a session; `cg destroy --all` is for leaving AWS entirely.

`cg destroy` removes the **box**. `cg destroy --all` removes everything cg made in this
region, plus cg's leftover disks, images and snapshots in **every** region.
`cg aws disconnect` goes further: machines and saved games in other regions too.

| | `cg destroy` | `--all` |
|---|---|---|
| Mirror the games to S3 first | **yes**, and refuses if it fails | no - they are being deleted |
| Instance (terminate + cancel the spot request) | gone | gone |
| Security group, key pair, `~/.ssh/<host>.pem` | **kept** - `cg init` reuses them | gone |
| Tailnet nodes | **kept** offline - `cg init` prunes them | gone |
| Per-box `.env` lines (instance id, node, Sunshine login) | cleared | cleared |
| The box's leftover volumes (tagged with its name) | gone | gone |
| Images made by `cg snapshot` (tagged `<host>-image`), and their snapshots | gone | gone |
| cg's disks, images and loose snapshots in **other** regions | kept | gone |
| **Monthly budget** | **kept** | gone |
| **S3 archive and its bucket** | **kept** | gone |
| **`<host>-box` role + instance profile** | **kept** | gone |
| **Cloud watchdog: function, schedule, role, logs** | **kept** | gone |
| Old EBS game volume, if you still have one | **kept** | gone |

**Destroy does not wait for the last minutes.** A spot box takes 6-7 minutes to go from
`shutting-down` to `terminated`, and stops billing when it starts shutting down. A plain destroy
waits 45 seconds, then says AWS is still finishing and returns; the box's `.env` lines are cleared
either way. `--all` waits in full, because it deletes the security group next and AWS refuses that
while the instance's network interface exists. A `cg init` straight afterwards is fine: it waits for
AWS to release the spot allowance (see troubleshooting).

**Cases where destroy stops instead of pressing on.** These follow from one rule: nothing
irreversible happens while the box may still be running.

- `--no-push` makes the archive read-only for the box's role, because the box mirrors its library
  as it shuts down. If the role cannot be read (refused, throttled) the destroy does not start. Only
  a role that does not exist counts as "nothing to lock". The archive is made writable again only
  once the box is confirmed `terminated` (this path waits in full, unlike a plain destroy); if it is
  not, the archive stays read-only and says so.
- `--all` deletes the archive, the box's role and the cloud watchdog only after the box is
  confirmed gone. If the instance would not terminate, it stops before those and says which were
  left, because a running GPU box with no watchdog and no role bills by the hour and nothing
  guards it. The local `.pem` stays too: it is how to reach that box.
- An instance whose spot request cannot be found (three tries) or cancelled is not terminated: a
  request that relaunches would replace it with a box cg does not know. The failure is reported;
  run the destroy again.
- A box whose state cannot be read (throttled, a network blip) is treated as running, so the push
  from the laptop is tried and the `--force` gate applies. It used to count as "nothing to push" and
  went straight to terminating. A stale id (the instance is not there at all) still has nothing to push.
- An image whose snapshots cannot be read is not deregistered, in `destroy` or `snapshot --delete`:
  deregistering first would leave the snapshots unreachable and billing. A snapshot that stays behind
  makes `snapshot --delete` exit 1 and say so.

`cg stop` says "billing has ended" only when the box is confirmed stopped; otherwise it exits 1 and
says the box may still be billing. `cg init` retries bucket creation only for `OperationAborted` (the
delay after a delete); `BucketAlreadyOwnedByYou` counts as success, and any other error is reported
at once with its own text.

**Only cg's own.** Images, volumes and snapshots are deleted only when they carry cg's tag
(`cg:host=<host>`), or the exact name cg gave them before that tag existed. Anything else in the region - another project's image or disk - is listed as left
alone and never touched.

**A plain destroy removes only what bills.** The security group, the key pair and the
tailnet node cost nothing, and the next build reuses each of them: `provision.sh` reuses a
security group and key pair of the same name, and offline nodes are pruned before launch. Deleting them bought nothing
and cost time - the security group step alone waited up to a minute for the network interface
to be released. The `.pem` is kept *with* the key pair on purpose: AWS hands out a private key
exactly once, so a surviving key pair whose `.pem` had been deleted would be reused by the next
build with no way to log in. If that `.pem` is lost anyway, `cg check` says so and the next
`cg init` replaces the key pair - free, and only while no box is using it. The per-box `.env` lines are still cleared - they are not resources,
and left in place `cg ssh` and `cg status` would point at a terminated instance.

`--all` asks you to type `DESTROY-ALL`, because the archive is the only copy of the games and
there is no versioning behind it. It skips the mirror entirely, since pushing games to S3 and
then deleting the archive would be nonsense.

**The budget is kept by a plain destroy on purpose.** It guards the account rather than the
instance, it costs nothing, and it used to be deleted on every destroy - which meant it was
recreated on every `cg init`, and AWS Budgets populates its spend figure up to 24 hours *after*
a budget is created. On a rig rebuilt several times a day it never populated. It reported
`$0.00 spent` against a real month of $12.17 and had never once been in a position to alert.

It leaves nothing behind on purpose. An earlier version kept the empty bucket and the role,
reasoning that both are free and the names are deterministic - but that is an argument for a
leftover being harmless, not for a command called `--all` producing one. `cg init` recreates all
of it, and because the bucket name is derived from your account id it comes back identical.

One consequence of that identical name: S3 holds a deleted bucket name for a few minutes, and
recreating it fails with `OperationAborted` in the meantime. `library-aws.sh` waits that out
(8 attempts, 15s apart) rather than failing an init that would have worked on the second run.

**A kept archive does not stay forever.** After 14 days with no box, the cloud watchdog deletes
the S3 archive, because it is the only thing still billing. `GAME_ARCHIVE_EXPIRY_DAYS=0` keeps it;
[cost-guards.md](cost-guards.md#game-archive-expiry) has how it decides.
