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
fi

progress "installing base packages"
pkg curl jq
