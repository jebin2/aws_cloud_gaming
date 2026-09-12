# --- Ephemeral scratch disk ---------------------------------------------------
# g6 instances ship a local NVMe instance store (232 GB on g6.xlarge) that costs
# nothing extra and is far faster than network-attached EBS. It is wiped on every
# *stop*, filesystem included - so it is formatted at each boot, and only holds
# things that regenerate: the Steam library, downloads and shader caches.
# Re-downloading is the trade, and it measured 62 MB/s from Steam's CDN here -
# about 8 minutes for a 30 GB game.
progress "setting up scratch disk"
cat > /usr/local/bin/mount-scratch.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEV=$(lsblk -dno NAME,MODEL | awk '/Instance Storage/{print "/dev/"$1; exit}')
[[ -n ${DEV:-} ]] || { echo "no instance store present"; exit 0; }
blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -F -L scratch "$DEV"
mkdir -p /scratch
mountpoint -q /scratch || mount -o discard,noatime "$DEV" /scratch
mkdir -p /scratch/nvidia-shader-cache /scratch/dxvk-cache /scratch/tmp \
         /scratch/steam/steamapps /scratch/downloads

# Steam's own shader cache (Fossilize pipeline caches) lives INSIDE the library
# at steamapps/shadercache, so it dies with /scratch on every stop - and for a
# Vulkan game under Proton that is the cache that matters, not the GL one below.
# Rebuilding it is minutes of a saturated CPU at launch, so point it at the root
# volume instead. Steam follows the symlink and never notices.
mkdir -p /home/ubuntu/.cache/steam-shadercache
chown -R ubuntu:ubuntu /home/ubuntu/.cache/steam-shadercache
rm -rf /scratch/steam/steamapps/shadercache
ln -sfn /home/ubuntu/.cache/steam-shadercache /scratch/steam/steamapps/shadercache

# Recreate the Steam library marker on every boot. This disk is reformatted at
# each start, so the marker that proves to Steam the library is real dies with
# it - while the *entry* in libraryfolders.vdf survives on the root volume.
# Steam prunes an entry whose marker is missing, so without this the NVMe
# library silently disappears on the first stop/start and games go back to
# filling the 50 GB root disk.
#
# Reuse the contentid already recorded in libraryfolders.vdf when there is one,
# so Steam sees the same library it adopted rather than a new one.
LIBVDF=/home/ubuntu/.steam/steam/config/libraryfolders.vdf
CID=$(grep -A4 '"/scratch/steam"' "$LIBVDF" 2>/dev/null \
      | sed -n 's/.*"contentid"[[:space:]]*"\([0-9]*\)".*/\1/p' | head -1) || true
[[ -n ${CID:-} ]] || CID=$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')
cat > /scratch/steam/steamapps/libraryfolder.vdf <<MARKER
"libraryfolder"
{
	"contentid"		"$CID"
	"label"		""
}
MARKER

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
verify "steam library dir on /scratch" test -d /scratch/steam/steamapps
