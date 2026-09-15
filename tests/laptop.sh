#!/usr/bin/env bash
# lib/laptop.sh: what `cg check` reports about the laptop, and what `cg check --fix`
# installs. Every tool is a fake on a PATH that holds nothing else, so the real
# laptop's aws, tailscale and moonlight cannot leak into a case, and nothing real
# is installed or signed in.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

# The real programs the code and the fakes themselves need - and nothing else.
mkdir -p "$T/sys"
for p in bash env grep sed awk cat rm mkdir mktemp uname head tr chmod date touch dirname; do
  ln -s "$(command -v "$p")" "$T/sys/$p"
done
ln -s "$(command -v bash)" "$T/sys/sh"
BASH_BIN=$(command -v bash)

fake() { # fake <name> [body] - a program in $T/bin; the default body does nothing
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\n%s\n' "$1" "${2:-exit 0}" > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}
fresh() { # a clean laptop: sudo, and whatever tools are named
  rm -rf "$T/bin" "$T/home" "$T/log" "$T/ts-up"; mkdir -p "$T/bin" "$T/home"; touch "$T/log"
  fake sudo 'exec "$@"'
  local t
  for t in "$@"; do
    case $t in
      aws)       fake aws 'echo "aws-cli/2.17.0 Python/3.12"' ;;
      aws1)      fake aws 'echo "aws-cli/1.22.34 Python/3.10" >&2' ;;
      ssh)       fake ssh; fake scp ;;
      tailscale) fake tailscale '[[ $1 == up ]] && touch "$TSUP"; [[ $1 == status ]] && [[ ! -e $TSUP ]] && exit 1; exit 0'
                 touch "$T/ts-up" ;;
      *)         fake "$t" ;;
    esac
  done
}
# What a package manager installs, as the fakes it creates.
provides() {
  cat <<'P'
case $pkg in
  aws-cli-v2)   printf '#!/usr/bin/env bash\necho aws-cli/2.17.0\n' > "$BIN/aws" ;;
  python|python3) printf '#!/usr/bin/env bash\n' > "$BIN/python3" ;;
  openssh|openssh-client|openssh-clients) printf '#!/usr/bin/env bash\n' > "$BIN/ssh"; printf '#!/usr/bin/env bash\n' > "$BIN/scp" ;;
  curl)         printf '#!/usr/bin/env bash\n' > "$BIN/curl" ;;
  unzip)        printf '#!/usr/bin/env bash\n' > "$BIN/unzip" ;;
  tailscale)    printf '#!/usr/bin/env bash\n[[ $1 == up ]] && touch "$TSUP"; [[ $1 == status ]] && [[ ! -e $TSUP ]] && exit 1; exit 0\n' > "$BIN/tailscale" ;;
  moonlight-qt) printf '#!/usr/bin/env bash\n' > "$BIN/moonlight" ;;
esac
chmod +x "$BIN"/* 2>/dev/null
P
}

# run '<code>' [stdin]: source the library on the sandboxed PATH, with a terminal.
run() {
  ( cd "$REPO" && printf '%s' "${2:-}" | env -i HOME="$T/home" LOG="$T/log" BIN="$T/bin" TSUP="$T/ts-up" \
      PATH="$T/bin:$T/sys" CG_COLOR=never "$BASH_BIN" -c \
      'source lib/common.sh; source lib/laptop.sh; laptop_tty() { true; }; '"$1" 2>&1 )
}

echo "1. a laptop with everything"
fresh python3 ssh curl aws tailscale moonlight
check    "nothing missing"                   "$(run laptop_missing)" ""
r=$(run 'laptop_report; echo "rc=$?"')
contains "names what is installed"           "$r" "installed: python3, OpenSSH (ssh, scp), curl, AWS CLI v2 (2.17.0), Tailscale, Moonlight"
contains "  and that Tailscale is signed in" "$r" "Tailscale signed in"
check    "  and is ready"                    "$(sed -n '$p' <<<"$r")" "rc=0"
r=$(run 'laptop_fix; echo "rc=$?"')
contains "--fix has nothing to do"           "$r" "everything is installed"
lacks    "  and installs nothing"            "$(cat "$T/log")" "sudo"

echo "2. what counts as missing"
fresh python3 ssh curl aws1 moonlight fake-pacman
check    "AWS CLI v1, and no Tailscale"      "$(run laptop_missing | tr '\n' ' ')" "aws tailscale "
fresh python3 curl aws tailscale moonlight
fake ssh
check    "ssh without scp is not OpenSSH"    "$(run laptop_missing)" "ssh"

echo "3. cg check: everything at once, and the way to fix it"
fresh python3 ssh aws1 pacman
r=$(run 'laptop_report; echo "rc=$?"')
contains "names what is there"                "$r" "installed: python3, OpenSSH (ssh, scp)"
lacks    "  and only that"                   "$r" "OpenSSH (ssh, scp), curl"
contains "names the AWS CLI"                 "$r" "missing: AWS CLI v2"
contains "  and curl"                        "$r" "missing: curl"
contains "  and Tailscale"                   "$r" "missing: Tailscale"
contains "  and Moonlight"                   "$r" "missing: Moonlight"
contains "  points to --fix"                 "$r" "cg check --fix"
contains "  and stops the build"             "$r" "rc=1"
fresh python3 ssh curl aws tailscale pacman
r=$(run 'laptop_report; echo "rc=$?"')
contains "Moonlight alone stops it"          "$r" "rc=1"
contains "  said as missing"                 "$r" "missing: Moonlight"
contains "  with --fix to install it"        "$r" "cg check --fix"
r=$(run 'laptop_report 1; echo "rc=$?"')
contains "after --fix: install it yourself"  "$r" "install it yourself: https://github.com/moonlight-stream/moonlight-qt/releases"
lacks    "  and no --fix again"              "$r" "cg check --fix"
contains "  still stops"                     "$r" "rc=1"
fresh python3 ssh curl aws tailscale moonlight
rm -f "$T/ts-up"
r=$(run 'laptop_report 1; echo "rc=$?"')
contains "after --fix, still signed out: sign in yourself" "$r" "sudo tailscale up"
lacks    "  and no --fix again"              "$r" "cg check --fix"
fresh python3 ssh curl aws tailscale moonlight
rm -f "$T/ts-up"
r=$(run 'laptop_report; echo "rc=$?"')
contains "Tailscale signed out: said"        "$r" "not signed in"
lacks    "  and not called signed in"        "$r" "Tailscale signed in"
contains "  and stops the build"             "$r" "rc=1"
fresh python3 ssh aws
r=$(run 'laptop_report; echo "rc=$?"')
contains "no package manager: by hand"       "$r" "https://tailscale.com/download"
lacks    "  and no --fix to suggest"         "$r" "cg check --fix"

echo "4. --fix on Arch: one confirmation, packages, then the sign-in"
fresh python3 ssh curl moonlight
fake pacman "pkg=\${@: -1}; $(provides)"
r=$(run 'laptop_fix; echo "rc=$?"; laptop_missing' y)
contains "shows the plan first"              "$r" "install AWS CLI v2 - sudo pacman -S aws-cli-v2"
contains "  including the sign-in"           "$r" "sign this laptop in to Tailscale"
contains "installs the AWS CLI"              "$(cat "$T/log")" "sudo pacman -S --needed --noconfirm aws-cli-v2"
contains "  and Tailscale"                   "$(cat "$T/log")" "sudo pacman -S --needed --noconfirm tailscale"
contains "  then signs in"                   "$(cat "$T/log")" "sudo tailscale up"
contains "done, and nothing left"            "$r" "rc=0"
check    "  by the check itself"             "$(sed -n '$p' <<<"$r")" "rc=0"

echo "5. --fix declined, or without a terminal"
fresh python3 ssh curl moonlight pacman
r=$(run 'laptop_fix; echo "rc=$?"' n)
contains "declined: nothing changed"         "$r" "nothing changed"
lacks    "  no install ran"                  "$(cat "$T/log")" "pacman -S"
contains "  and it fails"                    "$r" "rc=1"
fresh python3 ssh curl moonlight pacman
r=$(run 'laptop_tty() { false; }; laptop_fix; echo "rc=$?"')
contains "no terminal: refuses"              "$r" "run it in a terminal"
lacks    "  before any sudo"                 "$(cat "$T/log")" "sudo"

echo "6. an install that fails is said, and the rest still install"
fresh python3 ssh curl
fake pacman "pkg=\${@: -1}; [[ \$pkg == moonlight-qt ]] && exit 1; $(provides)"
r=$(run 'laptop_fix; echo "rc=$?"; laptop_missing' y)
contains "said"                              "$r" "could not install Moonlight"
contains "  Tailscale installed anyway"      "$(cat "$T/log")" "--noconfirm tailscale"
contains "  the fix fails"                   "$r" "rc=1"
check    "  and only Moonlight is left"      "$(sed -n '$p' <<<"$r")" "moonlight"

echo "7. --fix on Debian: AWS's installer, Tailscale's script, one apt update"
# python3 missing too, so apt installs two packages - and must still update once.
fresh ssh curl
fake apt-get "[[ \$1 == install ]] || exit 0; pkg=\${@: -1}; $(provides)"
# curl hands out Tailscale's install script, or AWS's zip.
fake curl 'if [[ $* == *install.sh* ]]; then
  printf "%s\n" "printf \"#!/usr/bin/env bash\\n[[ \\\$1 == up ]] && touch \\\"\\\$TSUP\\\"; [[ \\\$1 == status ]] && [[ ! -e \\\$TSUP ]] && exit 1; exit 0\\n\" > \"\$BIN/tailscale\"; chmod +x \"\$BIN/tailscale\""
else
  while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && echo zip > "$2"; shift; done
fi'
fake unzip 'while [[ $# -gt 0 ]]; do [[ $1 == -d ]] && d=$2; shift; done
mkdir -p "$d/aws"; printf "%s\n" "#!/usr/bin/env bash" "echo \"aws-install \$*\" >> \"\$LOG\"" \
  "while [[ \$# -gt 0 ]]; do [[ \$1 == -b ]] && b=\$2; shift; done" \
  "mkdir -p \"\$b\"; printf \"#!/usr/bin/env bash\\necho aws-cli/2.17.0\\n\" > \"\$b/aws\"; chmod +x \"\$b/aws\"" > "$d/aws/install"
chmod +x "$d/aws/install"'
r=$(run 'laptop_fix; echo "rc=$?"; laptop_missing; command -v aws' y)
contains "AWS: the official installer"       "$r" "AWS's official installer, into ~/.local"
contains "  run into ~/.local"               "$(cat "$T/log")" "-b $T/home/.local/bin"
contains "  and put on PATH for this run"    "$r" "$T/home/.local/bin/aws"
contains "  with the profile note"           "$r" "not on your PATH"
contains "Tailscale: its install script"     "$(cat "$T/log")" "curl -fsSL https://tailscale.com/install.sh"
contains "Moonlight: the package"            "$(cat "$T/log")" "apt-get install -y moonlight-qt"
contains "python3: the package"              "$(cat "$T/log")" "apt-get install -y python3"
check    "apt-get update runs once"          "$(grep -c '^sudo apt-get update' "$T/log")" "1"
contains "done"                              "$r" "rc=0"

echo "8. --fix with no package manager: what to get, by hand"
fresh python3 ssh curl
r=$(run 'laptop_fix; echo "rc=$?"' y)
contains "Moonlight's releases"              "$r" "moonlight-qt/releases"
contains "  and fails"                       "$r" "rc=1"
check    "  running nothing"                 "$(cat "$T/log")" ""

echo "9. only Tailscale signed out: no package manager needed"
fresh python3 ssh curl aws tailscale moonlight
rm -f "$T/ts-up"
fake systemctl 'exit 0'
r=$(run 'laptop_fix; echo "rc=$?"' y)
contains "signs in"                          "$(cat "$T/log")" "sudo tailscale up"
lacks    "  the daemon already runs"         "$(cat "$T/log")" "enable --now"
contains "  and is done"                     "$r" "rc=0"
fresh python3 ssh curl aws tailscale moonlight
rm -f "$T/ts-up"
fake systemctl '[[ $1 == is-active ]] && exit 3; exit 0'
r=$(run 'laptop_fix; echo "rc=$?"' y)
contains "a stopped daemon is started first" "$(cat "$T/log")" "sudo systemctl enable --now tailscaled"

echo "10. setup: check takes --fix and nothing else"
mkdir -p "$T/repo"; cp -r lib cg "$T/repo/"
r=$(cd "$T/repo" && env -i HOME="$T/home" PATH="$T/sys" CG_COLOR=never "$BASH_BIN" lib/setup check --nope 2>&1; echo "rc=$?")
contains "an unknown option is refused"      "$r" "usage: setup [check [--fix]"
fresh python3 ssh
r=$(cd "$T/repo" && env -i HOME="$T/home" LOG="$T/log" PATH="$T/bin:$T/sys" CG_COLOR=never "$BASH_BIN" lib/setup check 2>&1; echo "rc=$?")
contains "cg check lists the missing tools"  "$r" "missing: AWS CLI v2"
contains "  all of them"                     "$r" "missing: Tailscale"
contains "  and stops before AWS"            "$r" "the laptop is not ready"
contains "  failing"                         "$(sed -n '$p' <<<"$r")" "rc=1"
check    "cg passes --fix through"           "$(grep -c 'check)     exec lib/setup check "$@"' cg)" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
