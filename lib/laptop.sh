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

# A REAL terminal, and only that. This gates the half of --fix that shells out
# to sudo: `sudo pacman -S aws-cli-v2` has to be able to prompt for a password,
# and in the app there is nowhere to type one - sudo exits with "no tty present
# and no askpass program specified". So installing stays a terminal job.
#
# Asking a question is a different matter, and `cg_can_ask` is that one: under
# the app a question is an event and the answer comes back on stdin. Sharing one
# test for both is what made `cg check --fix` in the app install everything it
# could and then silently skip the one thing it cannot install - the access key,
# which needs no terminal and no sudo at all.
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

# How to become root from HERE. A terminal has sudo; the app has neither a
# terminal nor anywhere for sudo to ask for a password, so it goes through
# polkit, which puts the password prompt on the desktop where the person is
# already looking. With neither, installing is not possible from here and the
# caller says so rather than failing inside pacman.
#
# pkexec resets the environment and wants an absolute path, so the program is
# resolved here rather than left to a PATH it will not have.
laptop_root() {
  if laptop_tty; then echo sudo; return 0; fi
  if laptop_has pkexec && [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then echo pkexec; return 0; fi
  return 1
}
laptop_root_why() {   # why root is out of reach, in one line
  laptop_has pkexec || { echo "no terminal, and polkit (pkexec) is not installed"; return; }
  echo "no terminal, and no desktop session for polkit to show a password prompt on"
}

laptop_pkg_install() { # laptop_pkg_install <pm> <package>
  local as; as=$(laptop_root) || {
    log "cannot install from here: $(laptop_root_why)"
    log "  in a terminal:  cg deps install"
    return 1
  }
  local pm; pm=$(command -v "$1") || return 1
  case $1 in
    pacman)  "$as" "$pm" -S --needed --noconfirm "$2" ;;
    apt-get) if [[ -z ${_LAPTOP_APT_FRESH:-} ]]; then
               "$as" "$pm" update -qq || return 1
               _LAPTOP_APT_FRESH=1
             fi
             "$as" "$pm" install -y "$2" ;;
    dnf)     "$as" "$pm" install -y "$2" ;;
    zypper)  "$as" "$pm" --non-interactive install "$2" ;;
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

# The sign-in, from a terminal or from the app. Root is needed twice - to start
# tailscaled and to run `tailscale up` - and in a window that is polkit's job,
# the same as installing.
#
# `tailscale up` prints a login URL and then WAITS for someone to visit it, so
# every line is relayed as it arrives rather than collected at the end: the URL
# is the whole point and it is useless after the command returns.
laptop_tailscale_up() {
  local as; as=$(laptop_root) || {
    log "cannot sign in from here: $(laptop_root_why)"
    log "  in a terminal:  sudo tailscale up"
    return 1
  }
  laptop_has tailscale || { log_as fail "Tailscale is not installed"; return 1; }
  if laptop_has systemctl && ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    log "starting tailscaled"
    "$as" "$(command -v systemctl)" enable --now tailscaled || {
      log_as fail "could not start tailscaled"
      return 1
    }
  fi
  log "finishing the sign-in needs a browser - the link appears below"
  local line rc
  # stdbuf, where it exists: tailscale up writes the URL and then blocks, and a
  # block-buffered pipe would hold that line until the command ended - which is
  # after the sign-in it is asking for.
  local unbuf=(); laptop_has stdbuf && unbuf=(stdbuf -oL -eL)
  while IFS= read -r line; do
    case $line in
      *https://login.tailscale.com/*)
        # Said on its own line, with nothing else on it, so the app can lift the
        # URL out and offer it as a link.
        log "sign in here: $(printf '%s' "$line" | grep -oE 'https://login\.tailscale\.com/[^[:space:]]+')" ;;
      *) [[ -n ${line//[[:space:]]/} ]] && log "$line" ;;
    esac
  done < <("${unbuf[@]}" "$as" "$(command -v tailscale)" up 2>&1)
  # The pipeline's own status, not the loop's.
  if laptop_tailscale_down; then
    log_as fail "still not signed in"
    return 1
  fi
  log_as ok "signed in"
}

# tskey_signin - what `cg creds tailscale signin` runs.
tskey_signin() {
  if laptop_has tailscale && ! laptop_tailscale_down; then
    log_as ok "already signed in"
    return 0
  fi
  say "tailscale sign-in"
  laptop_tailscale_up
}

# laptop_aws_keys <region>: an access key, for --fix when no AWS credentials work.
# Asks for the two things only a person has - `aws configure` also asked for a
# default region and an output format, and cg sets the region itself and passes
# --output on every call. The secret is read without echo.
laptop_aws_keys() {
  local region=$1 key_id secret who
  log "AWS credentials: paste an access key (IAM > Users > Security credentials > Create access key)"
  key_id=$(cg_ask aws-access-key-id "    access key id: ")
  secret=$(cg_ask_secret aws-secret-access-key "    secret access key: ")
  if [[ -z ${key_id:-} || -z ${secret:-} ]]; then
    log "no key given - nothing saved"
    return 1
  fi
  # Checked BEFORE it is written. The old order wrote first and checked after,
  # so one mistyped character replaced a key that worked, and every screen then
  # reported rejected credentials - about the key you had just destroyed.
  #
  # The candidate goes in the environment of this one call, where it beats the
  # file without touching it. AWS_PROFILE and a session token would both win
  # over it, so they are unset for the call.
  # -u before the assignments: env takes its options first, and the other order
  # makes it look for a program called "-u".
  if ! who=$(env -u AWS_SESSION_TOKEN -u AWS_PROFILE \
                 AWS_ACCESS_KEY_ID="$key_id" AWS_SECRET_ACCESS_KEY="$secret" \
             aws sts get-caller-identity --query Account --output text 2>&1); then
    log_as fail "AWS rejected that key: $(printf '%s' "$who" | tr '\n' ' ' | sed -E 's/  +/ /g')"
    log "  nothing was saved - the key you had before is untouched"
    log "  check the key is Active: IAM > Users > Security credentials"
    return 1
  fi
  aws configure set aws_access_key_id "$key_id" \
    && aws configure set aws_secret_access_key "$secret" \
    && aws configure set region "$region" \
    && log "saved to ~/.aws/credentials, profile ${AWS_PROFILE:-default} - not to .env (.env.example says why)" \
    && log_as ok "credentials work (account $who)"
}

# laptop_aws_source - where the working AWS key comes from, in words, for cg
# check's line. From `aws configure list`, which shows the key masked. It prints
# "NAME : VALUE : TYPE : LOCATION"; older CLI versions pad with spaces instead.
laptop_aws_source() {
  local out type profile file=${AWS_SHARED_CREDENTIALS_FILE:-"~/.aws/credentials"}
  out=$(aws configure list 2>/dev/null) || return 1
  IFS=$'\t' read -r type profile < <(awk '
    { line = $0
      if (line ~ / : /) gsub(/[[:space:]]*:[[:space:]]*/, "\t", line)
      else { gsub(/<not set>/, "-", line); gsub(/[[:space:]]+/, "\t", line); sub(/^\t/, "", line) }
      split(line, f, "\t")
      if (f[1] == "access_key") t = f[3]
      if (f[1] == "profile")    p = f[2] }
    END { printf "%s\t%s\n", t, p }' <<<"$out")
  [[ -z $profile || $profile == "-" || $profile == "<not set>" ]] && profile=${AWS_PROFILE:-default}
  case $type in
    shared-credentials-file) echo "$file, profile $profile" ;;
    config-file)             echo "~/.aws/config, profile $profile" ;;
    # cg loads .env into the environment, so a key there would silently win.
    env)                     echo "AWS_ACCESS_KEY_ID in the environment - it wins over ~/.aws/credentials" ;;
    "")                      return 1 ;;
    *)                       echo "$type, profile $profile" ;;
  esac
}

# What is missing, all at once. Returns 0 when nothing is. Moonlight stops it too:
# cg init pairs it and cg open streams with it.
# laptop_report 1: after --fix, so what is left is for you to install - suggesting
# --fix again would only send you round in a loop.
laptop_report() {
  local after_fix=${1:-0} missing t ready=0 v found=() by_hand=0
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
  { laptop_pm >/dev/null && (( ! after_fix )); } || by_hand=1
  for t in $missing; do
    log_as fail "missing: $(laptop_label "$t")"; ready=1
    (( by_hand )) && log "  install it yourself: $(laptop_manual "$t")"
  done
  if laptop_tailscale_down; then
    log_as fail "Tailscale is installed but not signed in, or not running"; ready=1
    (( after_fix )) && log "  sign in yourself: sudo tailscale up"
  elif laptop_has tailscale; then
    log_as ok "Tailscale signed in"
  fi
  # --fix can sign Tailscale in with no package manager, so offer it for that too.
  if (( ready && ! after_fix )) && { laptop_pm >/dev/null || [[ -z $missing ]]; }; then
    log "cg check --fix installs and signs in what is missing, after asking"
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
    log "--fix installs with sudo, which needs a terminal to ask for your password"
    log "  run this in a terminal:  cg check --fix"
    log "  the access key does not need sudo: cg creds set, or Settings > AWS credentials"
    return 1
  fi

  log "--fix will:"
  for t in $missing; do log "  install $(laptop_label "$t") - $(laptop_plan "$pm" "$t")"; done
  log "  sign this laptop in to Tailscale if it is not, with sudo tailscale up (prints a login link)"
  if ! cg_confirm fix-go-ahead "    go ahead? [Y/n] " Y; then
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

# --- the AWS access key, as a command ----------------------------------------
# A new laptop has no credentials, and everything on every screen is then
# UNKNOWN - not empty. The banner used to say "Settings - or cg check --fix -
# takes a new key", and neither was true: Settings had no field for it, and
# --fix skipped the question for want of a terminal. This is what both now call.

# creds_mask <key-id> - the last four, which is what AWS shows in the console.
creds_mask() { local k=${1:-}; [[ -n $k ]] && printf '****%s' "${k: -4}"; }

# creds_facts - cli|source|key_id|account|arn|error, one per line as k=v.
# Each line is one fact so a caller never parses prose, and an absent fact is an
# empty value rather than a missing line.
creds_facts() {
  local src="" kid="" acct="" arn="" err=""
  if ! laptop_has aws; then
    printf 'cli=no\nsource=\nkey_id=\naccount=\narn=\nerror=%s\n' \
      "the AWS CLI is not installed - cg check --fix installs it"
    return 0
  fi
  src=$(laptop_aws_source 2>/dev/null) || src=""
  kid=$(aws configure get aws_access_key_id 2>/dev/null) || kid=""
  # One free call, and the only one that can say whether a key actually works.
  local who
  if who=$(aws sts get-caller-identity --query 'join(`|`, [Account, Arn])' \
             --output text 2>&1); then
    acct=${who%%|*}; arn=${who##*|}
  else
    # The CLI's own words, flattened to one line: "InvalidClientTokenId" and
    # "SignatureDoesNotMatch" mean different things to whoever has to fix it.
    err=$(printf '%s' "$who" | tr '\n' ' ' | sed -E 's/  +/ /g; s/^ +| +$//g')
    err=${err:-AWS rejected the credentials}
  fi
  printf 'cli=yes\nsource=%s\nkey_id=%s\naccount=%s\narn=%s\nerror=%s\n' \
    "$src" "$(creds_mask "$kid")" "$acct" "$arn" "$err"
}

creds_json() {
  creds_facts | python3 -I -c '
import json, sys
d = dict(l.split("=", 1) for l in sys.stdin.read().splitlines() if "=" in l)
# valid is a THIRD state short of true/false everywhere else in this app: with
# no CLI nothing was asked, so nothing was rejected either.
valid = None if d.get("cli") == "no" else (not d.get("error"))
print(json.dumps({
    "cli":     d.get("cli") == "yes",
    "source":  d.get("source") or None,
    "key_id":  d.get("key_id") or None,
    "account": d.get("account") or None,
    "arn":     d.get("arn") or None,
    "valid":   valid,
    "error":   d.get("error") or None,
}, indent=2))'
}

creds_show() {
  local cli source key_id account arn error
  while IFS='=' read -r k v; do
    case $k in cli) cli=$v ;; source) source=$v ;; key_id) key_id=$v ;;
               account) account=$v ;; arn) arn=$v ;; error) error=$v ;; esac
  done < <(creds_facts)
  say "aws credentials"
  if [[ $cli == no ]]; then
    log_as fail "aws cli          not installed  <- cg check --fix installs it"
    return 1
  fi
  log_as "$([[ -n ${key_id:-} ]] && echo ok || echo warn)" \
    "access key       ${key_id:-none configured}"
  log_as info "from             ${source:-not known}"
  if [[ -n ${error:-} ]]; then
    log_as fail "accepted         no  <- $error"
    log "  set a working key: cg creds set   (or the Set access key button in Settings)"
    return 1
  fi
  log_as ok "accepted         yes"
  log_as info "account          ${account:-unknown}"
  log_as info "identity         ${arn:-unknown}"
}

# creds_set <region> - ask for an access key and keep it if AWS takes it.
creds_set() {
  local region=${1:-${REGION:-}}
  laptop_has aws || die "the AWS CLI is not installed - run cg check --fix first"
  cg_can_ask || die "cg creds set has to ask for the key - run it in a terminal, or use the app"
  # laptop_aws_keys verifies before it writes and says what happened either
  # way, so there is nothing to add here - and a second sts call would only be
  # a second chance to disagree with the first.
  laptop_aws_keys "$region"
}

# --- the dependency list, as data ---------------------------------------------
# One row per tool: what it is, whether it is here, what would install it, and
# how to do it by hand. The app draws a page from this; `cg check` says the same
# thing in prose.
deps_json() {
  local pm t miss; pm=$(laptop_pm 2>/dev/null) || pm=""
  miss=$(laptop_missing)
  local root why=""; root=$(laptop_root 2>/dev/null) || { root=""; why=$(laptop_root_why); }
  {
    for t in "${LAPTOP_TOOLS[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$t" "$(laptop_label "$t")" \
        "$(grep -qx "$t" <<<"$miss" && echo no || echo yes)" \
        "$(laptop_why "$t")" \
        "$([[ -n $pm ]] && laptop_plan "$pm" "$t")" \
        "$(laptop_manual "$t")"
    done
  } | PM="$pm" ROOT="$root" WHY="$why" \
      TS_SIGNED="$(laptop_has tailscale && { laptop_tailscale_down && echo no || echo yes; } || echo -)" \
      python3 -I -c '
import json, os, sys
tools = []
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    tool, label, present, why, plan, manual = (line.split("\t") + [""] * 6)[:6]
    tools.append({"tool": tool, "label": label, "present": present == "yes",
                  "why": why or None, "plan": plan or None, "manual": manual or None})
g = os.environ.get
ts = g("TS_SIGNED")
print(json.dumps({
  "tools": tools,
  "package_manager": g("PM") or None,
  # How this process would become root, and why it cannot when it cannot. The
  # app needs this to know whether an Install button can do anything at all.
  "root": g("ROOT") or None,
  "root_blocked": g("WHY") or None,
  # Installed but not signed in is its own state: nothing to install, and
  # nothing works until someone signs in.
  "tailscale_signed_in": None if ts == "-" else ts == "yes",
}, indent=2))'
}

# What each tool is FOR. A list of names tells you nothing about which ones you
# can live without, and the honest answer is that cg needs all of them.
laptop_why() {
  case $1 in
    python3)   echo "renders every --json answer this app reads" ;;
    ssh)       echo "every command cg runs on the box goes through it" ;;
    curl)      echo "fetches the AWS CLI and Tailscale where there is no package" ;;
    aws)       echo "the only thing that talks to AWS - without it nothing can be read" ;;
    tailscale) echo "the private network the box joins; there is no public SSH port" ;;
    moonlight) echo "the stream itself - this is what you play on" ;;
    *)         echo "" ;;
  esac
}

# deps_install [tool...] - install what is missing, or just the ones named.
deps_install() {
  local pm t want=("$@") miss rc=0
  miss=$(laptop_missing)
  if [[ -z $miss ]]; then
    log_as ok "nothing to install - every tool cg needs is here"
    # Installed but signed out is the other half of being ready.
    laptop_tailscale_down || return 0
    log "Tailscale is installed but not signed in"
    laptop_tty || { log "  signing in needs a terminal:  sudo tailscale up"; return 1; }
    laptop_tailscale_up || return 1
    return 0
  fi
  if ! pm=$(laptop_pm); then
    log "no supported package manager (pacman, apt, dnf, zypper) - install these by hand:"
    for t in $miss; do log "  $(laptop_label "$t"): $(laptop_manual "$t")"; done
    return 1
  fi
  (( ${#want[@]} )) || mapfile -t want <<<"$miss"
  say "installing"
  for t in "${want[@]}"; do
    [[ -n $t ]] || continue
    if ! grep -qx "$t" <<<"$miss"; then
      log_as ok "$(laptop_label "$t") is already here"
      continue
    fi
    log "installing $(laptop_label "$t") - $(laptop_plan "$pm" "$t")"
    if laptop_install "$pm" "$t"; then
      hash -r
      log_as ok "$(laptop_label "$t") installed"
    else
      log_as fail "could not install $(laptop_label "$t")"
      log "  by hand: $(laptop_manual "$t")"
      rc=1
    fi
  done
  return $rc
}

# --- the Tailscale API token -------------------------------------------------
# Not the auth key a box joins with - this is the account token that prunes dead
# nodes and turns key expiry off. It is optional, cg says so when it is absent,
# and it is the other half of "the things only you can give cg".
#
# One free call checks it, and it has THREE answers, not two: a token the API
# refuses is not the same as an API nobody could reach.
TS_API="https://api.tailscale.com/api/v2"

tskey_check() { # tskey_check <token> -> prints ok|rejected|unreachable <detail>
  local token=$1 code
  [[ -n $token ]] || { echo "absent"; return; }
  code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
         -H "Authorization: Bearer $token" "$TS_API/tailnet/-/devices" 2>/dev/null) || code=000
  case $code in
    2*)      echo "ok" ;;
    401|403) echo "rejected $code" ;;
    *)       echo "unreachable $code" ;;
  esac
}

# tskey_facts - state|detail|signed_in|node, one per line as k=v.
tskey_facts() {
  local token=${TAILSCALE_API_KEY:-} state detail signed node
  read -r state detail <<<"$(tskey_check "$token")"
  if laptop_has tailscale; then
    laptop_tailscale_down && signed=no || signed=yes
    node=$(tailscale status --json 2>/dev/null \
           | python3 -I -c 'import json,sys
try:    print(json.load(sys.stdin).get("Self", {}).get("DNSName", "").split(".")[0])
except Exception: pass' 2>/dev/null) || node=""
  else
    signed="-"
  fi
  printf 'state=%s\ndetail=%s\nsigned_in=%s\nnode=%s\n' \
    "$state" "${detail:-}" "$signed" "${node:-}"
}

tskey_json() {
  tskey_facts | python3 -I -c '
import json, sys
d = dict(l.split("=", 1) for l in sys.stdin.read().splitlines() if "=" in l)
state = d.get("state", "absent")
signed = d.get("signed_in")
print(json.dumps({
    # present/valid are separate: a token that is set and refused is a
    # different thing to no token at all, and both differ from "the API could
    # not be reached", which says nothing about the token.
    "present": state != "absent",
    "valid":   True if state == "ok" else (False if state == "rejected" else None),
    "state":   state,
    "detail":  d.get("detail") or None,
    "signed_in": None if signed in ("-", "", None) else signed == "yes",
    "node":    d.get("node") or None,
}, indent=2))'
}

tskey_show() {
  local state detail signed node
  while IFS='=' read -r k v; do
    case $k in state) state=$v ;; detail) detail=$v ;; signed_in) signed=$v ;; node) node=$v ;; esac
  done < <(tskey_facts)
  say "tailscale"
  case ${signed:-} in
    yes) log_as ok   "signed in        ${node:-yes}" ;;
    no)  log_as fail "signed in        no  <- sudo tailscale up" ;;
    *)   log_as fail "tailscale        not installed" ;;
  esac
  case ${state:-absent} in
    ok)          log_as ok   "api token        works" ;;
    absent)      log_as warn "api token        not set  (optional: prunes old nodes, turns off key expiry)" ;;
    rejected)    log_as fail "api token        rejected (${detail:-}) <- https://login.tailscale.com/admin/settings/keys"; return 1 ;;
    unreachable) log_as warn "api token        set, but api.tailscale.com did not answer (${detail:-})" ;;
  esac
}

# tskey_set - ask for a token, check it, and only then write it to .env.
tskey_set() {
  local token state detail
  cg_can_ask || die "cg creds set tailscale has to ask for the token - run it in a terminal, or use the app"
  log "Tailscale API token (NOT an auth key): https://login.tailscale.com/admin/settings/keys"
  token=$(cg_ask_secret tailscale-api-token "    api token: ")
  if [[ -z ${token:-} ]]; then
    log "no token given - nothing saved"
    return 1
  fi
  [[ $token =~ ^tskey-[A-Za-z0-9-]+$ ]] || {
    log_as fail "that does not look like a Tailscale token - they start with tskey-"
    return 1
  }
  read -r state detail <<<"$(tskey_check "$token")"
  case $state in
    ok) ;;
    rejected)
      log_as fail "Tailscale rejected that token (${detail:-}) - nothing was saved"
      log "  make one at https://login.tailscale.com/admin/settings/keys (API access token)"
      return 1 ;;
    *)
      log_as fail "could not reach api.tailscale.com (${detail:-}) - nothing was saved"
      log "  nothing is wrong with the token as far as this knows; try again when the network is back"
      return 1 ;;
  esac
  # cg_env_set, not config_set: lib/config.sh belongs to `cg`, and this runs
  # inside lib/setup, which does not have it. The format check above is the
  # same one config_validate applies, so .env ends up with what it would.
  cg_env_set TAILSCALE_API_KEY "$token" || { log_as fail "could not write .env"; return 1; }
  export TAILSCALE_API_KEY="$token"
  log_as ok "the token works"
  log "  saved to .env as TAILSCALE_API_KEY"
}
