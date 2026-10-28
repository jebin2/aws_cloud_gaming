# Cloud Gaming

Stream games to your laptop from a GPU machine rented on AWS, or from a Linux server of your own.
A desktop app for Linux, built on [Sunshine](https://github.com/LizardByte/Sunshine),
[Moonlight](https://github.com/moonlight-stream) and [Tailscale](https://tailscale.com).

> **Beta.** An AWS machine bills by the hour while it runs. No warranty - see [LICENSE](LICENSE)
> and [docs/cost.md](docs/cost.md).

## Install

Download from [Releases](https://github.com/jebin2/aws_cloud_gaming/releases):

| File | For | Install |
|---|---|---|
| `.pacman` | Arch, CachyOS, Omarchy | `sudo pacman -U <file>` |
| `.deb` | Debian, Ubuntu, Mint | `sudo dpkg -i <file>` |
| `.tar.gz` | Any Linux | Extract and run `cg` |
| `.AppImage` | Any Linux with FUSE 2 | Make executable and run |

## What you need

- A [Tailscale](https://tailscale.com) account
- **Your own server:** a Linux machine you can reach over SSH
- **AWS:** an account on a paid plan

The app installs anything missing on this computer when you add a machine.

## Use

1. Open the app and choose **Add a machine** - AWS, or your own server.
2. Press **Play**. Moonlight opens with the machine's desktop.
3. Close Moonlight to end the session.

An AWS machine keeps running after a session until auto-stop ends it or you press **Delete**.
Your games are saved to S3 when it is deleted and restored on the next build. Saved games are a
recurring monthly cost, by size, for as long as they are kept - 14 days after the last machine by
default, adjustable on the Games page.

## From source

    git clone https://github.com/jebin2/aws_cloud_gaming.git
    cd aws_cloud_gaming/app && npm install && npm start

The app runs `cg`, a Go program built from this repository (`npm start` builds it first; Go is needed). To use it directly: `go build -o cg ./cmd/cg`, then `./cg help` - or see [docs/commands.md](docs/commands.md).

## Documentation

[Cost](docs/cost.md) · [AWS setup](docs/aws-account-setup.md) · [Streaming](docs/streaming.md) ·
[Troubleshooting](docs/troubleshooting.md) · [Architecture](docs/architecture.md) ·
[All commands](docs/commands.md)
