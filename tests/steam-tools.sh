#!/usr/bin/env bash
# Steam's tools are not games, and push must not archive them.
#
# Proton and the Steam Linux Runtimes were deliberately left out of the mirror
# (re-downloaded in under a minute). But Steam sometimes installs them into
# /scratch/steam, and a push on 2026-09-14 archived four of them as games. Per-
# game archiving never removes an absent app, so they would have stayed forever.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=host/cg-library
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: must not contain '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/state" "$T/home"
echo boot-a > "$T/bootid"; echo boot-a > "$T/state/restored"
cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$S5LOG"
case "$*" in *du*) echo "0 bytes in 0 objects: s3://b/steam/*" ;; *cat*) exit 1 ;; *) exit 0 ;; esac
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/mountpoint"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/pgrep"
chmod +x "$T/bin"/*

L="$T/scratch/steam/steamapps"
app() { # app <id> <installdir> <name>
  mkdir -p "$L/common/$2"; echo x > "$L/common/$2/f"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"%s"\n}\n' "$1" "$3" "$2" > "$L/appmanifest_$1.acf"
}
app 2344520 "Diablo IV" "Diablo IV"
app 1493710 "Proton - Experimental" "Proton Experimental"
app 2805730 "Proton 9.0" "Proton 9.0"
app 1391110 "SteamLinuxRuntime_soldier" "Steam Linux Runtime 2.0 (soldier)"
app 4183110 "SteamLinuxRuntime_4" "Steam Linux Runtime 4.0"
app 3086180 "Proton Voice Files" "Proton Voice Files"
app 228980  "Steamworks Shared" "Steamworks Common Redistributables"
# Games that merely look like tools: kept.
app 9999990 "ProtonHunter" "ProtonHunter"
app 9999991 "HunterGame" "Proton Hunter"

: > "$T/s5.log"
out=$(S5LOG="$T/s5.log" PATH="$T/bin:$PATH" HOME="$T/home" \
  CG_LIB_DIR="$T/scratch/steam" CG_S3_BUCKET=b CG_S3_PREFIX=steam \
  CG_STATE_DIR="$T/state" CG_S5CMD="$T/bin/s5cmd" CG_BOOT_ID_FILE="$T/bootid" \
  CG_STEAM_BASE="$T/home" timeout 60 bash "$SRC" push 2>&1)
log=$(cat "$T/s5.log")

echo "1. the game is archived"
contains "Diablo IV synced" "$log" "common/Diablo IV/"
echo "2. every tool is skipped, and says so"
for d in "Proton - Experimental" "Proton 9.0" "SteamLinuxRuntime_soldier" "SteamLinuxRuntime_4" "Proton Voice Files" "Steamworks Shared"; do
  lacks "no upload of $d" "$log" "common/$d"
done
lacks "no tool manifest uploaded" "$log" "appmanifest_1493710"
contains "explains the skip" "$out" "a Steam tool"
echo "3. games that only look like tools are still archived"
contains "installdir ProtonHunter (no space) kept" "$log" "common/ProtonHunter/"
contains "Proton in the NAME only is kept"         "$log" "common/HunterGame/"
echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
