#!/usr/bin/env bash
# The second half of every build (lib/build.sh): one path for an AWS box and for
# a machine of your own. Driven against a fake machine - ssh, curl, moonlight
# are fakes - once as the AWS target calls it (cg's key) and once as your own
# machine does (no key: your ssh setup), and held to the same steps either way.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; export T

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

# The machine: its build log, its ready marker, Steam's marker, its Sunshine login.
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/ssh.log"
cmd="${*: -1}"
case $cmd in
  *"tail -n +1 "*) printf '>>> installing sunshine\n>>> ok: sunshine installed\n>>> finishing up\n' ;;
  *"tail -n +"*) : ;;
  *cloud-gaming-ready*) [[ -f $T/ready ]] && { echo READY; exit 0; }; exit 1 ;;
  *steam-prewarmed*) exit 0 ;;
  *"sunshine --creds"*) read -r u p < <(sed -n "s/.*--creds '\\\\''\([^']*\)'\\\\'' '\\\\''\([^']*\)'\\\\''.*/\1 \2/p" <<<"$cmd")
                        printf '%s %s' "$u" "$p" > "$T/box" ;;
  *) : ;;
esac
FAKE
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
[[ $1 == list ]] && echo Desktop
FAKE
chmod +x "$T/bin/"*

# build <ssh-target> <key> - build_finish as a target calls it; prints what it said.
build() {
  : > "$T/ssh.log"; : > "$T/box"; : > "$T/saved"; touch "$T/ready"
  ( export PATH="$T/bin:$PATH" CG_COLOR=${COLOR:-never} CG_SLEEP_PCT=1
    source lib/common.sh; source lib/build.sh
    save() { echo "$1=$2" >> "$T/saved"; }
    BUILD_SSH=$1 BUILD_KEY=$2 BUILD_IP=100.64.0.9 BUILD_SAVE=save BUILD_NAME=$3
    build_finish; echo "rc=$? paired=$PAIRED steam=$STEAM_OK" ) 2>&1
}

for kind in aws host; do
  if [[ $kind == aws ]]; then out=$(build ubuntu@gamevps "$T/key.pem" "the box")
  else out=$(build me@homeserver "" homeserver); fi
  echo "$kind:"
  contains "  the build is followed to the end"    "$out" "sunshine installed"
  contains "  the Sunshine login is made"          "$out" "created; credentials saved"
  check    "  and kept where the target keeps it"   "$(grep -c '^SUNSHINE_PASS=' "$T/saved")" "1"
  contains "  pairing"                             "$out" "already paired"
  contains "  and Steam"                           "$out" "steam=1"
  contains "  it finishes"                         "$out" "rc=0 paired=1"
  check    "  every command runs under sh, whatever the login shell" \
           "$(grep -vc "sh -c '" "$T/ssh.log")" "0"
  if [[ $kind == aws ]]; then
    check  "  with cg's own key"                   "$(grep -vc -- "-i $T/key.pem" "$T/ssh.log")" "0"
    contains "  named as the box"                   "$out" "building the box"
  else
    check  "  with your own ssh setup, no key"     "$(grep -c -- "-i " "$T/ssh.log")" "0"
    contains "  named as your machine"              "$out" "building homeserver"
    lacks    "  and never said to reboot"            "$(COLOR=always build me@homeserver "" homeserver)" "reboots"
    contains "  (the AWS box still is)"               "$(COLOR=always build ubuntu@gamevps "$T/key.pem" "the box")" "reboots into the desktop"
  fi
done

echo "a build that stops with no FAILED line - as set -e stops one"
: > "$T/ssh.log"; rm -f "$T/ready"
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/ssh.log"
case "${*: -1}" in
  *"tail -n +1 "*) printf '>>> installing steam\n' ;;
  *"tail -n 8 "*) printf '+ GLPKG=\n+ echo 1\n' ;;
  *cloud-gaming-bootstrap.rc*) echo 'exited|no' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$T/bin/ssh"
t0=$SECONDS
out=$( ( export PATH="$T/bin:$PATH" CG_COLOR=never CG_SLEEP_PCT=1
  source lib/common.sh; stream_build me@homeserver "" 2400; echo "rc=$?" ) 2>&1)
contains "  it is called stopped"          "$out" "STOPPED before it finished"
contains "  with the end of its log"       "$out" "+ GLPKG="
contains "  and how to look, with no empty key" "$out" "ssh me@homeserver"
lacks    "  (not ssh -i with nothing after it)" "$out" "ssh -i  "
contains "  and it does not wait the 40 minutes out" "$out" "rc=1"
lacks    "  no timeout"                    "$out" "TIMEOUT"

echo "a build that does not finish"
rm -f "$T/ready"
out=$( ( export PATH="$T/bin:$PATH" CG_COLOR=never CG_SLEEP_PCT=1
  source lib/common.sh; source lib/build.sh
  stream_build() { return 1; }
  BUILD_SSH=x BUILD_KEY="" BUILD_IP=1 BUILD_SAVE=: BUILD_NAME=x
  build_finish; echo "rc=$?" ) 2>&1)
contains "  says so with its own code, for the target to explain" "$out" "rc=2"

echo; echo "build-finish: $pass passed, $fail failed"
(( fail == 0 ))
