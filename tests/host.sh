#!/usr/bin/env bash
# Your own machines (lib/host.sh): added, set up and streamed from over ssh.
#
# Driven against a fake machine - ssh, tailscale, curl and moonlight are fakes
# on PATH - so nothing here reaches a network or installs anything. What it
# holds cg to: the machine's own facts decide everything, nothing is set up on
# a system cg cannot set up, and no secret ever rides on a command line.
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
gpu=NVIDIA Corporation AD104 [GeForce RTX 4070]
nvidia=NVIDIA GeForce RTX 4070
render=/dev/dri/renderD128
sudo=nopass
tailscale=
ts_ip=
sunshine=
steam=/usr/bin/steam
session=wayland'

# ssh: every call logged with its arguments (never stdin). What the machine does
# is decided by the command it is given. A call handed cg's own stdin - where
# the app's answers arrive - is logged too: only data piped on purpose may reach
# ssh.
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/ssh.log"
case "${*: -1}" in "sh -s"|*mktemp*|*"sudo -S"*) ;;
  *) [[ $(readlink /proc/self/fd/0) == /dev/null ]] || echo "STDIN-OPEN ${*: -1}" >> "$T/stdin.log" ;; esac
[[ -n ${HOST_DOWN:-} ]] && exit 255
cmd="${*: -1}"
case $cmd in
  exit) exit 0 ;;
  "sh -s") cat > /dev/null; [[ -n ${WINDOWS:-} ]] && exit 127; cat "$T/facts" ;;
  ver) [[ -n ${WINDOWS:-} ]] && echo "Microsoft Windows [Version 10.0.22631]" || exit 127 ;;
  *mktemp*) n=$(( $(ls "$T"/script-* 2>/dev/null | wc -l) + 1 )); cat > "$T/script-$n"; echo "/tmp/script-$n" ;;
  *"sudo -S -p"*" -v"*) IFS= read -r pw; [[ $pw == "${GOOD_PW:-hunter2}" ]] ;;
  *"sudo -S"*) IFS= read -r pw; printf '%s' "$pw" > "$T/sudo-stdin"; echo "SUDO -S" >> "$T/root.log"
               f=$(grep -o "/tmp/script-[0-9]*" <<<"$cmd" | head -1); grep -q "tailscale up" "$T/${f#/tmp/}" && sed -i 's/^ts_ip=.*/ts_ip=100.64.0.9/' "$T/facts"
               sed -i 's/^tailscale=$/tailscale=\/usr\/bin\/tailscale/; s/^sunshine=$/sunshine=\/usr\/bin\/sunshine/' "$T/facts"
               echo ">>> ok: root steps done" ;;
  *"sudo -n"*) echo "SUDO -n" >> "$T/root.log"
               f=$(grep -o "/tmp/script-[0-9]*" <<<"$cmd" | head -1); grep -q "tailscale up" "$T/${f#/tmp/}" && sed -i 's/^ts_ip=.*/ts_ip=100.64.0.9/' "$T/facts"
               sed -i 's/^tailscale=$/tailscale=\/usr\/bin\/tailscale/; s/^sunshine=$/sunshine=\/usr\/bin\/sunshine/' "$T/facts"
               echo ">>> ok: root steps done" ;;
  *) exit 0 ;;
esac
FAKE
# This laptop's tailnet: the machine is on it at 100.64.0.9 once it has joined.
cat > "$T/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
case $1 in
  status) grep -q '^ts_ip=100.64.0.9' "$T/facts" && echo "100.64.0.9  mypc  player@  linux  -" ;;
  ping) exit 0 ;;
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
  ( export PATH="$T/bin:$PATH" TS_HOST=gamevps CG_COLOR=never ${EXTRA:-}
    source lib/common.sh; source lib/session.sh; source lib/host.sh
    cmd_host "$@" ) 2>&1
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]].get(sys.argv[3], ""))' \
            "$XDG_CONFIG_HOME/cg/hosts.json" "$1" "$2" 2>/dev/null; }

echo "1. adding a machine"
facts <<<"$LINUX"
contains "a bad name is refused"           "$(cgh add My_PC --ssh player@pc)" "lowercase letters"
contains "the AWS boxes' name is refused"  "$(cgh add gamevps-1 --ssh player@pc)" "clean-up would delete it"
contains "no key-based ssh, a clear way out" "$(HOST_DOWN=1 cgh add mypc --ssh player@pc)" "ssh-copy-id player@pc"
out=$(cgh add mypc --ssh player@pc)
contains "it says what the machine is"     "$out" "CachyOS Linux (x86_64), signed in as player"
contains "  and its GPU"                   "$out" "NVIDIA GeForce RTX 4070"
check    "CachyOS is set up as Arch, from os-release" "$(field mypc family)" "arch"
check    "the file is yours alone"          "$(stat -c %a "$XDG_CONFIG_HOME/cg/hosts.json")" "600"

echo "2. what cg will not set up"
facts <<<"$LINUX"
EXTRA="WINDOWS=1" cgh add winpc --ssh me@win >/dev/null
check    "Windows is recognised"           "$(field winpc os)" "Windows"
contains "  and setting it up is refused, plainly" "$(EXTRA="WINDOWS=1" cgh setup winpc)" "Windows machine up is not built yet"
facts <<<"${LINUX/id_like=arch/id_like=}"; sed -i 's/^id=cachyos/id=void/' "$T/facts"
cgh add voidbox --ssh me@void >/dev/null
contains "an unknown distribution is refused" "$(cgh setup voidbox)" "Install Sunshine and Tailscale yourself"
check    "  and nothing ran as root"        "$(cat "$T/root.log" 2>/dev/null | wc -l)" "0"

echo "3. the Sunshine package is picked by name for the system"
src=$(source lib/host.sh; _host_root_script ubuntu noble 24.04 u)
contains "Ubuntu 24.04"                    "$src" 'ubuntu) want="+ubuntu${VERSION}_amd64.deb"'
contains "  with the version from os-release" "$src" "VERSION='24.04'"
contains "Debian by its codename"          "$(source lib/host.sh; _host_root_script debian trixie 13 u)" "CODENAME='trixie'"
contains "the Arch family's package"       "$src" 'arch)   want="-x86_64.pkg.tar.zst"'
lacks    "no Sunshine version written down" "$src" "2026."

echo "3b. a derivative is set up as the release underneath it"
# Linux Mint 22.2 is Ubuntu 24.04: its own version would have picked a Sunshine
# package that does not exist ("+ubuntu22.2").
facts <<<"$(sed 's/^id=cachyos/id=linuxmint/; s/^id_like=arch/id_like=ubuntu debian/; s/^version_id=/version_id=22.2/; s/^pretty=.*/pretty=Linux Mint 22.2/' <<<"$LINUX")
ubuntu_version=24.04
debian_codename=zara"
cgh add mint --ssh me@mint >/dev/null
check    "Mint is Ubuntu"                  "$(field mint family)" "ubuntu"
rm -f "$T"/script-*; : > "$T/box"
EXTRA="TAILSCALE_AUTH_KEY=tskey-auth-x" cgh setup mint >/dev/null
contains "  set up with the Ubuntu release under it" "$(cat "$T/script-1" 2>/dev/null)" "VERSION='24.04'"
lacks    "  not Mint's own number"         "$(cat "$T/script-1" 2>/dev/null)" "VERSION='22.2'"
facts <<<"$(sed 's/^id=cachyos/id=linuxmint/; s/^id_like=arch/id_like=ubuntu debian/' <<<"$LINUX")"
contains "an Ubuntu base it cannot read is said, not guessed" "$(cgh setup mint)" "which Ubuntu release it is could not be read"
cgh remove mint >/dev/null
check    "the GPU is told by device class, not the PCI address" \
         "$(printf '00:02.0 VGA compatible controller: Intel UHD 620\n3d:00.0 Non-Volatile memory controller: Lenovo NVMe\n' \
            | grep -E " (VGA compatible|3D|Display) controller: " | sed -E "s/^[0-9a-f:.]+ [^:]+: //")" "Intel UHD 620"

echo "3c. the AWS build's steps, each only where the machine lacks it"
# Steam missing, no desktop at all, an NVIDIA card with no driver, no audio out.
facts <<<"$(sed 's/^steam=.*/steam=/; s/^session=.*/session=/; s/^nvidia=.*/nvidia=/' <<<"$LINUX")
dm=
sinks=0
nvidia_card=1"
cgh add bare --ssh me@bare >/dev/null
rm -f "$T"/script-*; : > "$T/box"
out=$(EXTRA="TAILSCALE_AUTH_KEY=tskey-auth-x" cgh setup bare)
root=$(cat "$T/script-1" 2>/dev/null)
contains "Steam, a desktop and the NVIDIA driver are asked for" "$root" "NEEDS='steam desktop nvidia'"
contains "  Steam the Arch way: multilib"   "$root" "[multilib]"
contains "the virtual audio output is added" "$out" "adding a virtual audio output"
for never in idle-watchdog cg-library /scratch; do
  lacks  "  never the AWS-only step: $never" "$root" "$never"
done
check    "  and it never reboots or switches the machine off" \
         "$(grep -cE '^[[:space:]]*(reboot|shutdown|poweroff|systemctl (reboot|poweroff))\b' <<<"$root")" "0"
# A machine that has it all is asked for nothing.
facts <<<"$LINUX
dm=sddm
sinks=2
nvidia_card=1"
cgh add full --ssh me@full >/dev/null; rm -f "$T"/script-*
sed -i 's/^tailscale=.*/tailscale=\/usr\/bin\/tailscale/; s/^sunshine=.*/sunshine=\/usr\/bin\/sunshine/; s/^ts_ip=.*/ts_ip=100.64.0.9/' "$T/facts"
out=$(cgh setup full)
contains "  and installs nothing"          "$out" "Tailscale, Sunshine and Steam are already installed"
lacks    "  nor adds a sound output"        "$out" "virtual audio output"
cgh remove bare >/dev/null; cgh remove full >/dev/null
echo "3d. Steam on Ubuntu as the AWS build installs it"
src=$(source lib/host.sh; _host_root_script ubuntu noble 24.04 u steam)
contains "32-bit packages"                 "$src" "dpkg --add-architecture i386"
contains "  and Valve's own .deb"          "$src" "repo.steampowered.com/steam/archive/stable/steam_latest.deb"

echo "4. setting it up"
facts <<<"$LINUX"; : > "$T/box"; rm -f "$T"/script-* "$T/root.log"
out=$(EXTRA="TAILSCALE_AUTH_KEY=tskey-auth-SECRETKEY" cgh setup mypc)
contains "what is missing is installed"    "$out" "installing what is missing on mypc"
contains "  as root, with no password asked" "$(cat "$T/root.log")" "SUDO -n"
contains "it joins the tailnet"            "$out" "on the tailnet at 100.64.0.9"
contains "the Sunshine login is created"   "$out" "created; credentials saved"
check    "  and saved for this machine"     "$(field mypc sunshine_pass)" "$(cut -d' ' -f2 "$T/box")"
contains "pairing"                         "$out" "already paired"
contains "ready, and how to play"          "$out" "ready: cg host open mypc"
lacks    "the auth key never rides on an ssh command line" "$(cat "$T/ssh.log")" "SECRETKEY"
grep -l "tailscale up" "$T"/script-* >/dev/null 2>&1 && ts=$(cat $(grep -l "tailscale up" "$T"/script-*))
contains "  it goes in a file on the machine instead" "${ts:-}" "--auth-key=file:"

echo "5. a machine that wants a sudo password"
sed -i 's/^sudo=nopass/sudo=password/; s/^tailscale=.*/tailscale=/; s/^ts_ip=.*/ts_ip=/' "$T/facts"; : > "$T/root.log"
out=$(printf 'hunter2\n' | EXTRA="CG_JSON=1 TAILSCALE_AUTH_KEY=tskey-auth-SECRETKEY" cgh setup mypc)
contains "it is asked for"                 "$out" '"id":"host-sudo"'
check    "  once, though two steps need root" "$(grep -c '"id":"host-sudo"' <<<"$out")" "1"
check    "  handed to sudo on the machine's stdin" "$(cat "$T/sudo-stdin")" "hunter2"
lacks    "  never on a command line"        "$(cat "$T/ssh.log")" "hunter2"
lacks    "  never saved"                    "$(cat "$XDG_CONFIG_HOME/cg/hosts.json")" "hunter2"
check    "no other ssh call is handed cg's stdin, where the app's answers arrive" "$(cat "$T/stdin.log" 2>/dev/null | wc -l)" "0"

sed -i 's/^tailscale=.*/tailscale=/' "$T/facts"; : > "$T/root.log"
out=$(printf 'wrong\n' | EXTRA="CG_JSON=1" cgh setup mypc)
contains "a wrong password is said at once" "$out" "sudo did not accept that password"
check    "  and nothing ran as root"        "$(cat "$T/root.log" | wc -l)" "0"

echo "6. status, list, open, remove"
j=$(cgh status mypc --json)
check    "status is data"                  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["online"], d["sunshine"], d["login_ok"], d["paired"], d["set_up"])' <<<"$j")" "True True True True True"
lacks    "the list carries no password"    "$(cgh list --json)" "sunshine_pass"
contains "  but every machine"             "$(cgh list --json)" '"name": "mypc"'
cgh open mypc >/dev/null
contains "it streams from the machine's tailnet address" "$(cat "$T/stream.log")" "stream"
contains "  at 100.64.0.9"                 "$(cat "$T/stream.log")" "100.64.0.9 Desktop"
contains "forgetting changes nothing there" "$(cgh remove mypc)" "nothing was changed on the machine itself"
check    "  and it is gone here"            "$(field mypc ssh)" ""

echo; echo "host: $pass passed, $fail failed"
(( fail == 0 ))
