#!/usr/bin/env bash
# Per-game archiving: the property that makes two games possible at all.
#
# A g6.xlarge holds 229 GB. Wukong (~128) and Diablo IV (~160) do not fit
# together, so the archive must hold more than the disk. The whole-tree sync
# could not: it mirrored the disk with --delete, so installing one game deleted
# the other from S3 - the same mechanism that removed Shakes & Fidget when it
# was uninstalled, and Proton when Steam moved it to another library.
#
# The central assertion here is therefore a NEGATIVE one: pushing game A must
# issue no delete that could reach game B.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=host/cg-library
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output must not contain '$3'"; fail=$((fail+1)); fi; }
cnt() { local n; n=$(grep -c "$1" "$T/s5.log" 2>/dev/null) || true; echo "${n:-0}"; }

mkdir -p "$T/bin" "$T/state" "$T/scratch/steam/steamapps"
echo "boot-aaaa" > "$T/bootid"

# INDEX is what the fake archive contains.
cat > "$T/index.json" <<'JSON'
{"apps":[
 {"appid":"2344520","name":"Diablo IV","installdir":"Diablo IV","bytes":171798691840,"pushed":"2026-09-13T11:02:00Z"},
 {"appid":"2358720","name":"Black Myth: Wukong","installdir":"BlackMythWukong","bytes":137438953472,"pushed":"2026-09-13T09:14:00Z"}
]}
JSON

mkstub() {
  cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$S5LOG"
case "$args" in
  version)          echo "v2.2.2" ;;
  *cat*index.json*) cat "$IDX" ;;
  *cp*index.json*)  : ;;                 # writing the index back
  *cp*symlinks-*)   exit 1 ;;            # no symlink manifests in this fixture
  *sync*|*cp*|*rm*) : ;;
  *)                echo "None" ;;
esac
FAKE
  chmod +x "$T/bin/s5cmd"
}
mkstub
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/mountpoint"; chmod +x "$T/bin/mountpoint"

install_game() { # install_game <appid> <installdir> <name> <mb>
  local id=$1 dir=$2 name=$3 mb=$4
  cat > "$T/scratch/steam/steamapps/appmanifest_$id.acf" <<ACF
"AppState"
{
	"appid"		"$id"
	"name"		"$name"
	"installdir"		"$dir"
	"StateFlags"		"4"
}
ACF
  mkdir -p "$T/scratch/steam/steamapps/common/$dir" \
           "$T/scratch/steam/steamapps/compatdata/$id" \
           "$T/scratch/steam/steamapps/shadercache/$id"
  dd if=/dev/zero of="$T/scratch/steam/steamapps/common/$dir/game.bin" \
     bs=1M count="$mb" status=none
}

run() {
  : > "$T/s5.log"
  S5LOG="$T/s5.log" IDX="$T/index.json" PATH="$T/bin:$PATH" \
  CG_LIB_DIR="$T/scratch/steam" CG_S3_BUCKET=b CG_S3_PREFIX=steam \
  CG_STATE_DIR="$T/state" CG_S5CMD="$T/bin/s5cmd" CG_BOOT_ID_FILE="$T/bootid" \
  CG_APPS="${CG_APPS:-all}" CG_DISK_BUDGET="${CG_DISK_BUDGET:-400000000000}" \
  bash "$SRC" "$@" 2>&1
}

echo "1. pushing a NEW game touches only that game's prefixes"
# A game not yet in the archive, which is also the first-push path. Using one of
# the archived games here would trip the half-present size guard instead, since
# the fixture's index says 128 GB and a test fixture is megabytes.
echo "boot-aaaa" > "$T/state/restored"
install_game 730 CS2 "Counter-Strike 2" 20
out=$(run push)
contains "pushed the installed game"  "$out" "pushing Counter-Strike 2"
contains "synced its common dir"      "$(cat "$T/s5.log")" "common/CS2/"
contains "synced its compatdata"      "$(cat "$T/s5.log")" "compatdata/730/"
contains "synced its shadercache"     "$(cat "$T/s5.log")" "shadercache/730/"

echo "2. and issues NOTHING that could reach the archived games"
# The whole point. Diablo and Wukong are in the archive and not on this disk.
lacks "no Diablo path at all"         "$(cat "$T/s5.log")" "2344520"
lacks "no Diablo directory"           "$(cat "$T/s5.log")" "Diablo"
lacks "no Wukong path at all"         "$(cat "$T/s5.log")" "2358720"
# --delete appears, but only ever scoped inside an installed app's own prefix.
check "every --delete is app-scoped" \
  "$(grep -c -- '--delete' "$T/s5.log" 2>/dev/null || true)" \
  "$(grep -- '--delete' "$T/s5.log" | grep -c -E 'common/CS2/|compatdata/730/|shadercache/730/' || true)"

echo "3. an EMPTY disk pushes nothing rather than emptying the archive"
# Under the whole-tree sync this was the catastrophic case, caught only by a
# size guard. Now there is no app to iterate, so there is nothing to delete.
rm -rf "$T/scratch/steam/steamapps"; mkdir -p "$T/scratch/steam/steamapps"
out=$(run push)
contains "says so plainly"            "$out" "no games installed"
contains "and that the archive is safe" "$out" "archive is left alone"
check    "issued no sync at all"      "$(cnt 'sync')" "0"
check    "issued no delete at all"    "$(cnt 'rm')" "0"

echo "4. pull --apps restores only what was asked for"
out=$(run pull --apps 2358720)
contains "restored Wukong"            "$out" "Black Myth: Wukong"
lacks    "did not restore Diablo"     "$out" "Diablo"
contains "fetched its manifest"       "$(cat "$T/s5.log")" "appmanifest_2358720.acf"
lacks    "fetched nothing of Diablo's" "$(cat "$T/s5.log")" "2344520"

echo "5. pull --apps none restores nothing, and still marks the boot"
rm -f "$T/state/restored"
out=$(run pull --apps none)
contains "says it is deliberate"      "$out" "restoring nothing by request"
check    "no transfers"               "$(cnt 'sync')" "0"
check    "marked restored, so a later push is allowed" \
  "$(cat "$T/state/restored" 2>/dev/null)" "boot-aaaa"

echo "6. pull all takes both"
out=$(run pull --apps all)
contains "Diablo"                     "$out" "Diablo IV"
contains "Wukong"                     "$out" "Black Myth: Wukong"

echo "7. an unknown appid is reported, not silently ignored"
out=$(run pull --apps 999999)
contains "says nothing matched"       "$out" "nothing to restore"

echo "8. a restore bigger than the disk skips games instead of filling it"
# The laptop prompt refuses an oversized selection, but CG_APPS can still say
# "all" - from an old .env, a scripted run, or a prompt that never ran. Filling
# /scratch mid-restore fails in the least legible way there is: a half-restored
# game that Steam reports as installed.
# The index is ordered largest first, so Diablo (160 GB) is considered before
# Wukong (128 GB) and is the one that will not fit a 150 GB budget.
out=$(CG_DISK_BUDGET=150000000000 run pull --apps all)
contains "skipped the one that does not fit" "$out" "SKIPPING Diablo IV"
contains "took the one that does"    "$out" "restoring Black Myth: Wukong"
contains "said how much was left"    "$out" "left"
contains "offered the way to get it" "$out" "pull --apps 2344520"
contains "counted the skips"         "$out" "1 game(s) skipped"
contains "reported the budget"       "$out" "disk budget"

echo "9. a game that is half-present locally does not overwrite its archived copy"
# Per-app prefixes make "empty disk empties the archive" impossible, but one
# game can still be broken locally. Same guard, scoped to that game.
echo "boot-aaaa" > "$T/state/restored"
rm -rf "$T/scratch/steam/steamapps"; mkdir -p "$T/scratch/steam/steamapps"
install_game 2358720 BlackMythWukong "Black Myth: Wukong" 1     # archive says 128 GB
out=$(run push)
contains "refuses that game"      "$out" "SKIPPING Black Myth"
contains "says why"               "$out" "less than half the archived"
contains "names the deliberate route" "$out" "cg library forget 2358720"
check    "uploaded nothing"       "$(cnt 'sync')" "0"
out=$(run push --force)
contains "--force overrides"      "$out" "pushing Black Myth"

echo "10. a failed file sync withholds the manifest rather than lying"
# An archive whose manifest says StateFlags 4 beside a quarter of the files
# gives Steam a game it believes is complete and which fails at launch - and the
# repair re-downloads everything. Seen for real: 33.87 GB of files under a
# manifest claiming 149.9 GB installed.
echo "boot-aaaa" > "$T/state/restored"
rm -rf "$T/scratch/steam/steamapps"; mkdir -p "$T/scratch/steam/steamapps"
install_game 730 CS2 "Counter-Strike 2" 20
cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$S5LOG"
case "$args" in
  version)          echo "v2.2.2" ;;
  *cat*index.json*) cat "$IDX" ;;
  *sync*)           exit 1 ;;          # every file sync fails
  *)                : ;;
esac
FAKE
chmod +x "$T/bin/s5cmd"
out=$(run push)
contains "says it is not archived"  "$out" "is NOT archived"
contains "explains why that matters" "$out" "worse than none"
contains "removed any stale manifest" "$(cat "$T/s5.log")" "rm s3://b/steam/steamapps/appmanifest_730.acf"
n=$(grep -c 'cp .*appmanifest_730.acf s3' "$T/s5.log" 2>/dev/null) || true
check "never uploaded the manifest"  "${n:-0}" "0"
mkstub

echo "11. list shows each game, the total, and what it costs"
out=$(run list)
contains "Diablo listed"              "$out" "Diablo IV"
contains "Wukong listed"              "$out" "Black Myth: Wukong"
contains "total line"                 "$out" "total"
# 160 + 128 = 288 GB at $0.025 = $7.20
contains "monthly cost"               "$out" "7.20"

echo "12. forget refuses without the typed word, and deletes nothing"
out=$(printf 'no\n' | run forget 2344520)
contains "names the game"             "$out" "Diablo IV"
contains "warns it must be redownloaded" "$out" "downloading it from Steam"
contains "aborted"                    "$out" "aborted"
check    "nothing removed"            "$(cnt 'rm')" "0"

echo "13. forget with FORGET removes that game only"
out=$(printf 'FORGET\n' | run forget 2344520)
contains "confirms"                   "$(cat "$T/s5.log")" "2344520"
lacks    "left Wukong alone"          "$(grep 'rm' "$T/s5.log" || true)" "2358720"

echo "14. an appid that is not archived is an error, not a silent no-op"
out=$(printf 'FORGET\n' | run forget 111111); rc=$?
check    "exits non-zero"             "$rc" "1"
contains "says it is not there"       "$out" "not in the archive"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
