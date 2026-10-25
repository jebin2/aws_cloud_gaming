#!/usr/bin/env bash
# Your own machines: a PC or a server you already have, reached over ssh and
# streamed from over Tailscale - not only an AWS box. See docs/own-machine-plan.md.
#
# The prerequisite is a machine with its OS installed and an ssh server. The
# first connection may use its password, once: cg puts a key of its own on it
# (host_key) and uses that from then on - the password is never saved.
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

# _host_write <set|forget> <name> [field value]... - the one writer: read,
# change and replace under an exclusive lock, through a temp file of its own,
# mode 0600. Setup and a stream run beside other commands; two writers each
# reading the old file and replacing it lost one's change - a Sunshine password
# the machine had already been given, and every pairing after it failed.
_host_write() {
  local f; f=$(host_file)
  mkdir -p "${f%/*}" && (umask 077; python3 -I -c '
import fcntl, json, os, sys, tempfile
f, op, name, kv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
with open(f + ".lock", "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try: d = json.load(open(f))
    except Exception: d = {}
    if op == "forget": d.pop(name, None)
    else: d.setdefault(name, {}).update(zip(kv[0::2], kv[1::2]))
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".hosts.")
    with os.fdopen(fd, "w") as o: json.dump(d, o, indent=1, sort_keys=True)
    os.chmod(tmp, 0o600); os.replace(tmp, f)' "$f" "$@")
}
# host_set <name> <field> <value> [<field> <value>]... - one write for them all.
host_set() { _host_write set "$@"; }

host_names() {
  local f; f=$(host_file)
  [[ -s $f ]] || return 0
  python3 -c 'import json,sys
try: print("\n".join(sorted(json.load(open(sys.argv[1])))))
except Exception: pass' "$f"
}

host_forget() {
  [[ -s $(host_file) ]] || return 0
  _host_write forget "$1"
}

# cg's own key for machines of yours: one per laptop, made the first time a
# machine is added, put on each machine by host_key_install. Its own, so that
# removing a machine takes off exactly the line cg added and nothing of yours.
host_key() { printf '%s/cg/ssh/id_ed25519' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
# A key only counts when its public half reads as one: a .pub that is missing or
# empty is made again from the private key, and a pair that cannot be read is
# replaced - an empty line is not a key, and sending one lets nothing in.
host_key_ensure() {
  local k; k=$(host_key)
  host_key_ok && return 0
  if [[ -s $k ]] && ssh-keygen -y -f "$k" > "$k.pub.new" 2>/dev/null; then
    mv -f "$k.pub.new" "$k.pub"; host_key_ok && return 0
  fi
  rm -f "$k" "$k.pub" "$k.pub.new"
  mkdir -p "${k%/*}" && chmod 700 "${k%/*}" \
    && ssh-keygen -q -t ed25519 -N '' -C "cg@$(cat /etc/hostname 2>/dev/null || echo laptop)" -f "$k" >/dev/null 2>&1 \
    && host_key_ok
}
host_key_ok() { local k; k=$(host_key); [[ -s $k ]] && grep -q '^ssh-ed25519 [A-Za-z0-9+/=]' "$k.pub" 2>/dev/null; }

# host_key_install <target> <password> - cg's key onto the machine, logging in
# once with its password. The password reaches ssh through SSH_ASKPASS from this
# process's environment - never a file, never a command line - and is gone
# when this returns. On the machine: appended to ~/.ssh/authorized_keys unless
# it is there already, under sh whatever the login shell is, and read back -
# exit 3 when the line is not there after all.
host_key_install() {
  local t=$1 pw=$2 ask pub rc
  host_key_ok || return 1
  pub=$(head -n 1 "$(host_key).pub") || return 1
  ask=$(mktemp) || return 1
  printf '#!/bin/sh\nprintf "%%s\\n" "$CG_SSH_PASSWORD"\n' > "$ask"; chmod 700 "$ask"
  CG_SSH_PASSWORD=$pw SSH_ASKPASS=$ask SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-:0} \
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
        "$t" "sh -c 'umask 077; mkdir -p \"\$HOME/.ssh\"; f=\"\$HOME/.ssh/authorized_keys\"; touch \"\$f\"; [ -n \"\$1\" ] || exit 3; grep -qxF \"\$1\" \"\$f\" || printf \"%s\\n\" \"\$1\" >> \"\$f\"; grep -qxF \"\$1\" \"\$f\" || exit 3' _ '$pub'" \
        </dev/null >/dev/null 2>&1
  rc=$?; rm -f "$ask"; return $rc
}

# host_key_remove <target> - cg's line off the machine, and nothing else.
host_key_remove() {
  local pub; pub=$(cat "$(host_key).pub" 2>/dev/null) || return 0
  host_ssh_raw "$1" "sh -c 'f=\"\$HOME/.ssh/authorized_keys\"; [ -f \"\$f\" ] || exit 0; grep -vxF \"\$1\" \"\$f\" > \"\$f.cg\"; cat \"\$f.cg\" > \"\$f\"; rm -f \"\$f.cg\"' _ '$pub'"
}

# host_ssh_raw [--in] <target> <command> - ssh as you run it - your keys, your
# ~/.ssh/config - plus cg's own key. A key, never a password: BatchMode turns a
# password prompt into a clear failure. stdin only with --in, for data piped on purpose: otherwise
# ssh reads cg's own stdin, which is where the app's answers arrive, and would
# swallow the next one.
host_ssh_raw() {
  local in=0; [[ $1 == --in ]] && { in=1; shift; }
  local t=$1; shift
  local o=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  [[ -f $(host_key) ]] && o+=(-i "$(host_key)")
  if (( in )); then ssh "${o[@]}" "$t" "$@"; else ssh "${o[@]}" "$t" "$@" < /dev/null; fi
}
# host_ssh [--in] <target> <command> - a machine of yours, through cg's one way
# of reaching any machine (mssh, lib/common.sh) with your own ssh setup: under
# sh whatever your login shell is, stdin only with --in.
host_ssh() {
  local in=(); [[ $1 == --in ]] && { in=(--in); shift; }
  local t=$1 k=""; shift
  [[ -f $(host_key) ]] && k=$(host_key)
  mssh "${in[@]}" "$t" "$k" "$@"
}

# What the machine is, asked of it: KEY=value lines. One ssh, read-only.
_HOST_FACTS='
os=$(uname -s 2>/dev/null)
echo "os=${os:-unknown}"
[ -r /etc/os-release ] && . /etc/os-release
echo "id=${ID:-}"; echo "id_like=${ID_LIKE:-}"; echo "version_id=${VERSION_ID:-}"
echo "codename=${VERSION_CODENAME:-}"; echo "pretty=${PRETTY_NAME:-}"
# The Ubuntu release underneath, for a derivative too - the function the build
# itself uses (lib/bootstrap.d/01-release.sh), included below, so the two agree.
echo "ubuntu_version=$(ubuntu_release)"
echo "debian_codename=${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
echo "arch=$(uname -m)"; echo "user=$(id -un)"; echo "hostname=$(hostname 2>/dev/null)"
# The machine itself, whatever address or name reaches it: kept on this laptop
# only as a hash, so the same machine is never added twice.
echo "machine_id=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null)"
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
# The Sunshine login every device shares, base64 so it is one line whatever it
# holds. Read with the rest, and never printed: facts are read a field at a time.
echo "sunlogin=$(base64 -w0 ~/.config/cg/sunshine-login 2>/dev/null)"
'

# host_facts <target> - the facts, or nothing when the machine cannot be asked.
# Windows answers uname with an error, so it is told apart by `ver`.
host_facts() {
  local out
  # The build's own ubuntu_release ahead of the facts that call it - one copy,
  # read when asked rather than when this file is loaded: cg loads it for every
  # command, and a copy of cg without the build modules is still cg.
  out=$( { grep -vE '^[[:space:]]*#' lib/bootstrap.d/01-release.sh 2>/dev/null; printf '%s' "$_HOST_FACTS"; } \
         | host_ssh_raw --in "$1" "sh -s" 2>/dev/null) || out=""
  if [[ $out != *os=Linux* ]]; then
    host_ssh_raw "$1" ver 2>/dev/null | grep -qi windows && { echo "os=Windows"; return 0; }
    [[ -n $out ]] && printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out"
}
_fact() { sed -n "s/^$2=//p" <<<"$1" | head -1; }

# The Sunshine login is kept on the machine too, in cg's folder there, readable
# by its user alone. Each device used to keep its own copy, so a setup from one
# - which sets a new login - left every other device holding a password
# Sunshine no longer took. Now a device whose copy fails reads the machine's,
# and one whose copy works puts it there, so they all agree on one.
# host_login_shared <facts> - "user<TAB>pass" as the machine keeps it, or nothing.
host_login_shared() {
  local b; b=$(_fact "$1" sunlogin)
  [[ -n $b ]] || return 0
  base64 -d <<<"$b" 2>/dev/null | head -2 | paste -sd $'\t' -
}
# host_login_share <target> <user> <pass> - keep it on the machine. Over stdin,
# so the password is in no command line there.
host_login_share() {
  [[ -n ${2:-} && -n ${3:-} ]] || return 1
  printf '%s\n%s\n' "$2" "$3" | host_ssh_raw --in "$1" \
    'umask 077; mkdir -p ~/.config/cg && cat > ~/.config/cg/sunshine-login.new && mv -f ~/.config/cg/sunshine-login.new ~/.config/cg/sunshine-login' \
    >/dev/null 2>&1
}

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

# host_machine_key <facts> - who the machine is, as a short hash of its own
# machine id: an IP, a tailnet name and a hostname can all reach one machine,
# and the raw id is not this laptop's to keep. Empty when it has none.
host_machine_key() {
  local m; m=$(_fact "$1" machine_id)
  [[ -n $m ]] && printf '%s' "$m" | sha256sum | cut -c1-16
}

# host_added_as <key> <target> - the name a machine is already added under:
# the same machine, by its key, or the same ssh address. Empty when it is new.
host_added_as() {
  local n
  for n in $(host_names); do
    if [[ -n $1 && $(host_get "$n" machine) == "$1" ]] || [[ $(host_get "$n" ssh) == "$2" ]]; then
      printf '%s' "$n"; return 0
    fi
  done
}

# A name from the machine's own hostname: what Tailscale would call it.
host_name_from() { # host_name_from <hostname>
  local n=${1,,}; n=${n%%.*}; n=$(sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//' <<<"$n")
  printf '%s' "${n:0:40}"
}

# host_let_in <target> - cg's key working on the machine, asking its password
# once when it does not: the first time a machine is added, and again whenever
# the key has gone from it - taken off by removing a second entry for the same
# machine, or by hand. Setup used to need the key already there, so a machine
# that lost it could only be removed and added again.
host_let_in() {
  local target=$1 pw rc
  host_key_ensure || die "could not make cg's ssh key ($(host_key))"
  host_ssh_raw "$target" exit 2>/dev/null && return 0
  cg_can_ask || die "ssh $target did not connect with a key, and there is no one to ask for its password -
       run this in a terminal, or make 'ssh $target' work with a key first (ssh-copy-id $target)"
  log "cg's key does not let it in: its password, once, puts the key on it, and is not kept"
  pw=$(cg_ask_secret host-ssh-password "  password for $target: ")
  [[ -n $pw ]] || die "no password given - nothing was changed on $target"
  host_key_install "$target" "$pw"; rc=$?
  (( rc == 3 )) && die "logged in to $target, but cg's key did not stay in its ~/.ssh/authorized_keys - is that file or folder not yours to write?"
  (( rc == 0 )) || die "$target did not let cg in with that password. Check the address, user and password -
       or, if it takes keys only, make 'ssh $target' work first (ssh-copy-id $target)"
  host_ssh_raw "$target" exit 2>/dev/null \
    || die "cg's key is on $target, but it still does not let cg in with it - is PubkeyAuthentication off in its sshd_config?"
  log "cg's key is on $target: no password from now on"
}

cmd_host_add() { # cmd_host_add [name] --ssh <target>
  local name="" target="" why facts key
  while (( $# )); do
    # --ssh with nothing after it: `shift 2` with one argument shifts none, and
    # the loop spun forever at full CPU instead of saying how to use it.
    case $1 in --ssh) (( $# >= 2 )) || die "usage: cg host add [name] --ssh <user@address>"
                      target=$2; shift 2 ;;
               -*) shift ;; *) name=$1; shift ;; esac
  done
  [[ -n $target ]] || die "usage: cg host add [name] --ssh <user@address>"
  # The same address: known before anything is asked, a password least of all.
  why=$(host_added_as "" "$target")
  [[ -z $why ]] || die "$target is already added, as '$why'"
  if [[ -n $name ]]; then
    why=$(host_name_ok "$name") || die "$why"
    [[ -z $(host_get "$name" ssh) ]] || die "there is already a machine called '$name'"
  fi
  say "reaching $target over ssh"
  host_let_in "$target"
  facts=$(host_facts "$target")
  [[ -n $facts ]] || die "connected, but $target did not say what it is"
  # The same machine by another address - its IP once, its tailnet name now -
  # added twice was two cards, two setups and two of cg's keys on one machine.
  key=$(host_machine_key "$facts")
  why=$(host_added_as "$key" "$target")
  [[ -z $why ]] || die "$target is a machine already added, as '$why' - the same machine, by another address"
  if [[ -z $name ]]; then
    name=$(host_name_from "$(_fact "$facts" hostname)")
    why=$(host_name_ok "$name") || die "its own name, '$name', will not do ($why) - give it one"
    [[ -z $(host_get "$name" ssh) ]] || die "there is already a machine called '$name' - give this one another name"
  fi
  host_set "$name" ssh "$target" os "$(_fact "$facts" os)" machine "$key"
  if [[ $(_fact "$facts" os) == Windows ]]; then
    log "Windows - added. Setting a Windows machine up is not built yet (docs/own-machine-plan.md)."
    return 0
  fi
  host_set "$name" family "$(host_family "$facts")" user "$(_fact "$facts" user)"
  log "$(_fact "$facts" pretty) ($(_fact "$facts" arch)), signed in as $(_fact "$facts" user)"
  log "GPU: $(_fact "$facts" nvidia)$( [[ -z $(_fact "$facts" nvidia) ]] && _fact "$facts" gpu)"
  [[ $(host_family "$facts") == unsupported ]] \
    && log "note: cg sets up Ubuntu, Debian, Arch (and its family) and Fedora - this one it can only stream from once you install Sunshine yourself"
  log "added '$name'. Next: cg host setup $name"
}

# host_sudo_ask <target> - the sudo password, asked once for a whole setup (it
# runs root steps more than once, and asking each time asked twice). Handed to
# sudo on the machine's stdin; never saved, never on a command line.
host_sudo_ask() {
  cg_can_ask || die "the machine wants a sudo password, and there is no one to ask - run this in a terminal"
  cg_ask_secret host-sudo "  sudo password for $1: "
}

# The Tailscale address this laptop reaches it at - only if it is on THIS tailnet.
host_ts_ip() { # host_ts_ip <ip-the-machine-reports>
  [[ -n $1 ]] && tailscale status 2>/dev/null | awk -v ip="$1" '$1 == ip {print $1; exit}'
}

# cmd_host_setup <name> - the build every machine gets, run on yours. The same
# modules the AWS box boots with (lib/bootstrap.d, assembled by lib/render.sh),
# here as a machine of yours: each step adds only what is missing, and the AWS
# box's own are left out (00-header.sh, aws_box). Then the same second half as
# the AWS box (lib/build.sh): its log followed, the Sunshine login, Moonlight
# paired, Steam. Safe to run again.
cmd_host_setup() {
  local name=${1:-} t facts fam pw="" key="" f how mk
  [[ -n $name ]] || die "usage: cg host setup <name>"
  t=$(host_get "$name" ssh); [[ -n $t ]] || die "no machine called '$name' - add it: cg host add $name --ssh <user@address>"
  # In, before anything: a machine whose key was taken off asks once for its
  # password here, rather than failing every step after.
  host_let_in "$t"
  say "asking $name what it is"
  facts=$(host_facts "$t"); [[ -n $facts ]] || die "$t did not answer over ssh"
  # A machine added before cg knew who machines are: learned now, so adding
  # it again by another address is caught.
  mk=$(host_machine_key "$facts")
  [[ -n $mk && -z $(host_get "$name" machine) ]] && host_set "$name" machine "$mk"
  [[ $(_fact "$facts" os) == Windows ]] && die "setting a Windows machine up is not built yet - see docs/own-machine-plan.md"
  fam=$(host_family "$facts")
  [[ $fam != unsupported ]] || die "cg sets up Ubuntu, Debian, Arch and Fedora; $(_fact "$facts" pretty) is not one."
  [[ $(_fact "$facts" arch) == x86_64 ]] || die "x86_64 only - Steam and Proton need it ($(_fact "$facts" arch) here)"
  [[ $fam != ubuntu || -n $(_fact "$facts" ubuntu_version) ]] \
    || die "$(_fact "$facts" pretty) is Ubuntu-based, but which Ubuntu release it is could not be read"
  log "$(_fact "$facts" pretty), signed in as $(_fact "$facts" user)"

  # The build runs as root: the sudo password, once, and checked before
  # anything runs, so a typo is said here and not halfway through.
  if [[ $(_fact "$facts" sudo) != nopass ]]; then
    say "root on $name - asked once, never saved"
    pw=$(host_sudo_ask "$t")
    [[ -n $pw ]] || die "no sudo password given - nothing was changed on $name"
    printf '%s\n' "$pw" | host_ssh --in "$t" "sudo -S -p '' -v" >/dev/null 2>&1 \
      || die "sudo did not accept that password on $name - nothing was changed"
  fi
  # The auth key only when it has to join; already on the tailnet, it stays as
  # it is. It is the AWS boxes' reusable, non-ephemeral key: an ephemeral one
  # would drop this machine whenever it slept. The stored one, one minted from
  # the API token, or - with neither - one asked for now, and saved.
  if [[ -z $(_fact "$facts" ts_ip) ]]; then
    # shellcheck source=lib/laptop.sh
    source lib/laptop.sh
    key=$(tskey_auth_ensure "$name") || key=""
    if [[ -z $key ]]; then
      cg_can_ask || die "$name is not on your tailnet, and there is no Tailscale auth key to join it with - cg creds tailscale authkey saves one"
      log "$name is not on your tailnet yet: it joins with a Tailscale auth key"
      tskey_auth_set || die "no usable auth key - nothing was changed on $name"
      key=$TAILSCALE_AUTH_KEY
    fi
  fi

  say "starting the build on $name"
  # shellcheck source=lib/render.sh
  source lib/render.sh
  # Copied as a file readable by root alone - it may carry the auth key - and
  # deleted by the build as it starts (00-header.sh).
  f=$(TS_AUTHKEY="$key" TS_HOST="$name" HOST_TGZ_URL="" S3_BUCKET="" CG_APPS="" CG_LOGIN="" \
      CG_RESERVE_GB="" CG_TARGET=host CG_USER="$(_fact "$facts" user)" CG_FAMILY="$fam" render_bootstrap \
      | host_ssh --in "$t" 'f=$(mktemp); cat > "$f"; chmod 600 "$f"; echo "$f"') \
    || die "could not copy the build to $name"
  # Detached, so it outlives this ssh as user-data outlives nobody watching. The
  # last run's marker, result and log go first, so the laptop never follows -
  # or calls stopped - an old one.
  local run='rm -f /var/lib/cloud-gaming-ready /var/lib/cloud-gaming-bootstrap.rc /var/log/cloud-gaming-bootstrap.log; setsid nohup bash "$1" >/dev/null 2>&1 </dev/null &'
  if [[ -n $pw ]]; then
    printf '%s\n' "$pw" | host_ssh --in "$t" "sudo -S -p '' sh -c '$run' _ '$f'" \
      || die "the build could not be started on $name"
  else
    host_ssh "$t" "sudo -n sh -c '$run' _ '$f'" || die "the build could not be started on $name"
  fi

  # The second half, as every build: lib/build.sh. Reached as host_ssh reaches
  # it - your ssh, with cg's key; its tailnet address is read once it has joined.
  # shellcheck source=lib/build.sh
  source lib/build.sh
  build_after_stream() {
    facts=$(host_facts "$t")
    # The machine's login, when another device has put one there: the one to
    # check first - a setup from here resets it only when that fails too.
    local shared; shared=$(host_login_shared "$facts")
    if [[ -n $shared ]]; then
      SUNSHINE_USER=${shared%%$'\t'*} SUNSHINE_PASS=${shared#*$'\t'}
      _host_save_login SUNSHINE_USER "$SUNSHINE_USER"; _host_save_login SUNSHINE_PASS "$SUNSHINE_PASS"
    fi
    BUILD_IP=$(host_ts_ip "$(_fact "$facts" ts_ip)")
    [[ -n $BUILD_IP ]] || die "$name is on Tailscale, but not on the tailnet this laptop is on - sign it in to the same one"
    log "on the tailnet at $BUILD_IP"
    host_set "$name" ts_ip "$BUILD_IP"
    # Key expiry off, as for the AWS boxes - a home machine must not drop out
    # after 180 days. Needs the API token; without it, it is said, not skipped.
    lib/tailnet-expiry.sh "$(tailscale status 2>/dev/null | awk -v ip="$BUILD_IP" '$1 == ip {print $2; exit}')" 2>&1 \
      | cg_relay '    ' || true
  }
  _host_save_login() { case $1 in SUNSHINE_USER) host_set "$name" sunshine_user "$2" ;; SUNSHINE_PASS) host_set "$name" sunshine_pass "$2" ;; esac; }
  SUNSHINE_USER=$(host_get "$name" sunshine_user); SUNSHINE_PASS=$(host_get "$name" sunshine_pass)
  BUILD_SSH="$t" BUILD_KEY="" BUILD_IP="" BUILD_SAVE=_host_save_login BUILD_NAME="$name" BUILD_TARGET=host
  [[ -f $(host_key) ]] && BUILD_KEY=$(host_key)
  build_finish || die "the build on $name did not finish - its log is /var/log/cloud-gaming-bootstrap.log there"
  # The login it ended with, kept on the machine for every other device.
  host_login_share "$t" "$(host_get "$name" sunshine_user)" "$(host_get "$name" sunshine_pass)" \
    || log "note: could not keep the Sunshine login on $name - other devices may need to run setup"

  # What cg does not change, said rather than fixed.
  [[ -n $(_fact "$facts" session) ]] || log "note: no desktop is signed in on $name right now - Sunshine streams a signed-in desktop"
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
    # Its tailnet address answered, which nothing but the tailnet reaches: on
    # it, whatever one ping said - a single tailscale ping can go unanswered on
    # a path that streams fine, and the card said "not connected" beside Play.
    ts_on=yes
    # Once a process: a status read stands alone, and nothing loaded it before.
    # shellcheck source=lib/sunshine-login.sh
    declare -F sun_login_ok >/dev/null || source lib/sunshine-login.sh
    local lu lp shared su sp
    lu=$(host_get "$name" sunshine_user); lp=$(host_get "$name" sunshine_pass)
    shared=$(host_login_shared "$facts"); su=${shared%%$'\t'*}; sp=${shared#*$'\t'}
    if sun_login_ok "$ip" "$lu" "$lp"; then
      login=yes
      # This device holds the one that works: kept on the machine, so the others find it.
      if [[ $ssh_ok == yes && ( $su != "$lu" || $sp != "$lp" ) ]]; then host_login_share "$t" "$lu" "$lp" || true; fi
    elif [[ -n $shared ]] && sun_login_ok "$ip" "$su" "$sp"; then
      # Another device's, which works: this one takes it.
      login=yes
      host_set "$name" sunshine_user "$su"; host_set "$name" sunshine_pass "$sp"
    fi
    command -v moonlight >/dev/null && timeout 20 moonlight list "$ip" 2>/dev/null | grep -q . && paired=yes
  fi
  if cg_json || [[ ${2:-} == --json ]]; then
    N="$name" T="$t" IP="$ip" SSH_OK=$ssh_ok TS_ON=$ts_on SUN=$sun_up LOGIN=$login PAIRED=$paired \
    OS="$(host_get "$name" os)" FAM="$(host_get "$name" family)" READY="$(host_get "$name" ready)" \
    SESSION="$(_fact "$facts" session)" STEAM="$(_fact "$facts" steam)" PRETTY="$(_fact "$facts" pretty)" \
    GPU="$(_fact "$facts" nvidia)" GPUS="$(_fact "$facts" gpu)" \
    python3 -c 'import json, os
g = os.environ.get; yes = lambda k: g(k) == "yes"
print(json.dumps({"name": g("N"), "ssh": g("T"), "os": g("OS") or None, "os_name": g("PRETTY") or None,
  "family": g("FAM") or None,
  "tailnet_ip": g("IP") or None, "reachable": yes("SSH_OK"), "online": yes("TS_ON"),
  "sunshine": yes("SUN"), "login_ok": yes("LOGIN"), "paired": yes("PAIRED"),
  "set_up": g("READY") == "yes", "desktop": g("SESSION") or None,
  "steam": bool(g("STEAM")) if yes("SSH_OK") else None,
  # The NVIDIA name when there is one; otherwise what lspci calls the card.
  "gpu": g("GPU") or (g("GPUS") or "").split(";")[0] or None}, indent=2))'
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
  # Two steps, which the app shows as the AWS machine's session is shown: the
  # machine answering, then the stream.
  say "checking $name is ready to stream"
  [[ $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$ip:47990/welcome" 2>/dev/null) != 000 ]] \
    || die "Sunshine is not answering on $name ($ip) - is it on, and a desktop signed in?"
  session_claim
  say "streaming from $name"
  stream_play "$ip" "${GAME_APP:-Desktop}"
  session_release
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
      if host_key_remove "$(host_get "$1" ssh)" 2>/dev/null; then
        log "took cg's key off it"
      else
        log_as warn "could not reach it to take cg's key off - that one line stays in its ~/.ssh/authorized_keys"
      fi
      host_forget "$1"; log "forgot '$1' - nothing else on the machine was changed" ;;
    *) die "usage: cg host [list|add [name] --ssh <user@address>|setup <name>|status <name>|open <name>|remove <name>]" ;;
  esac
}
