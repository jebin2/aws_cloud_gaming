#!/usr/bin/env bash
# The Sunshine login: this laptop and the box must never hold different ones.
#
# cg init used to create the box's password and save it here only after the
# box took it, so an init that ended in between - the app closed mid-build -
# left the box with a password nothing here knew, and pairing failed on every
# later run. Now the password is saved first, checked against the box, and set
# again on the box itself (sunshine --creds, over ssh) when they disagree.
#
# This runs the real block from lib/setup against a fake Sunshine (curl) and a
# fake box (the ssh command), with no network.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

# The box's login lives in $T/box ("user pass"); empty is Sunshine's first run.
# POST /api/password sets it; LOST=1 sets it but loses the reply. Any
# authenticated call answers 200 only for the login the box holds. The POST
# also records whether this laptop had already saved the password it carries.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
auth="" data="" url=""
while (( $# )); do case $1 in -u) auth=$2; shift 2 ;; -d) data=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac; done
case $url in
  */api/password)
    u=$(sed -n 's/.*"newUsername":"\([^"]*\)".*/\1/p' <<<"$data")
    p=$(sed -n 's/.*"newPassword":"\([^"]*\)".*/\1/p' <<<"$data")
    grep -q "SUNSHINE_PASS=$p" "$ENVF" && echo saved-first >> "$T/order" || echo sent-unsaved >> "$T/order"
    printf '%s %s' "$u" "$p" > "$T/box"
    [[ ${LOST:-0} == 1 ]] && exit 28
    echo '{"status":true}' ;;
  */api/clients/list)
    [[ -s $T/box && "$(tr ' ' ':' < "$T/box")" == "$auth" ]] && echo 200 || echo 401 ;;
esac
FAKE
chmod +x "$T/bin/curl"
# The box over ssh: `sunshine --creds 'u' 'p'` rewrites its login.
cat > "$T/bin/fakessh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$T/ssh"
[[ ${SSH_DOWN:-0} == 1 ]] && exit 255
read -r u p < <(sed -n "s/.*--creds '\([^']*\)' '\([^']*\)'.*/\1 \2/p" <<<"$*")
printf '%s %s' "$u" "$p" > "$T/box"
FAKE
chmod +x "$T/bin/fakessh"

# The block itself, from lib/setup: from its helpers to the pairing that follows.
awk '/^# Whether Sunshine takes this login/{f=1} /^say "moonlight pairing"/{f=0} f' lib/setup > "$T/block.sh"
check "the block was found" "$(grep -c 'sun_login_ok' "$T/block.sh" | awk '{print ($1 > 2)}')" "1"

run() { # run <welcome> ; the box state in $T/box, the laptop's in $ENVF
  : > "$T/log"; : > "$T/order"; : > "$T/ssh"
  ( export T ENVF="$T/env" PATH="$T/bin:$PATH" LOST="${LOST:-0}" SSH_DOWN="${SSH_DOWN:-0}"
    set -a; [[ -f $ENVF ]] && . "$ENVF"; set +a
    log() { echo "$*" >> "$T/log"; }
    cg_env_set() { sed -i "/^$1=/d" "$ENVF" 2>/dev/null; echo "$1=$2" >> "$ENVF"; }
    cg_env_file() { echo "$ENVF"; }
    sleep() { :; }
    IP=100.64.0.1 SUN_UP=1 WELCOME=$1 SSH="fakessh ubuntu@box"
    source "$T/block.sh" )
}
saved() { sed -n 's/^SUNSHINE_PASS=//p' "$T/env" 2>/dev/null; }
boxp()  { cut -d' ' -f2 "$T/box" 2>/dev/null; }

echo "1. a first run: the password is saved before the box is given it"
: > "$T/box"; rm -f "$T/env"
run 1
check    "saved here first"            "$(cat "$T/order")" "saved-first"
check    "  and the box holds the same" "$(boxp)" "$(saved)"
contains "  said plainly"              "$(cat "$T/log")" "created; credentials saved"

echo "2. the box took it but the reply was lost"
: > "$T/box"; rm -f "$T/env"
LOST=1 run 1
check    "still the same login on both" "$(boxp)" "$(saved)"
contains "  and called created, because it was checked" "$(cat "$T/log")" "created"

echo "3. a re-run with a login that works: nothing is changed"
before=$(saved)
run 0
check    "the same password"           "$(saved)" "$before"
check    "  and the box is not touched" "$(wc -l < "$T/ssh")" "0"
contains "  said"                      "$(cat "$T/log")" "already configured, and the saved login works"

echo "4. the gap: the box has a login this laptop never saved"
printf 'admin someone-elses' > "$T/box"
run 0
check    "set again on the box itself"  "$(grep -c -- '--creds' "$T/ssh")" "1"
check    "  to what is saved here"      "$(boxp)" "$(saved)"
contains "  and said"                   "$(cat "$T/log")" "reset; credentials saved"

echo "5. nothing saved here at all (a new laptop)"
printf 'admin old' > "$T/box"; rm -f "$T/env"
run 0
check    "the box is given a login this laptop has" "$(boxp)" "$(saved)"

echo "6. the box cannot be reached to reset it"
printf 'admin other' > "$T/box"
SSH_DOWN=1 run 0
contains "says what to do, rather than claiming success" "$(cat "$T/log")" "could not set the Sunshine login"

echo; echo "sunshine-login: $pass passed, $fail failed"
(( fail == 0 ))
