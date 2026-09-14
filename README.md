# aws_cloud_gaming

Your own Linux gaming desktop on an AWS GPU instance, streamed to any device over Tailscale with
Moonlight. Build it when you want to play, destroy it when you stop - your games and your Steam
login are saved to S3 and come back on the next build.

> **⚠️ This spends real money on your AWS account.** Measured in `ap-south-2`: a `g6.xlarge` spot
> instance is about **INR 20/hour** while it exists (on-demand about INR 85/hour); streaming past
> AWS's free 100 GB a month adds about **INR 86/hour**; and the game archive is about
> **INR 350/month** for a 160 GB game. `cg init` sets up a budget that emails you and four
> independent guards that stop a forgotten box, but they are software - check `cg cost`.
> No warranty, see [LICENSE](LICENSE). Details: [docs/cost.md](docs/cost.md).

## What you need

- **An AWS account on a paid plan, with an approved GPU quota.** The Free Plan cannot launch GPU
  instances at all, and quota approval can take days - start this first.
  [Step-by-step setup](docs/aws-account-setup.md)
- **[Tailscale](https://tailscale.com)**, installed and logged in, plus a pre-auth key
- **[Moonlight](https://moonlight-stream.org)** on the device you play from
- `aws` CLI v2, `python3`, `curl` and OpenSSH

## Get started

    git clone git@github.com:jebin2/aws_cloud_gaming.git
    cd aws_cloud_gaming
    cp .env.example .env     # Tailscale key, alert email, region
    ./cg check               # every prerequisite - creates nothing
    ./cg init                # build the box and pair Moonlight (10-20 min)
    ./cg open                # play

`cg init` asks which archived games to restore, then builds the box while restoring them. When you
quit Moonlight, `cg open` offers to destroy the box: that saves your games and Steam login to S3
and stops the bill. The next `cg init` brings everything back.

## Everyday commands

| Command | What it does |
|---|---|
| `cg init` | Build a box and restore the games you pick |
| `cg open` | Stream; offers to destroy the box when you quit |
| `cg destroy` | Save games and Steam login to S3, then delete the box |
| `cg status` | What exists, and whether every guard is armed |
| `cg cost` | What you have spent this month |
| `cg games` | What Steam has installed, downloading or running |
| `cg library list` | Archived games and what storing them costs |

Every command, and what is safe to run twice: [docs/commands.md](docs/commands.md).

## Documentation

| | |
|---|---|
| [AWS account setup](docs/aws-account-setup.md) | Step by step: paid plan, GPU quotas with example requests, how to verify - followable by a person or an AI |
| [Getting started](docs/getting-started.md) | Credentials, configuration, the first build and pairing |
| [Commands](docs/commands.md) | Every command, the terminal output, running things twice |
| [Cost](docs/cost.md) | What every charge is, measured, and why spot is the default |
| [Cost guards](docs/cost-guards.md) | The four layers that stop a forgotten box, and the off-site watchdog's IAM policy |
| [Destroy](docs/destroy.md) | What `cg destroy` and `cg destroy --all` remove, and what they keep |
| [Game library](docs/game-library.md) | How games and the Steam login persist in S3 |
| [Streaming](docs/streaming.md) | Moonlight and Steam settings, GPU performance, anti-cheat |
| [Architecture](docs/architecture.md) | How Tailscale, Sunshine, Moonlight and the storage fit together |
| [Testing](docs/testing.md) | Repository layout and the test suites |
| [Troubleshooting](docs/troubleshooting.md) | Every failure hit while building this, and why each fix works |

Tested on Ubuntu 24.04, `g6.xlarge` in `ap-south-2`, streamed to an Arch-based Linux client.
