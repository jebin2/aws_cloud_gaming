# needrestart must never restart the library units. It runs after every apt
# install and restarts any service whose processes hold outdated libraries - and
# during a restore that is the restore itself (bash, s5cmd). On 2026-09-14 the
# NVIDIA driver install restarted cg-library-restore six minutes into a 160 GB
# download: the first run was killed, a second started from scratch-plus-resume,
# and `systemctl restart` on a oneshot blocks until it finishes, so the driver
# install sat waiting ~9 minutes for a download it did not need.
#
# First thing in the build, before the first apt call, so no later stage can do it.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/50-cg-library.conf <<'NRCONF'
# cloud-gaming: never restart the library units (see lib/bootstrap.d/10-base.sh).
$nrconf{override_rc}{qr(^cg-library-)} = 0;
NRCONF

progress "installing base packages"
apt-get install -y curl jq
