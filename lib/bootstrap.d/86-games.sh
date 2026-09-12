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

# The root volume is EBS too, so "find an EBS disk" is not enough - it has to be
# "find an EBS disk that is not the root and holds nothing". Getting this wrong
# once meant trying to mount the root disk at /games; it only failed safely
# because the root has a filesystem. Device selection is upstream of the format
# guard, so a bug here bypasses the guard entirely.
root_disk() {
  local src pk
  src=$(findmnt -no SOURCE / 2>/dev/null) || return 1
  # PKNAME is the parent disk of a partition - far safer than stripping digits,
  # which turned /dev/nvme0n1p1 into /dev/nvme0n and matched nothing.
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 | tr -d ' ')
  [[ -n $pk ]] && { echo "/dev/$pk"; return 0; }
  echo "$src"
}

safe_to_format() {
  local dev=$1
  blkid "$dev" >/dev/null 2>&1 && return 1                                  # has a filesystem
  lsblk -no NAME "$dev" 2>/dev/null | tail -n +2 | grep -q . && return 1    # has partitions
  return 0
}

# Returns the games device, or nothing. Prefers one already labelled; otherwise
# the first EBS disk that is neither the root nor carrying any data.
find_games_dev() {
  local d m root; root=$(root_disk)
  d=$(blkid -L "$LABEL" 2>/dev/null) && [[ -n $d ]] && { echo "$d"; return 0; }
  for d in /dev/nvme*n1 /dev/xvd? /dev/sd?; do
    [[ -b $d ]] || continue
    [[ $d == "$root" ]] && continue
    m=$(cat "/sys/block/$(basename "$d")/device/model" 2>/dev/null || echo "")
    [[ $m == *"Elastic Block Store"* ]] || continue
    safe_to_format "$d" || continue
    echo "$d"; return 0
  done
  return 1
}

# provision.sh attaches the volume after the instance launches, so on a first
# boot cloud-init can get here before the device exists.
DEV=""
for _ in $(seq 1 40); do          # up to ~2 min
  DEV=$(find_games_dev) && [[ -n $DEV ]] && break
  DEV=""
  sleep 3
done
[[ -n ${DEV:-} ]] || { echo "no game volume found (root is $(root_disk))"; exit 1; }

if ! blkid -L "$LABEL" >/dev/null 2>&1; then
  if safe_to_format "$DEV"; then
    echo "formatting $DEV as the game library"
    mkfs.ext4 -F -L "$LABEL" "$DEV" || exit 1
    DEV=$(blkid -L "$LABEL" 2>/dev/null || echo "$DEV")
  else
    echo "$DEV already carries data - refusing to format"
    exit 1
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
