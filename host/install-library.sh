#!/usr/bin/env bash
# Run this ON THE BOX, as root, from the extracted host/ tarball.
# Installs the S3 game-library mirror: the script, its four units, and s5cmd.
set -euo pipefail

BUCKET="${1:?usage: install-library.sh <s3-bucket> [prefix] [apps-csv]}"
PREFIX="${2:-steam}"
CG_APPS="${3:-${CG_APPS:-all}}"
S5_VERSION="${S5_VERSION:-2.2.2}"

# The AWS CLI can do this, but at roughly 80 MB/s single-threaded; s5cmd
# parallelises across objects and measured 235 MB/s down / 508 MB/s up on a
# g6.xlarge. On a 140 GB library that is the difference between 30 minutes and
# 10, which is the entire point of this design.
if ! /usr/local/bin/s5cmd version >/dev/null 2>&1; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  base="https://github.com/peak/s5cmd/releases/download/v${S5_VERSION}"
  tgz="s5cmd_${S5_VERSION}_Linux-64bit.tar.gz"
  # Retries, because this is a third-party CDN on the critical path of a build.
  # A single GitHub 504 killed a whole bootstrap once: the download failed, the
  # verify that followed returned non-zero, and `set -e` took the rest of the
  # build with it.
  curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$tmp/$tgz" "$base/$tgz"
  # Checksums come from the same release, so this catches a truncated or
  # corrupted download - not a compromised release. Said plainly because a
  # checksum line invites the assumption that it does more than it does.
  if curl -fsSL -o "$tmp/sums" "$base/s5cmd_checksums.txt" 2>/dev/null; then
    ( cd "$tmp" && grep " $tgz\$" sums | sha256sum -c - ) \
      || { echo "s5cmd checksum mismatch"; exit 1; }
  else
    echo "note: could not fetch s5cmd checksums; proceeding on the HTTPS transport alone"
  fi
  tar -xzf "$tmp/$tgz" -C "$tmp" s5cmd
  install -m 755 "$tmp/s5cmd" /usr/local/bin/s5cmd
fi

install -m 755 cg-library /usr/local/bin/cg-library

# One config file rather than five copies of the bucket name in unit files.
# CG_APPS is decided on the LAPTOP, before launch. The restore runs here at boot
# with no terminal to ask at, and it has to start early to overlap the build, so
# the choice cannot be made on the box. "all" is the default; "none" boots a
# clean box for other work.
cat > /etc/cg-library.conf <<EOF
CG_S3_BUCKET=$BUCKET
CG_S3_PREFIX=$PREFIX
CG_LIB_DIR=${CG_LIB_DIR:-/scratch/steam}
CG_APPS=${CG_APPS:-all}
EOF
chmod 644 /etc/cg-library.conf

# The state directory records WHICH boot restored the library - the guard that
# stops an empty /scratch being pushed over the archive. It must be writable by
# the user the units run as.
#
# Nothing is deleted here. The marker names its boot, so a stale one from a
# previous boot is already disregarded; deleting it instead meant that
# re-running this installer on a live box revoked a valid restore and left
# `cg stop` and `cg destroy` unable to save the games.
install -d -o ubuntu -g ubuntu -m 755 /var/lib/cg-library

# Two units: restore at boot, and a mirror on the way down. There is
# deliberately NO periodic push timer - nothing uploads while you are playing.
#
# The shutdown unit is not optional cover. The box stops itself three ways (the
# on-host idle watchdog, the CloudWatch alarm, and the off-site watchdog) and
# every one of them ends in a graceful OS shutdown, so without this unit all
# three would wipe the instance store and lose every game installed since the
# last explicit `cg stop`.
install -m 644 cg-library-restore.service /etc/systemd/system/
install -m 644 cg-library-shutdown.service /etc/systemd/system/
# Remove the periodic timer if an earlier build installed one.
systemctl disable --now cg-library-push.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/cg-library-push.service \
      /etc/systemd/system/cg-library-push.timer
systemctl daemon-reload
systemctl enable cg-library-restore.service cg-library-shutdown.service >/dev/null

echo "library mirror installed: s3://$BUCKET/$PREFIX"

# See the note at the end of cg: bash reads a script incrementally and returns
# for more input after the last command, so a file edited while this runs can
# resume at a stale offset. An explicit exit ends the read.
exit 0
