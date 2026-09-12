# --- Persistent game library volume -------------------------------------------
# A separate EBS volume, attached by provision.sh, holding the Steam library.
# The point is that the instance and its root disk are disposable: destroy the
# box between sessions and the games, the Proton prefix (which holds saves) and
# the shader cache all survive.
#
# On Nitro instances EBS does not appear as /dev/sdf - it shows up as an NVMe
# device - and the instance store is NVMe too, so the device has to be
# identified by its model rather than its name.
progress "setting up the game library volume"
cat > /usr/local/bin/mount-games.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
LABEL=games
MP=/games

root_disk() {
  local src; src=$(findmnt -no SOURCE / 2>/dev/null)
  src=${src%p[0-9]}; src=${src%[0-9]}
  echo "$src"
}

# Wait for the volume: provision.sh attaches it after the instance launches, so
# on a first boot cloud-init can easily get here before the device exists.
DEV=""
for _ in $(seq 1 40); do          # up to ~2 min
  DEV=$(blkid -L "$LABEL" 2>/dev/null) && [[ -n $DEV ]] && break
  DEV=""
  for d in /dev/nvme*n1; do
    [[ -b $d ]] || continue
    [[ $d == "$(root_disk)" ]] && continue
    m=$(cat "/sys/block/$(basename "$d")/device/model" 2>/dev/null || echo "")
    [[ $m == *"Elastic Block Store"* ]] || continue
    DEV=$d; break
  done
  [[ -n $DEV ]] && break
  sleep 3
done
[[ -n ${DEV:-} ]] || { echo "no game volume found"; exit 0; }

# THE dangerous decision. Only format a device carrying no filesystem AND no
# partitions: a false positive here erases the entire game library, and there is
# no undo. A device already labelled 'games' never reaches this path. Kept as a
# function so the logic can be tested against stubs rather than trusted.
safe_to_format() {
  local dev=$1
  blkid "$dev" >/dev/null 2>&1 && return 1        # has a filesystem already
  lsblk -no NAME "$dev" 2>/dev/null | tail -n +2 | grep -q . && return 1   # has partitions
  return 0
}

if ! blkid "$DEV" >/dev/null 2>&1; then
  if safe_to_format "$DEV"; then
    echo "formatting $DEV as the game library"
    mkfs.ext4 -F -L "$LABEL" "$DEV" || exit 0
    DEV=$(blkid -L "$LABEL" 2>/dev/null || echo "$DEV")
  else
    echo "$DEV already carries data - refusing to format"
    exit 0
  fi
fi

mkdir -p "$MP"
mountpoint -q "$MP" || mount -o noatime "$DEV" "$MP"
mkdir -p "$MP/steam/steamapps" "$MP/downloads"
chown -R ubuntu:ubuntu "$MP"
EOF
chmod 755 /usr/local/bin/mount-games.sh

cat > /etc/systemd/system/games-disk.service <<'EOF'
[Unit]
Description=Mount the persistent game library volume at /games
Before=lightdm.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-games.sh
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
systemctl enable games-disk.service
systemctl start games-disk.service || true

verify "game volume mount script installed" test -x /usr/local/bin/mount-games.sh
verify "/games mounted" mountpoint -q /games
verify "steam library dir on /games" test -d /games/steam/steamapps
