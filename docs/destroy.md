# What destroy removes

`cg destroy` is the everyday end of a session; `cg destroy --all` is for leaving AWS entirely.

`cg destroy` removes the **box**. `cg destroy --all` removes the **account footprint**.

| | `cg destroy` | `--all` |
|---|---|---|
| Mirror the games to S3 first | **yes**, and refuses if it fails | no - they are being deleted |
| Instance (terminate + cancel the spot request) | gone | gone |
| Idle-stop alarm | **kept** - `cg init` rewrites it | gone |
| Security group, key pair, `~/.ssh/<host>.pem` | **kept** - `cg init` reuses them | gone |
| Tailnet nodes | **kept** offline - `cg init` prunes them | gone |
| Per-box `.env` lines (instance id, node, Sunshine login) | cleared | cleared |
| Untagged orphaned volumes | gone | gone |
| **Monthly budget** | **kept** | gone |
| **S3 archive and its bucket** | **kept** | gone |
| **`<host>-box` role + instance profile** | **kept** | gone |
| **`<host>-watchdog` user, its key, the `.env` entries** | **kept** | gone |
| **Off-site watchdog units on the VPS** | **kept** | gone |
| Old EBS game volume, if you still have one | **kept** | gone |

**A plain destroy removes only what bills.** The security group, the key pair, the idle-stop
alarm and the tailnet node cost nothing, and the next build reuses or rewrites each of them:
`provision.sh` reuses a security group and key pair of the same name, `put-metric-alarm`
overwrites the alarm, and offline nodes are pruned before launch. Deleting them bought nothing
and cost time - the security group step alone waited up to a minute for the network interface
to be released. The `.pem` is kept *with* the key pair on purpose: AWS hands out a private key
exactly once, so a surviving key pair whose `.pem` had been deleted would be reused by the next
build with no way to log in. The per-box `.env` lines are still cleared - they are not resources,
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
