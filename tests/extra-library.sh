#!/usr/bin/env bash
# The service that keeps the disk added for the games in Steam's list of folders:
# it adds the folder once Steam is closed, puts it back if Steam drops it, and
# never touches the list while Steam is running.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

H="$T/home"; LIB="$T/extra/steam"
mkdir -p "$H/.local/share/Steam/config" "$H/.steam" "$LIB/steamapps"
ln -s "$H/.local/share/Steam" "$H/.steam/steam"
CONF="$H/.local/share/Steam/config/libraryfolders.vdf"
fresh() {
  printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"/home/ubuntu/.local/share/Steam"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"/scratch/steam"\n\t}\n}\n' > "$CONF"
}
# pgrep, as the service sees Steam: STEAM_UP=1 means it is running.
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\n[[ ${STEAM_UP:-0} == 1 ]]\n' > "$T/bin/pgrep"; chmod +x "$T/bin/pgrep"
# Two seconds of waiting between looks is the service's pace; the test shortens it.
sed 's/sleep 2/sleep 0.2/g' host/steam-add-extra-library > "$T/svc.sh"
svc() { HOME="$H" CG_EXTRA_LIB="$LIB" PATH="$T/bin:$PATH" timeout "${1:-3}" bash "$T/svc.sh" >/dev/null 2>&1; }

echo "1. Steam is closed: the folder is added, after the ones that are there"
fresh; STEAM_UP=0 svc
check "it is in the list"          "$(grep -c "$LIB" "$CONF")" "1"
check "  as the next number"       "$(grep -c '^	"2"' "$CONF")" "1"
check "  with a marker Steam accepts" "$(grep -c contentid "$LIB/steamapps/libraryfolder.vdf")" "1"
check "  and the others kept"      "$(grep -c '/scratch/steam' "$CONF")" "1"

echo "2. it is not added twice"
STEAM_UP=0 svc
check "still once"                 "$(grep -c "$LIB" "$CONF")" "1"

echo "3. Steam running: the list is not touched"
fresh; STEAM_UP=1 svc
check "nothing added"              "$(grep -c "$LIB" "$CONF")" "0"

echo "4. Steam drops it on exit: it is put back, with the same id"
fresh; STEAM_UP=0 svc; id=$(grep -o 'contentid"[^"]*"[0-9]*' "$LIB/steamapps/libraryfolder.vdf" | head -1)
fresh; STEAM_UP=0 svc
check "back again"                 "$(grep -c "$LIB" "$CONF")" "1"
check "  with the id it had"       "$(grep -c "${id##*\"}" "$CONF")" "1"

echo "5. no list yet (Steam never signed in): it waits and does not fail"
rm -f "$CONF"; STEAM_UP=0 svc 2
check "no file made"               "$([[ -f $CONF ]] && echo made || echo none)" "none"

echo; echo "extra-library: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
