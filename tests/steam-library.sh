#!/usr/bin/env bash
# Regression test for the Steam library invariant.
#
# Extracts steam-ensure-library.sh straight out of lib/bootstrap.d/90-steam-prewarm.sh
# and exercises it against a faked Steam install, so the logic that has broken
# most often in this project can be checked without spending a build.
#
#   ./tests/steam-library.sh
#
# Covers: a fresh client with no libraryfolders.vdf, the no-op healthy path, the
# marker being wiped (every stop reformats /scratch), and Steam dropping the
# entry (what a first sign-in can do).
set -uo pipefail
cd "$(dirname "$0")/.."
MOD=lib/bootstrap.d/90-steam-prewarm.sh
[[ -f $MOD ]] || { echo "cannot find $MOD"; exit 1; }
SRC=$(mktemp)
awk "/^cat > \\/usr\\/local\\/bin\\/steam-ensure-library.sh <<'EOF'\$/{f=1;next} f&&/^EOF\$/{exit} f" "$MOD" > "$SRC"
bash -n "$SRC" || { echo "extracted script does not parse"; exit 1; }

T=$(mktemp -d)
sed 's|^export PATH=.*|:|' "$SRC" > "$T/ensure.sh"

export HOME="$T/home" STEAM_LIB_DIR="$T/scratch/steam"
ROOT="$HOME/.local/share/Steam"
CONF="$ROOT/config/libraryfolders.vdf"
MARKER="$STEAM_LIB_DIR/steamapps/libraryfolder.vdf"
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

setup() {
  rm -rf "$T/home" "$T/scratch"
  mkdir -p "$ROOT/ubuntu12_64" "$ROOT/config" "$HOME/.steam" "$STEAM_LIB_DIR/steamapps" "$T/bin"
  ln -sfn "$ROOT" "$HOME/.steam/steam"
  # Behaves like the real client: on start it drops a library entry that has no
  # in-library marker. That is the pruning behaviour the whole design defends against.
  cat > "$T/bin/steam" <<FAKE
#!/usr/bin/env bash
touch "$T/running"
if [[ -f "$CONF" ]] && grep -q "$STEAM_LIB_DIR" "$CONF" && [[ ! -f "$MARKER" ]]; then
  python3 - "$CONF" <<'P'
import sys,re
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'\t"1"\n\t\{\n(?:.*\n)*?\t\}\n','',s,count=1))
P
fi
sleep 2; rm -f "$T/running"
FAKE
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/xset"
  printf '#!/bin/sh\ntest -f %s/running\n' "$T" > "$T/bin/pgrep"
  printf '#!/bin/sh\nrm -f %s/running\n' "$T" > "$T/bin/pkill"
  chmod +x "$T"/bin/*
}
run() { PATH="$T/bin:$PATH" bash "$T/ensure.sh" >/dev/null 2>&1; echo $?; }
ecid() { grep -A4 "$STEAM_LIB_DIR" "$CONF" 2>/dev/null | sed -n 's/.*"contentid"[[:space:]]*"\([0-9]*\)".*/\1/p' | head -1; }
mcid() { sed -n 's/.*"contentid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$MARKER" 2>/dev/null | tail -1; }
drop_entry() { python3 - "$CONF" <<'P'
import sys,re
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'\t"1"\n\t\{\n(?:.*\n)*?\t\}\n','',s,count=1))
P
}

echo "1. fresh client, no libraryfolders.vdf at all"
setup; rc=$(run)
check "exit 0" "$rc" "0"
check "entry written"  "$([[ -n $(ecid) ]] && echo yes)" "yes"
check "marker written" "$([[ -n $(mcid) ]] && echo yes)" "yes"
check "cids match"     "$(ecid)" "$(mcid)"
first=$(ecid)

echo "2. already healthy - no-op, must not change the cid"
rc=$(run)
check "exit 0" "$rc" "0"
check "cid unchanged" "$(ecid)" "$first"

echo "3. marker wiped - what every stop does to /scratch"
rm -f "$MARKER"; rc=$(run)
check "exit 0" "$rc" "0"
check "marker restored"  "$(mcid)" "$first"
check "same cid reused"  "$(ecid)" "$first"

echo "4. entry dropped by steam - what a first sign-in can do"
setup; run >/dev/null; keep=$(ecid); drop_entry
check "entry really gone" "$(ecid)" ""
rc=$(run)
check "exit 0" "$rc" "0"
check "entry restored" "$([[ -n $(ecid) ]] && echo yes)" "yes"
check "cids match"     "$(ecid)" "$(mcid)"
check "reused marker cid, not a new one" "$(ecid)" "$keep"

echo "5. no client installed - must do nothing and not fail"
setup; rm -rf "$ROOT/ubuntu12_64"; rc=$(run)
check "exit 0" "$rc" "0"
check "wrote nothing" "$([[ -f $CONF ]] && echo yes || echo no)" "no"

echo; echo "passed $pass, failed $fail"; rm -rf "$T"; [[ $fail -eq 0 ]]
