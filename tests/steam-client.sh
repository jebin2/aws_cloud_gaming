#!/usr/bin/env bash
# Steam's client as an archive: what is packed (the client, and nothing that
# belongs to a person or a machine), and what a new box does with it (uses it when it
# matches its fingerprint, and never when it does not). Run here with a stand-in
# client and a web server on this machine.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
T=$(mktemp -d); pass=0; fail=0
WEB=""
trap '[[ -n $WEB ]] && kill "$WEB" 2>/dev/null; rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3' in: $2"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: has '$3'"; fail=$((fail+1)); fi; }
command -v zstd >/dev/null || { echo "  (no zstd - skipped)"; echo "steam-client: 0 passed, 0 failed"; exit 0; }

# A client folder as Steam leaves it: programs and packages to keep, a login and
# other things that are a person's or a machine's to leave out.
mk() {
  local d=$1
  mkdir -p "$d/ubuntu12_32" "$d/ubuntu12_64" "$d/package" "$d/steamui" "$d/config" "$d/logs" "$d/userdata/1" "$d/steamapps" "$d/htmlcache" "$d/dumps"
  echo prog > "$d/ubuntu12_32/steam"; echo prog64 > "$d/ubuntu12_64/steamwebhelper"; echo ui > "$d/steamui/index.html"
  printf '"manifest"\n{\n\t"version"\t"1730000000"\n}\n' > "$d/package/steam_client_ubuntu12.manifest"
  echo TOKEN > "$d/config/config.vdf"; echo log > "$d/logs/a.log"; echo mine > "$d/userdata/1/config.vdf"
  echo acf > "$d/steamapps/appmanifest_1.acf"; echo cache > "$d/htmlcache/x"; echo dump > "$d/dumps/c.dmp"; echo ssfn > "$d/ssfn123"
  ln -s ubuntu12_32 "$d/linux32"
}
mk "$T/runner/.local/share/Steam"

echo "1. what is packed"
out=$(bash .github/scripts/steam-client-pack.sh "$T/runner/.local/share/Steam" "$T/out" 2>&1)
contains "it says what it made" "$out" "packed "
list=$(zstd -dc "$T/out/steam-client.tar.zst" | tar -t)
for keep in ubuntu12_32/steam ubuntu12_64/steamwebhelper steamui/index.html package/steam_client_ubuntu12.manifest linux32; do
  contains "the client has $keep" "$list" "Steam/$keep"
done
for leave in config/config.vdf logs/a.log userdata/1/config.vdf steamapps/appmanifest_1.acf htmlcache/x dumps/c.dmp ssfn123; do
  lacks "and not $leave" "$list" "Steam/$leave"
done
check "the fingerprint is the archive's" "$(cd "$T/out" && sha256sum -c steam-client.sha256 >/dev/null 2>&1 && echo yes)" "yes"
contains "the manifest has the client's version" "$(cat "$T/out/steam-client.json")" '"client_version":"1730000000"'

echo "2. a link that names the folder by its full path is made relative"
mk "$T/abs/Steam"; ln -s "$T/abs/Steam/ubuntu12_32" "$T/abs/Steam/abs"
out=$(bash .github/scripts/steam-client-pack.sh "$T/abs/Steam" "$T/absout" 2>&1)
contains "it says what it did" "$out" "made 1 link(s) inside the folder relative"
check "  and makes the archive" "$([[ -e $T/absout/steam-client.tar.zst ]] && echo made || echo none)" "made"
mkdir -p "$T/moved" && tar -I zstd -xf "$T/absout/steam-client.tar.zst" -C "$T/moved"
check "  with a link that works anywhere" "$(readlink "$T/moved/Steam/abs")" "ubuntu12_32"

echo "3. a new box uses a matching archive"
mkdir -p "$T/web" && cp "$T/out"/steam-client.* "$T/web/"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
( cd "$T/web" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
WEB=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/steam-client.json" >/dev/null 2>&1 && break; sleep 0.1; done
URL=http://127.0.0.1:$PORT
fetch() { CG_FETCH_HOME=$1 bash host/steam-client-fetch "$URL" "$(id -un)" 2>&1; echo "rc=$?"; }
out=$(fetch "$T/box1")
contains "it succeeds"                "$out" "rc=0"
contains "  and says where"           "$out" "the Steam client is in place"
check "the client is there"           "$(cat "$T/box1/.local/share/Steam/ubuntu12_64/steamwebhelper")" "prog64"
check "  with its link"               "$(readlink "$T/box1/.local/share/Steam/linux32")" "ubuntu12_32"
check "  and Steam's own links to it" "$(readlink "$T/box1/.steam/steam")" "$T/box1/.local/share/Steam"
check "  none of the login came along" "$([[ -e $T/box1/.local/share/Steam/config/config.vdf ]] && echo there || echo none)" "none"

echo "4. one that is already there is left alone"
echo mine > "$T/box1/.local/share/Steam/ubuntu12_32/extra"
out=$(fetch "$T/box1")
contains "it says so"                 "$out" "already here"
check "  and changes nothing"         "$(cat "$T/box1/.local/share/Steam/ubuntu12_32/extra")" "mine"

echo "5. an archive that does not match its fingerprint is never used"
mkdir -p "$T/web2" && cp "$T/out"/steam-client.* "$T/web2/"
echo tamper >> "$T/web2/steam-client.tar.zst"
kill "$WEB" 2>/dev/null; wait "$WEB" 2>/dev/null
( cd "$T/web2" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
WEB=$!
for _ in $(seq 1 50); do curl -fs "$URL/steam-client.json" >/dev/null 2>&1 && break; sleep 0.1; done
out=$(fetch "$T/box2")
contains "it refuses"                 "$out" "does not match its fingerprint"
contains "  with a code of its own"   "$out" "rc=3"
check "  and puts nothing on the box" "$([[ -e $T/box2/.local/share/Steam ]] && echo there || echo none)" "none"

echo "6. an archive that reaches outside its own folder is never used"
python3 - "$T/evil" <<'PY'
import io, sys, tarfile, os
d = sys.argv[1]; os.makedirs(d, exist_ok=True)
with tarfile.open(d + "/steam-client.tar", "w") as t:
    for name in ("Steam/ok", "../escaped"):
        data = b"x"; ti = tarfile.TarInfo(name); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
PY
zstd -q -f "$T/evil/steam-client.tar" -o "$T/evil/steam-client.tar.zst" && (cd "$T/evil" && sha256sum steam-client.tar.zst > steam-client.sha256)
kill "$WEB" 2>/dev/null; wait "$WEB" 2>/dev/null
( cd "$T/evil" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
WEB=$!
for _ in $(seq 1 50); do curl -fs "$URL/steam-client.sha256" >/dev/null 2>&1 && break; sleep 0.1; done
out=$(fetch "$T/box3")
contains "it refuses"                 "$out" "outside its own folder"
check "  and nothing escaped"         "$([[ -e $T/box3/.local/share/../escaped || -e $T/box3/.local/escaped ]] && echo escaped || echo none)" "none"

echo "7. no archive at all is not an error for the build"
kill "$WEB" 2>/dev/null; wait "$WEB" 2>/dev/null; WEB=""
out=$(fetch "$T/box4")
contains "it says there is none"      "$out" "no Steam client archive to use"
contains "  with a code of its own"    "$out" "rc=2"

echo; echo "steam-client: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
