# --- Local NVMe, where the games live -----------------------------------------
# g6 instances ship a local NVMe instance store (232 GB on g6.xlarge) that costs
# nothing extra and is several times faster than network-attached EBS. The Steam
# library lives here, and the price of that is the whole reason 16-library.sh
# exists: the instance store is wiped on every STOP, filesystem included.
#
# This used to be a 160 GB EBS volume at /games, which survived a stop but billed
# INR 1,284/month whether or not the box existed, and pinned every launch to one
# AZ because EBS cannot cross one. The library now lives here and is mirrored to
# S3 at INR ~310/month instead.
#
# Mounted THIS early - before the NVIDIA driver, the slowest step in the build -
# so that the S3 restore can start immediately and run while everything else
# installs. That overlap is what turns a 10-minute download into roughly no
# extra wait at all.
progress "setting up local NVMe at /scratch"
cat > /usr/local/bin/mount-scratch.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEV=$(lsblk -dno NAME,MODEL | awk '/Instance Storage/{print "/dev/"$1; exit}')
[[ -n ${DEV:-} ]] || { echo "no instance store present"; exit 0; }
# A reboot keeps the instance store and its filesystem; only a stop wipes it.
# So format only when there is nothing there - reformatting on every boot would
# throw away a library that survived the build's own reboot.
blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -F -L scratch "$DEV"
mkdir -p /scratch
mountpoint -q /scratch || mount -o discard,noatime "$DEV" /scratch
mkdir -p /scratch/tmp /scratch/downloads /scratch/steam/steamapps

chown -R ubuntu:ubuntu /scratch
chmod 1777 /scratch/tmp

EOF
chmod 755 /usr/local/bin/mount-scratch.sh

cat > /etc/systemd/system/scratch-disk.service <<'EOF'
[Unit]
Description=Format and mount the local NVMe instance store at /scratch
Before=lightdm.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-scratch.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable scratch-disk.service

# Shader caches go on the ROOT volume, not /scratch. The NVIDIA and DXVK caches
# are per-user and outside the Steam library, so mirroring them to S3 would mean
# a second sync of its own; the root volume keeps them across a reboot for free.
# They are lost on a destroy, which costs one slow first launch - the Fossilize
# cache that matters most lives INSIDE the library at steamapps/shadercache and
# is mirrored with it.
cat > /etc/profile.d/shader-cache.sh <<'EOF'
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH="$HOME/.cache/nvidia-shader-cache"
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
export DXVK_STATE_CACHE_PATH="$HOME/.cache/dxvk-cache"
EOF
mkdir -p "/home/$USER_NAME/.cache/nvidia-shader-cache" "/home/$USER_NAME/.cache/dxvk-cache"
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.cache"

# Start it now rather than waiting for the next boot, and check the *mount*, not
# just that the script exists - "installed the thing that does X" has been a
# reliable way to report success while X never happened.
systemctl start scratch-disk.service || true
verify "scratch mount script installed" test -x /usr/local/bin/mount-scratch.sh
verify "/scratch mounted on local NVMe" mountpoint -q /scratch
verify "steam library dir on /scratch" test -d /scratch/steam/steamapps
