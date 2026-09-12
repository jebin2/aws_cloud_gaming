#!/usr/bin/env bash
# Tests cg-library against a stubbed s5cmd.
#
# The thing being tested is not the copying - s5cmd does that - but the refusals.
# push deletes remote objects that are absent locally, and the local copy sits on
# a disk that is wiped on every stop, so the failure mode of a missing guard is
# "the archive is silently emptied and 140 GB is gone". Every guard gets a case
# that proves it fires, and a case that proves it does not fire when it should
# not - a guard that always refuses is as broken as one that never does.
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
reset() { unset MOUNTED SYNC_FAILS REMOTE_BYTES REMOTE_OBJECTS; : > "$T/s5.log"; }

echo "1. pull: an empty archive is a first run, not a failure"
reset; rm -f "$T/state/restored"
REMOTE_OBJECTS=0 REMOTE_BYTES=0 out=$(run pull)
contains "says the archive is empty" "$out" "is empty"
check "no sync attempted" "$(grep -c sync "$T/s5.log")" "0"
check "marks the library restored for THIS boot" "$(cat "$T/state/restored" 2>/dev/null)" "boot-aaaa"

echo "2. pull: a real archive is restored and marked"
reset; rm -f "$T/state/restored"
REMOTE_OBJECTS=1200 REMOTE_BYTES=150000000000 out=$(run pull)
check "sync ran" "$(grep -c 'sync' "$T/s5.log")" "1"
contains "size-only comparison, not mtime" "$(cat "$T/s5.log")" "--size-only"
check "marks the library restored for THIS boot" "$(cat "$T/state/restored" 2>/dev/null)" "boot-aaaa"

echo "3. pull: a FAILED restore must not mark the library restored"
reset; rm -f "$T/state/restored"
REMOTE_OBJECTS=1200 REMOTE_BYTES=150000000000 SYNC_FAILS=1 out=$(run pull); rc=$?
check "exits non-zero" "$rc" "1"
check "no restored marker - push will refuse" \
  "$(test -f "$T/state/restored" && echo yes || echo no)" "no"

echo "4. pull: refuses to restore onto the root disk if /scratch is not mounted"
reset
REMOTE_OBJECTS=1200 REMOTE_BYTES=1000 MOUNTED=0 out=$(run pull); rc=$?
check "exits non-zero" "$rc" "1"
contains "names the reason" "$out" "not a mountpoint"
check "nothing downloaded" "$(grep -c 'sync' "$T/s5.log")" "0"

echo "5. push: refuses when the library was never restored on this boot"
reset; rm -f "$T/state/restored"; fill 20
REMOTE_OBJECTS=1200 REMOTE_BYTES=150000000000 out=$(run push); rc=$?
check "exits non-zero" "$rc" "1"
contains "explains it would delete the archive" "$out" "would delete the archive"
check "nothing uploaded" "$(grep -c 'sync' "$T/s5.log")" "0"

echo "6. push: refuses when the local copy is far smaller than the archive"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 10
REMOTE_OBJECTS=1200 REMOTE_BYTES=150000000000 out=$(run push); rc=$?
check "exits non-zero" "$rc" "1"
contains "compares the two sizes" "$out" "far smaller than the archive"
check "nothing uploaded" "$(grep -c 'sync' "$T/s5.log")" "0"

echo "7. push: --force overrides the size guard"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 10
REMOTE_OBJECTS=1200 REMOTE_BYTES=150000000000 out=$(run push --force)
contains "warns rather than refusing" "$out" "pushing anyway"
check "uploaded" "$(grep -c 'sync' "$T/s5.log")" "1"

echo "8. push: a normal push proceeds, deletes removed objects, and is size-only"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 40
REMOTE_OBJECTS=10 REMOTE_BYTES=41000000 out=$(run push)
check "uploaded" "$(grep -c 'sync' "$T/s5.log")" "1"
contains "propagates local deletions" "$(cat "$T/s5.log")" "--delete"
contains "size-only by default" "$(cat "$T/s5.log")" "--size-only"
contains "skips Steam's partial downloads" "$(cat "$T/s5.log")" "steamapps/downloading/*"

echo "9. push: --verify drops size-only so mtime changes are caught"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 40
REMOTE_OBJECTS=10 REMOTE_BYTES=41000000 out=$(run push --verify)
check "uploaded" "$(grep -c 'sync' "$T/s5.log")" "1"
if grep -q -- '--size-only' "$T/s5.log"; then
  echo "  FAIL --verify still passed --size-only"; fail=$((fail+1))
else echo "  ok   --verify compares fully"; pass=$((pass+1)); fi

echo "10. push: the first ever push, against an empty archive, is allowed"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 40
REMOTE_OBJECTS=0 REMOTE_BYTES=0 out=$(run push)
check "uploaded" "$(grep -c 'sync' "$T/s5.log")" "1"

echo "11. push: a failed upload reports it and does not claim success"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 40
REMOTE_OBJECTS=10 REMOTE_BYTES=41000000 SYNC_FAILS=1 out=$(run push); rc=$?
check "exits non-zero" "$rc" "1"
contains "says the archive is unchanged" "$out" "still holds the previous contents"

echo "12. an unconfigured bucket is an error, not a silent no-op"
out=$(S5LOG="$T/s5.log" PATH="$T/bin:$PATH" CG_S3_BUCKET= CG_STATE_DIR="$T/state" \
      CG_S5CMD="$T/bin/s5cmd" bash "$SRC" status 2>&1); rc=$?
check "exits non-zero" "$rc" "1"
contains "names what is missing" "$out" "no bucket configured"

echo "13. the object count is parsed out of the real s5cmd format"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 40
REMOTE_OBJECTS=1234 REMOTE_BYTES=41000000 out=$(run status)
# numfmt renders in IEC units, so 41,000,000 bytes is 40MB - the assertion, not
# the code, was wrong the first time this ran.
contains "reports the archive size and count" "$out" "archive   40MB  in 1234 objects"

echo "14. the size guard survives an unparseable object count"
# The bug that deleted a live archive: the count read as 0, and the guard was
# conditioned on the count. Bytes are what it keys off now, so a count this
# parser cannot read must NOT disable the refusal.
reset; echo "boot-aaaa" > "$T/state/restored"; fill 1
cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$S5LOG"
case "$args" in
  version) echo "v2.2.2" ;;
  *du*)    echo "150000000000 bytes in ?? widgets: s3://b/steam/*" ;;
  *sync*)  echo "sync ok" ;;
  *)       echo "None" ;;
esac
FAKE
chmod +x "$T/bin/s5cmd"
out=$(run push); rc=$?
check "still refuses" "$rc" "1"
contains "on the size comparison" "$out" "far smaller than the archive"
check "nothing uploaded" "$(grep -c 'sync' "$T/s5.log")" "0"

echo "15. a marker from a PREVIOUS boot does not count as restored"
# /var/lib survives a reboot; /scratch does not. A marker that only said "some
# boot restored this" would vouch for data that had since been wiped.
reset; echo "boot-OLD" > "$T/state/restored"; fill 20
REMOTE_OBJECTS=1200 REMOTE_BYTES=150000000000 out=$(run push); rc=$?
check "refuses" "$rc" "1"
contains "for the right reason" "$out" "never restored on this boot"
check "nothing uploaded" "$(grep -c 'sync' "$T/s5.log")" "0"

echo "16. check: reports mirrored when a dry run would transfer nothing"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 5
cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$S5LOG"
case "$*" in
  *du*) echo "5000000 bytes in 1 objects: s3://b/steam/*" ;;
  *dry-run*) : ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/s5cmd"
out=$(run check); rc=$?
check "exits 0" "$rc" "0"
contains "says so" "$out" "nothing to push"

echo "17. check: reports NOT mirrored when a dry run would transfer something"
reset; echo "boot-aaaa" > "$T/state/restored"; fill 5
cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$S5LOG"
case "$*" in
  *du*) echo "0 bytes in 0 objects: s3://b/steam/*" ;;
  *) echo "cp /scratch/steam/steamapps/blob s3://b/steam/steamapps/blob" ;;
esac
FAKE
chmod +x "$T/bin/s5cmd"
out=$(run check); rc=$?
check "exits non-zero" "$rc" "1"
contains "counts what differs" "$out" "NOT mirrored"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
