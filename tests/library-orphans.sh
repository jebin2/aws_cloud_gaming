#!/usr/bin/env bash
# Objects the index does not know about.
#
# A push that dies leaves files with no manifest and no index entry - by design,
# so a half-uploaded game is never mistaken for a complete one. But nothing
# could SEE them: `cg library list` read the index and reported an empty archive
# while 76 GB of a dead Diablo IV download sat there costing INR 167 a month,
# and `forget` could not reach it because forget works off the index too.
# Clearing it meant hand-written `aws s3 rm` commands.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
cnt()      { local n; n=$(grep -c "$1" "$T/log" 2>/dev/null) || true; echo "${n:-0}"; }

mkdir -p "$T/bin" "$T/home"
cp "$PWD/cg" "$T/cg"; cp -r "$PWD/lib" "$T/lib"
printf 'GAME_S3_BUCKET=b\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\n' > "$T/.env"

# Wukong is indexed; Diablo IV is not - files with no manifest, the real case.
cat > "$T/index.json" <<'JSON'
{"apps":[{"appid":"2358720","name":"Black Myth: Wukong","installdir":"BlackMythWukong","bytes":137438953472,"pushed":"2026-09-13T09:14:00Z"}]}
JSON
cat > "$T/listing.txt" <<'LIST'
2026-09-13 09:14:00 5000000000 steam/steamapps/common/BlackMythWukong/game.pak
2026-09-13 09:14:00       4096 steam/steamapps/compatdata/2358720/pfx/system.reg
2026-09-13 09:14:00       2048 steam/steamapps/shadercache/2358720/foz/cache.foz
2026-09-13 14:29:36 40000000000 steam/steamapps/common/Diablo IV/Data/big.mpq
2026-09-13 14:32:02 36419386741 steam/steamapps/common/Diablo IV/Diablo IV.exe
2026-09-13 14:32:02       8192 steam/steamapps/shadercache/2344520/foz/cache.foz
LIST

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "aws $args" >> "$LOG"
case "$args" in
  *"s3 cp"*index.json*) [[ ${NO_INDEX:-0} == 1 ]] && exit 1; cat "$IDX" ;;
  *"s3 ls"*--recursive*) cat "$LISTING"; [[ $args == *summarize* ]] && printf '\nTotal Objects: 6\n   Total Size: 81419400077\n' ;;
  *"s3 rm"*) exit 0 ;;
  *"s3 ls"*index.json*) [[ ${NO_INDEX:-0} == 1 ]] && exit 1; echo "index.json" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$T/bin/aws"

run() { # run <answer> <args...>
  rm -f "$T/log"
  local ans="$1"; shift
  ( cd "$T" && printf '%s\n' "$ans" | HOME="$T/home" LOG="$T/log" IDX="$T/index.json" \
      LISTING="$T/listing.txt" NO_INDEX="${NO_INDEX:-0}" PATH="$T/bin:$PATH" \
      timeout 30 bash ./cg library "$@" 2>&1 )
}

echo "1. list names the orphans it would otherwise hide"
out=$(run "" list)
contains "lists the indexed game" "$out" "Black Myth: Wukong"
contains "flags the orphans"      "$out" "ORPHANED"
contains "gives their size"       "$out" "71.2 GB"
contains "says how to remove"     "$out" "cg library clean"

echo "2. clean shows what it would delete, and refuses without the word"
out=$(run "no" clean)
contains "names the orphan dir"   "$out" "common/Diablo IV"
contains "names the other area"   "$out" "shadercache/2344520"
contains "says they are unusable" "$out" "Steam cannot see them"
contains "aborted"                "$out" "aborted"
check    "deleted nothing"        "$(cnt 's3 rm')" "0"

echo "3. clean never touches an INDEXED game"
out=$(run "CLEAN" clean)
check "deleted the orphans"       "$(grep -c 's3 rm.*Diablo IV' "$T/log" || true)" "1"
check "and the orphan shadercache" "$(grep -c 's3 rm.*shadercache/2344520' "$T/log" || true)" "1"
check "left Wukong alone"         "$(grep -c 's3 rm.*BlackMythWukong' "$T/log" || true)" "0"
check "left its compatdata alone" "$(grep -c 's3 rm.*2358720' "$T/log" || true)" "0"

echo "4. with NO index at all, everything is an orphan"
# The state after a first push dies: files present, index never written.
out=$(NO_INDEX=1 run "no" clean)
contains "offers to clear Wukong too" "$out" "common/BlackMythWukong"
contains "and Diablo"                 "$out" "common/Diablo IV"

echo "5. an empty archive is not an error"
# aws s3 ls on an empty prefix exits 1; with pipefail that used to kill the
# whole command, so `cg library list` printed nothing exactly when it mattered.
printf '' > "$T/listing.txt"
out=$(run "" clean); rc=$?
check    "exits 0"            "$rc" "0"
contains "says so plainly"    "$out" "no orphaned objects"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
