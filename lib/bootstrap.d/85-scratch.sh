# --- Ephemeral scratch disk ---------------------------------------------------
# g6 instances ship a local NVMe instance store (232 GB on g6.xlarge) that costs
# nothing extra and is far faster than network-attached EBS. It is wiped on every
# *stop*, filesystem included - so it is formatted at each boot, and only holds
# things that genuinely do not matter: temp files and browser downloads.
#
# It used to hold the Steam library, which is why so much of this project is
# about surviving its wipe. That moved to a persistent volume (/games, see
# 86-games.sh) because re-downloading 140 GB per session was the single worst
# thing about this rig. What is left here is 232 GB of free, fast, disposable
# space - useful, but nothing depends on it any more.
progress "setting up scratch disk"
cat > /usr/local/bin/mount-scratch.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEV=$(lsblk -dno NAME,MODEL | awk '/Instance Storage/{print "/dev/"$1; exit}')
[[ -n ${DEV:-} ]] || { echo "no instance store present"; exit 0; }
blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -F -L scratch "$DEV"
mkdir -p /scratch
mountpoint -q /scratch || mount -o discard,noatime "$DEV" /scratch
mkdir -p /scratch/tmp /scratch/downloads

chown -R ubuntu:ubuntu /scratch
chmod 1777 /scratch/tmp

EOF
chmod 755 /usr/local/bin/mount-scratch.sh

cat > /etc/systemd/system/scratch-disk.service <<'EOF'
[Unit]
Description=Format and mount the ephemeral instance store at /scratch
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

# Shader caches go on the ROOT volume, not /scratch. They were here originally
# because /scratch is fast and they regenerate - but "regenerates" hides the
# cost: compiling them is minutes of 100% CPU on 4 vCPUs, which is exactly what
# makes a first launch crawl. /scratch is reformatted on every stop, so keeping
# them there means paying that price every single session. They are small (a few
# GB at most) and the root volume has room.
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
verify "/scratch mounted on the instance store" mountpoint -q /scratch
