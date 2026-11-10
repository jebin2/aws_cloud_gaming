#!/usr/bin/env bash
# Runs once, as root, and turns a machine into a streamable desktop - the one
# build for every machine ayis sets up (lib/render.sh assembles it):
#   aws   a bare Ubuntu GPU instance, as EC2 user-data on first boot
#   host  a machine of your own with its OS installed, copied over ssh and run
#         with sudo (lib/host.sh). Every step there only adds what is missing,
#         and the AWS box's own - /scratch, the S3 library, the idle shutdown,
#         the headless X, the reboot - are left out: see aws_box below.
# Its placeholders (double underscores either side) are filled in before it
# leaves the laptop.
set -euxo pipefail

exec > >(tee /var/log/ayis-bootstrap.log) 2>&1
# ayis:prelude-begin

# Progress markers. `set -x` traces every command, which is far too noisy to
# watch remotely, so these give ayis init a clean line to stream instead.
progress() { set +x; echo ">>> $*"; set -x; }

# Where the install time goes, on the AWS box: every apt-get is timed, and with it
# the moment dpkg began (the hook in 10-base.sh) - what came before is resolving and
# downloading, what came after is unpacking and configuring. The record is
# /var/log/ayis-timings.log, "start end dpkg-start command"; 99-finish.sh prints the
# slowest. A function, not a script on the PATH: it must not be what apt itself runs.
apt-get() {
  local s e d rc=0 n=0
  s=$(date +%s.%N); rm -f /run/ayis-dpkg-start
  [ "${AYIS_TARGET:-}" = aws ] && n=$(wc -l < /var/log/dpkg.log 2>/dev/null || echo 0)
  command apt-get "$@" || rc=$?
  e=$(date +%s.%N); d=$(cat /run/ayis-dpkg-start 2>/dev/null) || d=-
  if [ "${AYIS_TARGET:-}" = aws ]; then
    echo "$s $e ${d:--} apt-get $*" >> /var/log/ayis-timings.log
    ayis_weigh "$s" "$n" || true
  fi
  return $rc
}
# What an install brought in: how many packages, how large they are unpacked, and
# the three largest - read from what dpkg logged since line $2. A record of its own
# ("pkgs <start> <count> <MB> name MB ..."), joined to the install's by its start.
ayis_weigh() {
  local names
  names=$(tail -n +$(( $2 + 1 )) /var/log/dpkg.log 2>/dev/null | awk '$3 == "install" { print $4 }') || return 0
  [ -n "$names" ] || return 0
  # shellcheck disable=SC2086
  dpkg-query -W -f '${Package} ${Installed-Size}\n' $names 2>/dev/null \
    | sort -k2 -rn \
    | awk -v s="$1" '{ n++; kb += $2; if (n <= 3) top = top " " $1 " " int($2 / 1024) "MB" }
                     END { printf "pkgs %s %d %d%s\n", s, n, kb / 1024, top }' >> /var/log/ayis-timings.log
}

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

USER_NAME="__AYIS_USER__"
TS_AUTHKEY="__TS_AUTHKEY__"
TS_HOST="__TS_HOST__"
AYIS_TARGET="__AYIS_TARGET__"     # aws | host
FAMILY="__AYIS_FAMILY__"        # ubuntu | debian | arch | fedora
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6); USER_HOME=${USER_HOME:-/home/$USER_NAME}
USER_UID=$(id -u "$USER_NAME" 2>/dev/null || echo 1000)

# The AWS box's own steps, never a machine of yours.
aws_box() { [ "$AYIS_TARGET" = aws ]; }
# One way to install a package, whatever the distribution.
pkg() {
  case $FAMILY in
    ubuntu|debian) apt-get install -y "$@" ;;
    # Never -Sy first: a refreshed list installing beside an old system is a
    # partial upgrade, which Arch does not support - new pipewire or steam
    # against old libraries, and programs on the machine break. Upgrading a
    # machine of yours is yours to do, so ayis installs from the lists it has and
    # asks for an upgrade when they are too old to install from.
    arch)          pacman -S --noconfirm --needed "$@" \
                     || { echo ">>> FAILED: pacman could not install $* - the system may be out of date: run sudo pacman -Syu, then run setup again"; return 1; } ;;
    fedora)        dnf install -y "$@" ;;
    *)             echo ">>> FAILED: no package manager known for '$FAMILY'"; return 1 ;;
  esac
}
# What a machine of yours already has.
has_display_manager() { systemctl is-enabled display-manager >/dev/null 2>&1; }

# ayis:prelude-end
# How the build ended, for a machine with no cloud-init to ask: ayis reads it to
# tell a build that stopped from one still running (lib/common.sh).
# On a machine of yours this script came over ssh and may carry the tailnet auth
# key: gone from the disk as soon as it starts (bash keeps it open to read).
if [ "$AYIS_TARGET" = host ]; then rm -f "$0"; fi
# Run again on a machine of yours, the last run's ready marker would read as this
# one finished before it began.
rm -f /var/lib/ayis-bootstrap.rc /var/lib/ayis-ready
trap 'echo $? > /var/lib/ayis-bootstrap.rc' EXIT

export DEBIAN_FRONTEND=noninteractive
# apt's lists are refreshed (a refresh alone changes nothing installed); Arch's
# are not - see pkg.
case $FAMILY in
  ubuntu|debian) apt-get update ;;
esac
