#!/usr/bin/env bash
# The build times its own apt-get calls and update-initramfs, and says at the end
# which were slowest and where each spent its time (fetching or in dpkg).
# Runs the shipped code: the function from 00-header.sh and the summary from
# 99-finish.sh are lifted out, with the log pointed at a temp file.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not have '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
LOG=$T/timings.log

echo "1. apt-get is timed, with the moment dpkg began"
mkdir -p "$T/bin"
cat > "$T/bin/apt-get" <<'FAKE'
#!/usr/bin/env bash
sleep 0.2; [[ ${1:-} == install ]] && date +%s.%N > "$CG_DPKG_START"; sleep 0.2; [[ ${1:-} == fail ]] && exit 7; exit 0
FAKE
chmod +x "$T/bin/apt-get"
FN=$(sed -n '/^apt-get() {/,/^}/p' lib/bootstrap.d/00-header.sh \
     | sed "s|/run/cg-dpkg-start|$T/dpkg-start|g; s|/var/log/cg-timings.log|$LOG|g")
run() { env PATH="$T/bin:$PATH" CG_DPKG_START="$T/dpkg-start" CG_TARGET="$1" bash -c "$FN"$'\n'"shift_args=1; apt-get $2; echo rc=\$?"; }
out=$(run aws "install -y curl")
contains "it passes the command through" "$out" "rc=0"
check    "one line is logged"            "$(wc -l < "$LOG")" "1"
contains "  naming the command"          "$(cat "$LOG")" "apt-get install -y curl"
check    "  and the dpkg start, a number" "$(awk '{print ($3 ~ /^[0-9.]+$/) ? "yes":"no"}' "$LOG")" "yes"
out=$(run aws "fail")
contains "a failing apt-get still fails the build" "$out" "rc=7"
check    "  and is logged, with no dpkg start" "$(tail -1 "$LOG" | awk '{print $3}')" "-"
: > "$LOG"; out=$(run host "install -y curl")
check    "on a machine of yours, nothing is written" "$(wc -c < "$LOG")" "0"

echo "2. the slowest are listed at the end"
cat > "$LOG" <<'D'
100.0 162.0 130.0 apt-get install -y nvidia-driver-615-open linux-modules-nvidia-615-open-7.0.0-1014-aws
170.0 200.0 - apt-get update
200.0 290.0 215.0 apt-get install -y xfce4 xfce4-goodies lightdm xserver-xorg x11-xserver-utils xclip
120.0 150.0 - update-initramfs -u -k 7.0.0-1014-aws
D
BLOCK=$(sed -n '/^if \[ -s \/var\/log\/cg-timings.log \]/,/^fi$/p' lib/bootstrap.d/99-finish.sh | sed "s|/var/log/cg-timings.log|$LOG|g")
out=$(bash -c 'set -euo pipefail; progress() { echo ">>> $*"; }; '"$BLOCK")
first=$(sed -n 1p <<<"$out")
contains "the slowest comes first"            "$first" "timing: 90s (fetch 15s, dpkg 75s) apt-get install -y xfce4"
contains "  with the fetch and dpkg split"      "$out" "(fetch 30s, dpkg 32s) apt-get install -y nvidia-driver-615-open"
contains "a command with no dpkg is plain"    "$out" "timing: 30s update-initramfs -u -k"
lacks    "  and has no split"                  "$(grep initramfs <<<"$out")" "fetch"
check    "all four are listed"                "$(grep -c 'timing:' <<<"$out")" "4"
lacks    "no word the progress reader takes for a failure" "$out" "failed"
check    "an absent log is silent"            "$(bash -c 'set -euo pipefail; progress() { echo "$*"; }; '"$(sed "s|$LOG|$T/none.log|g" <<<"$BLOCK")")" ""

echo "3. the build installs and removes its timers"
base=$(<lib/bootstrap.d/10-base.sh); fin=$(<lib/bootstrap.d/99-finish.sh)
contains "the dpkg hook is set"            "$base" "99-cg-build-timing"
contains "update-initramfs is timed"      "$base" "/usr/local/sbin/update-initramfs"
contains "both are taken out at the end"  "$fin" "rm -f /etc/apt/apt.conf.d/99-cg-build-timing /usr/local/sbin/update-initramfs"

echo; echo "timings: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
