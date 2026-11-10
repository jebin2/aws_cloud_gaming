#!/usr/bin/env bash
# Which disk is where. The machine's own drive is /scratch, always. A disk added
# for the games that do not fit it is /scratch2: the EBS disk that has nothing
# mounted on it, never the root disk - and it is still found on the next boot,
# when it is already mounted at /scratch2.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/scratch"
for c in chown chmod; do printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/$c"; done
printf '#!/usr/bin/env bash\necho "MKFS $*" >> "$LOG"\n' > "$T/bin/mkfs.ext4"
printf '#!/usr/bin/env bash\necho "MOUNT $*" >> "$LOG"\n' > "$T/bin/mount"
printf '#!/usr/bin/env bash\nexit "${MOUNTED:-1}"\n' > "$T/bin/mountpoint"
printf '#!/usr/bin/env bash\n[[ -n ${FORMATTED:-} ]]\n' > "$T/bin/blkid"
# lsblk: -dno NAME,MODEL lists the disks; -no MOUNTPOINT /dev/X lists what is mounted on one.
cat > "$T/bin/lsblk" <<'FAKE'
#!/usr/bin/env bash
if [[ $1 == -dno ]]; then printf '%b' "$DISKS"; exit 0; fi
case $3 in
  /dev/nvme0n1) printf '/\n/boot/efi\n' ;;
  /dev/nvme1n1) printf '%s\n' "${DATA_MOUNT:-}" ;;
  /dev/nvme2n1) printf '%s\n' "${DATA_MOUNT:-}" ;;
  *) ;;
esac
FAKE
chmod +x "$T/bin"/*

# The script as the bootstrap writes it, with /scratch moved into the sandbox.
script() { # script <DATA_GB>
  sed -n "/mount-scratch.sh <<'EOF'/,/^EOF$/p" lib/bootstrap.d/12-scratch.sh | sed '1d;$d' \
    | sed "s#__AYIS_DATA_GB__#$1#; s#/scratch#$T/scratch#g" > "$T/ms.sh"
}
run() { LOG="$T/log" PATH="$T/bin:$PATH" DISKS="$DISKS" bash "$T/ms.sh" >"$T/out" 2>&1; echo $?; }
# root, the machine's own drive, and (when one was added) the games disk.
OWN_ONLY='nvme0n1 Amazon Elastic Block Store\nnvme1n1 Amazon EC2 NVMe Instance Storage\n'
WITH_EXTRA='nvme0n1 Amazon Elastic Block Store\nnvme1n1 Amazon EC2 NVMe Instance Storage\nnvme2n1 Amazon Elastic Block Store\n'
EXTRA_FIRST='nvme2n1 Amazon Elastic Block Store\nnvme0n1 Amazon Elastic Block Store\nnvme1n1 Amazon EC2 NVMe Instance Storage\n'

echo "1. no games disk: the machine's own drive, as before"
script 0; DISKS=$OWN_ONLY; rm -f "$T/log"
check "ran"                      "$(run)" "0"
check "formatted the instance store"  "$(grep -c 'MKFS.*nvme1n1' "$T/log")" "1"
check "  and made no /scratch2"  "$(grep -c 'scratch2' "$T/log")" "0"

echo "2. a games disk: still the drive at /scratch, and the disk with nothing mounted at /scratch2"
script 190; DISKS=$WITH_EXTRA; rm -f "$T/log"
check "ran"                      "$(run)" "0"
check "formatted the machine's own drive" "$(grep -c 'MKFS.*nvme1n1' "$T/log")" "1"
check "formatted the added disk"  "$(grep -c 'MKFS.*ayisextra.*nvme2n1' "$T/log")" "1"
check "  and never the root disk" "$(grep -c 'nvme0n1' "$T/log")" "0"
check "  mounting it at /scratch2" "$(grep -c "MOUNT.*nvme2n1 $T/scratch2" "$T/log")" "1"

echo "3. a games disk, with it listed first (device order differs)"
DISKS=$EXTRA_FIRST; rm -f "$T/log"
check "ran"                      "$(run)" "0"
check "still not the root disk"  "$(grep -c 'nvme0n1' "$T/log")" "0"
check "  and the added disk is the one"  "$(grep -c 'MKFS.*ayisextra.*nvme2n1' "$T/log")" "1"

echo "4. the next boot: the added disk is already at /scratch2 and formatted"
DISKS=$WITH_EXTRA; DATA_MOUNT="$T/scratch2"; FORMATTED=1; MOUNTED=0; export DATA_MOUNT FORMATTED MOUNTED
rm -f "$T/log"; : > "$T/log"
check "ran"                      "$(run)" "0"
check "not formatted again"      "$(grep -c MKFS "$T/log" || true)" "0"
unset DATA_MOUNT FORMATTED MOUNTED

echo "5. a games disk that never attached"
DISKS=$OWN_ONLY; rm -f "$T/log"
check "fails loudly"             "$(run)" "1"
check "  and says why"           "$(grep -c 'not attached' "$T/out")" "1"

echo; echo "mount-scratch: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
