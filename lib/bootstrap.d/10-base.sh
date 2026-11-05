# needrestart must never restart the library units. It runs after every apt
# install and restarts any service whose processes hold outdated libraries - and
# during a restore that is the restore itself (bash, s5cmd). On 2026-09-14 the
# NVIDIA driver install restarted cg-library-restore six minutes into a 160 GB
# download: the first run was killed, a second started from scratch-plus-resume,
# and `systemctl restart` on a oneshot blocks until it finishes, so the driver
# install sat waiting ~9 minutes for a download it did not need.
#
# First thing in the build, before the first apt call, so no later stage can do it.
if aws_box; then
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/50-cg-library.conf <<'NRCONF'
# cloud-gaming: never restart the library units (see lib/bootstrap.d/10-base.sh).
$nrconf{override_rc}{qr(^cg-library-)} = 0;
NRCONF
fi

# The AWS box is built once and thrown away if the build fails, so dpkg need not
# flush every file it unpacks to disk (force-unsafe-io): on network disks that wait
# is a good part of installing a few thousand files. Taken out again before the
# build ends (99-finish.sh), so the running machine's package database is as safe
# as any. No translation files either: nothing here reads them.
if aws_box; then
  echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/99-cg-build-unsafe-io
  echo 'Acquire::Languages "none";' > /etc/apt/apt.conf.d/99-cg-build-no-translations
  # The first boot has the image's own updater holding the package lock for a
  # while; wait for it rather than fail.
  echo 'DPkg::Lock::Timeout "900";' > /etc/apt/apt.conf.d/99-cg-build-lock-wait
  # Timings (see apt-get in 00-header.sh): when dpkg starts, and how long the
  # boot-image rebuilds it triggers take - update-initramfs is a script of its own
  # first on root's PATH, since dpkg's triggers call it and no function reaches them.
  printf '%s\n' 'DPkg::Pre-Install-Pkgs { "cat >/dev/null; date +%s.%N >/run/cg-dpkg-start"; };' \
    > /etc/apt/apt.conf.d/99-cg-build-timing
  cat > /usr/local/sbin/update-initramfs <<'WRAP'
#!/bin/sh
s=$(date +%s.%N); /usr/sbin/update-initramfs "$@"; rc=$?
echo "$s $(date +%s.%N) - update-initramfs $*" >> /var/log/cg-timings.log
exit $rc
WRAP
  chmod 755 /usr/local/sbin/update-initramfs
fi

progress "installing base packages"
pkg curl jq zstd
