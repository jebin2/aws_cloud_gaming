# Go Migration Plan: every CLI-first command

Revision: 7 (no legacy fallback: the port completes and the Bash CLI is deleted in this branch)

Status: approved 2026-10-25; the pilot slice is in progress on the `go-migration-plan` branch, which is not merged to `main`. The current Bash
CLI remains the source of truth until a phase gate passes.

Scope: replace the `cg` CLI and its command surface with one Go binary. The Electron app,
`lib/bootstrap.d/`, `host/`, and the Python Lambda stay in place for the first migration. They may
be embedded as assets, but they are not rewritten as part of this plan.

Why: the project is maintained by AI. A compiler, types that can say "unknown", offline tests, and
no runtime dependency on bash, python3, jq or the AWS CLI all make that maintenance safer, and a
native binary is what removes WSL from the Windows path. It does not remove the need for real-AWS
verification, which stays gated and approved by the owner (section 5).



## 0. What changed in this revision

### Revision 7 (this one)

- **No legacy fallback.** The owner decided (2026-10-25) that the migration is completed in the
  `go-migration-plan` branch with no `cg-legacy` and no one-release overlap. The Bash CLI stays in
  the tree only as the test oracle while commands are ported, and is deleted in this branch once the
  port is complete and the real-AWS gates have passed. `main` is not touched: it keeps the Bash CLI
  and is the rollback until the owner chooses to merge. Rules 1, 3 and 11, the definition of done,
  15.2, decision 6 and the risks table are updated to match.
- The consequence is that the real-AWS gates (section 5) and the contract tests are the only safety
  net, so neither may be skipped or shortened.

### Revision 6

- Added a **pilot slice** (section 8.0): the module, a minimal registry, the Phase 1 basics, and
  `cost` ported with its fixtures, before the rest of Phase 0 is done. It settles layout, embed,
  harness and app boundary cheaply. The full Phase 0 follows once the pilot has been reviewed.
- Target operating systems are now **Linux and macOS first, native Windows after** (rule 9,
  decision 11). The seams that differ per OS (`Runner`, paths, privilege, process control, package
  managers) are designed in Phase 1, not retrofitted.
- Human-readable text is matched on fields and wording; JSON, NDJSON, exit codes and prompt IDs
  stay exact (rule 8, section 8.3, decision 4).
- Added a pre-Phase 1 check of which box-side scripts source helpers from `lib/common.sh`
  (section 7), so those helpers are not ported away from the box.
- Recorded that shell tests which grep source files need Go equivalents (section 17).
- Every real-AWS gate gets a cost estimate that goes to the owner before it runs (section 5).
- Added the AI-maintenance rule (rule 16).
- Section 20 now carries a recommendation for every decision. All stay **pending** until approved.

### Revision 5

- Review pass after commits `e010fff..d385f99` (post-audit baseline `1405fc5`): updated `cg cost`
  for cross-region reporting, the derived archive bucket, cg-owned estimate inputs, actual
  spot/IPv4 pricing, region-prefix parsing, full-row totals, and unknown S3 price; updated watchdog
  deployment for stopped on-demand expiry, its tags, and shared `GAME_ARCHIVE_EXPIRY_DAYS`
  semantics; recorded the remaining cost gaps in 10.2.

### Earlier revisions

- Corrected the command inventory against the dispatcher and the subcommand handlers. `--json`
  belongs to many commands, not only `ping` and `snapshot --list`.
- Added every alias, default subcommand, and currently accepted form. Aliases and defaults are part
  of the compatibility contract, not implementation details.
- Split read-only commands from their mutating variants: `deps status` vs `deps install`, `quota
  status` vs `quota request`, `regions` vs `regions enable`, and so on. `check` is not read-only:
  it can save settings and mint or replace a Tailscale auth key, so both `check` forms are Phase 3.
- Split S3-only library reads from reads that need a running box.
- Corrected the legacy volume command: `cg games --volume --delete` (or `cg games volume
  --delete`), not `cg games --delete`.
- Added a helper and asset disposition table so no shell/Python module is silently orphaned.
- Added a command-spec registry, generated help/contract requirement, and an explicit Phase 0 exit
  checklist.
- Added cutover mechanics for `cg-go`, `cg-legacy`, and the Electron runner.
- Clarified that Phase 2 includes remote reads and treats `ssh` as an explicit passthrough; moved
  `pair` to Phase 5 and on-box `library` commands to Phase 5.
- Corrected `sweep --cached` behavior, the JSON matrix, and the exact library/creds/deps forms.
- Recorded the current `--json` dispatch collision on `deps install` and `creds set`.
- Made Phase 0 contract-only and moved module pinning into its scaffolding.
- Recorded Go's `go:embed` parent-directory limitation and the transition packaging rule; added
  `startup-gate.sh` to the app test set.



## 1. Non-negotiable rules

1. **One deployable binary, not one source file.** Split the Go source into focused packages under
   `internal/`. Final releases ship `cg` as one static binary; during the transition the package may
   also carry the Bash tree as the oracle (section 16). No `cg-legacy` ships.
2. **The CLI contract is the product.** `cg --contract`, stdout JSON, stderr NDJSON events, exit
   codes, prompts, aliases, defaults, and report content are frozen before the first command is
   ported (rule 8 says how tightly).
3. **No big-bang port, and no legacy fallback.** Build `cg-go` beside the Bash `cg`. Move one
   command at a time; the Bash CLI is the oracle until the port is complete, then it is deleted in
   this branch. `main` keeps the Bash CLI until the owner merges, and that is the only rollback.
   Nothing is merged to `main` without the owner's say-so.
4. **No shelling out to the AWS CLI for normal operation.** Use AWS SDK for Go v2. Keep a tiny
   adapter only for a service the SDK does not cover, and isolate it behind an interface.
5. **No shell string construction for local commands.** Use `exec.CommandContext` with argument
   slices, or a narrow local-exec interface. Fix the Windows/WSL quoting bug while porting.
6. **Fail closed.** "AWS could not be asked" is not "nothing exists." Cleanup, archive reads, role
   deletion, and other-region scans must report unknown scope, not success.
7. **Secrets never enter logs, events, argv, or errors.** Secret prompts stay hidden. `config get`
   is the only deliberate reveal path.
8. **Machine contracts exact, human text by content.** JSON payloads, NDJSON events, exit codes, and
   prompt IDs are byte-exact against the oracle. Plain human reports are matched on their fields,
   wording, ordering, and the unknown/zero distinctions; spacing and column alignment may differ.
   Build the plain report first and styling second; `tests/ui.sh` must be able to strip styling and
   recover the plain text byte-for-byte from the Go renderer's own plain output.
9. **Linux and macOS first, native Windows next.** Both are Unix and share the host tooling
   assumptions. Windows is a first-class target, not an afterthought: the per-OS seams are designed
   in Phase 1 and native Windows ships once a real Windows machine can test it. Until then WSL
   remains the Windows path, and the app's process control is fixed (section 15.1). Do not claim an
   OS is supported without a real machine or CI runner for it.
10. **Do not copy Bash structure.** Read the comments for the failures they encode, then express the
    invariant in Go and lock it with a test.
11. **The old CLI is the migration oracle.** Until a command's phase gate passes, its current
    behavior wins over a cleaner design. Once the port is complete the oracle is retired, and the
    checked-in fixtures and schemas are the contract from then on.
12. **Every intentional behavior change is recorded.** A parity exception gets a reason, a test, and
    a note in this plan. "It seemed better" is not enough.
13. **Aliases, defaults, and flag placement are contract.** `up`, `down`, `guards`, `lib`, `types`,
    `dependencies`, and `credentials` are supported today. Removing one silently breaks a user or
    the app.
14. **Locks are contract.** The session lock, archive lock, and `runs_alone` verdict are observable
    behavior. The app schedules work from `cg --contract`; a drift is a silent deadlock or a
    destructive command running beside another.
15. **Tests are offline by default.** AWS and network calls use fakes. A disposable AWS account is
    required only for the phase gates that explicitly say so.
16. **Built for AI maintenance.** No human reads every diff, so the safety net is mechanical:
    checked-in schemas and golden fixtures, the compiler, `go vet`, race tests, and small packages
    (about 700 lines at most) that fit in context. A change that cannot be proven by a test is not
    done.



## 2. Scope

### In scope for the first port

- The `cg` command surface and its JSON/event contract.
- `.env` loading, config registry, region/host overrides.
- AWS lifecycle: `init`, `open`, `stop`, `destroy`, `snapshot`.
- Inventory, ownership, cross-region cleanup, budget/watchdog management.
- Cost Explorer, prices, daily/monthly reports.
- S3 archive, Steam login, game index, and library operations.
- Host commands for a user's own machines.
- The Electron integration boundary and CLI runner fixes.
- The laptop side on Linux, macOS, and (after the Windows track) native Windows.

### Out of scope until the control plane is stable

- Electron renderer rewrite.
- `lib/bootstrap.d/` package installation and host setup.
- `host/` idle-watchdog units and mirror daemon.
- Lambda runtime rewrite.
- Running a user's own *server* on macOS or Windows. The server side stays Linux; only the machine
  that runs `cg` and Moonlight needs to be cross-OS.

### Current planning decision

The user has selected **Go** and requested **plan only** for now. This document therefore defines the
work but does not start it. The open decisions in section 20 still need explicit approval before
Phase 0.



## 3. Definition of done

The migration is done when:

- Every form in section 6 works, including aliases and default subcommands.
- `cg-go` implements every command with the same contract, except recorded parity exceptions.
- The old shell suite either passes against `cg-go` or has an equivalent Go test that asserts the
  same observable behavior.
- `cg --contract`, all `--json` payloads, and the NDJSON event stream validate against checked-in
  schemas.
- Help and `--contract` are generated from one command registry and cannot drift from dispatch.
- A real AWS cycle works: `init`, `open`, `stop`, `destroy`, `init`, library restore,
  `destroy --all`, `aws disconnect`.
- The Electron app runs every screen against the Go binary without renderer changes by default
  (or with only the data-only CLI-04 change if open decision 7 is lifted).
- `go test ./...`, `go vet ./...`, race tests for concurrent command paths, and the static binary
  build all pass, for each supported OS on a real machine or runner.
- The Bash CLI, its libraries and its shell tests are deleted in this branch without losing a
  documented behavior. No `cg-legacy` is shipped.



## 4. Standard per-command migration loop

Every command follows the same seven steps. The command sections below list only the specifics.

1. **Inventory the behavior.** Read the command's dispatcher branch, implementation, tests, docs,
   and app call sites. Record aliases, defaults, flags, exit codes, stdout/stderr, prompts, side
   effects, locks, and AWS calls.
2. **Classify the command.** Read-only vs local mutation vs AWS mutation; local vs remote vs AWS;
   JSON support; watch support; run-alone; whether it needs a box.
3. **Write fixtures.** Save golden plain output, `--json` output, and NDJSON events from the current
   CLI. Normalize timestamps, IDs, prices, and durations. Include failure and unknown cases.
4. **Define types.** Add request/options and response/result structs. Model "unknown" separately
   from zero/empty. Put the command spec in the registry.
5. **Implement with injected dependencies.** AWS clients, local exec, SSH, Tailscale, HTTP, clock,
   and filesystem are interfaces. No globals.
6. **Test below and above the seam.** Unit tests use fakes; black-box tests run the built binary
   against fixture servers and temp HOME/XDG directories.
7. **Enable in `cg-go`.** Keep the Bash route selectable. Do not change the default `cg` until the
   phase gate passes.

Required artifact per command:

| Artifact | Must record |
| --- | --- |
| Command spec | form, aliases, default subcommand, flags, summary, phase |
| Contract | JSON support, watch support, exit codes, `runs_alone`, asks |
| Fixtures | plain, JSON, NDJSON, failure, unknown scope |
| Tests | unit, black-box, app call site where applicable |
| Parity note | intentional differences and why |



## 5. Phase map and ordering

| Phase | Scope | Exit gate | Depends on |
| --- | --- | --- | --- |
| Pilot | Module, minimal registry, Phase 1 basics, `cost` with fixtures (section 8.0) | `cg-go cost` and `cost --json` match the oracle; layout, embed, harness and app boundary proven; reviewed before anything else starts | none |
| 0 | Contract freeze and fixtures (the rest, after the pilot) | Golden files, schemas, command registry committed; no product behavior changed | Pilot |
| 1 | Go skeleton and shared runtime, including the per-OS seams | `cg-go --version`, `--contract`, `help`, config, output, prompts, AWS client factory work | 0 |
| 2 | Read-only commands, including remote reads | All read-only commands in this phase return parity output; no cg-initiated AWS or remote mutation is enabled (`ssh` is the explicit passthrough) | 1 |
| 3 | Laptop and small AWS mutations | Config, deps, creds, `check`/`check --fix`, notify, quota request, regions enable, and watchdog install/remove work; no EC2 instance is launched | 1, 2 |
| 4 | Host and no-box library | Own-machine commands and library operations that need no box work; no box lifecycle yet | 2, 3 |
| 5 | Box lifecycle | `init`, `open`, `stop`, `pair`, `clean`, `snapshot`, on-box `library status/check/push/pull`, `games --volume --delete`, normal `destroy` work | 3, 4 |
| 6 | Account destruction | `destroy --all`, `aws forget`, and `aws disconnect` work and fail closed; inventory hardening is included | 5 |
| 7 | App integration and cutover | Electron drives `cg`; the Bash tree is deleted when the real-AWS gates have passed | 2 for basic read screens; 4 for host and no-box library screens; 6 for default cutover |
| W | Native Windows and macOS packaging | Each OS passes the black-box suite on a real machine or runner; installs, Moonlight/Tailscale launch, SSH keys and Stop work natively | 3 and 7 for the pieces it touches |

Ordering rules:

- Read-only before destructive.
- S3-only library reads before box-dependent library reads.
- Config and lock primitives before preflight; credential mutations before `check`/`check --fix`.
- Host setup before host streaming; a real box cycle before account destruction.
- Normal `destroy` before `destroy --all`.
- The app can adopt read screens early, but destructive screens move last.
- Never run two destructive commands in parallel, even in tests.

Real-AWS gates and cost:

- Writing and offline-testing the Go code costs nothing on AWS. The real-AWS gates (Phase 5's
  build/open/stop/destroy cycle and library restore, Phase 6's disposable-account clean-up) bill
  real hours and may move data across regions.
- Every real-AWS gate is proposed to the owner with an estimate (hours, instance type, spot or
  on-demand, S3 requests and any cross-region transfer) **before** it runs. The owner approves each
  one. Nothing is launched on the strength of this plan alone.
- Prefer the cheapest honest test: spot, the smallest GPU type that exercises the path, a small test
  library rather than the real one, and a single region.



## 6. Current command inventory

This table was checked against `cg:2394-2524`, the subcommand handlers, and `lib/host.sh:542`.
The existing `cg help` text is incomplete and stale; it is not sufficient as an inventory.

| Form(s) | Default / aliases | Kind | JSON | Phase | Main source | Existing tests |
| --- | --- | --- | --- | --- | --- | --- |
| `cg help`, `-h`, `--help` | `help` when no command | local read | no | 0 | `cg:2305` | `app.sh`, `ui.sh` |
| `cg --version` | none | local read | no | 0 | `cg:58` | `app.sh` |
| `cg --contract` | none | local read | contract JSON | 0 | `cg:34` | `app.sh`, `json-events.sh` |
| global `--json`, `--watch`, `--region <r>`, `--host <h>` | before command; `--json` and `--watch` are also scanned after it | dispatch | n/a | 0 | `cg:12-73` | `app.sh`, `env-loader.sh` |
| `cg init` | none | full lifecycle | NDJSON | 5 | `cg:2395`, `lib/setup`, `lib/provision.sh` | `init-watchdog.sh`, `standalone.sh`, `userdata-render.sh`, `build-*.sh`, `choose-games.sh` |
| `cg check [--fix]` | no subcommand | preflight with settings/key mutations | NDJSON | 3 (both; `check` can write `.env` and mint a Tailscale key) | `lib/setup:1172` | `deps.sh`, `laptop.sh`, `settings.sh`, `env-loader.sh` |
| `cg deps [status\|install [tool...]]`, `cg dependencies ...` | `status` | local read/mutation | `--json` for status | status 2; install 3 | `lib/setup:1183`, `lib/laptop.sh` | `deps.sh`, `deps-dom.sh`, `sandbox-deps.sh` |
| `cg creds [status]`, `cg creds set [aws\|tailscale\|ts]`, `cg creds tailscale [status\|set\|signin\|up\|authkey]`, `cg credentials ...` | `status`; `set` defaults to `aws`; `tailscale` defaults to `status` | local/HTTP read/mutation | `--json` for creds status; token JSON for `creds tailscale [status] --json` | status 2; mutations 3 | `lib/setup:1192`, `lib/laptop.sh` | `creds.sh`, `authkey.sh`, `creds-dom.sh` |
| `cg status [--on <name>]` | AWS box | AWS/host read | `--json` | AWS 2; `--on` 4 | `lib/setup:372`, `lib/host.sh:462` | `status-json.sh`, `status-iam.sh`, `reports-more.sh`, `host.sh` |
| `cg cost [--daily]` | month-to-date | AWS read | `--json`; human-only `other regions` section | Pilot, then 2 | `cg:2466`, `lib/setup:700` | `cost-daily.sh`, `cost-dom.sh`, `cost-estimate.sh`, `prices.sh`, `fx-rate.sh`, `aws-disconnect.sh` |
| `cg watcher`, `cg guards` | status view | AWS/host read | `--json` | 2 | `cg:2254` | `watcher.sh`, `guards-dom.sh` |
| `cg ping [--watch]` | one probe | tailnet read | `--json` | 2 | `cg:1846` | add focused test |
| `cg log [build\|steam\|watchdog\|disk\|sunshine] [--watch]`, `cg logs` | `build`; `logs` alias | remote read | no (raw stream) | 2 | `cg:1829` | `logs-dom.sh` |
| `cg ssh [cmd...]` | interactive shell | remote exec passthrough | no | 2 | `cg:2520` | `ssh-key.sh`, `tail-exit.sh` |
| `cg machines [region] [--all]`, `cg types`, `cg machines --sweep` | current region | AWS read | `--json` | 2 | `lib/machines.sh`, `cg:2463` | `machines.sh` |
| `cg sweep [--all] [--cached]`, `cg regions-sweep` | fresh scan unless `--cached` | AWS read | `--json` | 2 | `lib/sweep.sh:419-521` | `sweep.sh`, `region-optin.sh` |
| `cg regions [optin]`, `cg regions enable <r>` | enabled regions | AWS read/mutation | `--json` | read 2; enable 3 | `lib/sweep.sh:546-648` | `region-optin.sh` |
| `cg quota [status]`, `cg quota request [ondemand\|spot]`, `cg quota appeal [ondemand\|spot]` | `status`; request/appeal default to `ondemand` | AWS read/mutation | `--json` for status | read 2; request/appeal 3 | `lib/quota.sh` | `quota.sh`, `quota-dom.sh` |
| `cg config`, `cg config show`, `cg config --json`, `cg config get <key>`, `cg config set <key> [value]` | `show` | local read/mutation | `--json` for show | read 2; set 3 | `lib/config.sh` | `config.sh`, `settings.sh`, `settings-layout.sh`, `env-loader.sh` |
| `cg host`, `cg host list`, `cg host add [name] --ssh <user@address>`, `cg host setup <name>`, `cg host status <name>`, `cg host open <name>`, `cg host remove <name>` | `list` | local/remote | `--json` for list/status | list 2; status/add/setup/open/remove 4 | `lib/host.sh:542` | `host.sh`, `hosts-dom.sh`, `tailnet-expiry.sh`, `session.sh` |
| `cg library`, `cg lib`, `cg library status`, `cg library push\|sync [--force\|--verify]`, `cg library pull\|restore [--apps <csv\|all\|none>]`, `cg library check`, `cg library list`, `cg library account\|login [status\|push\|pull\|restore\|forget\|delete\|rm [--from <bucket>]]`, `cg library forget <appid> [--from <bucket>]`, `cg library clean`, `cg library elsewhere`, `cg library reset\|keep <appid> [--from <bucket>]`, `cg library keep-for <days>`, `cg library move <appid> --from <bucket>`, `cg library --bucket\|bucket` | `status` for `library` and `account` | AWS/remote read/mutation | `--json` for `list`, `elsewhere`, `account status` | S3 reads 2; other no-box library 4; on-box 5 | `cg:1271`, `cg:1308-1312`, `lib/library-aws.sh` | `library-*.sh`, `steam-library.sh`, `archive-unreadable.sh`, `s3-region.sh`, `steam-account.sh`, `login-dom.sh`, `steam-login*.sh` |
| `cg games`, `cg games volume [show]`, `cg games --volume`, `cg games volume --delete`, `cg games --volume --delete` | remote report / volume show | remote/AWS read; delete mutation | no | read 2; delete 5 | `cg:1616-1753` | `games-status.sh`, `steam-library.sh` |
| `cg snapshot`, `cg snapshot create`, `cg snapshot --list`, `cg snapshot list`, `cg snapshot --delete <id>`, `cg snapshot delete <id>` | `create` | AWS read/mutation | `--json` for list | list 2; create/delete 5 | `cg:1755` | add focused test |
| `cg watchdog`, `cg watchdog status`, `cg watchdog check`, `cg watchdog logs [--watch]`, `cg watchdog install`, `cg watchdog remove` | `status` | AWS/remote read/mutation | no | status/logs 2; check/install/remove 3 | `cg:1594`, `lib/cloud-watchdog.sh` | `cloud-watchdog.sh`, `init-watchdog.sh`, `guards-dom.sh` |
| `cg aws inventory [--json]` | none | AWS read | `--json` | 2 | `cg:2002`, `cg:2448` | `aws-disconnect.sh` |
| `cg aws forget [--anyway]` | none | local/account read + `.env` write | no | 6 | `cg:1971` | `aws-forget.sh` |
| `cg aws disconnect [--plan]` | none | account mutation; `--plan` is a read | `--json` for `--plan` | 6 (the mutation; `--plan` is an internal read) | `cg:2149` | `aws-disconnect.sh`, `destroy-all.sh` |
| `cg notify` | none | HTTP mutation | NDJSON only | 3 | `cg:1579` | `notify.sh` |
| `cg pair` | none | remote box mutation | NDJSON only | 5 | `cg:1250`, `lib/pair.sh` | `pair.sh`, `sunshine-login.sh` |
| `cg clean` | none | remote mutation | NDJSON only | 5 | `lib/setup:860` | add focused test |
| `cg destroy [--force] [--no-push]` | normal destroy | AWS mutation | NDJSON only | 5 | `cg:1339`, `lib/setup:901` | `destroy-scope.sh`, `destroy-budget.sh`, `stranded-spot.sh`, `archive-unreadable.sh` |
| `cg destroy --all [--force]` | none | account mutation | NDJSON only | 6 | `cg:1400`, `lib/setup:901` | `destroy-all.sh`, `archive-unreadable.sh` |
| `cg open`, `cg up`, `cg open --on <name>` | AWS box | AWS session / host session | NDJSON only | `--on` 4; AWS 5 | `lib/game:83`, `lib/host.sh:521` | `session.sh`, `spot-restart.sh`, `open-unfinished.sh`, `moonlight-gpu.sh` |
| `cg stop [--force]`, `cg down` | none | AWS mutation | NDJSON only | 5 | `cg:300`, `lib/game:293` | `shutdown-push.sh`, `spot-restart.sh` |
| unknown command or flag | `help` on unknown command; error on unknown flag | dispatch | n/a | 0 | `cg:68`, `cg:2526` | `app.sh` |

Not currently reachable from `cg`:

- `lib/setup rebuild` exists but the dispatcher does not expose it. Do not port it unless it is
  promoted to a documented command.
- Generated `lib/__pycache__/` files are not assets and should not be embedded or packaged.

### 6.1 JSON support to verify in Phase 0

The current help says `--json` is only for `ping` and `snapshot --list`. That is stale. At minimum,
the app calls these with JSON:

| Command | JSON source |
| --- | --- |
| `status --json` | `lib/setup status_json` |
| `cost --json` | `lib/setup cost_json` |
| `watcher --json` | `cg watcher_json` |
| `ping --json` | `cg cmd_ping` |
| `machines --json` | `lib/machines.sh machines_json` |
| `sweep --json`, `sweep --cached --json` | `lib/sweep.sh` |
| `regions --json`, `regions optin --json` | `lib/sweep.sh` |
| `quota --json`, `quota status --json` | `lib/quota.sh` |
| `config --json`, `config show --json` | `lib/config.sh config_json` |
| `deps --json` | `lib/laptop.sh deps_json` |
| `creds --json`, `creds tailscale --json` | `lib/laptop.sh` |
| `host list --json`, `host status <name> --json` | `lib/host.sh` |
| `library list --json`, `library elsewhere --json`, `library account status --json` | `cg`, `lib/library-aws.sh` |
| `snapshot --list --json`, `snapshot list --json` | `cg cmd_snapshot` raw `describe-images` |
| `aws inventory --json`, `aws disconnect --plan --json` | `cg aws_inventory_json` |

Phase 0 must record whether each JSON form is supported before or after the subcommand, and whether
it is stable enough to freeze. Do not infer support from the help text.



## 7. Shared Go design

```text
cmd/cg/main.go                 flags, version, dispatch
internal/contract/             command registry, event contract, JSON schemas
internal/cli/                  global flag parsing, aliases, help generation
internal/config/               .env loader, registry, validation, secret masking
internal/output/               plain report, styled report, NDJSON emitters
internal/ask/                  questions, typed confirmations, secret input
internal/awscfg/               SDK config, endpoint overrides, retries, user agent
internal/aws/{ec2,s3,iam,...}  narrow service interfaces and implementations
internal/local/                exec, ssh, tailscale, moonlight, curl, package managers
internal/platform/             per-OS seams: paths, privilege, process control, packages
internal/state/                .env writes, cache, session lock, hosts.json
internal/commands/...          one package per command group
internal/pricing/              rates, price cache, INR conversion
internal/testfixture/          fake AWS, fake local executables, golden helpers
testdata/contract/             frozen JSON and NDJSON fixtures
testdata/golden/               normalized plain output fixtures
```

Rules:

- `cmd/cg` stays thin. It parses global flags, resolves the environment, and dispatches.
- The command registry is the source of truth for help, `--contract`, aliases, default subcommands,
  JSON support, watch support, and `runs_alone`.
- Command packages return typed results and errors. Printing happens in `internal/output`.
- AWS clients are interfaces. A command never constructs an SDK client directly.
- Local commands are injected as a `Runner` with `Run`, `Output`, and `Stream`.
- Everything that differs per operating system lives behind `internal/platform` and is chosen at
  build time: config and cache directories, the runtime directory for locks, how a command is
  elevated (sudo, polkit, UAC), how a process tree is stopped, how the package manager is found, and
  where Moonlight, Tailscale and OpenSSH live. A command package never checks `runtime.GOOS`.
  Linux and macOS implementations are written first; the Windows one is a stub that returns a clear
  "not supported yet" until the Windows track.
- `context.Context` is passed to every AWS call and child process.
- All paths use `filepath`, not string concatenation.
- `go:embed` holds immutable shell assets: `lib/bootstrap.d`, `host`, `lambda`, and any `lib/*.sh`
  that still runs on the box. This keeps one release artifact without turning the Go source into one
  file. Go cannot embed paths above the package directory, so `//go:embed ../../lib/...` is invalid:
  either put `go.mod` and the embedding package at the repository root, or stage assets with `go
  generate` into an embeddable directory. The pilot must prove the chosen layout with a trivial
  build.
- A command package should stay under roughly 700 lines. If it grows beyond that, split by operation,
  not by shell file.

Check before Phase 1: shared helpers.

- Section 16 says to port `lib/common.sh` and also to embed `lib/bootstrap.d` and `host/*`
  unchanged. If any script that runs on the box sources a helper from `lib/common.sh` (or another
  `lib/*.sh`), that helper cannot simply be ported away; it has to stay as shell next to the
  embedded script, or be copied into the asset.
- The pilot's first task is to list every `source`/`.` line in `lib/bootstrap.d/*`, `host/*`, and
  the user-data template, and record which helper each one needs. The result decides which parts of
  `lib/common.sh` are "port" and which are "embed".

Suggested command spec shape:

```text
Path            []string        e.g. ["library", "forget"]
Aliases         [][]string      e.g. [["lib", "forget"]]
Default         []string        e.g. ["status"]
Summary         string
Flags           []FlagSpec
SupportsJSON    bool
SupportsWatch   bool
Kind            read|local-write|aws-write|remote-write
RunsAlone       bool
NeedsBox        bool
Asks            []string
ExitCodes       []int
Tests           []string
```

Help and `--contract` are generated from this registry. If a command is not in the registry, the
dispatcher must not route to it.



## 8. Phase 0: freeze the contract

Phase 0 changes documentation, fixtures, and test scaffolding only. It does not change the product's
observable behavior. It starts with the pilot slice (8.0); the rest follows once the pilot is
reviewed.

### 8.0 Pilot slice

Purpose: prove the layout, the embed, the harness, the oracle comparison, and the app boundary on
one real command, cheaply, before the whole contract is frozen.

1. Create the Go module (pinned `go`/`toolchain`, `CGO_ENABLED=0` Linux build). Put it where
   `go:embed` can reach the asset trees (section 7) and prove that with a trivial embed.
2. Record the shared-helper list (section 7) before any package is created.
3. Add a minimal registry with the globals, `--version`, `--contract`, `help`, and `cost`. Help and
   `--contract` are generated from it.
4. Implement just enough of Phase 1 for `cost`: global flags, the env loader, the three output modes,
   the AWS client factory with endpoint override, the `Runner`, and the `internal/platform`
   interface with its Linux and macOS implementations.
5. Capture the oracle for `cost`: plain, `--daily`, `--json`, and NDJSON, normalized, for the
   normal, no-box, unknown-price, unreadable-archive, and other-regions cases (10.2).
6. Port `cost` (10.2) and make the fixtures and the existing `cost-*.sh` suites' observable checks
   pass against `cg-go`.
7. Run the Electron app's Spending screen against `cg-go` through the runner, with no renderer
   change.
8. Write down what the pilot taught: package layout, embed approach, harness gaps, how much the
   human-text matching rule saved, and an honest estimate for the rest. Stop for review.

Pilot exit gate: `cg-go cost`, `cost --daily` and `cost --json` match the oracle; the app screen
works; `go test ./...`, `go vet ./...` and the static build pass; the findings are written up. No
other command is started until the owner reviews it.

### 8.1 Command registry and inventory

1. Encode section 6 as a machine-readable registry, including aliases and default subcommands.
2. Record the exact usage/error text for every invalid form.
3. Record the current dispatch order, so alias matching cannot shadow a command.
4. Add a generated help test: every registered command appears once; no unregistered command is
   reachable.
5. Decide whether undocumented forms such as `aws disconnect --plan` are public or internal, and
   document the decision.

### 8.2 Global flags and exit codes

1. Enumerate the exact behavior of `cg:12-73`.
2. Freeze the current rule: global flags are accepted before the command; `--json` and `--watch` are
   also scanned after it. Decide whether `--region` and `--host` should also be accepted after the
   command. Recommendation: normalize all four in both positions as a documented parity exception,
   with tests, because inconsistent placement is already a source of bugs.
3. Record the current `--json` dispatch collision: because `deps` and `creds` check `JSON` before
   the subcommand, `cg deps install --json` prints deps JSON instead of installing, and `cg creds
   set --json` / `cg creds tailscale set --json` print creds/token JSON instead of saving. Do not
   preserve this silently: reject `--json` on mutating forms or make JSON output-only, and test the
   chosen rule. Record it as a parity exception if the chosen behavior changes current output.
4. Freeze missing-value behavior for `--region` and `--host`.
5. Freeze exit codes:
   - `0`: success, including an idempotent no-op.
   - `1`: handled failure.
   - `3`: AWS scope unknown where the current CLI returns 3 (`aws forget`, `aws disconnect`).
   - `130`: interrupt.
   - Child exit status for `ssh` and streamed commands where the current CLI propagates it.
6. Freeze `--version`: `cg <commit>` then `events 1`, including the dirty suffix and the `unknown`
   fallback. Use `-ldflags` for release builds and `debug.ReadBuildInfo` for VCS data when
   available.
7. Freeze `--contract` JSON: `events`, `runs_alone`, `asks`. Add a schema before extending it. If
   adding a command list or registry version, make it additive and update the app contract test.
8. Add tests for flags before and after the command, aliases, missing values, and unknown flags.

### 8.3 Output contract

1. Capture plain output for every command form. Timestamps, IDs, prices, durations, and paths are
   placeholders in golden files.
2. Compare machine contracts exactly (JSON payloads, NDJSON events, exit codes, prompt IDs). Compare
   human reports by content: the same fields, wording, ordering, labels, and unknown/zero
   distinctions, after normalizing whitespace and column alignment. A report that prints a price of
   0 where the oracle prints `?` is a failure; one that pads a column differently is not.
3. Capture styled output only as a rendering test: strip ANSI and gutter, require the plain text to
   come back byte-for-byte from the Go renderer's own plain output, as `tests/ui.sh` does.
4. Capture NDJSON for `CG_JSON=1`: `step`, `line`, `step_end`, `report`, `block`, `ask`, `error`.
5. Freeze field types: `rc`, `secs`, and `secret` are numbers; all other event fields are strings.
6. Freeze stream rules: events on stderr, command data on stdout, answers on stdin. Non-JSON stderr
   from a child is raw output.
7. Freeze prompt IDs and typed confirmations from `cg --contract`. `CG_YES=1` must not answer a
   typed confirmation.
8. Record the exact difference between a report, a block, a relay line, and a plain line. The app
   renders them differently.
9. Record `CG_COLOR`, `CG_JSON`, `CG_YES`, `CG_SLEEP_PCT`, `CG_PRICES_FILE`, and test-only env
   behavior.

### 8.4 Config contract

1. Freeze `cg_env_file` resolution order exactly: `CG_ENV_FILE`, `CG_HOME/.env`, repo `.env` if
   present, writable repo `.env`, then `XDG_CONFIG_HOME/cg/.env` (and each OS's equivalent behind
   `internal/platform`).
2. Freeze `cg_env_load` behavior: parse `KEY=VALUE`, ignore malformed lines, skip comments, exported
   values win, and preserve a final line without a newline.
3. Freeze atomic writes: temp file, copy, `0600`, keep other lines.
4. Freeze the registry fields: key, kind, default, rule, note, label, group.
5. Freeze validation for number, choice, secret, ntfy, email, region, and text.
6. Freeze `config --json`; secrets report `is_set`, never a value.
7. Freeze `config get` as the only secret reveal path.

### 8.5 Locks and concurrency contract

1. Freeze the session lock at `XDG_RUNTIME_DIR/cg-session-<uid>.pid`, falling back to `TMPDIR` and
   then `/tmp`: alive process plus a command line that still looks like a cg session. The per-OS
   location is chosen behind `internal/platform`.
2. Freeze archive locking (`ro`/`rw`) and the `destroy --no-push` behavior.
3. Freeze the `runs_alone` list exactly as `cg --contract` publishes it.
4. Record which commands read the session lock, which write it, and which end a session first.
5. Add tests for a second `open`, `destroy` ending a session, and a read while a write is running.

### 8.6 AWS contract

1. Freeze the client factory contract: region, credentials, retry policy, a `User-Agent` identifying
   `cg`, and SDK base-endpoint overrides for tests. Phase 1 implements the factory; Phase 0 only
   records the contract.
2. Define ownership: `cg:host=<host>` is authoritative. `Name=<host>` is a read-only legacy
   fallback. Destructive paths require the cg tag or an explicit legacy decision.
3. Freeze "could not ask" as a first-class error. A failed region list, describe call, or S3 read
   must propagate; it must not become an empty result.
4. Record the audit fixes the Go path must make in the owning phase: role-used-elsewhere is
   tri-state, cleanup failures are collected, multipart uploads are aborted before bucket deletion,
   and other-region inventory records per-region errors.
5. Record the AWS calls behind each command, including pagination and region selection. Do not treat
   AWS CLI text output as the contract; treat the current `cg` output as the contract.

### 8.7 Test harness

1. Add a `testfixture` package that starts an AWS-compatible HTTP server. Point SDK clients at it
   with base endpoints.
2. Add fake `ssh`, `tailscale`, `moonlight`, `curl`, and package-manager executables on a temp
   `PATH` for black-box tests.
3. Run tests with isolated `HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, and `XDG_RUNTIME_DIR`.
4. Capture old CLI output into `testdata/contract` before changing anything. Those fixtures are the
   migration oracle.
5. Add a parity harness that runs the existing shell suite against the Go binary without editing
   every test: copy or symlink `cg-go` as `cg` in a temporary checkout. Tests that read source files
   instead of behavior cannot run this way (section 17).
6. A phase is not complete until its fixtures pass.

### 8.8 Phase 0 exit checklist

- Pilot slice reviewed and its findings written down.
- Command registry committed and reviewed.
- Every command form has at least one fixture or a documented reason why it cannot be captured.
- JSON and NDJSON schemas committed.
- Help generated from the registry; stale hand-written help removed at cutover.
- Global flag and exit-code fixtures pass against the Bash oracle.
- Session/archive lock fixtures pass against the Bash oracle.
- AWS fake server and fake local tools run offline.
- The Go module and test harness build and test offline.
- Shared-helper list recorded (section 7).
- No product behavior changed.
- Open decisions in section 20 are resolved or explicitly deferred.



### 8.9 Pilot findings (2026-10-25)

What was built, on `go-migration-plan`: the module at the repo root; `--version`, `--contract`,
`help` and global flags (`--json`, `--watch`, `--region`, `--host`); the output package (plain
errors and NDJSON events); `internal/config` (settings file, exported values win); `internal/pricing`
(Price List, cache, exchange rate, GST); `internal/costdaily` and `internal/costreport` (the two
Python files); `internal/costfacts` (every AWS read `cost` makes, each saying whether it could be
read); `internal/commands/cost` (human report, `--daily`, `--json`, the not-yet-billed estimate);
`internal/testfixture` (scenario-driven AWS fakes). Static binary, about 13 MB, `CGO_ENABLED=0`.
All tests pass, including with `-race`.

**What the pilot settled**

- The module belongs at the repo root so `go:embed` can reach `lib`, `host` and `lambda`.
- The shared-helper check is done: the box-side scripts (`lib/bootstrap.d/*`, `host/*`) source
  nothing from `lib/*.sh`, only `/etc/os-release`. All of `lib/common.sh` can be ported.
- Two kinds of oracle work. For pure transforms (`cost-daily.py`, `cost-report.py`) the Python is
  run on saved inputs and the Go output is compared to what it printed (64 captured outputs). For
  everything that reads AWS, the shell suite's assertions are ported to Go tests over fake clients
  (`internal/testfixture`), the way the price and exchange-rate tests were. Capturing golden output
  of the Bash `cg` against a faked `aws` CLI was not worth building: the fake would have to emulate
  `--query` and text output, and would be thrown away.
- JSON is compared on values, keys and nulls; number formatting (`110` against `110.0`) is not part
  of the contract. Rule 8 already says this; the Python-isms are not reproduced.
- The AWS SDK needs no adapters: the SDK clients satisfy narrow interfaces, so fakes are a few lines
  each, and a test that forgets cg's tag finds another project's disk and fails.

**What the pilot found**

- `cost` is not a clean first command. Its human report borrows lines from subsystems that are
  ported later: the Steam login line (`login_line`), the archive countdown (`cw_archive_line`), the
  IAM role lines (`iam_lines`), the stranded-spot note, and the other-regions section
  (`cost_elsewhere`). They are shared with `status`.
- The pilot's boundary is therefore: everything `cost` computes itself. The borrowed lines come
  back with their owners (library, watchdog, `aws inventory`, `status`). Until then the Go report
  omits them and `--json` has `archive.decision: null`. This is the one known gap, and it is
  tracked, not forgotten.
- Deliberate differences from the Bash `cg`, all of them fail-closed:
  - an unreadable fact is `?` or `null`, never `0`, `none` or `false` (the Bash printed `0` for a
    failed volume, image or key-pair read, and "EMPTY" for an archive it could not list);
  - a month whose only charges are under half a cent shows its total;
  - the report says `cg games --volume --delete`, which exists, not `cg games --delete`, which does
    not;
  - the day-by-day Cost Explorer call is always the single call, so `cost` without `--daily` no
    longer makes a second, monthly one.
- Exchange-rate fetch uses HTTP only. The Bash used `curl`, which also accepted `file://`; the
  tests used that. The Go tests use a local server.

**Not yet done in the pilot**

- No real-AWS run. `cg-go cost` has never talked to AWS. One run is a read-only Cost Explorer call
  at about $0.01 (about INR 1) plus free reads, and it needs the owner's approval (decision 14).
- The app's Spending screen has not been run against `cg-go` (step 7 of 8.0).

**Estimate for the rest**: `cost` took the most design because it set the patterns (facts with
unknown states, fakes, oracle, wiring). The remaining read-only commands (Phase 2) are each
smaller but there are about 15 of them, and the lifecycle and destruction phases (5 and 6) are the
large ones. This is months of work, not weeks; the order in section 5 stands.

### 8.10 Progress (2026-10-25)

**Phase 2 (the read-only commands) is done.** Each was ported, tested over fakes, and compared with
the Bash `cg` on the real account (both outputs side by side, same moment): `cost`, `status`,
`watcher`/`guards`, `watchdog` (status, logs), `ping`, `log`, `ssh`, `config` (show, get, set,
`--json`), `deps` (status), `creds` (status), `machines`/`types`, `sweep`, `regions` (list, optin,
enable), `quota` (status, request, appeal), `host list`, `library` (list, elsewhere, account,
`--bucket`), `games` (and `--volume`), `snapshot --list`, and `aws inventory`. Text and JSON are
identical to the Bash's except for the deliberate differences below.

Shared pieces that came with them: the output primitives (plain and NDJSON events), the settings
registry and its validation, prices and the exchange rate, the session lock, the watchdog's
definition (its package is byte-identical to Python's, its policy equal as data, its fingerprint
equal to the shell's), the derived archive bucket name, the library reads, the every-region storage
scan, and the AWS and local-runner fakes.

Deliberate differences from the Bash, all recorded in the commits that made them:

- an archive with no games is empty (the Bash read `aws s3 ls`'s non-zero exit for an empty prefix
  as a failed listing and called the Steam login "unknown");
- an unreadable fact is `?` or null, never `0`, `none` or `false`; `cost` says "could not be read"
  where the Bash said "nothing of cg's" about a region or a library scan that had failed;
- `deps` lists ssh, Tailscale and Moonlight; python3, curl and the AWS CLI are no longer needed;
- the egress cache lives in the cache directory, not beside the scripts;
- the settings table pads by characters, not bytes, so a row with a dash lines up;
- `machines` says when a quota could not be read (`quota_unknown`) and is several times faster;
  `sweep` is about twice as fast and fills in `store_gb`, which the Bash always left null;
- the quota appeal states the forced-shutdown time that is actually set (the Bash printed 180
  minutes whatever the setting), and names the city without its nesting parentheses;
- `games --volume` tells you to `cg games --volume --delete`, a command that exists;
- flags are accepted after the subcommand everywhere, as people type them.

Not ported yet (the Bash prints the same pieces): the styled terminal rendering (a terminal gets the
plain text), `games --volume --delete`, `snapshot create/--delete`, the box-side `library`
commands, and everything in Phases 3 to 6.

### 8.11 Phase 3 progress

Done and compared (where it reads only) with the Bash on the real account: `config set`, `notify`,
`watchdog install/check/remove`, the ask layer (with a masked secret read, so a pasted key shows
`*`), `creds set [aws|tailscale]`, `creds tailscale set/authkey/signin`, `deps install`, and
`check` / `check --fix` (identical to the Bash apart from the deps list). The Tailscale key client
(`internal/tskey`), the ssh-key comparison (`internal/sshkey`, the fingerprint is computed in Go,
no openssl) and the root-run helper (`internal/laptop/root.go`) are shared with Phase 5's `init`.

Nothing that changes the account has been run live: `check` was run only where it made no change
(every setting present and the stored key probed, not replaced), and its writes are proven over
fakes, including that no EC2 create call exists in its client.

Open: `cg-go check` on this server stops at "Tailscale refused the API token", as the Bash does;
that token has probably expired.

### 8.12 Phase 4 progress

Done: `host add`, `host remove`, `host status`, `host setup`, `host open`, and every no-box library
change (`forget`, `clean`, `reset`/`keep`, `keep-for`, `move`, `account forget`). Where a command can be
run without changing anything (the refusals and the unconfirmed prompts of the library commands) it
was compared with the Bash on the real account and is identical. Everything that writes is proven
over fakes: an in-memory S3 for the archive, a scripted runner for ssh, and a Sunshine server that
behaves as Sunshine does (first-run account, the pairing request, a client that is or is not saved).

The shared pieces Phase 5's `init` and `open` reuse are now Go: `internal/render` (byte-identical to
`lib/render.sh`, tested against it), `internal/build` (the log follower, the Steam wait and
`build_finish`), `internal/sunshine` (the login rules and pairing), `internal/stream` (Moonlight's
flags and the Intel-GPU choice), `internal/session` (claim/release) and the tailnet key-expiry call
in `internal/tskey`.

Not run live: no machine of yours exists on this server, so `host add`/`setup`/`open` were never
pointed at a real one. They need the laptop and a test machine; that is the first thing to do there.

Deliberate differences from the Bash: `library clean` and `forget` delete a folder with a trailing
slash, so an orphan called "Diablo" no longer takes "Diablo IV" with it; `library clean` says when the
archive could not be read instead of claiming nothing is orphaned; a copy over 5 GiB is made in parts.

### 8.13 Phase 5 progress

Written and tested over fakes: `open`, `stop`, `clean`, `pair`, `snapshot create/--delete`, the on-box
`library` forms, `games --volume --delete`, the normal `destroy` (`--force`, `--no-push`), and `init` end
to end (the bucket and role, the budget, the shutdown check, the image, key pair and security group,
user-data, the launch, the tailnet node, the build, pairing, the summary, and the game chooser). Where a
piece has a Bash twin whose output is deterministic it is tested against it on the real files: the launch
error report, the bootstrap assembly, the host bundle's comment strip, the end-of-init summary.

`cg-go init` was behind `CG_GO_INIT=1` until the real-AWS gate passed (see 8.14: init on demand and spot,
stop/restart/restore, destroy, destroy --all). The switch was removed after that, so the app can build.

Differences from the Bash worth knowing:

- `cg clean` no longer deletes the installed games. The Bash ran `find /scratch -mindepth 1 -maxdepth 1
  -exec rm -rf`, which removes `/scratch/steam`, and the next push then mirrored the deletion to S3. The
  safer version already in `lib/game` was never the one `cg` ran. **This is a bug on `main` too.**
- remote words (`cg library push --apps ...`) are quoted one by one, so nothing typed becomes a second
  command on the box;
- a `DERP` path warns as relayed (tailscale never prints the word "relay" for it);
- destroy collects cleanup failures instead of hiding them, and clears the box's own settings only once
  the instance is really gone;
- an orphan folder called "Diablo" no longer takes "Diablo IV" with it (the Bash deleted by prefix).

### 8.14 Phase 6 progress

Written and tested over fakes: `destroy --all`, `aws forget` and `aws disconnect`. They were NOT compared with
the Bash on the real account: running a delete command there, even to see it stop at the typed word, was
declined, and rightly. The exit gate (a disposable account fully cleaned, final inventory empty) is open.

Differences from the Bash:

- `destroy --all --no-push` is refused. The Bash accepted the pair and ignored `--no-push` while it deleted
  the archive.
- a game archive that cannot be listed is said to be unreadable, not shown as "0 objects";
- `destroy --all` and `aws disconnect` carry on past a failure, say everything that failed, and return
  non-zero; a bucket that will not go stays in `.env`;
- multipart uploads are aborted by the bucket delete itself, not only by `aws s3 rb --force`;
- the failed old-volume message names `cg games --volume --delete`, which exists (the Bash named
  `cg games --delete`, which does not).

### 8.15 Phase 7 progress

Started. The app's `runner.js` drives the Go binary unchanged (`CG_JSON=1`,
events on stderr, answers on stdin; `--contract` is raw JSON on stdout).

- Compared the two engines through the app's own runner on the renderer's read
  commands: config, watcher, machines, sweep --cached, creds, host list/status,
  regions, quota, watchdog status, snapshot --list, aws inventory, ping, library
  list/elsewhere, status, cost. Same, except the deliberate differences:
  `status --json` carries extra `login` and `tailnet.ip`, `deps --json` lists
  three tools (ssh, tailscale, moonlight), and `cost --json` leaves
  `archive.decision` null (the renderer never reads it).
- Real differences found and fixed: a bucket that does not exist is an empty
  archive (library list, status budget alerts, cost), not an unknown one.
- CLI-01: the repo path and every argument are single-quoted on the WSL route,
  and `wslpath -u` converts the repo path. CLI-03: Stop on Windows runs
  `taskkill /T`. CLI-06: `cg --contract` now carries `env`, the settings a
  screen may send; the app falls back to GAME_APPS only if cg cannot be asked.
  Both engines print it, so the golden file stays shared until cutover.
- `destroy` was dispatched but missing from the registry (and so from help);
  added, and the stale "to come" summaries refreshed.

Not done: the cutover itself (rename the binary to `cg`, delete the Bash tree and
the shell tests it replaces, ship only the Go binary in the package) and Track W.

## 9. Phase 1: skeleton and shared runtime

1. Create `cmd/cg` and the packages in section 7, using the module pinned in the pilot.
2. Implement global flags, aliases, help, version, and contract from the registry. No command
   implementation may call AWS yet.
3. Implement the env loader, config registry, atomic writer, and secret masking.
4. Implement the three output modes: plain, styled, NDJSON.
5. Implement the ask layer: normal prompt, secret prompt, typed confirmation, JSON ask event.
6. Implement the error type with exit code and event emission. Ensure `step_end` is emitted on
   success, failure, and interrupt.
7. Implement the AWS client factory and one fake-backed smoke call (`sts get-caller-identity`).
8. Implement local-exec wrappers with context cancellation and argument slices.
9. Implement `internal/platform` for Linux and macOS, with a Windows stub, and run the unit tests
   for it on both.
10. Implement the session lock and archive lock primitives.
11. Wire the Phase 0 test harness to the Go binary and run one end-to-end `cg-go --contract` test.

Exit gate: `cg-go help`, `--version`, `--contract`, `config show`, and a fake `status` skeleton all
work; `go test ./...` and `go vet ./...` pass on Linux and macOS.



## 10. Phase 2: read-only commands

Read-only means no AWS resource creation/deletion, no `.env` write, and no cg-initiated remote
mutation. Some commands still write cache or session status; preserve that separately. `cg ssh` is a
user-controlled passthrough, not a cg mutation; it stays here but is called out in the phase gate.

Phase 2 covers local, AWS, and remote-box reads. Host status stays with the host boundary in Phase
4. On-box `library` commands move to Phase 5 with the box lifecycle.

### 10.1 `status`

1. Port `status_facts` as a snapshot struct with explicit `Unknown` states.
2. Collect account, plan, credits, quotas, box, volumes, snapshots, images, EIPs, key pair, security
   group, old volume, archive, login, expiry, config, budget, session, local tools, tailnet, and
   readiness facts.
3. Preserve the rule that a failed probe is unknown, not empty. In particular, a failed S3 listing
   must not print "EMPTY".
4. Port the human report from the same facts. Do not make the styled report the source of truth.
5. Port `--json` with the same field names, null semantics, rates, and month hours.
6. Preserve the EIP wording: the count is region/account-wide and not made by cg, and it bills while
   idle. Do not present it as a cg-owned resource.
7. `--on <name>` delegates to host status; keep that dispatch in Phase 4.
8. Tests: `status-json.sh`, `status-iam.sh`, `reports-more.sh`; add a failed-S3-listing case.

### 10.2 `cost` (the pilot command)

1. Port the single Cost Explorer call and the daily/aggregate models. `--daily` must not make a
   second Cost Explorer call; the CloudWatch, Price List, spot-price, S3, and cross-region reads are
   separate facts, not Cost Explorer calls.
2. Port the facts behind the report: tagged instance/state/type/lifecycle/AZ, CloudWatch hours,
   cg-owned volumes with `CreateTime`, attached volumes, cg-owned images and their snapshots,
   cg-tagged loose snapshots, account-wide EIPs, key pair, security group, budget, legacy games
   volume, archive, login, and watchdog state.
3. Preserve cg ownership scope. Count the current box's attached volumes plus `cg_owned_volumes`
   (tag or legacy games name); count only cg-owned images, their snapshots, and cg-tagged loose
   snapshots. Keep EIPs account/region-wide and label them as not made by cg.
4. Estimate from the actual type and lifecycle, not configured values: Price List on-demand price,
   or the current spot price for a spot box. Add the public IPv4 hourly price. An unknown price is
   `?`/null, never a hard-coded fallback. Accrue each disk from its `CreateTime`, not the first of
   the month; snapshot cost is an upper bound; with no instance, say the compute estimate does not
   include earlier sessions.
5. Cost Explorer parsing: strip only a real region prefix matching `^[A-Z]{2,4}[0-9]{0,2}-`; never
   split at the first dash. Preserve unprefixed usage-type names. Include every row in the total
   even when the table hides rows at or below `0.004`. If the only charges are sub-cent non-egress
   rows, still print the total, not "nothing billed yet this month" (the remaining COST-07 gap).
6. Port the human report's scope. The resource block covers this region; the archive bucket comes
   from `.env` or its derived name; `head-bucket` distinguishes missing, unreadable, and readable.
   The `other regions` section lists saved games plus cg's disks, images, and snapshots elsewhere,
   with monthly cost where known. If a global or per-place library read fails, or a storage scan
   fails, print unknown - never "nothing of cg's". The current `cost_elsewhere` treats a
   `library_elsewhere_json` error object as empty and can still print that false reassurance; fix it
   during the port and test it. `cg_storage_everywhere` also falls back to the current region when
   `describe-regions` fails, so that failure can read as "none" too.
7. Add the missing Elastic IP line to the human resource block, or correct the docs that now claim
   `cg cost` lists one. Leave COST-01 marked partial until that is settled.
8. `--json` remains the app contract: preserve field names and null semantics.
   `storage.known_usd_month` and `storage.unknown_usd_month` are null when the S3 price is unknown.
   The cross-region section is human-only today; do not silently add it to JSON without a schema
   and golden-output change.
9. Tests: `cost-daily.sh`, `cost-dom.sh`, `cost-estimate.sh`, `prices.sh`, `fx-rate.sh`, and
   `aws-disconnect.sh` case 6c. Add: only-sub-cent rows still total; `list-buckets` and per-place
   failures never read as empty; an Elastic IP is visible; cross-region scan failure is unknown; and
   an unknown S3 price leaves both storage fields null.
10. Post-audit status: COST-06 and COST-08 are fixed; COST-01, COST-07, and COST-09 are partial;
    COST-04 is addressed by the stopped-box expiry but still needs a real-AWS check that
    `DeleteOnTermination` removes the root disk; COST-02, COST-03, and COST-05 are unchanged.

### 10.3 `watcher`

1. Port guard facts: instance state, on-host timer, shutdown action, cloud rule, last decision,
   budget, archive, and idle/stuck minutes.
2. Preserve "no box" vs "box not reachable" vs "not armed" as distinct states.
3. Port `--json` and `--watch` (remote journal tail).
4. Tests: `watcher.sh`, `guards-dom.sh`, `init-watchdog.sh`.

### 10.4 `ping`

1. Wrap `tailscale ping`; parse the last line for direct vs DERP and the median latency.
2. Preserve `{"node","path","median_ms"}`; no reply is `null`, not zero.
3. `--watch` streams `tailscale ping --until-direct=false`.
4. Add a test with a fake tailscale that returns direct, DERP, and no-reply cases.

### 10.5 `log`

1. Map `build`, `steam`, `watchdog`, `disk`, and `sunshine` to the exact remote commands.
2. `--watch` uses a streaming child with cancellation.
3. Preserve exit status and raw output.
4. Test with a fake SSH that records the remote command.

### 10.6 `ssh`

1. Resolve the tailnet IP, then exec the user's `ssh` binary with argument slices.
2. `cg ssh [cmd]` passes the argv directly to `ssh` without adding a local shell. OpenSSH still
   joins the remote command with spaces, so preserve that existing behavior rather than pretending
   it is a quoted remote argv.
3. Propagate the child exit status and stdio.
4. Tests: `ssh-key.sh`, `tail-exit.sh`.

### 10.7 `machines`

1. Port the GPU type shortlist, per-region offering lookup, vCPU/GPU/RAM/disk data, quota, on-demand
   price, spot price by zone, and the table/JSON renderers.
2. Preserve explicit-region parsing, `--all`, and the `--sweep` alias to a fresh sweep.
3. Unknown prices and missing quota are distinct from zero.
4. Tests: `machines.sh`.

### 10.8 `sweep`

1. Port region discovery, coarse RTT shortlist, quiet second pass, spot placement scores, quota, and
   price lookup.
2. Preserve the 80 ms default and `CG_SWEEP_MAX_MS`; latency is measured, not looked up.
3. Port the cache at `XDG_CACHE_HOME/cg/sweep.json` with atomic writes. A cache write failure is
   silent and must not fail the sweep.
4. `--cached --json` never scans. A missing or unreadable cache returns the empty answer with
   `cached:false` and no error. Readable but invalid JSON returns empty `cached:false` with an
   `error`; it is not a hard failure. A readable but old cache is *not* discarded: return it with
   `cached:true` and its `age_seconds`, and let the app decide whether to rescan. Human `cg sweep
   --cached` intentionally fails with "for the app; run cg sweep to scan."
5. Preserve `--json`, `--all`, and the app's `--cached --json` path.
6. Tests: `sweep.sh`, `region-optin.sh`; add missing-cache, invalid-cache, and old-cache cases.

### 10.9 `regions`

1. Bare `regions` uses `describe-regions` for enabled regions.
2. `optin` lists every region and its opt-in status.
3. `enable <region>` is a mutation; keep it in Phase 3.
4. Preserve `--json` payloads and the after-subcommand `--json` form.
5. Tests: `region-optin.sh`.

### 10.10 `quota status`

1. Port the quota codes for spot and on-demand, current value, request state, and vCPU need.
2. Port `quota --json` and the human view.
3. `request` and `appeal` are mutations; Phase 3.
4. Tests: `quota.sh`, `quota-dom.sh`.

### 10.11 `config show/get/--json`

1. Port the registry and renderers.
2. `get` is the deliberate secret reveal path; preserve raw output with no label.
3. `set` is a mutation; Phase 3.
4. Preserve unknown-key errors and validation.
5. Tests: `config.sh`, `settings.sh`, `settings-layout.sh`, `env-loader.sh`.

### 10.12 `deps status`

1. Port the tool registry, package-manager detection, missing/installed facts, and manual hints.
   Detection goes through `internal/platform`, so each OS reports its own package manager.
2. Port `--json`.
3. `install` is a mutation; Phase 3.
4. Tests: `deps.sh`, `deps-dom.sh`.

### 10.13 `creds status`

1. Port AWS credential source detection and masked display.
2. Port Tailscale token and auth-key status.
3. Port `--json` without secret values.
4. `set`/`tailscale set`/`signin`/`authkey` are mutations; Phase 3.
5. Tests: `creds.sh`, `authkey.sh`, `creds-dom.sh`.

### 10.14 `host list`

1. Port `hosts.json` read, name/ssh/os/family/ready facts, and secret removal from `list`.
2. Preserve `--json` and the default `list` subcommand.
3. `host status` and all host mutations are Phase 4.
4. Tests: `host.sh`, `hosts-dom.sh`.

### 10.15 `library` reads that do not need the box

1. Port bucket resolution: explicit env, then account/host/region derivation.
2. Port the S3 index read with the "missing index on a readable bucket is empty; any other error is
   an error" rule.
3. Port `list` (index + orphan scan), `account status`, `elsewhere`, and `--bucket`.
4. Preserve `list --json`, `elsewhere --json`, and `account status --json`.
5. Add failed-listing, missing-bucket, denied, expired-token, and cross-region fixtures.
6. `library status`, `library check`, `library push/pull`, and `account push/pull` need the box;
   Phase 5 (13.9).
7. Tests: `library-*.sh`, `steam-library.sh`, `archive-unreadable.sh`, `s3-region.sh`.

### 10.16 `games` and `games --volume`

1. Port the remote Steam manifest read and the state/size/progress calculation.
2. Preserve the "trust disk over manifest" incomplete-game rule.
3. Port the old EBS volume lookup and cost line.
4. `games --volume --delete` is a mutation; Phase 5.
5. Tests: `games-status.sh`, `steam-library.sh`, `steam-tools.sh`.

### 10.17 `snapshot --list`

1. Port `describe-images`, creation ordering, volume size, snapshot price, and total.
2. Preserve `--json` raw image list.
3. `snapshot` default create, `create`, and `--delete` are Phase 5.
4. Add a fake-AWS test for empty, one image, and missing price.

### 10.18 `watchdog status/logs`

1. Port function, rule, role, recent log decisions, archive expiry status, and the stopped-box lines
   now emitted by the Lambda (`cg-watchdog:` stopped-for / deleted-in / deleted).
2. Preserve raw log streaming for `logs --watch`.
3. `check`, `install`, `remove` are Phase 3.
4. Tests: `cloud-watchdog.sh`, `guards-dom.sh`.

### 10.19 `aws inventory`

1. Port cross-region machine, watchdog, S3, SSM, budget, disk, image, and snapshot inventory.
2. Record per-region failures, including non-current regions. Do not silently omit them.
3. Preserve `error`, `items`, `usd_month`, `hourly`, and `inr_per_usd`.
4. Preserve `aws inventory --json`; it reuses the `aws disconnect --plan` renderer. The disconnect
   mutation itself stays Phase 6.
5. Tests: `aws-disconnect.sh`; add a failed-other-region fixture.

Phase 2 exit gate: every read-only command in this phase has parity fixtures, no cg-initiated AWS
or remote mutation is reachable (`cg ssh` is the explicit passthrough), and `cg-go` can run the
app's basic read screens (status, guards, cost, library list, machines, sweep). Host screens wait
for Phase 4. `cg check` is deliberately not here: even without `--fix` it can write `.env` and mint
or replace a Tailscale auth key.



## 11. Phase 3: laptop and small AWS mutations

This phase holds most of the per-OS work. Package managers, privilege, and where Moonlight,
Tailscale and OpenSSH live all go through `internal/platform`.

### 11.1 `config set`

1. Validate through the typed registry.
2. Write atomically to the resolved env file with `0600`.
3. Preserve the "applies to next init/deploy" messages.
4. Never echo a secret value.
5. Tests: `config.sh`, `settings.sh`.

### 11.2 `deps install`

1. Port the package-manager plan and the `--fix`/tool-filter behavior.
2. Use a privilege interface for sudo/polkit (and the macOS and Windows equivalents); never build a
   shell string from a tool name.
3. Preserve "already installed", "manual install", and failure messages.
4. Tests: `deps.sh`, `sandbox-deps.sh`.

### 11.3 `creds set` and `creds tailscale`

1. Port AWS key validation with STS before writing `~/.aws/credentials`.
2. Port Tailscale token validation, auth-key mint/check/delete, sign-in, and `.env` writes.
3. Preserve `creds set aws`, `creds set tailscale`, `creds tailscale status`, `signin`, `up`, `set`,
   and `authkey`.
4. Preserve the dispatch quirk: `creds tailscale status --json` is normalized to the token JSON, not
   a separate status schema.
5. Secret input must not echo and must not appear in events.
6. Preserve failure exit codes and "nothing was written" behavior.
7. Tests: `creds.sh`, `authkey.sh`, `creds-dom.sh`.

### 11.4 `check` and `check --fix`

1. Port preflight in this order: local tools, AWS identity, account plan, region, instance type,
   purchase model/quota, SSH key, settings prompts, Tailscale auth key preflight.
2. `check` is not side-effect-free. `settings_prompts 0` can prompt for and save
   `TAILSCALE_AUTH_KEY` and `EMAIL_ALERTS` to `.env`; with `TAILSCALE_API_KEY` it can mint, replace,
   and delete a Tailscale auth key. Preserve these writes and the "nothing was launched" failure
   text.
3. `--fix` installs tools and asks for credentials/settings, then rechecks.
4. Preserve the free-plan and quota failure explanations.
5. Tests: `deps.sh`, `laptop.sh`, `settings.sh`, `env-loader.sh`; add a case that proves `check` can
   write settings and that no EC2 resource is created.

### 11.5 `notify`

1. Validate `GAME_NTFY_URL` as a topic or full URL.
2. POST with title/tags; never print the topic.
3. Tests: `notify.sh`.

### 11.6 `quota request/appeal`

1. Port request state checks and the exact support-case text.
2. No resource creation; it is a Support API mutation.
3. Preserve the `ondemand`/`spot` argument.
4. Tests: `quota.sh`, `quota-dom.sh`.

### 11.7 `regions enable`

1. Port opt-in with the correct region name.
2. Preserve "already enabled" and AWS error messages.
3. Tests: `region-optin.sh`.

### 11.8 `watchdog check/install/remove`

1. Port the Lambda bundle build, role/policy, EventBridge rule, dry-run proof, and removal.
2. Keep the Lambda Python source as an embedded asset, including the post-report stopped-box expiry
   (`expire_stopped`), its warning, and its tag writes.
3. Make role deletion tri-state: only delete when no other region is confirmed to use it.
4. `install` is best effort during `init`, but `watchdog install` itself must fail loudly.
5. Preserve the shared expiry setting: `GAME_ARCHIVE_EXPIRY_DAYS` controls both archive expiry and
   the maximum age of a stopped on-demand box; `0` disables both. Keep the policy's CreateTags
   allowlist for `cg-stopped-since` and `cg-stopped-warned`.
6. The Lambda terminates only a stopped on-demand box (never spot), using AWS's stop timestamp or a
   first-seen tag, warns once in the last day, and acts hourly. The role must not gain permissions
   beyond the tagged host plus those two new tag keys.
7. Tests: `cloud-watchdog.sh` (stopped kept/warned/terminated, no timestamp, earlier-stop tag, spot
   skipped, `0`, dry run, hourly gate, IAM tag allowlist), `init-watchdog.sh`; add role-used-
   elsewhere unknown and in-use cases.

Phase 3 exit gate: a laptop can be prepared end to end; no EC2 instance is launched.



## 12. Phase 4: host and no-box library

### 12.1 `host add`

1. Parse `[name] --ssh <target>` strictly.
2. Reject duplicates by address and by machine identity.
3. Ensure cg's key, ask for a password only when needed, and never save it.
4. Read facts, detect OS/family/arch/GPU, and write `hosts.json`.
5. Refuse Windows setup while keeping the recorded machine.
6. Tests: `host.sh`, `hosts-dom.sh`.

### 12.2 `host setup`

1. Reuse the existing bootstrap modules via embedded assets.
2. Copy and launch the build detached; follow the log from `lib/build.sh` logic.
3. Handle Tailscale join, key expiry, Sunshine login, and Moonlight pairing.
4. Save the Sunshine login in `hosts.json`, not in the app.
5. Preserve all "not changed, but noted" warnings.
6. Tests: `host.sh`, `hosts-dom.sh`, `tailnet-expiry.sh`.

### 12.3 `host status`, `host open`, `host remove`

1. `status`: probe SSH, tailnet ping, Sunshine welcome, login, and pairing; preserve `--json`.
2. `open`: require setup, check Sunshine, claim the session lock, stream, release.
3. `remove`: remove cg's key, then forget the host; keep the machine otherwise untouched.
4. `status --on <name>` and `open --on <name>` delegate to these.
5. Tests: `host.sh`, `session.sh`.

### 12.4 `library` S3 model and read reuse

1. Reuse the Phase 2 `list`, `elsewhere`, `--bucket`, and `account status` paths; do not duplicate
   read commands or their JSON.
2. Keep the on-box `cg-library` script as the implementation for now. It is called over SSH, so
   `status`, `check`, `push`/`sync`, `pull`/`restore`, and `account push/pull` move to 13.9, after a
   box exists.
3. The on-box forms follow 13.9's argv and failure rules.
4. Tests: `library-*.sh`, `steam-library.sh`, `archive-unreadable.sh`, `s3-region.sh`.

### 12.5 `library account`

1. Reuse the Phase 2 `status` read; do not create a second S3 path.
2. `forget`/`delete`/`rm` delete the archived login with confirmation.
3. `push/pull` run the remote `cg-library account` path; implement them in 13.9.
4. Tests: `steam-account.sh`, `login-dom.sh`, `steam-login*.sh`.

### 12.6 `library forget/reset/keep-for/move/clean`

1. `forget`, `move`, and `clean` are S3 mutations. Use the SDK for delete/list; preserve the typed
   confirmations. Multipart cleanup belongs to bucket deletion in 14.1, not here.
2. `reset`/`keep` writes an SSM parameter under `/cloud-gaming/<host>/kept/<bucket>/<appid>`; it is
   not an S3 operation.
3. `keep-for` writes `GAME_ARCHIVE_EXPIRY_DAYS` and redeploys the watchdog with `cw_install`; it
   depends on Phase 3's watchdog install and is not an S3 operation. The same value now sets the
   maximum stopped age for an on-demand box, so the redeploy must refresh both Lambda environment
   and policy, not just the CLI setting.
4. Preserve "permanent" warnings and the index update after a move.
5. Preserve `reset`/`keep` alias and `--from <bucket>`.
6. Tests: `library-perapp.sh`, `library-orphans.sh`, `library-elsewhere.sh`, `cloud-watchdog.sh`.

Phase 4 exit gate: own-machine setup works, and every no-box library operation works (S3, SSM, and
`keep-for`'s watchdog redeploy) without touching the AWS box lifecycle. The on-box `cg-library`
forms are gated in Phase 5.



## 13. Phase 5: box lifecycle

Each real-AWS test in this phase is proposed with a cost estimate and approved by the owner before it
runs (section 5).

### 13.1 `init`

This is the largest command. Port it in sub-steps, each mergeable and testable.

1. **Init shell**: `watchdog_ensure` (best effort), `choose_games`, then setup.
2. **Preflight**: reuse the Phase 3 `check`/`check --fix` logic, including free-plan/quota/spot
   selection.
3. **AWS bootstrap resources**: S3 bucket, instance role, security group, key pair, saved image
   lookup, Ubuntu AMI lookup.
4. **User-data**: render embedded `lib/bootstrap.d` modules, inject the host bundle, gzip, enforce
   the 16 KB limit. Use literal replacement, never `sed`-style replacement of URLs.
5. **Launch**: existing instance reuse, on-demand vs one-time spot, shutdown behavior, tags, EIP
   absence, no AZ pinning.
6. **Wait and record**: instance ID, new/reused tailnet node, key expiry, `known_hosts` cleanup,
   `.env` writes.
7. **Build follow**: stream the build log, run the post-build watchdog refresh, create Sunshine
   login, pair Moonlight, wait for Steam, report the summary.
8. **Failure paths**: launch error, build abort, no Sunshine, no new tailnet node, a laptop that
   dies mid-build. Match the current messages and exit codes.
9. **Tests**: fake EC2/SSM/S3/Tailscale/SSH; golden user-data; reuse path; spot/on-demand paths;
   build failure; no second instance on rerun.

Do not enable `cg-go init` by default until this phase's real-AWS test passes.

### 13.2 `open`

1. Claim the session lock and refuse a second stream.
2. Read instance state; handle deleted, unreadable, and spot-request-disabled cases.
3. Start a stopped on-demand box; wait for running.
4. Wait for Tailscale and Sunshine; report direct vs relayed.
5. Print disk use, stream, then print the post-session billing message.
6. `--on` delegates to `host open`; keep that branch.
7. Tests: `session.sh`, `spot-restart.sh`, `open-unfinished.sh`, `moonlight-gpu.sh`.

### 13.3 `stop`

1. Accept only `--force`.
2. Mirror the library first; a failed mirror aborts unless forced.
3. Stop on-demand; spot offers destroy; "already stopped" is success.
4. A stopped on-demand box is not permanent: the cloud watchdog deletes it after
   `GAME_ARCHIVE_EXPIRY_DAYS` and keeps its games in S3 for that many days again. Do not assume
   `stop` preserves the disk forever, and make sure the deployed watchdog is current after
   `init`/`keep-for`.
5. Tests: `shutdown-push.sh`, `spot-restart.sh`; add a stopped-box/watchdog lifecycle case.

### 13.4 `clean`

1. Require a running box.
2. Confirm, run the named cleanup actions, remount `/scratch`.
3. Never touch `/scratch/steam`.
4. Add a fake-SSH test for the exact cleanup commands.

### 13.5 `snapshot`

1. Default and `create`: require an instance, warn if running, create image with tags, wait for
   available.
2. `--list`/`list`: already ported in Phase 2; reuse the same result type.
3. `--delete`/`delete`: deregister image, then delete every backing snapshot; report failures.
4. Tests: fake EC2 image/snapshot cases.

### 13.6 `games --volume --delete`

1. `games --volume`/`games volume` reports the legacy volume; already ported in Phase 2.
2. `games --volume --delete`/`games volume --delete` refuses unless the volume is `available`.
3. Require typed `DELETE`.
4. Delete the legacy volume; report that charges stop.
5. The current human text points at `cg games --delete` in the volume report (`cg:1743`) and in
   destroy cleanup (`cg:1537`), which is not a valid command. The `games_volume` usage line
   (`cg:1752`) also omits `--volume`. Print `cg games --volume --delete` or `cg games volume
   --delete` instead; this is a parity exception fixing a broken instruction.
6. Tests: `games-status.sh`.

### 13.7 `destroy` (normal, `--force`, `--no-push`)

1. End any local stream first.
2. Parse options strictly; reject unknown flags.
3. Normal: if running, push first; abort on push failure. If not running, report archive state.
4. `--no-push`: lock the archive read-only, destroy, then restore write access.
5. `--force`: proceed without a mirror, with the current warning.
6. Port `lib/setup destroy`: terminate instances, cancel spot requests, deregister cg images, delete
   their snapshots, delete cg volumes, keep free resources, clear box-only `.env` keys.
7. Collect cleanup failures instead of suppressing them.
8. Tests: `destroy-scope.sh`, `destroy-budget.sh`, `stranded-spot.sh`, `archive-unreadable.sh`.

### 13.8 `pair`

1. Check node, Moonlight, and Sunshine credentials.
2. If already paired, succeed without changes.
3. Port the Sunshine API pairing flow from `lib/pair.sh`.
4. Tests: `pair.sh`, `sunshine-login.sh`.

### 13.9 On-box `library`

1. Keep the on-box `cg-library` script as the implementation for now; call it over SSH.
2. Build the remote argv as a slice and hand it to SSH; do not interpolate a local shell string.
   OpenSSH still joins the remote command, as 10.6 notes.
3. Preserve `status`, `check`, `push`/`sync`, `pull`/`restore`, and `account push/pull`.
4. Preserve push failure as a hard failure for `stop`/`destroy`, including the shutdown-mirror
   explanation and the `cg library list` recovery hint.
5. Implement this before 13.3's and 13.7's push paths, or keep them gated: a running box's normal
   `stop` and `destroy` call `library_push` before teardown.
6. Tests: `library-*.sh`, `steam-library.sh`, `shutdown-push.sh`; add a fake-SSH parser test and
   gate real transfers on a disposable box.

Phase 5 exit gate: one real build/open/pair/stop/destroy/rebuild cycle and one library restore
succeed with `cg-go`.



## 14. Phase 6: account destruction

### 14.1 `destroy --all`

1. Build the inventory first; show only what exists.
2. Require typed `DESTROY-ALL` unless `--force`.
3. Reject `--no-push` with `--all`. The current parser accepts the combination and silently ignores
   `--no-push` while deleting the archive; that is exactly the kind of destructive surprise the port
   must not preserve. Record it as a safety parity exception.
4. Delete the box, archive bucket, multipart uploads, IAM role/profile (only when no other region's
   watchdog uses it), watchdog, budget, old volume, images/snapshots, and cg's disks in other
   regions. Other-region buckets, machines, SSM parameters, and a still-shared role belong to 14.3.
5. Use `cg_bucket` as a fallback when `GAME_S3_BUCKET` is absent.
6. Continue after one failure, collect all failures, and return non-zero.
7. Remove `GAME_S3_BUCKET` from `.env` only after deletion succeeds.
8. Tests: `destroy-all.sh`, `archive-unreadable.sh`.

### 14.2 `aws forget`

1. Refuse if a machine or any saved games exist, unless `--anyway`.
2. Distinguish "AWS could not be asked" (exit 3) from "nothing there".
3. Remove only `GAME_REGION` from `.env`; keep credentials and AWS resources.
4. Tests: `aws-forget.sh`.

### 14.3 `aws disconnect`

1. Inventory everything, with per-region errors.
2. Require typed `DELETE`.
3. Delete the current region via `destroy --all --force`; continue after failures.
4. Remove watchdogs in other regions; remove the shared role only if unused.
5. Terminate machines in other regions; cancel spot requests first.
6. Delete other-region buckets after aborting multipart uploads.
7. Delete SSM parameters in batches of ten.
8. Re-inventory; if anything remains, keep AWS configured and fail.
9. Clear `GAME_REGION` only after the final inventory is clean.
10. Tests: `aws-disconnect.sh`, `destroy-all.sh`; add failed-region and multipart cases.

Phase 6 exit gate: a disposable AWS account is fully cleaned by `cg-go`, and the final inventory is
empty.



## 15. Phase 7: Electron integration and cutover

### 15.1 App boundary

1. Keep the renderer unchanged by default. It must still receive events on stderr and send answers
   on stdin.
2. Keep `app/main/runner.js` pointed at the stable `cg` name (Go after cutover); do not add a
   Bash/Go switch to the app.
3. Fix CLI-01: quote/escape arguments, convert Windows paths with `wslpath`, and do not interpolate
   the repo path into a shell string. With a native Windows binary this path disappears; until then
   it protects the WSL route.
4. Fix CLI-03: use a WSL-side supervisor or WSL-native process-group termination for Stop. A native
   binary uses `internal/platform`'s process-tree stop instead.
5. Move scheduling facts and the environment allowlist into `cg --contract` where the main process
   can enforce them (CLI-06). For renderer-owned display/read tables (CLI-04), either keep the
   renderer frozen and add a drift test, or lift the renderer freeze for a data-only change. Record
   the choice under open decision 7; do not silently rewrite the renderer.
6. Keep the app's `cg` invocation name stable. The app should not need to know whether Bash or Go is
   behind it.
7. Tests: `app.sh`, `app-packaged.sh`, `app-gpu.sh`, `json-events.sh`, `ask-events.sh`,
   `interrupt.sh`, `tail-exit.sh`, `startup-gate.sh`.

### 15.2 Completing the port (no legacy fallback)

1. Build the Go binary as `cg-go` beside the Bash `cg` while commands are ported; the Bash CLI is the
   oracle and stays unchanged.
2. Point a development wrapper at `cg-go` only when the read-only slice passes golden tests.
3. Move screens in this order: status/cost/watcher, machines/sweep, config, library reads, library
   writes, host, lifecycle, destruction.
4. When every command is ported and the Phase 5 and Phase 6 real-AWS gates have passed, in this
   branch: rename the binary to `cg`, delete the Bash `cg`, `lib/*.sh` and `lib/*.py` that were
   ported, and the shell tests that were replaced by Go tests. There is no `cg-legacy`.
5. Update docs and `--contract` in the same change.
6. The app package then ships only the Go `cg` and the embedded box-side assets (`lib/bootstrap.d`,
   `host`, `lambda`). Update `tests/app.sh` and the package config accordingly.
7. Merging to `main` is a separate decision for the owner. Until then `main` and its Bash CLI are
   untouched and are the rollback.

### 15.3 Track W: native Windows and macOS

Starts once Phase 3 (the per-OS tooling) and the Phase 7 runner fixes exist.

1. Fill in the Windows `internal/platform` implementation: config/cache/runtime paths, elevation,
   process-tree stop, package-manager and install locations for Moonlight, Tailscale and OpenSSH.
2. Build `cg` for darwin (amd64, arm64) and windows (amd64) as static binaries.
3. Run the black-box suite on a real macOS and a real Windows machine, or a hosted runner for each.
   Until that passes for an OS, the docs say it is untested.
4. Package the Electron app for each OS with the matching `cg` binary, and drop WSL from the Windows
   route.
5. Document what is supported: the machine running `cg` and Moonlight may be Linux, macOS or
   Windows; the AWS box and an own server stay Linux.



## 16. Helper and asset disposition

| Path | Disposition | Notes |
| --- | --- | --- |
| `cg` | Port | Dispatcher, global flags, contract, aliases |
| `lib/common.sh` | Port core; keep only box-side helpers if needed | Output/events, logging, locks, AWS helpers; the pilot's shared-helper list decides which stay shell (section 7) |
| `lib/env-file.sh` | Port | Env resolution and atomic writes |
| `lib/config.sh` | Port | Registry, validation, settings |
| `lib/setup` | Port | Status, cost, check, clean, destroy orchestration |
| `lib/game` | Port | Open, stop, status, clean, destroy behavior |
| `lib/host.sh` | Port | Hosts.json, SSH, setup, stream |
| `lib/machines.sh` | Port | Instance types and prices |
| `lib/sweep.sh` | Port | Region scoring, opt-in, enable |
| `lib/quota.sh` | Port | Quota status, request, appeal |
| `lib/library-aws.sh` | Port | Bucket, role, index, S3 policy |
| `lib/cloud-watchdog.sh` | Port | Lambda deploy, role, proof, status, remove |
| `lib/laptop.sh` | Port | Deps, creds, Tailscale keys |
| `lib/pair.sh` | Port | Moonlight pairing |
| `lib/session.sh` | Port | Session pid lock, stream lifecycle, teardown |
| `lib/sunshine-login.sh` | Port | Shared Sunshine login across AWS and own hosts |
| `lib/provision.sh` | Port | Instance launch and user-data |
| `lib/aws-setup.sh` | Port | Shutdown behavior and budget |
| `lib/build.sh` | Port | Build log follow and post-build steps |
| `lib/choose-games.sh`, `lib/choose-games.py` | Port or wrap | Pre-build game selection; do not silently drop |
| `lib/render.sh`, `lib/summary.sh`, `lib/settings.sh` | Port | Report and settings rendering |
| `lib/rates.sh`, `lib/prices.py` | Port | Prices, cache, INR |
| `lib/launch-error.sh` | Port | AWS launch error classification |
| `lib/ssh-key.sh` | Port | Key ensure/repair |
| `lib/tailnet-expiry.sh`, `lib/tailnet-prune.sh` | Port | Node cleanup and expiry |
| `lib/s3-region.sh` | Port | Bucket region lookup |
| `lib/cost-daily.py`, `lib/cost-report.py` | Port | Cost parsing and reports (the pilot) |
| `lib/bootstrap.d/*` | Embed unchanged | On-box bootstrap modules |
| `host/*` | Embed unchanged | On-box watchdog and mirror scripts |
| `lambda/cloud_watchdog.py` | Embed unchanged | Python Lambda stays Python |
| `tests/*.sh` | Keep as oracle | Add Go contract tests; do not line-for-line port |
| `app/main/*` | Keep, patch runner | CLI-01/03, contract use, packaging |
| `app/renderer/*` | Freeze by default | No renderer rewrite; CLI-04 data-only change only if open decision 7 is lifted |
| `lib/__pycache__/*` | Ignore | Generated, not an asset |



## 17. Test matrix

| Area | Go unit tests | Black-box tests | Real AWS |
| --- | --- | --- | --- |
| Contract/output | schema + golden | flags in both positions, NDJSON, interrupts | no |
| Config | parser/validator/atomic write | isolated HOME/XDG, secret masking | no |
| Locks | session/archive state machine | second open, destroy ends session | no |
| AWS reads | fake SDK | fake endpoint + golden JSON | no |
| AWS mutations | fake SDK with failure injection | typed confirmations, partial failure | disposable account, approved with a cost estimate |
| SSH/remote | fake runner | fake `ssh` on PATH | one box |
| Tailscale | fake runner/HTTP | direct/DERP/no-reply | one node |
| Library | fake S3 | missing/denied/expired/orphan/multipart | one bucket, a small test library |
| Lifecycle | fake EC2/SSM | golden user-data + failure paths | one full cycle |
| Destruction | fake multi-region | partial failure + final inventory | disposable account |
| Per-OS seams | platform unit tests | black-box on each supported OS | no |
| App | main-process runner tests; no renderer change by default | Electron smoke + packaged app | no |

Run `go test ./...`, `go vet ./...`, `go test -race ./...` for packages with goroutines, and the
built binary's black-box suite. Keep the old shell suite in CI until the phase gate that retires it.

The parity harness should run the old suite against `cg-go` by placing the Go binary at `cg` in a
temporary checkout. Tests that inspect source files or call `lib/` directly cannot run this way.
Several do: the "wired in" checks in `tests/cost-daily.sh` grep `cg` and `lib/setup` for strings,
and others read `lib/` files for what they contain. Each of those needs a Go equivalent that asserts
the behavior (or the registry entry) instead of the source text. Phase 0 counts them: list every
test that reads a source file, and mark each "runs against the binary", "needs a Go equivalent", or
"retires with the Bash CLI". Do not change every test just to prove parity.



## 18. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| `init` becomes a second product | Sub-step it; keep all bootstrap/host assets embedded and unchanged |
| Human output drifts | Plain text is the source; styling is a renderer; content-level golden tests; exact machine contracts |
| JSON contract drifts | Checked-in schemas and app contract tests |
| Aliases or default subcommands are lost | Registry-driven dispatch and explicit alias tests |
| AWS SDK differs from CLI output | Treat the current CLI output as the contract, not raw SDK JSON |
| Cross-region cleanup still fails open | Tri-state results, per-region error markers, collected failures |
| Secrets leak in errors/events | Typed secret values, redaction tests, no secret in argv |
| WSL path/process bugs persist | Fix runner quoting and stop semantics before default cutover; native Windows removes the route |
| A supported OS is untested | Do not claim it; each OS needs a real machine or runner before it is listed (rule 9) |
| Per-OS logic leaks into commands | Everything OS-specific lives behind `internal/platform`; commands never check `runtime.GOOS` |
| Box-side scripts depend on shell helpers that get ported away | The shared-helper list in the pilot decides what stays shell |
| One binary grows into a monolith | One binary, many focused packages; no command over ~700 lines |
| Host or library behavior is orphaned | Section 16 disposition table and per-module phase gate |
| Source-grepping tests silently stop testing anything | Phase 0 classifies them; each gets a Go equivalent or retires with the Bash CLI |
| Test oracle is too slow or flaky | Run old suite in parallel; keep fixtures deterministic; pin rates/prices |
| Real-AWS gates cost money unexpectedly | Each gate is estimated and approved by the owner first; cheapest honest test (section 5) |
| No human reviews every diff | Mechanical safety net: schemas, goldens, compiler, vet, race tests (rule 16) |
| Rust temptation mid-port | Finish Go parity; keep Rust for a later host-agent decision |
| No legacy fallback inside the branch | The real-AWS gates and contract tests may not be skipped; `main` keeps the Bash CLI until the owner merges |
| Lambda rewrite distracts | Keep Python Lambda; port only the CLI orchestration that deploys it |



## 19. Source map for review

Use these as starting points; line numbers will move as the plan is implemented.

| Concern | Source |
| --- | --- |
| Global flags, contract, version | `cg:12-73` |
| Dispatch and aliases | `cg:2394-2524` |
| Help text | `cg:2305` |
| Destroy and `--all` | `cg:1339-1554`, `lib/setup:901` |
| AWS inventory and disconnect | `cg:2002-2253` |
| Library | `cg:1271-1337`, `lib/library-aws.sh`, `host/cg-library` |
| Games, snapshots, logs, ping | `cg:1616-1876` |
| Watchdog | `lib/cloud-watchdog.sh` |
| Status/cost/check | `lib/setup` |
| Host, Sunshine login | `lib/host.sh`, `lib/sunshine-login.sh` |
| Laptop/deps/creds | `lib/laptop.sh` |
| Session lock | `lib/session.sh` |
| App runner | `app/main/runner.js`, `app/main/index.js` |
| App command tables | `app/renderer/app.js` |
| Existing tests | `tests/*.sh` |



## 20. Open decisions

All fourteen were approved by the owner on 2026-10-25 as recommended. This migration lives on the
`go-migration-plan` branch and is not merged to `main`.

| # | Decision | Recommendation | Why | Status |
| --- | --- | --- | --- | --- |
| 1 | First port is CLI only, or CLI plus Lambda/watchdog runtime? | CLI only | Keeps the risky contract in one language; Lambda already works | Approved 2026-10-25 |
| 2 | "One file" means source or binary? | One binary | A 10k-line source file would make AI maintenance worse | Approved 2026-10-25 |
| 3 | Embed shell assets or ship beside the binary? | Embed, with `go.mod` and the embedding package at the repository root | One artifact; avoids missing `host/` or `lib/` at runtime; `go:embed` cannot reach parent directories | Approved 2026-10-25 |
| 4 | Preserve human output byte-for-byte or by content? | By content: exact JSON, NDJSON, exit codes and prompt IDs; human text on fields and wording, not spacing | Byte-exact text is expensive and brittle; the app depends on the machine contracts | Approved 2026-10-25 |
| 5 | Fix audit bugs during the port or after parity? | Fix the remaining fail-closed cost paths and COST-07 only-sub-cent branch in the port; preserve the COST-06/08 fixes already landed; everything else after parity | They are exactly the bugs the port must not preserve, and the new commits only partly closed them | Approved 2026-10-25 |
| 6 | Cut over `destroy --all` immediately or one release later? | Superseded by the no-fallback decision: there is no release overlap, so `destroy --all` is ported last and gated on a disposable-account run | Normal destroy must be proven first | Approved 2026-10-25; revised 2026-10-25 |
| 7 | Freeze the Electron renderer? | Yes, except CLI-01/03 in the main process | UI rewrite is a separate project | Approved 2026-10-25 |
| 8 | Accept global flags after the subcommand for all flags? | Yes, as a documented parity exception | Current partial parsing already causes argument leaks | Approved 2026-10-25 |
| 9 | Is Rust still wanted for the host agent? | Defer | One language until parity; revisit with measured data | Approved 2026-10-25 |
| 10 | Are undocumented forms such as `aws disconnect --plan` public? | Treat `--plan` as internal but tested | `aws inventory` is the public read path | Approved 2026-10-25 |
| 11 | Which operating systems? | Linux and macOS first, then native Windows; WSL stays until then; the AWS box and own servers stay Linux | The goal is other people on every OS; both first targets are Unix; native Windows needs a real machine to test | Approved 2026-10-25 |
| 12 | What should `--json` do on mutating `deps install` / `creds set` forms? | Reject `--json` on mutating forms; JSON only for reads | The current dispatch prints status JSON and silently skips the mutation | Approved 2026-10-25 |
| 13 | Start with the pilot slice before the full Phase 0? | Yes: module, minimal registry, Phase 1 basics, and `cost` first; review before continuing | Proves layout, embed, harness and app boundary cheaply on a read-only command | Approved 2026-10-25 |
| 14 | Who approves a real-AWS gate? | The owner, each time, with an estimate first | The port is free to write; the real-AWS cycles bill | Approved 2026-10-25 |



## 21. Next step

1. Review this revision, in particular the pilot slice (8.0), the cross-OS rule (rule 9), and the
   content-level human-text rule (rule 8), and resolve the decisions in section 20.
2. On approval, start the pilot slice only. Stop for review when it exits.
3. Do not write further command implementations until the pilot is reviewed and Phase 0's exit
   checklist is signed off.
