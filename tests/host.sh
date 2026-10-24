#!/usr/bin/env bash
# Your own machines (lib/host.sh): added, set up and streamed from over ssh -
# with the same build and the same second half as the AWS box.
#
# Driven against a fake machine - ssh, tailscale, curl and moonlight are fakes
# on PATH - so nothing here reaches a network or installs anything. What it
# holds cg to: the machine's own facts decide everything, the build is the one
# every machine gets, nothing is set up on a system cg cannot set up, and no
# secret ever rides on a command line.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_RUNTIME_DIR="$T/run" T
mkdir -p "$XDG_RUNTIME_DIR"

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

# The machine: its facts in $T/facts, as the read-only facts script prints them.
facts() { cat > "$T/facts"; }
LINUX='os=Linux
id=cachyos
id_like=arch
version_id=
codename=
pretty=CachyOS Linux
arch=x86_64
user=player
gpu=NVIDIA GeForce RTX 4070
nvidia=NVIDIA GeForce RTX 4070
render=/dev/dri/renderD128
sudo=nopass
tailscale=
ts_ip=
sunshine=
steam=/usr/bin/steam
session=wayland'

# ssh: every call logged with its arguments (never stdin). What the machine does
# is decided by the command it is given. Starting the build stands in for the
# build itself: it joins the tailnet, writes its log and its ready marker. A
# call handed cg's own stdin - where the app's answers arrive - is logged too:
# only data piped on purpose may reach ssh.
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/ssh.log"
[[ -n ${HOST_DOWN:-} ]] && exit 255
cmd="${*: -1}"
# The one login by password: the password comes from SSH_ASKPASS, as ssh would
# get it, and only the right one puts cg's key on the machine.
if [[ $* == *PubkeyAuthentication=no* ]]; then
  [[ $("$SSH_ASKPASS") == letmein ]] || exit 255
  [[ -n ${NOSTICK:-} ]] && exit 3
  printf '%s\n' "$cmd" > "$T/install.cmd"; touch "$T/keyed"; exit 0
fi
case $cmd in "sh -s"|*mktemp*|*"sudo -S"*) ;;
  *) [[ $(readlink /proc/self/fd/0) == /dev/null ]] || echo "STDIN-OPEN $cmd" >> "$T/stdin.log" ;; esac
case $cmd in
  exit) [[ -n ${KEYLESS:-} && ! -f $T/keyed ]] && exit 255; exit 0 ;;
  "sh -s") cat > /dev/null; [[ -n ${WINDOWS:-} ]] && exit 127; cat "$T/facts" ;;
  ver) [[ -n ${WINDOWS:-} ]] && echo "Microsoft Windows [Version 10.0.22631]" || exit 127 ;;
  *mktemp*) n=$(( $(ls "$T"/script-* 2>/dev/null | wc -l) + 1 )); cat > "$T/script-$n"; echo "/tmp/script-$n" ;;
  *"sudo -S -p"*" -v"*) IFS= read -r pw; [[ $pw == hunter2 ]] ;;
  *"setsid nohup bash"*)
    if [[ $cmd == *"sudo -S"* ]]; then IFS= read -r pw; printf '%s' "$pw" > "$T/sudo-stdin"; fi
    echo "STARTED $cmd" >> "$T/root.log"
    sed -i 's/^ts_ip=.*/ts_ip=100.64.0.9/; s/^tailscale=$/tailscale=\/usr\/bin\/tailscale/; s/^sunshine=$/sunshine=\/usr\/bin\/sunshine/' "$T/facts"
    printf '>>> installing sunshine\n>>> ok: sunshine installed\nbootstrap complete\n' > "$T/buildlog"
    touch "$T/ready" ;;
  *"sudo -n sh -c"*) echo "STARTED $cmd" >> "$T/root.log"
    sed -i 's/^ts_ip=.*/ts_ip=100.64.0.9/; s/^tailscale=$/tailscale=\/usr\/bin\/tailscale/; s/^sunshine=$/sunshine=\/usr\/bin\/sunshine/' "$T/facts"
    printf '>>> installing sunshine\n>>> ok: sunshine installed\nbootstrap complete\n' > "$T/buildlog"
    touch "$T/ready" ;;
  *"tail -n +1 /var/log/cloud-gaming-bootstrap.log"*) cat "$T/buildlog" 2>/dev/null ;;
  *"tail -n +"*) : ;;
  *cloud-gaming-ready*) [[ -f $T/ready ]] && { echo READY; exit 0; }; exit 1 ;;
  *steam-prewarmed*) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
# This laptop's tailnet: the machine is on it at 100.64.0.9 once it has joined.
cat > "$T/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
case $1 in
  status) grep -q '^ts_ip=100.64.0.9' "$T/facts" && echo "100.64.0.9  mypc  player@  linux  -" ;;
  ping) [[ -z ${PING_FAIL:-} ]] ;;
esac
FAKE
# Sunshine on the machine: first run until a password is set; the login checked.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
auth="" data="" url=""
while (( $# )); do case $1 in -u) auth=$2; shift 2 ;; -d) data=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac; done
case $url in
  */welcome) [[ -s $T/box ]] && echo 401 || echo 200 ;;
  */api/password) p=$(sed -n 's/.*"newPassword":"\([^"]*\)".*/\1/p' <<<"$data"); printf 'admin %s' "$p" > "$T/box"; echo '{"status":true}' ;;
  */api/clients/list) [[ -s $T/box && "$(tr ' ' ':' < "$T/box")" == "$auth" ]] && echo 200 || echo 401 ;;
esac
FAKE
cat > "$T/bin/moonlight" <<'FAKE'
#!/usr/bin/env bash
case $1 in list) echo "Desktop" ;; stream) echo "STREAM $*" >> "$T/stream.log" ;; esac
FAKE
chmod +x "$T/bin/"*

cgh() { # cgh <args...> - cmd_host, as cg runs it
  : > "$T/ssh.log"
  ( export PATH="$T/bin:$PATH" TS_HOST=gamevps CG_COLOR=never CG_SLEEP_PCT=1 ${EXTRA:-}
    source lib/common.sh; source lib/session.sh; source lib/host.sh
    cmd_host "$@" ) 2>&1
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]].get(sys.argv[3], ""))' \
            "$XDG_CONFIG_HOME/cg/hosts.json" "$1" "$2" 2>/dev/null; }
fresh() { rm -f "$T"/script-* "$T/root.log" "$T/ready" "$T/buildlog" "$T/stdin.log" "$T/sudo-stdin"; : > "$T/box"; }

echo "1. adding a machine"
facts <<<"$LINUX"
contains "a bad name is refused"           "$(cgh add My_PC --ssh player@pc)" "lowercase letters"
contains "the AWS boxes' name is refused"  "$(cgh add gamevps-1 --ssh player@pc)" "clean-up would delete it"
out=$(timeout 10 bash -c 'cd "$1" && source lib/common.sh && source lib/session.sh && source lib/host.sh && cmd_host add mypc --ssh' _ "$PWD" 2>&1); rc=$?
check    "--ssh with no address does not hang"    "$([[ $rc == 124 ]] && echo hung || echo ended)" "ended"
contains "  it says how to use it"              "$out" "usage: cg host add [name] --ssh <user@address>"
contains "no key-based ssh, a clear way out" "$(HOST_DOWN=1 cgh add mypc --ssh player@pc)" "ssh-copy-id player@pc"
out=$(cgh add mypc --ssh player@pc)
contains "it says what the machine is"     "$out" "CachyOS Linux (x86_64), signed in as player"
contains "  and its GPU"                   "$out" "NVIDIA GeForce RTX 4070"
check    "CachyOS is set up as Arch, from os-release" "$(field mypc family)" "arch"
check    "the file is yours alone"          "$(stat -c %a "$XDG_CONFIG_HOME/cg/hosts.json")" "600"
# Writers side by side - a setup saving its Sunshine login while another
# command writes: every one of them lands, none is lost to the other's replace.
( source lib/common.sh; source lib/host.sh
  for i in $(seq 1 20); do host_set mypc "race$i" "v$i" & done; wait )
check    "twenty writers at once: all twenty kept" \
         "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["mypc"]; print(sum(1 for i in range(1,21) if d.get("race%d" % i) == "v%d" % i))' "$XDG_CONFIG_HOME/cg/hosts.json")" "20"
check    "  and what was there stays"       "$(field mypc family)" "arch"
check    "  no temp files left behind"      "$(ls -A "$XDG_CONFIG_HOME/cg" | grep -c '^\.hosts\.\|\.new$')" "0"
check    "several fields, one write"        "$( (source lib/common.sh; source lib/host.sh; host_set mypc a 1 b 2); field mypc a)$(field mypc b)" "12"

echo "1b. the first time, with the machine's password"
# A server that takes passwords and has no key of cg's yet: its password once,
# then cg's own key for good. Named after itself when no name is given.
facts <<<"$LINUX
hostname=Living-Room.local"
rm -f "$T/keyed" "$T/install.cmd"
out=$(printf 'nope\n' | EXTRA="KEYLESS=1 CG_JSON=1" cgh add --ssh me@server)
contains "a wrong password is said plainly"   "$out" "did not let cg in with that password"
check    "  and nothing is added"             "$(field living-room ssh)" ""
out=$(printf 'letmein\n' | EXTRA="KEYLESS=1 CG_JSON=1" cgh add --ssh me@server)
contains "the password is asked for"          "$out" '"id":"host-ssh-password"'
contains "  and hidden"                       "$out" '"secret":1'
contains "cg's own key goes on the machine"   "$(cat "$T/install.cmd")" "$(cut -d' ' -f1,2 "$XDG_CONFIG_HOME/cg/ssh/id_ed25519.pub")"
check    "  a key of its own, in a private place" "$(stat -c %a "$XDG_CONFIG_HOME/cg/ssh")" "700"
lacks    "the password is on no command line" "$(cat "$T/ssh.log")" "letmein"
contains "it is named after its own hostname" "$out" "added 'living-room'"
check    "  and saved"                        "$(field living-room ssh)" "me@server"
check    "every later ssh uses cg's key"      "$(grep -v PubkeyAuthentication=no "$T/ssh.log" | grep -vc -- "-i $XDG_CONFIG_HOME/cg/ssh/id_ed25519")" "0"
rm -f "$T/ssh.log"
out=$(printf 'letmein\n' | EXTRA="KEYLESS=1 CG_JSON=1" cgh add --ssh me@server)
contains "the same address twice is refused"  "$out" "me@server is already added, as 'living-room'"
check    "  before a password is asked"       "$(cat "$T/ssh.log" 2>/dev/null | grep -c PubkeyAuthentication=no)" "0"
# The same machine by another address and another name: its IP once, its
# tailnet name now. It was added twice - two cards, two of cg's keys on it.
facts <<<"$LINUX
hostname=Living-Room.local
machine_id=0123456789abcdef0123456789abcdef"
EXTRA="CG_JSON=1" cgh add den --ssh me@den >/dev/null
check    "who a machine is, kept as a hash"   "$(field den machine)" "$(printf 0123456789abcdef0123456789abcdef | sha256sum | cut -c1-16)"
lacks    "  never the raw id"                 "$(cat "$XDG_CONFIG_HOME/cg/hosts.json")" "0123456789abcdef0123456789abcdef"
out=$(EXTRA="CG_JSON=1" cgh add study --ssh me@100.64.0.9)
contains "the same machine by another address is refused" "$out" "a machine already added, as 'den'"
check    "  and not added"                    "$(field study ssh)" ""
cgh remove den >/dev/null
out=$(cgh remove living-room)
contains "removing it takes cg's key off"     "$out" "took cg's key off it"
contains "  that one line, nothing else"      "$(cat "$T/ssh.log")" "grep -vxF"
# A key whose public half came out empty: made again from the private key, so
# what goes on the machine is a key and never an empty line.
k="$XDG_CONFIG_HOME/cg/ssh/id_ed25519"; want=$(cut -d' ' -f1,2 "$k.pub"); : > "$k.pub"
rm -f "$T/keyed" "$T/install.cmd"
printf 'letmein\n' | EXTRA="KEYLESS=1 CG_JSON=1" cgh add --ssh me@server >/dev/null
contains "an empty .pub is made again from the key" "$(cat "$T/install.cmd")" "$want"
check    "  the same key, not a new one"      "$(cut -d' ' -f1,2 "$k.pub")" "$want"
contains "  and the line is read back there"  "$(cat "$T/install.cmd")" "|| exit 3"
cgh remove living-room >/dev/null
rm -f "$T/keyed"
out=$(printf 'letmein\n' | EXTRA="KEYLESS=1 NOSTICK=1 CG_JSON=1" cgh add --ssh me@server)
contains "a line that does not stay is said plainly" "$out" "did not stay in its ~/.ssh/authorized_keys"
lacks    "  not blamed on sshd_config"        "$out" "PubkeyAuthentication"
check    "  and nothing is added"             "$(field living-room ssh)" ""
cgh add --ssh me@server >/dev/null
out=$(HOST_DOWN=1 cgh remove living-room)
contains "unreachable: it says the line stays" "$out" "that one line stays"
check    "  and forgets it all the same"      "$(field living-room ssh)" ""
facts <<<"$LINUX"

echo "2. what cg will not set up"
EXTRA="WINDOWS=1" cgh add winpc --ssh me@win >/dev/null
check    "Windows is recognised"           "$(field winpc os)" "Windows"
contains "  and setting it up is refused, plainly" "$(EXTRA="WINDOWS=1" cgh setup winpc)" "Windows machine up is not built yet"
facts <<<"$(sed 's/^id=cachyos/id=void/; s/^id_like=arch/id_like=/' <<<"$LINUX")"
cgh add voidbox --ssh me@void >/dev/null; fresh
contains "an unknown distribution is refused" "$(cgh setup voidbox)" "is not one"
check    "  and nothing was started there"  "$(cat "$T/root.log" 2>/dev/null | wc -l)" "0"

echo "3. the build is the one every machine gets"
facts <<<"$LINUX"; fresh
out=$(EXTRA="TAILSCALE_AUTH_KEY=tskey-auth-SECRETKEY" cgh setup mypc)
build=$(cat "$T/script-1" 2>/dev/null)
contains "the shared modules, assembled by lib/render.sh" "$build" "aws_box()"
contains "  as a machine of yours"         "$build" 'CG_TARGET="host"'
contains "  your user, not the AWS box's"  "$build" 'USER_NAME="player"'
contains "  your distribution"             "$build" 'FAMILY="arch"'
check    "  every placeholder filled"      "$(grep -c '__[A-Z0-9_]*__' <<<"$build")" "0"
contains "it is started detached, as root" "$(cat "$T/root.log")" "sudo -n sh -c"
contains "  and its log followed, as an AWS build's is" "$out" "sunshine installed"
contains "the Sunshine login is made"      "$out" "created; credentials saved"
check    "  and kept for this machine"     "$(field mypc sunshine_pass)" "$(cut -d' ' -f2 "$T/box")"
contains "it joins the tailnet"            "$out" "on the tailnet at 100.64.0.9"
contains "pairing"                         "$out" "already paired"
contains "ready, and how to play"          "$out" "ready: cg host open mypc"
lacks    "the auth key never rides on an ssh command line" "$(cat "$T/ssh.log")" "SECRETKEY"
contains "  it is inside the build file, which deletes itself" "$build" 'if [ "$CG_TARGET" = host ]; then rm -f "$0"; fi'

echo "3b. a derivative is built as the release underneath it"
# Linux Mint 22.2 is Ubuntu 24.04: its own version would have picked a Sunshine
# package that does not exist ("+ubuntu22.2").
facts <<<"$(sed 's/^id=cachyos/id=linuxmint/; s/^id_like=arch/id_like=ubuntu debian/; s/^version_id=/version_id=22.2/; s/^pretty=.*/pretty=Linux Mint 22.2/' <<<"$LINUX")
ubuntu_version=24.04"
cgh add mint --ssh me@mint >/dev/null; fresh
check    "Mint is Ubuntu"                  "$(field mint family)" "ubuntu"
EXTRA="TAILSCALE_AUTH_KEY=tskey-auth-x" cgh setup mint >/dev/null
contains "  built as Ubuntu"               "$(cat "$T/script-1" 2>/dev/null)" 'FAMILY="ubuntu"'
facts <<<"$(sed 's/^id=cachyos/id=linuxmint/; s/^id_like=arch/id_like=ubuntu debian/' <<<"$LINUX")"
contains "an Ubuntu base it cannot read is said, not guessed" "$(cgh setup mint)" "which Ubuntu release it is could not be read"
cgh remove mint >/dev/null
check    "the GPU is told by device class, not the PCI address" \
         "$(printf '00:02.0 VGA compatible controller: Intel UHD 620\n3d:00.0 Non-Volatile memory controller: Lenovo NVMe\n' \
            | grep -E " (VGA compatible|3D|Display) controller: " | sed -E "s/^[0-9a-f:.]+ [^:]+: //")" "Intel UHD 620"

echo "4. a machine that wants a sudo password"
facts <<<"$(sed 's/^sudo=nopass/sudo=password/' <<<"$LINUX")"; fresh
out=$(printf 'hunter2\n' | EXTRA="CG_JSON=1 TAILSCALE_AUTH_KEY=tskey-auth-SECRETKEY" cgh setup mypc)
contains "it is asked for"                 "$out" '"id":"host-sudo"'
check    "  once"                          "$(grep -c '"id":"host-sudo"' <<<"$out")" "1"
check    "  handed to sudo on the machine's stdin" "$(cat "$T/sudo-stdin" 2>/dev/null)" "hunter2"
lacks    "  never on a command line"       "$(cat "$T/ssh.log")" "hunter2"
lacks    "  never saved"                   "$(cat "$XDG_CONFIG_HOME/cg/hosts.json")" "hunter2"
check    "no other ssh call is handed cg's stdin, where the app's answers arrive" "$(cat "$T/stdin.log" 2>/dev/null | wc -l)" "0"
fresh
out=$(printf 'wrong\n' | EXTRA="CG_JSON=1" cgh setup mypc)
contains "a wrong password is said at once" "$out" "sudo did not accept that password"
check    "  and nothing was started"       "$(cat "$T/root.log" 2>/dev/null | wc -l)" "0"

echo "4b. a machine not on the tailnet, and no key for it yet"
# The key is asked for only here: a machine that is on the tailnet already is
# never asked for one, and one that is not joins with a key pasted now - saved,
# as every later build of a machine uses the same reusable key.
facts <<<"$LINUX"; fresh
out=$(printf 'tskey-auth-PASTED\n' | EXTRA="CG_JSON=1 CG_ENV_FILE=$T/env" cgh setup mypc)
contains "it is asked for, as the app's own question" "$out" '"id":"tailscale-auth-key"'
contains "  saying why"                    "$out" "mypc is not on your tailnet yet"
check    "  saved for next time"           "$(grep -c '^TAILSCALE_AUTH_KEY=tskey-auth-PASTED$' "$T/env")" "1"
contains "  and the build joins with it"   "$(cat "$T/script-1" 2>/dev/null)" "tskey-auth-PASTED"
lacks    "  never on an ssh command line"  "$(cat "$T/ssh.log")" "PASTED"
facts <<<"$LINUX"; fresh; rm -f "$T/env"
out=$(EXTRA="CG_ENV_FILE=$T/env" cgh setup mypc </dev/null)
contains "nobody to ask: said plainly"     "$out" "not on your tailnet, and there is no Tailscale auth key"
check    "  and nothing was started"       "$(cat "$T/root.log" 2>/dev/null | wc -l)" "0"
facts <<<"$LINUX"; sed -i 's/^ts_ip=.*/ts_ip=100.64.0.9/' "$T/facts"; fresh; rm -f "$T/env"
out=$(EXTRA="CG_JSON=1 CG_ENV_FILE=$T/env" cgh setup mypc </dev/null)
lacks    "on the tailnet already: never asked" "$out" '"id":"tailscale-auth-key"'
contains "  and set up all the same"       "$(cat "$T/root.log" 2>/dev/null)" "STARTED"

echo "5. the build steps of the AWS box that a machine of yours never runs"
for m in 12-scratch 15-watchdog 22-library 50-xorg 80-firefox; do
  check "  $m only on the AWS box" "$(grep -c '^if aws_box; then' "lib/bootstrap.d/$m.sh")" "1"
done
# Arch: no partial upgrade. The lists are never refreshed without the upgrade,
# which is the machine owner's to run - asked for, plainly, when it is needed.
# Sunshine is found where it is, the same way for the install and its check.
sun() { # sun <where native lives, or -> <flatpak app or -> -> native=? flatpak=?
  local d; d=$(mktemp -d); mkdir -p "$d/bin" "$d/usr/bin" "$d/usr/local/bin"
  [[ $1 != - ]] && { printf '#!/bin/sh\n' > "$d$1"; chmod +x "$d$1"; }
  printf '#!/bin/sh\n[ "%s" = - ] || echo "%s"\n' "$2" "$2" > "$d/bin/flatpak"; chmod +x "$d/bin/flatpak"
  printf '#!/bin/sh\nshift 2; exec "$@"\n' > "$d/bin/sudo"; chmod +x "$d/bin/sudo"
  ( fns=$(sed -nE '/^sunshine_native\(\)/p;/^sunshine_flatpak\(\)/,/^}/p' lib/bootstrap.d/95-sunshine.sh)
    fns=${fns//\/usr\/bin/$d\/usr\/bin}; fns=${fns//\/usr\/local\/bin/$d\/usr\/local\/bin}
    ln -s "$(command -v grep)" "$d/bin/grep"
    # Only the sandbox on PATH: this machine's own Sunshine must not answer.
    PATH="$d/bin" USER_NAME=player "$BASH" -c "$fns"'
    sunshine_native && n=yes || n=no; sunshine_flatpak && f=yes || f=no; echo "native=$n flatpak=$f"' )
  rm -rf "$d"
}
check    "a build in /usr/local/bin is Sunshine"  "$(sun /usr/local/bin/sunshine -)" "native=yes flatpak=no"
check    "  as is the package's /usr/bin"         "$(sun /usr/bin/sunshine -)" "native=yes flatpak=no"
check    "the Flatpak is seen, not doubled"       "$(sun - dev.lizardbyte.app.Sunshine)" "native=no flatpak=yes"
check    "  and nothing is nothing"               "$(sun - -)" "native=no flatpak=no"
contains "a Flatpak alone stops setup, plainly"   "$(cat lib/bootstrap.d/95-sunshine.sh)" "Sunshine is installed here as a Flatpak"
contains "the check is the install's own test"    "$(cat lib/bootstrap.d/95-sunshine.sh)" 'verify "sunshine binary installed" sunshine_native'
# The build view says "reboots" only for the AWS box - told so by the build,
# not guessed from the key (a machine of yours has cg's key too).
contains "a machine of yours is said to be one"   "$(cat lib/host.sh)" 'BUILD_NAME="$name" BUILD_TARGET=host'
contains "  and the view asks that, not the key"  "$(cat lib/common.sh)" '${BUILD_TARGET:-aws} == host'
lacks    "  no guess from an empty key left"      "$(cat lib/common.sh)" '"finishing up" && -z $key'
# Steam as the user has it, asked as root: Ubuntu's /usr/games, and a Flatpak
# of the user's own.
stm() { # stm <path or -> <user flatpak yes|no> -> present|absent
  local d; d=$(mktemp -d); mkdir -p "$d/bin" "$d/usr/games" "$d/usr/bin" "$d/usr/local/bin"
  [[ $1 != - ]] && { printf '#!/bin/sh\n' > "$d$1"; chmod +x "$d$1"; }
  printf '#!/bin/sh\ncase "$*" in *--user*) [ "%s" = yes ] ;; *) exit 1 ;; esac\n' "$2" > "$d/bin/flatpak"
  printf '#!/bin/sh\nshift 2; exec "$@"\n' > "$d/bin/sudo"; chmod +x "$d/bin/"*
  ( fn=$(sed -nE '/^steam_present\(\)/,/^}/p' lib/bootstrap.d/70-steam-pkg.sh)
    fn=${fn//\/usr\/games/$d\/usr\/games}; fn=${fn//\/usr\/local\/bin/$d\/usr\/local\/bin}; fn=${fn//\/usr\/bin/$d\/usr\/bin}
    PATH="$d/bin" USER_NAME=player "$BASH" -c "$fn"'
    steam_present && echo present || echo absent' )
  rm -rf "$d"
}
check    "Ubuntu's Steam in /usr/games is Steam, asked as root" "$(stm /usr/games/steam no)" "present"
check    "  as is the user's own Flatpak"           "$(stm - yes)" "present"
check    "  and nothing is nothing"                 "$(stm - no)" "absent"
# One copy of what release a machine is: the build's, which the facts include.
check    "the Ubuntu release is told in one place"  "$(grep -rl 'upstream-release/lsb-release' lib cg | tr '\n' ' ')" "lib/bootstrap.d/01-release.sh "
contains "  the Sunshine package asks it"           "$(cat lib/bootstrap.d/95-sunshine.sh)" 'uv=$(ubuntu_release)'
contains "  and so do the facts, with its own text" "$(cat lib/host.sh)" "grep -vE '^[[:space:]]*#' lib/bootstrap.d/01-release.sh"
check    "  read when the facts are asked, not when cg loads" "$(bash -c 'cd /tmp && source "$1/lib/common.sh" >/dev/null 2>&1; source "$1/lib/host.sh" 2>&1 | wc -l' _ "$PWD")" "0"
check    "the Sunshine login is loaded once in a build" "$(grep -c '^ *source lib/sunshine-login.sh' lib/build.sh)" "1"
check    "no pacman -Sy anywhere in the build" "$(grep -rhE 'pacman -Sy( |$)' lib/bootstrap.d | grep -vc 'run sudo pacman -Syu')" "0"
contains "an install the old lists cannot make asks for an upgrade" "$(cat lib/bootstrap.d/00-header.sh)" "run sudo pacman -Syu, then run setup again"
contains "multilib off is asked of you, not switched on behind your back" "$(cat lib/bootstrap.d/70-steam-pkg.sh)" "uncomment [multilib] in /etc/pacman.conf, run sudo pacman -Syu"
check    "it is never rebooted by the build" \
         "$(awk '/^if aws_box; then/{a=1} /^else/{a=0} /^\s*reboot\s*$/{print a}' lib/bootstrap.d/99-finish.sh)" "1"

echo "6. status, list, open, remove"
facts <<<"$LINUX"; sed -i 's/^ts_ip=.*/ts_ip=100.64.0.9/' "$T/facts"
printf 'admin %s' "$(field mypc sunshine_pass)" > "$T/box"   # the machine as setup left it
j=$(cgh status mypc --json)
check    "status is data"                  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["online"], d["sunshine"], d["login_ok"], d["paired"], d["set_up"])' <<<"$j")" "True True True True True"
check    "  named as it names itself"      "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["os_name"])' <<<"$j")" "CachyOS Linux"
# One unanswered tailscale ping beside a Sunshine that answered at the tailnet
# address: the real home server, whose card said "not connected" beside Play.
check    "Sunshine at its tailnet address means it is on the tailnet" \
         "$(PING_FAIL=1 cgh status mypc --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["online"])')" "True"
sed -i 's/^nvidia=.*/nvidia=/' "$T/facts"
check    "no NVIDIA card: the GPU lspci names" \
         "$(cgh status mypc --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["gpu"])')" "$(sed -n 's/^gpu=//p' <<<"$LINUX" | cut -d';' -f1)"
facts <<<"$LINUX"; sed -i 's/^ts_ip=.*/ts_ip=100.64.0.9/' "$T/facts"
lacks    "the list carries no password"    "$(cgh list --json)" "sunshine_pass"
contains "  but every machine"             "$(cgh list --json)" '"name": "mypc"'
cgh open mypc >/dev/null
contains "it streams from the machine's tailnet address" "$(cat "$T/stream.log")" "stream"
contains "  at 100.64.0.9"                 "$(cat "$T/stream.log")" "100.64.0.9 Desktop"
# As cg runs it: a process whose command line is cg's, which is the only kind
# the session lock believes - the test shell above is not one, and that is how
# a session that ended by killing itself went unseen.
cat > "$T/cg-open" <<'RUN'
source lib/common.sh; source lib/session.sh; source lib/host.sh; cmd_host open mypc
RUN
( export PATH="$T/bin:$PATH" TS_HOST=gamevps CG_COLOR=never; bash "$T/cg-open" >/dev/null 2>&1 ); rc=$?
check    "a session that ends normally exits 0, not killed by its own lock" "$rc" "0"
check    "  and leaves no lock behind"     "$(ls "$XDG_RUNTIME_DIR"/cg-session-*.pid 2>/dev/null | wc -l)" "0"
contains "forgetting changes nothing else there" "$(cgh remove mypc)" "nothing else on the machine was changed"
check    "  and it is gone here"           "$(field mypc ssh)" ""

echo "7. one Play for every machine"
check    "the stream is the AWS box's and yours alike" \
         "$(grep -c 'stream_play "\$ip"' lib/game lib/host.sh | grep -c ':1')" "2"
check    "  and neither runs Moonlight itself"  "$(grep -c 'moonlight stream' lib/game lib/host.sh | grep -vc ':0')" "0"
contains "cg open --on <name> is your machine" "$(cat cg)" 'cmd_host_open "${2:-}"'
contains "cg status --on <name> too"          "$(cat cg)" 'cmd_host_status "${2:-}"'

echo; echo "host: $pass passed, $fail failed"
(( fail == 0 ))
