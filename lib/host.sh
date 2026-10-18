#!/usr/bin/env bash
# Your own machines: a PC or a server you already have, reached over ssh and
# streamed from over Tailscale - not only an AWS box. See docs/own-machine-plan.md.
#
# The prerequisite is a machine with its OS installed and ssh working with a key.
# cg adds only what streaming needs - Tailscale, Sunshine, a Sunshine login, the
# Moonlight pairing - and touches nothing else: not the desktop, not autologin,
# not the display, not the games. It is your machine, not a throwaway one.
#
# Nothing here calls AWS. Linux first; Windows is refused plainly for now.

# Where they are kept: one JSON file, readable by you alone - it holds each
# machine's Sunshine login.
host_file() { printf '%s/cg/hosts.json' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# host_get <name> [field] - a field, or the whole record as JSON; empty if none.
host_get() {
  local f; f=$(host_file)
  [[ -s $f ]] || return 0
  python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
h = d.get(sys.argv[2])
if h is None: sys.exit(0)
if len(sys.argv) > 3: print(h.get(sys.argv[3], ""))
else: print(json.dumps(h))' "$f" "$1" ${2:+"$2"}
}

# host_set <name> <field> <value> - written whole, atomically, mode 0600.
host_set() {
  local f; f=$(host_file)
  mkdir -p "${f%/*}" && (umask 077; python3 -c '
import json, os, sys
f, name, k, v = sys.argv[1:5]
try: d = json.load(open(f))
except Exception: d = {}
d.setdefault(name, {})[k] = v
tmp = f + ".new"
with open(tmp, "w") as o: json.dump(d, o, indent=1, sort_keys=True)
os.chmod(tmp, 0o600); os.replace(tmp, f)' "$f" "$1" "$2" "$3")
}

host_names() {
  local f; f=$(host_file)
  [[ -s $f ]] || return 0
  python3 -c 'import json,sys
try: print("\n".join(sorted(json.load(open(sys.argv[1])))))
except Exception: pass' "$f"
}

host_forget() {
  local f; f=$(host_file)
  [[ -s $f ]] || return 0
  (umask 077; python3 -c '
import json, os, sys
f, name = sys.argv[1:3]
d = json.load(open(f)); d.pop(name, None)
with open(f + ".new", "w") as o: json.dump(d, o, indent=1, sort_keys=True)
os.chmod(f + ".new", 0o600); os.replace(f + ".new", f)' "$f" "$1")
}

# host_ssh_raw [--in] <target> <command> - your own ssh: your keys, your
# ~/.ssh/config. A key, never a password: BatchMode turns a password prompt into
# a clear failure. stdin only with --in, for data piped on purpose: otherwise
# ssh reads cg's own stdin, which is where the app's answers arrive, and would
# swallow the next one.
host_ssh_raw() {
  local in=0; [[ $1 == --in ]] && { in=1; shift; }
  local t=$1; shift
  local o=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  if (( in )); then ssh "${o[@]}" "$t" "$@"; else ssh "${o[@]}" "$t" "$@" < /dev/null; fi
}
# host_ssh <target> <command> - the command run by sh on the machine, whatever
# your login shell there is. ssh hands a command to the login shell, and fish -
# CachyOS's default - cannot read sh. Quoted as 'it'\''s': the one form sh,
# bash, zsh and fish all read the same way. stdin is passed through.
host_ssh() {
  local in=(); [[ $1 == --in ]] && { in=(--in); shift; }
  local t=$1; shift
  local q="'\''" c="$*"
  host_ssh_raw "${in[@]}" "$t" "sh -c '${c//\'/$q}'"
}

# What the machine is, asked of it: KEY=value lines. One ssh, read-only.
_HOST_FACTS='
os=$(uname -s 2>/dev/null)
echo "os=${os:-unknown}"
[ -r /etc/os-release ] && . /etc/os-release
echo "id=${ID:-}"; echo "id_like=${ID_LIKE:-}"; echo "version_id=${VERSION_ID:-}"
echo "codename=${VERSION_CODENAME:-}"; echo "pretty=${PRETTY_NAME:-}"
# The Ubuntu or Debian release underneath, for a derivative: Linux Mint 22.2 is
# Ubuntu 24.04, and Sunshine publishes its packages by the Ubuntu number. Read
# from the system - Mint keeps the upstream release, distro-info maps a codename
# - never from a table written here.
uv=""
[ -r /etc/upstream-release/lsb-release ] && uv=$(sed -n "s/^DISTRIB_RELEASE=//p" /etc/upstream-release/lsb-release)
[ -z "$uv" ] && [ "${ID:-}" = ubuntu ] && uv=${VERSION_ID:-}
[ -z "$uv" ] && [ -n "${UBUNTU_CODENAME:-}" ] && [ -r /usr/share/distro-info/ubuntu.csv ] \
  && uv=$(awk -F, -v c="$UBUNTU_CODENAME" "\$3 == c {v = \$1} END {print v}" /usr/share/distro-info/ubuntu.csv | sed "s/ LTS//")
echo "ubuntu_version=$uv"
echo "debian_codename=${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
echo "arch=$(uname -m)"; echo "user=$(id -un)"
# By device class, not anywhere on the line: "3d" also matched the PCI address
# 3d:00.0 of an NVMe drive.
echo "gpu=$(lspci 2>/dev/null | grep -E " (VGA compatible|3D|Display) controller: " | sed -E "s/^[0-9a-f:.]+ [^:]+: //" | paste -sd";" -)"
echo "nvidia=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
echo "render=$(ls /dev/dri/renderD* 2>/dev/null | head -1)"
sudo -n true 2>/dev/null && echo "sudo=nopass" || echo "sudo=password"
echo "tailscale=$(command -v tailscale || true)"
echo "ts_ip=$(tailscale ip -4 2>/dev/null | head -1)"
echo "sunshine=$(command -v sunshine || true)"
steam=$(command -v steam || true)
[ -z "$steam" ] && flatpak list --app 2>/dev/null | grep -q com.valvesoftware.Steam && steam=flatpak
echo "steam=$steam"
s=""
for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" "\$3==u{print \$1}"); do
  t=$(loginctl show-session "$id" -p Type --value 2>/dev/null)
  case $t in x11|wayland) s=$t ;; esac
done
echo "session=$s"
# What the AWS build adds that a machine may already have: a desktop to start,
# somewhere for sound to go, a driver for an NVIDIA card.
dm=""; for d in lightdm gdm gdm3 sddm lxdm xdm; do command -v "$d" >/dev/null 2>&1 && dm=$d && break; done
echo "dm=$dm"
echo "sinks=$(XDG_RUNTIME_DIR=/run/user/$(id -u) pactl list short sinks 2>/dev/null | wc -l)"
echo "nvidia_card=$(lspci 2>/dev/null | grep -E " (VGA compatible|3D) controller: " | grep -ci nvidia)"
echo "flatpak=$(command -v flatpak || true)"
'

# host_facts <target> - the facts, or nothing when the machine cannot be asked.
# Windows answers uname with an error, so it is told apart by `ver`.
host_facts() {
  local out
  out=$(printf '%s' "$_HOST_FACTS" | host_ssh_raw --in "$1" "sh -s" 2>/dev/null) || out=""
  if [[ $out != *os=Linux* ]]; then
    host_ssh_raw "$1" ver 2>/dev/null | grep -qi windows && { echo "os=Windows"; return 0; }
    [[ -n $out ]] && printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out"
}
_fact() { sed -n "s/^$2=//p" <<<"$1" | head -1; }

# The distribution family, which decides how Sunshine is installed - read from
# os-release (ID, then ID_LIKE), so CachyOS or Manjaro count as Arch.
host_family() { # host_family <facts>
  local id like w
  id=$(_fact "$1" id); like=$(_fact "$1" id_like)
  for w in $id $like; do
    case $w in
      ubuntu) echo ubuntu; return ;;
      debian) echo debian; return ;;
      arch)   echo arch; return ;;
      fedora) echo fedora; return ;;
    esac
  done
  echo unsupported
}

# A name the cloud's own pruning can never take for one of its boxes, and one
# Tailscale accepts as a hostname.
host_name_ok() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] || { echo "use lowercase letters, digits and dashes"; return 1; }
  if [[ $1 =~ ^${TS_HOST:-gamevps}(-[0-9]+)?$ ]]; then
    echo "'$1' is the name cg gives its AWS boxes, and their clean-up would delete it - pick another"
    return 1
  fi
}

cmd_host_add() { # cmd_host_add <name> --ssh <target>
  local name="" target="" why facts
  while (( $# )); do
    case $1 in --ssh) target=${2:-}; shift 2 ;; -*) shift ;; *) name=$1; shift ;; esac
  done
  [[ -n $name && -n $target ]] || die "usage: cg host add <name> --ssh <user@address>"
  why=$(host_name_ok "$name") || die "$why"
  say "reaching $target over ssh"
  host_ssh_raw "$target" exit 2>/dev/null \
    || die "ssh $target did not connect without a password. cg uses your own ssh setup:
       make 'ssh $target' work with a key first (ssh-copy-id $target)."
  facts=$(host_facts "$target")
  [[ -n $facts ]] || die "connected, but $target did not say what it is"
  host_set "$name" ssh "$target"
  host_set "$name" os "$(_fact "$facts" os)"
  if [[ $(_fact "$facts" os) == Windows ]]; then
    log "Windows - added. Setting a Windows machine up is not built yet (docs/own-machine-plan.md)."
    return 0
  fi
  host_set "$name" family "$(host_family "$facts")"
  host_set "$name" user "$(_fact "$facts" user)"
  log "$(_fact "$facts" pretty) ($(_fact "$facts" arch)), signed in as $(_fact "$facts" user)"
  log "GPU: $(_fact "$facts" nvidia)$( [[ -z $(_fact "$facts" nvidia) ]] && _fact "$facts" gpu)"
  [[ $(host_family "$facts") == unsupported ]] \
    && log "note: cg sets up Ubuntu, Debian, Arch (and its family) and Fedora - this one it can only stream from once you install Sunshine yourself"
  log "added '$name'. Next: cg host setup $name"
}

# The part that needs root, as one script: the AWS build's steps, each done the
# way this machine needs it and only when it is missing. Tailscale, Sunshine,
# virtual input, the firewall letting the tailnet in - and, as the AWS build
# does, Steam, a desktop when there is none, an NVIDIA driver when the card
# has none. Never the AWS-only steps: no idle shutdown (a home machine must not
# switch itself off), no S3 library, no /scratch, no reboot.
_host_root_script() { # <family> <codename> <version> <user> <needs: steam desktop nvidia>
  cat <<EOF
set -euo pipefail
FAMILY='$1' CODENAME='$2' VERSION='$3' USER_NAME='$4' NEEDS='${5:-}'
EOF
  cat <<'EOF'
# Package managers talk a lot; their output goes to a log on the machine and is
# shown only when a step fails. Never a question on a terminal there is not.
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/cg-host-setup.log
quiet() { "$@" >> "$LOG" 2>&1 || { echo ">>> FAILED: $* - the end of $LOG:"; tail -25 "$LOG"; exit 1; }; }
if ! command -v tailscale >/dev/null; then
  echo ">>> installing Tailscale"
  quiet sh -c "curl -fsSL https://tailscale.com/install.sh | sh"
fi
systemctl enable --now tailscaled >/dev/null 2>&1 || true
if ! command -v sunshine >/dev/null; then
  echo ">>> installing Sunshine"
  # The file for this distribution and version, picked from the latest release
  # by its name - no version written down here.
  case $FAMILY in
    ubuntu) want="+ubuntu${VERSION}_amd64.deb" ;;
    debian) want="+debian${CODENAME}_amd64.deb" ;;
    arch)   want="-x86_64.pkg.tar.zst" ;;
    fedora) want=".fc${VERSION}.x86_64.rpm" ;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
        | python3 -c 'import json,sys
w = sys.argv[1]
print(next((a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(w)), ""))' "$want")
  [ -n "$url" ] || { echo ">>> FAILED: Sunshine publishes no package for this system ($want)"; exit 1; }
  tmp=$(mktemp -d); f="$tmp/${url##*/}"
  quiet curl -fsSL -o "$f" "$url"
  case $FAMILY in
    ubuntu|debian) quiet apt-get update -qq; quiet apt-get install -y "$f" ;;
    arch)          quiet pacman -U --noconfirm --needed "$f" ;;
    fedora)        quiet dnf install -y "$f" ;;
  esac
  echo ">>> ok: Sunshine $(sunshine --version 2>/dev/null | head -1 | grep -oE "[0-9][0-9.]+" | head -1) installed"
  rm -rf "$tmp"
fi
needs() { case " $NEEDS " in *" $1 "*) return 0 ;; esac; return 1; }
# Steam, as the AWS build installs it on Ubuntu (lib/bootstrap.d/70-steam-pkg.sh):
# 32-bit packages and Valve's own .deb. Arch has it in multilib, Fedora only
# outside its own repositories, so there it comes from Flathub.
if needs steam; then
  echo ">>> installing Steam"
  case $FAMILY in
    ubuntu|debian)
      dpkg --add-architecture i386
      quiet apt-get update -qq
      echo steam steam/question select "I AGREE" | debconf-set-selections
      echo steam steam/license note '' | debconf-set-selections
      quiet apt-get install -y libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 || true
      quiet curl -fsSL --retry 3 -o /tmp/steam_latest.deb https://repo.steampowered.com/steam/archive/stable/steam_latest.deb
      quiet apt-get install -y /tmp/steam_latest.deb
      rm -f /tmp/steam_latest.deb ;;
    arch)
      if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
        echo ">>> enabled the multilib repository in /etc/pacman.conf (Steam needs it)"
      fi
      quiet pacman -Sy --noconfirm --needed steam ;;
    fedora)
      quiet dnf install -y flatpak
      quiet flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
      quiet flatpak install -y --noninteractive flathub com.valvesoftware.Steam ;;
  esac
  echo ">>> ok: Steam installed"
fi
# A desktop for Sunshine to stream, only when the machine has none - the AWS
# build's (30-desktop, 60-autologin): XFCE, signed in at boot.
if needs desktop; then
  case $FAMILY in
    ubuntu|debian)
      echo ">>> installing a desktop (XFCE) and signing $USER_NAME in at boot"
      quiet apt-get install -y xfce4 lightdm xserver-xorg x11-xserver-utils
      mkdir -p /etc/lightdm/lightdm.conf.d
      printf '[Seat:*]\nautologin-user=%s\nautologin-user-timeout=0\nuser-session=xfce\n' "$USER_NAME" \
        > /etc/lightdm/lightdm.conf.d/50-autologin.conf
      groupadd -f autologin; usermod -aG autologin "$USER_NAME"
      systemctl set-default graphical.target; systemctl enable lightdm >/dev/null 2>&1 || true
      echo ">>> ok: desktop installed - it starts at the next boot" ;;
    *) echo ">>> no desktop on this machine, and cg installs one only on Ubuntu or Debian - install one, then run setup again" ;;
  esac
fi
# An NVIDIA card with no driver: the newest open driver, as the AWS build does
# (40-nvidia). Loaded at the next boot - this does not reboot your machine.
if needs nvidia; then
  case $FAMILY in
    ubuntu|debian)
      echo ">>> installing the NVIDIA driver"
      pkg=$(apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' 2>/dev/null | grep -oE 'nvidia-driver-[0-9]+-open' | sort -uV | tail -1)
      [ -n "$pkg" ] || { echo ">>> FAILED: no NVIDIA driver package found"; exit 1; }
      quiet apt-get install -y "$pkg"
      echo ">>> ok: $pkg installed - reboot the machine to load it" ;;
    arch) quiet pacman -S --noconfirm --needed nvidia-open-dkms nvidia-utils
          echo ">>> ok: NVIDIA driver installed - reboot the machine to load it" ;;
    *) echo ">>> this NVIDIA card has no driver, and cg installs one only on Ubuntu, Debian or Arch" ;;
  esac
fi
# Sunshine plays your keyboard and controller through a virtual input device.
modprobe uinput 2>/dev/null || true
grep -qx uinput /etc/modules-load.d/uinput.conf 2>/dev/null || echo uinput > /etc/modules-load.d/uinput.conf
# Its user service runs when you are signed in; lingering keeps it up between.
loginctl enable-linger "$USER_NAME" 2>/dev/null || true
# A firewall that is on would drop the stream arriving from the tailnet.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow in on tailscale0 >/dev/null
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 >/dev/null && firewall-cmd --reload >/dev/null
fi
echo ">>> ok: root steps done"
EOF
}

# host_sudo_ask <target> - the sudo password, asked once for a whole setup (it
# runs root steps more than once, and asking each time asked twice). Handed to
# sudo on the machine's stdin; never saved, never on a command line.
host_sudo_ask() {
  cg_can_ask || die "the machine wants a sudo password, and there is no one to ask - run this in a terminal"
  cg_ask_secret host-sudo "  sudo password for $1: "
}

# host_run_root <target> <script> [sudo password] - the script, as root: with
# no password, sudo must need none.
host_run_root() {
  local t=$1 script=$2 pw=${3:-} f
  f=$(printf '%s' "$script" | host_ssh --in "$t" 'f=$(mktemp); cat > "$f"; chmod 600 "$f"; echo "$f"') \
    || die "could not copy the setup script to $t"
  if [[ -z $pw ]]; then
    host_ssh "$t" "sudo -n bash '$f'; r=\$?; rm -f '$f'; exit \$r"
  else
    printf '%s\n' "$pw" | host_ssh --in "$t" "sudo -S -p '' bash '$f'; r=\$?; rm -f '$f'; exit \$r"
  fi
}

# The Tailscale address this laptop reaches it at - only if it is on THIS tailnet.
host_ts_ip() { # host_ts_ip <ip-the-machine-reports>
  [[ -n $1 ]] && tailscale status 2>/dev/null | awk -v ip="$1" '$1 == ip {print $1; exit}'
}

cmd_host_setup() { # cmd_host_setup <name>
  local name=${1:-} t facts fam ip=""
  [[ -n $name ]] || die "usage: cg host setup <name>"
  t=$(host_get "$name" ssh); [[ -n $t ]] || die "no machine called '$name' - add it: cg host add $name --ssh <user@address>"
  say "asking $name what it is"
  facts=$(host_facts "$t"); [[ -n $facts ]] || die "$t did not answer over ssh"
  [[ $(_fact "$facts" os) == Windows ]] && die "setting a Windows machine up is not built yet - see docs/own-machine-plan.md"
  fam=$(host_family "$facts")
  [[ $fam != unsupported ]] || die "cg sets up Ubuntu, Debian, Arch and Fedora; $(_fact "$facts" pretty) is not one. Install Sunshine and Tailscale yourself, then: cg host pair $name"
  [[ $(_fact "$facts" arch) == x86_64 ]] || die "x86_64 only - Steam and Proton need it ($(_fact "$facts" arch) here)"
  [[ $fam != ubuntu || -n $(_fact "$facts" ubuntu_version) ]] \
    || die "$(_fact "$facts" pretty) is Ubuntu-based, but which Ubuntu release it is could not be read"

  # What the AWS build would add that this machine lacks - each read from the
  # machine, nothing assumed.
  local needs=()
  [[ -n $(_fact "$facts" steam) ]] || needs+=(steam)
  [[ -n $(_fact "$facts" dm) || -n $(_fact "$facts" session) ]] || needs+=(desktop)
  [[ $(_fact "$facts" nvidia_card) -gt 0 && -z $(_fact "$facts" nvidia) ]] 2>/dev/null && needs+=(nvidia)
  local install=0
  [[ -z $(_fact "$facts" tailscale) || -z $(_fact "$facts" sunshine) || ${#needs[@]} -gt 0 ]] && install=1

  # Root is needed to install, or to join the tailnet; then the password, once,
  # in a step of its own.
  local pw=""
  local root=$install
  [[ -z $(_fact "$facts" ts_ip) ]] && root=1
  if (( root )) && [[ $(_fact "$facts" sudo) != nopass ]]; then
    say "root on $name - asked once, never saved"
    pw=$(host_sudo_ask "$t")
    [[ -n $pw ]] || die "no sudo password given - nothing was changed on $name"
    # Checked before anything runs, so a typo is said here and not as a failed
    # install halfway through.
    printf '%s\n' "$pw" | host_ssh --in "$t" "sudo -S -p '' -v" >/dev/null 2>&1 \
      || die "sudo did not accept that password on $name - nothing was changed"
  fi

  if (( install )); then
    say "installing what is missing on $name"
    host_run_root "$t" \
      "$(_host_root_script "$fam" "$(_fact "$facts" debian_codename)" \
         "$(_fact "$facts" "$([[ $fam == fedora ]] && echo version_id || echo ubuntu_version)")" "$(_fact "$facts" user)" "${needs[*]}")" "$pw" \
      | cg_relay '    ' || die "setting up $name failed - the lines above say where"
    facts=$(host_facts "$t")
  else
    log "Tailscale, Sunshine and Steam are already installed"
  fi

  say "joining the tailnet"
  ip=$(host_ts_ip "$(_fact "$facts" ts_ip)")
  if [[ -z $(_fact "$facts" ts_ip) ]]; then
    local key="${TAILSCALE_AUTH_KEY:-${GAME_TS_AUTHKEY:-}}"
    [[ -n $key ]] || die "no Tailscale auth key in the settings - cg check --fix asks for one"
    # The key goes in a file on the machine, never on its command line, and is
    # deleted straight after. It is the same reusable, non-ephemeral key the AWS
    # boxes use: an ephemeral one would drop this machine whenever it slept.
    host_run_root "$t" "set -e
umask 077; k=\$(mktemp); printf '%s' '$key' > \"\$k\"
tailscale up --auth-key=file:\"\$k\" --hostname='$name'; r=\$?; rm -f \"\$k\"; exit \$r" "$pw" \
      | cg_relay '    ' || die "tailscale up failed on $name"
    facts=$(host_facts "$t"); ip=$(host_ts_ip "$(_fact "$facts" ts_ip)")
  fi
  [[ -n $ip ]] || die "$name is on Tailscale, but not on the tailnet this laptop is on - sign it in to the same one"
  log "on the tailnet at $ip"
  host_set "$name" ts_ip "$ip"
  # Key expiry off, as for the AWS boxes - a home machine must not drop out
  # after 180 days. Needs the API token; without it, it is said, not skipped.
  local node; node=$(tailscale status 2>/dev/null | awk -v ip="$ip" '$1 == ip {print $2; exit}')
  lib/tailnet-expiry.sh "$node" 2>&1 | cg_relay '    ' || true

  say "starting Sunshine"
  host_ssh "$t" 'export XDG_RUNTIME_DIR=/run/user/$(id -u)
    u=$(systemctl --user list-unit-files "*unshine*" --no-legend 2>/dev/null | awk "NR==1{print \$1}")
    [ -n "$u" ] && systemctl --user enable --now "$u" >/dev/null 2>&1; true' || true
  local up=0 code
  for _ in $(seq 1 20); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$ip:47990/welcome" 2>/dev/null || echo 000)
    [[ $code != 000 ]] && { up=1; break; }
    sleep 3
  done
  (( up )) || die "Sunshine is not answering at https://$ip:47990 - is a desktop signed in on $name?"

  # Somewhere for the sound to go: a machine with no audio output streams
  # silence. The AWS build's answer (92-audio): a virtual sink, kept by a user
  # service. A machine with speakers already has one and is left alone.
  if [[ $(_fact "$facts" sinks) == 0 ]]; then
    say "adding a virtual audio output"
    host_ssh "$t" 'export XDG_RUNTIME_DIR=/run/user/$(id -u); d=$HOME/.config/systemd/user; mkdir -p "$d"
      printf "[Unit]\nDescription=Virtual audio output for Sunshine\nAfter=pipewire-pulse.service pulseaudio.service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/pactl load-module module-null-sink sink_name=sunshine sink_properties=device.description=Sunshine\nExecStart=/usr/bin/pactl set-default-sink sunshine\n[Install]\nWantedBy=default.target\n" > "$d/cg-audio-sink.service"
      systemctl --user daemon-reload && systemctl --user enable --now cg-audio-sink.service' >/dev/null 2>&1 \
      && log "added - sound streams through it" || log "could not add one - the stream will be silent"
  fi

  say "the Sunshine login"
  # shellcheck source=lib/sunshine-login.sh
  source lib/sunshine-login.sh
  SUNSHINE_USER=$(host_get "$name" sunshine_user); SUNSHINE_PASS=$(host_get "$name" sunshine_pass)
  _host_save_login() { case $1 in SUNSHINE_USER) host_set "$name" sunshine_user "$2" ;; SUNSHINE_PASS) host_set "$name" sunshine_pass "$2" ;; esac; }
  sun_login_ensure "$ip" "$([[ $code == 200 ]] && echo 1 || echo 0)" _host_save_login host_ssh "$t" \
    || die "the Sunshine login could not be set on $name"

  say "pairing Moonlight"
  if ! command -v moonlight >/dev/null; then
    log "Moonlight is not installed on this laptop - cg check --fix installs it"
  elif timeout 45 moonlight list "$ip" 2>/dev/null | grep -q .; then
    log "already paired"
  else
    # shellcheck source=lib/pair.sh
    source lib/pair.sh
    pair_moonlight "$ip" "$SUNSHINE_USER" "$SUNSHINE_PASS" && log "paired" || die "pairing failed - try again: cg host setup $name"
  fi

  # What cg does not change, said rather than fixed.
  [[ -n $(_fact "$facts" session) ]] || log "note: no desktop is signed in on $name right now - Sunshine streams a signed-in desktop"
  [[ -n $(_fact "$facts" steam) ]] || log "note: Steam could not be installed on $name"
  [[ -n $(_fact "$facts" nvidia) || -n $(_fact "$facts" render) ]] \
    || log "note: no GPU video encoder found on $name - the stream would fall back to the CPU"
  host_set "$name" ready yes
  log "ready: cg host open $name"
}

# cmd_host_status <name> [--json] - every fact the Machine page needs. Free.
cmd_host_status() {
  local name=${1:-} t ip facts ssh_ok=no ts_on=no sun_up=no login=no paired=no
  [[ -n $name ]] || die "usage: cg host status <name>"
  t=$(host_get "$name" ssh); [[ -n $t ]] || die "no machine called '$name'"
  ip=$(host_get "$name" ts_ip)
  facts=$(host_facts "$t"); [[ -n $facts ]] && ssh_ok=yes
  [[ -n $ip ]] && tailscale ping -c 1 --timeout 3s "$ip" >/dev/null 2>&1 && ts_on=yes
  if [[ -n $ip ]] && [[ $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$ip:47990/welcome" 2>/dev/null) != 000 ]]; then
    sun_up=yes
    # shellcheck source=lib/sunshine-login.sh
    source lib/sunshine-login.sh
    sun_login_ok "$ip" "$(host_get "$name" sunshine_user)" "$(host_get "$name" sunshine_pass)" && login=yes
    command -v moonlight >/dev/null && timeout 20 moonlight list "$ip" 2>/dev/null | grep -q . && paired=yes
  fi
  if cg_json || [[ ${2:-} == --json ]]; then
    N="$name" T="$t" IP="$ip" SSH_OK=$ssh_ok TS_ON=$ts_on SUN=$sun_up LOGIN=$login PAIRED=$paired \
    OS="$(host_get "$name" os)" FAM="$(host_get "$name" family)" READY="$(host_get "$name" ready)" \
    SESSION="$(_fact "$facts" session)" STEAM="$(_fact "$facts" steam)" GPU="$(_fact "$facts" nvidia)" \
    python3 -c 'import json, os
g = os.environ.get; yes = lambda k: g(k) == "yes"
print(json.dumps({"name": g("N"), "ssh": g("T"), "os": g("OS") or None, "family": g("FAM") or None,
  "tailnet_ip": g("IP") or None, "reachable": yes("SSH_OK"), "online": yes("TS_ON"),
  "sunshine": yes("SUN"), "login_ok": yes("LOGIN"), "paired": yes("PAIRED"),
  "set_up": g("READY") == "yes", "desktop": g("SESSION") or None,
  "steam": bool(g("STEAM")) if yes("SSH_OK") else None, "gpu": g("GPU") or None}, indent=2))'
    return 0
  fi
  local ok="✓" no="✗"
  printf '  %s  %s (%s)\n' "$name" "$t" "$(host_get "$name" os)"
  printf '  %s ssh\n  %s on the tailnet%s\n  %s Sunshine\n  %s Sunshine login\n  %s paired with Moonlight\n' \
    "$([[ $ssh_ok == yes ]] && echo $ok || echo $no)" "$([[ $ts_on == yes ]] && echo $ok || echo $no)" "${ip:+ at $ip}" \
    "$([[ $sun_up == yes ]] && echo $ok || echo $no)" "$([[ $login == yes ]] && echo $ok || echo $no)" \
    "$([[ $paired == yes ]] && echo $ok || echo $no)"
  [[ -n $facts && -z $(_fact "$facts" session) ]] && printf '  ! no desktop signed in - Sunshine streams a signed-in desktop\n'
  return 0
}

# cmd_host_open <name> - stream from it. No machine to start, nothing billed by
# the hour: it is already there.
cmd_host_open() {
  local name=${1:-} ip held pid
  [[ -n $name ]] || die "usage: cg host open <name>"
  ip=$(host_get "$name" ts_ip)
  [[ -n $ip ]] || die "'$name' is not set up yet: cg host setup $name"
  command -v moonlight >/dev/null || die "Moonlight is not installed - cg check --fix installs it"
  if held=$(session_running); then
    read -r pid _ <<<"$held"
    die "a stream from this laptop is already running (pid $pid)"
  fi
  [[ $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$ip:47990/welcome" 2>/dev/null) != 000 ]] \
    || die "Sunshine is not answering on $name ($ip) - is it on, and a desktop signed in?"
  session_claim
  local mlf=(); moonlight_flags mlf
  local t0=$SECONDS
  moonlight stream ${mlf[@]+"${mlf[@]}"} "$ip" "${GAME_APP:-Desktop}" || true
  session_end 2>/dev/null || true
  log "session ended after $(( (SECONDS - t0) / 60 ))m"
}

cmd_host() {
  local sub=${1:-list}; shift || true
  case $sub in
    add)    cmd_host_add "$@" ;;
    setup)  cmd_host_setup "$@" ;;
    status) cmd_host_status "$@" ;;
    open)   cmd_host_open "$@" ;;
    list)
      if cg_json || [[ ${1:-} == --json ]]; then
        local n first=1; printf '['
        for n in $(host_names); do
          (( first )) || printf ','; first=0
          host_get "$n" | N="$n" python3 -c 'import json,sys,os; h=json.load(sys.stdin); h.pop("sunshine_pass",None); h["name"]=os.environ["N"]; print(json.dumps(h), end="")' 2>/dev/null
        done
        printf ']\n'
      else
        local any=0 n
        for n in $(host_names); do any=1; printf '  %-16s %-28s %s\n' "$n" "$(host_get "$n" ssh)" "$(host_get "$n" os)"; done
        (( any )) || echo "  no machines of your own yet - add one: cg host add <name> --ssh <user@address>"
      fi ;;
    remove)
      [[ -n ${1:-} && -n $(host_get "$1" ssh) ]] || die "usage: cg host remove <name>"
      host_forget "$1"; log "forgot '$1' - nothing was changed on the machine itself" ;;
    *) die "usage: cg host [list|add <name> --ssh <user@address>|setup <name>|status <name>|open <name>|remove <name>]" ;;
  esac
}
