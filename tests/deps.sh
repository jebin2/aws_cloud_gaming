#!/usr/bin/env bash
# `cg deps`: the tools this laptop needs, as data, and installing them.
#
# The page this feeds exists because of what a new laptop looked like: every
# number on every screen UNKNOWN, a banner blaming AWS credentials, and the
# actual reason - no AWS CLI - six lines into a preflight report nobody had run.
#
# The hard part is not the list. It is that installing needs root, and the app
# has no terminal for sudo to ask for a password in: so this reports HOW it
# would become root, and the page refuses to draw a button that cannot work.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home" "$T/repo" "$T/sys"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
for p in bash sh env grep sed awk python3 cat rm mkdir mktemp uname head tail tr \
         chmod date touch dirname basename cut sort wc find readlink timeout sleep tee; do
  ln -sf "$(command -v "$p")" "$T/sys/$p"
done

fake() { printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\n%s\n' "$1" "${2:-exit 0}" > "$T/bin/$1"
         chmod +x "$T/bin/$1"; }
fresh() { rm -rf "$T/bin" "$T/log" "$T/pacdb"; mkdir -p "$T/bin"; touch "$T/log"
          fake sudo 'exec "$@"'
          fake pkexec 'exec "$@"'
          # Never faked: see the note above fresh().
          local t
          for t in "$@"; do
            case $t in
              aws)       fake aws 'echo "aws-cli/2.17.0 Python/3.12"' ;;
              ssh)       fake ssh; fake scp ;;
              tailscale) fake tailscale 'exit 0' ;;
              tailsignedout) fake tailscale '[[ $1 == status ]] && exit 1; exit 0' ;;
              pacman)    fake pacman 'pkg=${@: -1}
case "$1" in
  -Sy) : > "${PACDB:?}"; exit 0 ;;
esac
# No database, no packages. This is what a machine that has never synced says,
# and it reads as "there is no such package" rather than "I have not looked".
if [[ ! -e ${PACDB:?} ]]; then
  echo "warning: database file for '"'"'core'"'"' does not exist (use -Sy to download)" >&2
  echo "error: target not found: $pkg" >&2
  exit 1
fi
case $pkg in
  aws-cli-v2) printf "#!/usr/bin/env bash\necho aws-cli/2.17.0\n" > "$BIN/aws" ;;
  moonlight-qt) printf "#!/usr/bin/env bash\n" > "$BIN/moonlight" ;;
esac
chmod +x "$BIN"/* 2>/dev/null' ;;
              *)         fake "$t" ;;
            esac
          done; }

cg_() { # cg_ <args...> - EXTRA passes env through
  # WAYLAND_DISPLAY: there is no terminal in a test either, so every case here
  # is the app's case - a desktop session and polkit.
  # shellcheck disable=SC2086
  ( cd "$T/repo" && env -i CG_INR_PER_USD=88 PATH="$T/bin:$T/sys" HOME="$T/home" CG_COLOR=never \
      WAYLAND_DISPLAY=wayland-1 \
      LOG="$T/log" BIN="$T/bin" PACDB="$T/pacdb" GAME_REGION=ap-south-1 ${EXTRA:-} bash ./cg "$@" 2>&1 )
}
jq_() { python3 -I -c 'import json,sys
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[int(k)] if isinstance(d, list) else d[k]
print(json.dumps(d))' "$@"; }

echo "1. the list, as data"
fresh ssh curl tailscale                  # no aws, no moonlight
j=$(cg_ deps --json)
check    "it is valid JSON"            "$(python3 -I -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$j")" "yes"
check    "every tool is listed"        "$(python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)["tools"]))' <<<"$j")" "6"
check    "  what is here is here"      "$(python3 -I -c 'import json,sys
print(",".join(t["tool"] for t in json.load(sys.stdin)["tools"] if t["present"]))' <<<"$j")" "python3,ssh,curl,tailscale"
check    "  and what is not"           "$(python3 -I -c 'import json,sys
print(",".join(t["tool"] for t in json.load(sys.stdin)["tools"] if not t["present"]))' <<<"$j")" "aws,moonlight"
# A list of names does not tell you which you can live without. All of them.
contains "each one says what it is for" "$j" "the only thing that talks to AWS"
contains "  including the stream"       "$j" "this is what you play on"
check    "and no package manager is null" "$(jq_ package_manager <<<"$j")" "null"
contains "  with the manual link instead"  "$j" "docs.aws.amazon.com/cli"

echo "2. with a package manager, the plan is named"
fresh ssh curl tailscale pacman
j=$(cg_ deps --json)
check    "it says which one"           "$(jq_ package_manager <<<"$j")" '"pacman"'
contains "  and the command"           "$j" "pacman -S aws-cli-v2"

echo "3. how it would become root"
# The question the Install button lives or dies on. The page must say this
# BEFORE anything is pressed: a button that fails inside pacman is worse than
# a line of text saying where to run the command.
j=$(cg_ deps --json)
check    "a desktop session means polkit"  "$(jq_ root <<<"$j")" '"pkexec"'
check    "  and nothing is blocked"        "$(jq_ root_blocked <<<"$j")" "null"
rm -f "$T/bin/pkexec"
j=$(cg_ deps --json)
check    "no polkit, no terminal: nothing" "$(jq_ root <<<"$j")" "null"
contains "  and it says polkit is missing" "$(jq_ root_blocked <<<"$j")" "pkexec) is not installed"
fake pkexec 'exec "$@"'
j=$(EXTRA="WAYLAND_DISPLAY= DISPLAY=" cg_ deps --json)
check    "no desktop session either"       "$(jq_ root <<<"$j")" "null"
contains "  and it says which is missing"  "$(jq_ root_blocked <<<"$j")" "no desktop session"
# Installing with no way to be root must refuse in words, not fail in pacman.
out=$(EXTRA="WAYLAND_DISPLAY= DISPLAY=" cg_ deps install)
contains "installing refuses, with why"    "$out" "cannot install from here"
contains "  naming the terminal"           "$out" "cg deps install"
lacks    "  and runs no package manager"   "$(cat "$T/log")" "pacman -S"

echo "4. installing what is missing"
fresh ssh curl tailscale pacman
out=$(cg_ deps install)
contains "it says what it is doing"    "$out" "installing AWS CLI v2"
contains "  and confirms each one"     "$out" "AWS CLI v2 installed"
contains "  including Moonlight"       "$out" "Moonlight installed"
check    "the package manager ran as root" \
         "$(grep -cE '^pkexec .*/pacman -S --needed --noconfirm aws-cli-v2$' "$T/log")" "1"
# `hash -r` after each install, or bash keeps answering from its command cache
# and the tool it just installed still looks missing.
j=$(cg_ deps --json)
check    "nothing is missing afterwards" "$(python3 -I -c 'import json,sys
print(len([t for t in json.load(sys.stdin)["tools"] if not t["present"]]))' <<<"$j")" "0"

echo "4b. a machine that has never synced its package database"
# What a fresh Omarchy VM did: "error: target not found: aws-cli-v2" for a
# package that is right there in extra. pacman had no database to look in, and
# said so in a way that reads as "no such package".
fresh ssh curl tailscale pacman
out=$(cg_ deps install)
contains "the database is refreshed"   "$out" "refreshing the package database"
check    "  before anything is installed" \
         "$(grep -oE 'pacman -Sy|pacman -S --needed' "$T/log" | head -1)" "pacman -Sy"
check    "  and only once"             "$(grep -cE '^(sudo|pkexec) .*/pacman -Sy ' "$T/log")" "1"
contains "then the install works"      "$out" "AWS CLI v2 installed"
contains "  for both of them"          "$out" "Moonlight installed"

echo "5. one tool at a time"
fresh ssh curl tailscale pacman
out=$(cg_ deps install moonlight)
contains "it installs that one"        "$out" "Moonlight installed"
lacks    "  and not the others"        "$(cat "$T/log")" "aws-cli-v2"

echo "6. a tool that is already here"
# Moonlight stays missing on purpose: with nothing missing at all, deps_install
# answers "nothing to install" and never reaches the per-tool decision.
fresh ssh curl tailscale aws pacman
out=$(cg_ deps install aws)
contains "it says so"                  "$out" "already here"
lacks    "  and installs nothing"      "$(cat "$T/log")" "pacman -S"

echo "7. nothing missing at all"
fresh ssh curl tailscale aws moonlight pacman
out=$(cg_ deps install)
contains "it says it is ready"         "$out" "every tool cg needs is here"

echo "8. installed but not signed in is its own state"
# Nothing to install, and nothing works: a list of installed tools would call
# this laptop ready.
fresh ssh curl tailsignedout aws moonlight pacman
j=$(cg_ deps --json)
check    "tailscale is present"        "$(python3 -I -c 'import json,sys
print([t["present"] for t in json.load(sys.stdin)["tools"] if t["tool"]=="tailscale"][0])' <<<"$j")" "True"
check    "  but not signed in"         "$(jq_ tailscale_signed_in <<<"$j")" "false"
out=$(EXTRA="CG_JSON=1" cg_ deps install </dev/null)
contains "install says what is left"   "$out" "not signed in"
contains "  and that it needs a terminal" "$out" "sudo tailscale up"

echo "9. no package manager: by hand, with the link"
fresh ssh curl tailscale
out=$(cg_ deps install)
contains "it says there is none"       "$out" "no supported package manager"
contains "  and where to get each one" "$out" "https://docs.aws.amazon.com/cli"
contains "  including Moonlight"       "$out" "moonlight-stream/moonlight-qt"

echo "10. wired in"
contains "cg dispatches deps"          "$(cat cg)" "deps|dependencies)"
contains "  and help names it"         "$(cat cg)" "cg deps [install]"
contains "the app reads it"            "$(cat app/renderer/app.js)" "[['deps', '--json'], 'deps']"
# cg says which commands run alone, and listing is not one of them.
alone=$(./cg --contract | python3 -I -c 'import json,sys
print(" ".join(" ".join(p) for p in json.load(sys.stdin)["runs_alone"]))')
contains "  installing runs alone"    "$alone" "deps install"
lacks    "  and listing does not"     "$alone" "deps --json"
# No page of its own: setup installs what is missing in place, and a tool that
# goes missing later is offered as an Install button where it is noticed.
lacks    "there is no Dependencies tab" "$(cat app/renderer/index.html)" 'data-view="deps"'

echo ""
echo "deps: $pass passed, $fail failed"
(( fail == 0 ))
