#!/usr/bin/env bash
# Runs once, as root, and turns a machine into a streamable desktop - the one
# build for every machine cg sets up (lib/render.sh assembles it):
#   aws   a bare Ubuntu GPU instance, as EC2 user-data on first boot
#   host  a machine of your own with its OS installed, copied over ssh and run
#         with sudo (lib/host.sh). Every step there only adds what is missing,
#         and the AWS box's own - /scratch, the S3 library, the idle shutdown,
#         the headless X, the reboot - are left out: see aws_box below.
# Its placeholders (double underscores either side) are filled in before it
# leaves the laptop.
set -euxo pipefail

exec > >(tee /var/log/cloud-gaming-bootstrap.log) 2>&1

# Progress markers. `set -x` traces every command, which is far too noisy to
# watch remotely, so these give cg init a clean line to stream instead.
progress() { set +x; echo ">>> $*"; set -x; }

# Assert that a step achieved its effect, not merely that it ran. Nearly every
# failure in this build has been something reporting success while broken - a
# config file written but never loaded, a unit "active" but stuck, a symlink
# made into a directory that did not exist yet. `verify` is where a step states
# what "worked" means, in terms of the running system.
verify() {  # verify <description> <command...>
  set +x
  if "${@:2}" >/dev/null 2>&1; then
    echo ">>> ok: $1"
    set -x
  else
    echo ">>> FAILED: $1"
    set -x
    return 1
  fi
}

USER_NAME="__CG_USER__"
TS_AUTHKEY="__TS_AUTHKEY__"
TS_HOST="__TS_HOST__"
CG_TARGET="__CG_TARGET__"     # aws | host
FAMILY="__CG_FAMILY__"        # ubuntu | debian | arch | fedora
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6); USER_HOME=${USER_HOME:-/home/$USER_NAME}
USER_UID=$(id -u "$USER_NAME" 2>/dev/null || echo 1000)

# The AWS box's own steps, never a machine of yours.
aws_box() { [ "$CG_TARGET" = aws ]; }
# One way to install a package, whatever the distribution.
pkg() {
  case $FAMILY in
    ubuntu|debian) apt-get install -y "$@" ;;
    arch)          pacman -S --noconfirm --needed "$@" ;;
    fedora)        dnf install -y "$@" ;;
    *)             echo ">>> FAILED: no package manager known for '$FAMILY'"; return 1 ;;
  esac
}
# What a machine of yours already has.
has_display_manager() { systemctl is-enabled display-manager >/dev/null 2>&1; }

# How the build ended, for a machine with no cloud-init to ask: cg reads it to
# tell a build that stopped from one still running (lib/common.sh).
# On a machine of yours this script came over ssh and may carry the tailnet auth
# key: gone from the disk as soon as it starts (bash keeps it open to read).
if [ "$CG_TARGET" = host ]; then rm -f "$0"; fi
# Run again on a machine of yours, the last run's ready marker would read as this
# one finished before it began.
rm -f /var/lib/cloud-gaming-bootstrap.rc /var/lib/cloud-gaming-ready
trap 'echo $? > /var/lib/cloud-gaming-bootstrap.rc' EXIT

export DEBIAN_FRONTEND=noninteractive
case $FAMILY in
  ubuntu|debian) apt-get update ;;
  arch)          pacman -Sy --noconfirm ;;
esac
