# Getting started

Everything you need before the first `cg init`, and what that first build does. The short version
is in the [README](../README.md).

## What you need first

Two of these take real time to obtain, so start them before anything else. The exact procedure -
console pages, what to request, example justifications and how to verify each one - is in
[aws-account-setup.md](aws-account-setup.md).

- **An AWS account on a paid plan.** The new-style Free Plan can only launch free-tier-eligible
  instance types - **no GPU instances at all**, whatever your quota says, and the error message
  does not explain this. Check with `aws freetier get-account-plan-state`.
- **An approved GPU quota** in your chosen region: `Running On-Demand G and VT instances`
  (`L-DB2E81BA`). Mine took three days. **File it from the console with a real use case** - a
  request submitted through the CLI carries no justification and is usually refused. Spot needs
  a *separate* quota (`L-3819A6DF`), which is **0 by default**; approval of one says nothing
  about the other, and spot is refused more often. Mine was denied first time and granted the
  next day on a re-file, so a denial is worth appealing. `cg init` prefers spot and falls back
  to on-demand when the quota cannot cover the instance.

  Note that "Resolved" on a support case means the case was **closed**, not that you got the
  quota. Compare the applied value against the default instead:

      aws service-quotas get-service-quota --region <r> --service-code ec2 --quota-code <code>
      aws service-quotas get-aws-default-service-quota --region <r> --service-code ec2 --quota-code <code>

And locally:

- **Tailscale**, installed and up (`sudo tailscale up`), plus a
  [pre-auth key](https://login.tailscale.com/admin/settings/keys)
- optionally a **Tailscale API access token** (a different credential, from the same page) as
  `TAILSCALE_API_KEY`. With it, `cg init` prunes offline nodes before each launch (and
  `cg destroy --all` deletes them), so rebuilds keep the clean hostname instead of climbing
  `gamevps-1`, `-2`, `-3` - and turns off key expiry on the new box, which would otherwise drop
  off the tailnet after ~180 days. Only nodes named exactly `<GAME_TS_HOST>` or
  `<GAME_TS_HOST>-<number>` are ever touched, and only a connected one gets its expiry turned off.
  These tokens expire after 90 days; when one does, `cg init` says so plainly, and key expiry
  shows as a manual step again
- **Moonlight** (`moonlight-qt`) - only needed to stream, so `setup` warns rather than stops
- `aws` CLI v2 configured, `python3`, `curl`, and OpenSSH (`ssh`/`scp`)

### AWS credentials

If `aws configure` has already been run, nothing to do. Otherwise the console hands you an
access key as a **`.csv` download** rather than something you can paste, so `setup` accepts it
directly:

    AWS_KEY_CSV=~/Downloads/CLI_accessKeys.csv cg init

With no path given it looks for one in your home directory and offers to import it. It picks
the first file that actually *parses* rather than the first matching name - the console also
issues a `*_credentials.csv` containing a sign-in **password** and no access key, and choosing
by filename would grab that instead.

**Delete the .csv once imported.** It is a plaintext secret, and anyone who reads it has your
account. `*.csv` is gitignored here so a stray copy in the repo cannot be committed, but that
does not help it sitting in `~/Downloads`.

## Configuration

Everything lives in `.env` - see [.env.example](../.env.example), which documents every variable.
`cg init` prompts for the Tailscale key and alert email if they are absent, so the minimum is a
working AWS profile and a Tailscale account.

## The first build

`cg init` checks every prerequisite before it spends a cent and tells you exactly what is
missing. It provisions the instance, arms the cost guards, installs the watchdog, and hands you
a pairing URL. After that, `cg open` is the whole workflow.

Use `cg check` to run every check and stop before anything is created.

The build takes about 10-20 minutes - most of it the NVIDIA driver, with the game restore
running alongside it - and streams its progress, so a slow step looks slow rather than
hung. Each step asserts its *effect* rather than merely running, because nearly every failure
in this project has been something reporting success while broken:

    ==> building the box - live progress below
        installing nvidia driver (the slowest step)
          ok  nvidia driver packages installed
        disabling nvidia DRM KMS (NvFBC cannot capture with it on)
          ok  nvidia DRM KMS disabled
        installing steam
          ok  steam bootstrap shipped
          ok  steamdeps cannot block a headless boot
        setting up scratch disk
          ok  /scratch mounted on the instance store
        (host rebooting - reconnecting)
        build complete after 17m

A failed `verify` stops the build. That is deliberate: a box that provisions cleanly and then
cannot stream is a worse outcome than one that refuses to finish. The exceptions are the stages
that must never cost you the box - tailscale and the game library report a failure and carry on,
because an unreachable GPU instance is worse than a missing library.

Anything that looks like an error is surfaced with a `!` prefix; the thousands of shell-trace
lines behind it are not. The full log lives at `/var/log/cloud-gaming-bootstrap.log` on the box.

## Pairing and the web UI

Pairing is automatic and needs no browser: `cg init` creates the Sunshine account and pairs
Moonlight itself, then saves the credentials to `.env`. Pairing is certificate-based, so it
survives stop/start and re-running `cg init`.

The web UI at `https://<tailscale-ip>:47990` is there if you want it. Its self-signed
certificate warning is expected - the traffic is already encrypted by WireGuard before TLS
applies.

Run `cg open` from a real terminal: the prompt at the end of a session needs one.
