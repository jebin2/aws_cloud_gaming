#!/usr/bin/env bash
# What the laptop needs: `cg check` reports it, `cg check --fix` installs it.
# Sourced by lib/setup, after lib/common.sh.
#
# Linux only, through pacman, apt, dnf or zypper. Accounts and keys stay yours:
# --fix installs software and starts the two sign-ins (Tailscale, AWS), and asks
# once before it uses sudo.

# In install order: curl fetches the AWS CLI and Tailscale on distros without packages.
LAPTOP_TOOLS=(python3 ssh curl aws tailscale moonlight)

laptop_has() { command -v "$1" >/dev/null 2>&1; }

# On its own, so a test can stand in for a terminal.
laptop_tty() { [[ -t 0 ]]; }

laptop_pm() {
  local pm
  for pm in pacman apt-get dnf zypper; do
    laptop_has "$pm" && { echo "$pm"; return 0; }
  done
  return 1
}

# The tools that are absent, one per line. AWS CLI v1 counts as absent: the
# account-plan check (`aws freetier`) exists only in v2.
laptop_missing() {
  local t
  for t in "${LAPTOP_TOOLS[@]}"; do
    case $t in
      aws) laptop_has aws && aws --version 2>&1 | grep -q '^aws-cli/2' || echo aws ;;
      ssh) { laptop_has ssh && laptop_has scp; } || echo ssh ;;
      *)   laptop_has "$t" || echo "$t" ;;
    esac
  done
}

laptop_tailscale_down() { laptop_has tailscale && ! tailscale status >/dev/null 2>&1; }

laptop_label() {
  case $1 in
    aws) echo "AWS CLI v2" ;; ssh) echo "OpenSSH (ssh, scp)" ;;
    tailscale) echo "Tailscale" ;; moonlight) echo "Moonlight" ;; *) echo "$1" ;;
  esac
}

laptop_pkg() { # laptop_pkg <pm> <tool> -> its package; nothing when it installs another way
  case $1:$2 in
    pacman:aws)         echo aws-cli-v2 ;;
    pacman:python3)     echo python ;;
    pacman:ssh)         echo openssh ;;
    pacman:tailscale)   echo tailscale ;;
    apt-get:ssh)        echo openssh-client ;;
    dnf:ssh|zypper:ssh) echo openssh-clients ;;
    *:python3|*:curl)   echo "$2" ;;
    *:moonlight)        echo moonlight-qt ;;
  esac
}

laptop_manual() { # laptop_manual <tool> -> where to get it by hand
  case $1 in
    aws)       echo "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
    tailscale) echo "https://tailscale.com/download" ;;
    # cg runs `moonlight`, which a Flatpak does not put on PATH.
    moonlight) echo "https://github.com/moonlight-stream/moonlight-qt/releases (cg needs a moonlight command on PATH)" ;;
    ssh)       echo "your distro's OpenSSH client package" ;;
    *)         echo "your distro's $1 package" ;;
  esac
}

laptop_plan() { # laptop_plan <pm> <tool> -> what --fix will run, in words
  local pkg; pkg=$(laptop_pkg "$1" "$2")
  if [[ -n $pkg ]]; then
    case $1 in
      pacman) echo "sudo pacman -S $pkg" ;;  apt-get) echo "sudo apt-get install $pkg" ;;
      dnf)    echo "sudo dnf install $pkg" ;; zypper) echo "sudo zypper install $pkg" ;;
    esac
    return
  fi
  case $2 in
    aws)       echo "AWS's official installer, into ~/.local (no sudo)" ;;
    tailscale) echo "Tailscale's install script, https://tailscale.com/install.sh (uses sudo)" ;;
  esac
}

laptop_pkg_install() { # laptop_pkg_install <pm> <package>
  case $1 in
    pacman)  sudo pacman -S --needed --noconfirm "$2" ;;
    apt-get) if [[ -z ${_LAPTOP_APT_FRESH:-} ]]; then
               sudo apt-get update -qq || return 1
               _LAPTOP_APT_FRESH=1
             fi
             sudo apt-get install -y "$2" ;;
    dnf)     sudo dnf install -y "$2" ;;
    zypper)  sudo zypper --non-interactive install "$2" ;;
  esac
}

# AWS's own v2 installer, into the home directory. Distro packages are often v1.
laptop_aws_zip() { # laptop_aws_zip <pm>
  local tmp rc=0
  laptop_has unzip || laptop_pkg_install "$1" unzip || return 1
  tmp=$(mktemp -d) || return 1
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp/awscli.zip" \
    && unzip -q "$tmp/awscli.zip" -d "$tmp" \
    && "$tmp/aws/install" --update -i "$HOME/.local/aws-cli" -b "$HOME/.local/bin" || rc=1
  rm -rf "$tmp"
  (( rc == 0 )) || return 1
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH"
       log "the AWS CLI is in ~/.local/bin, which is not on your PATH - add it to your shell profile" ;;
  esac
}

laptop_install() { # laptop_install <pm> <tool>
  local pkg; pkg=$(laptop_pkg "$1" "$2")
  if [[ -n $pkg ]]; then laptop_pkg_install "$1" "$pkg"; return; fi
  case $2 in
    aws)       laptop_aws_zip "$1" ;;
    tailscale) curl -fsSL https://tailscale.com/install.sh | sh ;;
    *)         return 1 ;;
  esac
}

laptop_tailscale_up() {
  if laptop_has systemctl && ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    sudo systemctl enable --now tailscaled || return 1
  fi
  # Prints a login link and waits for it.
  sudo tailscale up
}

# What is missing, all at once. Returns 0 when the build can go ahead: Moonlight
# alone does not stop it, since streaming needs it and building does not.
laptop_report() {
  local missing t ready=0 v found=()
  missing=$(laptop_missing)
  for t in "${LAPTOP_TOOLS[@]}"; do
    grep -qx "$t" <<<"$missing" && continue
    if [[ $t == aws ]]; then
      v=$(aws --version 2>&1 | sed -n 's#^aws-cli/\([^ ]*\).*#\1#p')
      found+=("AWS CLI v2${v:+ ($v)}")
    else
      found+=("$(laptop_label "$t")")
    fi
  done
  if (( ${#found[@]} )); then
    v=$(printf '%s, ' "${found[@]}"); log_as ok "installed: ${v%, }"
  fi
  for t in $missing; do
    if [[ $t == moonlight ]]; then
      log "WARNING: Moonlight not found - building does not need it, streaming does"
    else
      log "missing: $(laptop_label "$t")"; ready=1
    fi
    laptop_pm >/dev/null || log "  install it by hand: $(laptop_manual "$t")"
  done
  if laptop_tailscale_down; then
    log "Tailscale is installed but not signed in, or not running"; ready=1
  elif laptop_has tailscale; then
    log_as ok "Tailscale signed in"
  fi
  if [[ -n $missing ]] || (( ready )); then
    laptop_pm >/dev/null && log "cg check --fix installs and signs in what is missing, after asking"
  fi
  return "$ready"
}

# Installs what is missing and signs Tailscale in. Returns 0 when nothing is left.
laptop_fix() {
  local missing pm="" t a
  missing=$(laptop_missing)
  if [[ -z $missing ]] && ! laptop_tailscale_down; then
    log "laptop: everything is installed"
    return 0
  fi
  if [[ -n $missing ]] && ! pm=$(laptop_pm); then
    log "no supported package manager (pacman, apt, dnf, zypper) - install these by hand:"
    for t in $missing; do log "  $(laptop_label "$t"): $(laptop_manual "$t")"; done
    return 1
  fi
  if ! laptop_tty; then
    log "--fix asks before it uses sudo - run it in a terminal"
    return 1
  fi

  log "--fix will:"
  for t in $missing; do log "  install $(laptop_label "$t") - $(laptop_plan "$pm" "$t")"; done
  log "  sign this laptop in to Tailscale if it is not, with sudo tailscale up (prints a login link)"
  # A reply with no newline still counts; only no reply at all (end of input) is a no.
  read -rp "    go ahead? [Y/n] " a || [[ -n ${a:-} ]] || a=n
  if [[ ${a:-Y} =~ ^[Nn] ]]; then
    log "nothing changed"
    return 1
  fi

  for t in $missing; do
    log "installing $(laptop_label "$t")"
    laptop_install "$pm" "$t" || log "could not install $(laptop_label "$t")"
  done
  hash -r
  if laptop_tailscale_down; then
    log "signing in to Tailscale"
    laptop_tailscale_up || log "the Tailscale sign-in did not finish"
  fi
  [[ -z $(laptop_missing) ]] && ! laptop_tailscale_down
}
