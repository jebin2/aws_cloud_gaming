#!/usr/bin/env bash
# The refusals and the boot marker, which survived the move to per-game
# archiving unchanged. The per-game behaviour itself - and the property that
# pushing one game cannot touch another - is tests/library-perapp.sh.
#
# The thing being tested is not the copying - s5cmd does that - but the refusals.
# push writes into a disk that is wiped on every stop, so a guard that fails
# open loses games. Every guard gets a case that proves it fires, and one that
# proves it does not fire when it should not - a guard that always refuses is as
# broken as one that never does.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=host/cg-library
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/state" "$T/scratch/steam/steamapps"
echo "boot-aaaa" > "$T/bootid"

# A stub that records what it was asked to do and reports a remote size we set.
# REMOTE_BYTES/REMOTE_OBJECTS stand in for the archive.
#
# A FUNCTION, not a one-off write: cases that need different s5cmd behaviour
# overwrite this file, and the overwrite used to leak into every case after
# them - four later cases "failed" against an empty archive one of them had
# hard-coded. reset() restores it, so each case starts from the default.
mkstub() {
  cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$S5LOG"
case "$args" in
  version) echo "v2.2.2" ;;
  # Byte-for-byte the real s5cmd format, colon included. The first version of
  # this stub invented "TOTAL: N bytes in M objects", which matched the parser
  # and hid a bug that deleted a real 250 MB archive on the first live test.
  *du*)    echo "${REMOTE_BYTES:-0} bytes in ${REMOTE_OBJECTS:-0} objects: s3://b/steam/*" ;;
  *sync*)  [[ ${SYNC_FAILS:-0} == 1 ]] && exit 1; echo "sync ok" ;;
  *)       echo "None" ;;
esac
FAKE
  chmod +x "$T/bin/s5cmd"
}
mkstub

# /scratch is a mountpoint on the box; here it cannot be, so the mountpoint
# guard is exercised separately and stubbed out for the rest.
cat > "$T/bin/mountpoint" <<'FAKE'
#!/usr/bin/env bash
[[ ${MOUNTED:-1} == 1 ]]
FAKE
chmod +x "$T/bin/mountpoint"

run() { # run <args...>
  S5LOG="$T/s5.log" PATH="$T/bin:$PATH" \
  CG_LIB_DIR="$T/scratch/steam" CG_S3_BUCKET=b CG_S3_PREFIX=steam \
  CG_STATE_DIR="$T/state" CG_S5CMD="$T/bin/s5cmd" CG_BOOT_ID_FILE="$T/bootid" \
  REMOTE_BYTES="${REMOTE_BYTES:-0}" REMOTE_OBJECTS="${REMOTE_OBJECTS:-0}" \
  SYNC_FAILS="${SYNC_FAILS:-0}" MOUNTED="${MOUNTED:-1}" \
    bash "$SRC" "$@" 2>&1
}
fill() { # fill <megabytes>  - give the local library a size
  rm -rf "$T/scratch/steam"; mkdir -p "$T/scratch/steam/steamapps"
  (( ${1:-0} > 0 )) && dd if=/dev/zero of="$T/scratch/steam/steamapps/blob" \
    bs=1M count="$1" status=none
  :
}
# `VAR=x somefunc` leaves VAR SET in the calling shell - bash only scopes a
# prefix assignment for a real command, not a function. Without this, MOUNTED=0
# from the one test that wants an unmounted /scratch leaked into every test
# after it, and nine cases "failed" for a reason none of them was testing.
reset() { unset MOUNTED SYNC_FAILS REMOTE_BYTES REMOTE_OBJECTS; : > "$T/s5.log"; mkstub; }


echo "1. pull refuses to restore onto the root disk if /scratch is not mounted"
reset
REMOTE_OBJECTS=1200 REMOTE_BYTES=1000 MOUNTED=0 out=$(run pull); rc=$?
check "exits non-zero" "$rc" "1"
contains "names the reason" "$out" "not a mountpoint"

echo "2. push refuses when the library was never restored on this boot"
reset; rm -f "$T/state/restored"; fill 20
out=$(run push); rc=$?
check "exits non-zero" "$rc" "1"
contains "explains the risk" "$out" "not restored on this boot"

echo "3. a marker from a PREVIOUS boot does not count as restored"
# /var/lib survives a reboot; /scratch does not. A marker that only said "some
# boot restored this" would vouch for data that had since been wiped.
reset; echo "boot-OLD" > "$T/state/restored"; fill 20
out=$(run push); rc=$?
check "refuses" "$rc" "1"
contains "for the right reason" "$out" "not restored on this boot"

echo "4. push refuses when /scratch is not a mountpoint"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 20
MOUNTED=0 out=$(run push); rc=$?
check "exits non-zero" "$rc" "1"
contains "names the reason" "$out" "not a mountpoint"

echo "5. an unconfigured bucket is an error, not a silent no-op"
out=$(S5LOG="$T/s5.log" PATH="$T/bin:$PATH" CG_S3_BUCKET= CG_STATE_DIR="$T/state" \
      CG_S5CMD="$T/bin/s5cmd" bash "$SRC" status 2>&1); rc=$?
check "exits non-zero" "$rc" "1"
contains "names what is missing" "$out" "no bucket configured"

echo "6. status names an in-progress download instead of hiding it"
# The mirror excludes steamapps/downloading, so a 29 GB disk can report a 3.3 GB
# library. That gap needs explaining where it is seen.
reset; echo "boot-aaaa" > "$T/state/restored"; fill 5
mkdir -p "$T/scratch/steam/steamapps/downloading"
dd if=/dev/zero of="$T/scratch/steam/steamapps/downloading/chunk" bs=1M count=200 status=none
out=$(run status)
contains "names the download" "$out" "downloading - excluded"

echo "7. a trivial downloading dir is not worth mentioning"
rm -f "$T/scratch/steam/steamapps/downloading/chunk"
reset; echo "boot-aaaa" > "$T/state/restored"
out=$(run status)
n=$(grep -c 'downloading - excluded' <<<"$out" || true)
check "stays quiet" "${n:-0}" "0"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
