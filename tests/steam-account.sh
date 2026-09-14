#!/usr/bin/env bash
# The Steam LOGIN, which is not in the game library and never was.
#
# The games live on /scratch and are archived per app. The login does not: it is
# config.vdf (the refresh token), loginusers.vdf, registry.vdf and userdata/,
# all on the ROOT disk, which is destroyed with the instance. That is why every
# new box asked for Steam Guard again even though the games came back intact.
#
# What is easy to get wrong here, and what each case pins down:
#   - archiving a logged-OUT box over a good saved login (case 3)
#   - .steam/steam is a symlink to the Steam dir, so a dereferencing tar
#     archives everything twice and can recurse (case 2)
#   - config.vdf must come back 0600 or Steam rejects it (case 5)
#   - the login is worth keeping on exactly the boots the GAME guards refuse:
#     no games installed, or nothing restored this boot (cases 7 and 8)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=host/cg-library
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' must not contain '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/state" "$T/scratch/steam/steamapps"
echo "boot-aaaa" > "$T/bootid"
SD=".local/share/Steam"

# s5cmd stands in for the bucket: cp TO the archive stores the file under
# $T/remote, cp FROM it hands that file back. Anything else is a no-op, so the
# game paths do not interfere.
cat > "$T/bin/s5cmd" <<'FAKE'
#!/usr/bin/env bash
args="$*"; echo "$args" >> "$S5LOG"
case "$args" in
  *cp*steam-account.tgz*)
    [[ ${UPLOAD_FAILS:-0} == 1 ]] && exit 1
    src=${@: -2:1}; dst=${@: -1}
    if [[ $dst == s3://* ]]; then cp "$src" "$REMOTE/account.tgz"
    else [[ -f $REMOTE/account.tgz ]] || exit 1; cp "$REMOTE/account.tgz" "$dst"; fi ;;
  *ls*steam-account.tgz*) [[ -f $REMOTE/account.tgz ]] || exit 1; echo "account.tgz" ;;
  version) echo "v2.2.2" ;;
  *du*)    echo "0 bytes in 0 objects: s3://b/steam/*" ;;
  *)       echo "None" ;;
esac
FAKE
printf '#!/usr/bin/env bash\n[[ ${MOUNTED:-1} == 1 ]]\n' > "$T/bin/mountpoint"
# Steam itself: present-or-not is driven by $STEAM_UP, and `steam -shutdown`
# clears it, which is how case 6 proves the graceful-exit path is taken.
printf '#!/usr/bin/env bash\n[[ $1 == -x && $2 == steam && -f $T_UP ]]\n' > "$T/bin/pgrep"
cat > "$T/bin/steam" <<'FAKE'
#!/usr/bin/env bash
# Exits after a beat, like the real thing. Synchronous removal here would let a
# build with NO wait loop pass: pgrep would already report Steam gone.
[[ $1 == -shutdown ]] && ( sleep 2; rm -f "$T_UP" ) &
exit 0
FAKE
chmod +x "$T/bin"/*
mkdir -p "$T/remote"

run() {
  S5LOG="$T/s5.log" REMOTE="$T/remote" PATH="$T/bin:$PATH" T_UP="$T/up" \
  CG_LIB_DIR="$T/scratch/steam" CG_S3_BUCKET=b CG_S3_PREFIX=steam \
  CG_STATE_DIR="$T/state" CG_S5CMD="$T/bin/s5cmd" CG_BOOT_ID_FILE="$T/bootid" \
  CG_STEAM_BASE="$T/home" CG_STEAM_DIR="$SD" HOME="$T/home" \
  MOUNTED="${MOUNTED:-1}" UPLOAD_FAILS="${UPLOAD_FAILS:-0}" \
  CG_STEAM_SHUTDOWN="${CG_STEAM_SHUTDOWN:-1}" \
    timeout 60 bash "$SRC" "$@" 2>&1
  # timeout, not bare bash: a tar that follows a symlink loop under userdata/
  # does not fail, it spins - and a hung suite reads as "still running", not as
  # the regression it is.
}

# A box with a signed-in Steam: the token, the remembered account, the machine
# identity, per-user config, and 40 MB of cache that must NOT be archived.
make_login() {
  rm -rf "$T/home"
  mkdir -p "$T/home/$SD/config/htmlcache" "$T/home/$SD/config/avatarcache" \
           "$T/home/$SD/userdata/12345678/config/librarycache" "$T/home/.steam"
  echo 'refresh_token_here' > "$T/home/$SD/config/config.vdf"
  # Where the token really is. config.vdf above holds the account list only.
  printf '"MachineUserConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"ConnectCache"\n\t\t\t\t{\n\t\t\t\t\t"1a2b3c4d5"\t\t"5b9aENCRYPTED"\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n' > "$T/home/$SD/local.vdf"
  echo 'loginusers'         > "$T/home/$SD/config/loginusers.vdf"
  echo 'registry'           > "$T/home/.steam/registry.vdf"
  echo 'localconfig'        > "$T/home/$SD/userdata/12345678/config/localconfig.vdf"
  dd if=/dev/zero of="$T/home/$SD/config/htmlcache/blob" bs=1M count=40 status=none
  dd if=/dev/zero of="$T/home/$SD/userdata/12345678/config/librarycache/b" bs=1M count=5 status=none
  ln -sfn "$T/home/$SD" "$T/home/.steam/steam"
}
reset() { unset MOUNTED UPLOAD_FAILS CG_STEAM_SHUTDOWN; rm -f "$T/up"; : > "$T/s5.log"; }
members() { tar -tzf "$T/remote/account.tgz" 2>/dev/null; }

echo "1. push archives the files that carry the login"
reset; make_login; rm -f "$T/remote/account.tgz"
out=$(run account push)
contains "says so"            "$out" "steam account: archived"
contains "the token store"    "$(members)" "$SD/local.vdf"
contains "the config"         "$(members)" "config/config.vdf"
contains "the account list"   "$(members)" "config/loginusers.vdf"
contains "the machine id"     "$(members)" ".steam/registry.vdf"
contains "per-user config"    "$(members)" "userdata/12345678/config/localconfig.vdf"

echo "2. the directory that IS walked - userdata - stays small and stays flat"
# Two of these are structural rather than filtered, and saying which is which
# matters: config/ is archived as two named FILES, so its 40 MB htmlcache was
# never a candidate and the --exclude for it is insurance, not the mechanism.
# userdata/ is the one real directory walk, so it is where the excludes and the
# symlink handling actually earn their place.
lacks "no librarycache under userdata" "$(members)" "librarycache"
n=$(members | grep -c "$SD/config/" || true)
check "config/ contributes exactly its two named files" "${n:-0}" "2"
lacks "the .steam symlink is not a member" "$(members)" ".steam/steam"
sz=$(stat -c %s "$T/remote/account.tgz")
if (( sz < 1048576 )); then echo "  ok   archive is small ($sz bytes, not 45 MB)"; pass=$((pass+1));
else echo "  FAIL archive is $sz bytes - a cache got in"; fail=$((fail+1)); fi

echo "2b. a symlink inside userdata is stored as a link, not followed"
# This is the hazard that OOM-killed the library sync: a symlink pointing at a
# parent makes the walk archive the whole tree again, or recurse. tar -h here
# would inline 45 MB of cache through the link.
reset; make_login
ln -sfn "$T/home/$SD" "$T/home/$SD/userdata/12345678/steamroot"
rm -f "$T/remote/account.tgz"; run account push >/dev/null
contains "the link is a member"  "$(members)" "userdata/12345678/steamroot"
lacks    "but nothing under it"  "$(members)" "steamroot/config"
sz=$(stat -c %s "$T/remote/account.tgz")
if (( sz < 1048576 )); then echo "  ok   still small ($sz bytes) - the link was not followed"; pass=$((pass+1));
else echo "  FAIL archive ballooned to $sz bytes - tar followed the symlink"; fail=$((fail+1)); fi
rm -f "$T/home/$SD/userdata/12345678/steamroot"; rm -f "$T/remote/account.tgz"; run account push >/dev/null

echo "3. a logged-OUT box does not overwrite a good saved login"
# The failure this prevents: boot a box, never sign in, destroy it, and the
# push replaces a working archived login with an empty one.
reset; before=$(md5sum < "$T/remote/account.tgz")
# The shape of the real 2026-09-14 failure: a signed-out Steam still writes a
# large config.vdf, so "config.vdf is non-empty" is no evidence of a login.
rm -rf "$T/home"; mkdir -p "$T/home/$SD/config" "$T/home/.steam"
head -c 21676 /dev/zero | tr '\0' 'x' > "$T/home/$SD/config/config.vdf"
echo 'registry' > "$T/home/.steam/registry.vdf"
printf '"MachineUserConfigStore"\n{\n}\n' > "$T/home/$SD/local.vdf"
out=$(run account push)
contains "explains itself"     "$out" "not signed in"
check    "archive is untouched" "$(md5sum < "$T/remote/account.tgz")" "$before"

echo "4. pull restores it onto a fresh box"
reset; rm -rf "$T/home"
out=$(run account pull)
contains "says so"          "$out" "steam account: restored"
check "token is back"       "$(cat "$T/home/$SD/config/config.vdf" 2>/dev/null)" "refresh_token_here"
check "machine id is back"  "$(cat "$T/home/.steam/registry.vdf" 2>/dev/null)" "registry"
check "token store is back" "$(grep -c '"ConnectCache"' "$T/home/$SD/local.vdf" 2>/dev/null)" "1"

echo "5. the restored token is 0600, and .steam/steam is recreated"
# Steam refuses a config.vdf that other users can read, and .steam/steam is a
# symlink so it cannot be in the tarball - it has to be made on extract.
check "mode" "$(stat -c %a "$T/home/$SD/config/config.vdf" 2>/dev/null)" "600"
check "token store mode" "$(stat -c %a "$T/home/$SD/local.vdf" 2>/dev/null)" "600"
if [[ -L "$T/home/.steam/steam" ]]; then echo "  ok   symlink recreated"; pass=$((pass+1));
else echo "  FAIL .steam/steam missing - Steam cannot find its own root"; fail=$((fail+1)); fi

echo "6. a running Steam is asked to exit first, then archived anyway"
reset; make_login; touch "$T/up"
out=$(run account push)
contains "asks Steam to exit"    "$out" "asking Steam to exit"
contains "archives after it"     "$out" "steam account: archived"
# It waited for Steam to actually go, rather than firing -shutdown and racing it.
lacks "did not give up on it"    "$out" "still running - archiving the file as it stands"
if [[ ! -f $T/up ]]; then echo "  ok   Steam was shut down, not ignored"; pass=$((pass+1));
else echo "  FAIL Steam never exited"; fail=$((fail+1)); fi

echo "6b. a Steam that refuses to exit is archived anyway, and says so"
# Losing the login because a process would not die is the wrong trade: the file
# on disk is almost always the valid token already.
reset; make_login; touch "$T/up"
out=$(CG_STEAM_SHUTDOWN=0 run account push)
contains "notes the risk" "$out" "still running"
contains "archives anyway" "$out" "steam account: archived"

echo "7. pull will not overwrite the login of a running Steam"
reset; make_login; touch "$T/up"; echo 'LIVE_SESSION' > "$T/home/$SD/config/config.vdf"
out=$(run account pull)
contains "refuses"        "$out" "Steam is running"
check "live file intact"  "$(cat "$T/home/$SD/config/config.vdf")" "LIVE_SESSION"

echo "7b. a full restore brings the login back, not just a direct account pull"
# The hook, not the function: dropping account_pull from cmd_pull left every
# direct-call case green while a real boot came up logged out.
reset; rm -rf "$T/home"; rm -rf "$T/scratch/steam"; mkdir -p "$T/scratch/steam/steamapps"
out=$(run pull --apps none)
contains "the restore mentions it" "$out" "steam account: restored"
check "and the token is on disk"   "$(cat "$T/home/$SD/config/config.vdf" 2>/dev/null)" "refresh_token_here"

echo "8. the login is pushed even when no games are installed"
# The boot most likely to have a NEW login is the one used for something else.
reset; make_login; rm -f "$T/remote/account.tgz"
rm -rf "$T/scratch/steam"; mkdir -p "$T/scratch/steam/steamapps"
echo "boot-aaaa" > "$T/state/restored"
out=$(run push)
contains "no games to push"    "$out" "no games installed"
contains "but the login is"    "$out" "steam account: archived"
if [[ -f $T/remote/account.tgz ]]; then echo "  ok   it reached the archive"; pass=$((pass+1));
else echo "  FAIL nothing uploaded"; fail=$((fail+1)); fi

echo "9. the login is pushed even when the games guard refuses the push"
# restored-this-boot protects the GAME archive from a partial copy. The login
# has no such hazard, and blocking it would lose a real login to an unrelated rule.
reset; make_login; rm -f "$T/remote/account.tgz" "$T/state/restored"
out=$(run push); rc=$?
check    "push still fails"   "$rc" "1"
contains "for the games"      "$out" "was not restored on this boot"
contains "login saved first"  "$out" "steam account: archived"

echo "10. a failed upload never claims success"
reset; make_login
out=$(UPLOAD_FAILS=1 run account push)
contains "says it failed" "$out" "upload failed"
lacks    "no false claim"  "$out" "steam account: archived"

echo "11. pull on an empty archive explains, and does not fail the restore"
reset; rm -f "$T/remote/account.tgz"; rm -rf "$T/home"
out=$(run account pull); rc=$?
check    "exits clean" "$rc" "0"
contains "explains"    "$out" "none archived yet"

echo "12. status reports whether a new box will start signed in"
reset; make_login
out=$(run status); contains "warns when absent" "$out" "NOT archived"
run account push >/dev/null
out=$(run status); contains "confirms when present" "$out" "steam login archived"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
