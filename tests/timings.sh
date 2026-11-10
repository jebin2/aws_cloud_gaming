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
sleep 0.2
if [[ ${1:-} == install ]]; then
  date +%s.%N > "$AYIS_DPKG_START"
  for p in "${@:3}"; do echo "2026-11-05 10:00:00 install $p:amd64 <none> 1.0" >> "$AYIS_DPKG_LOG"; done
fi
sleep 0.2; [[ ${1:-} == fail ]] && exit 7; exit 0
FAKE
cat > "$T/bin/dpkg-query" <<'FAKE'
#!/usr/bin/env bash
# dpkg-query -W -f FMT name...: the sizes, in KiB, are 100x the name's length
for p in "${@:4}"; do printf '%s %d\n' "${p%%:*}" $(( ${#p} * 100 )); done
FAKE
chmod +x "$T/bin/apt-get" "$T/bin/dpkg-query"
: > "$T/dpkg.log"
FN=$(awk '/^apt-get\(\) \{/{f=1} f{print} f&&/^\}/{c++; if(c==2) exit}' lib/bootstrap.d/00-header.sh \
     | sed "s|/run/ayis-dpkg-start|$T/dpkg-start|g; s|/var/log/ayis-timings.log|$LOG|g; s|/var/log/dpkg.log|$T/dpkg.log|g")
run() { env PATH="$T/bin:$PATH" AYIS_DPKG_START="$T/dpkg-start" AYIS_DPKG_LOG="$T/dpkg.log" AYIS_TARGET="$1" bash -c "$FN"$'\n'"shift_args=1; apt-get $2; echo rc=\$?"; }
out=$(run aws "install -y curl")
contains "it passes the command through" "$out" "rc=0"
check    "an install line and a weight line are logged" "$(wc -l < "$LOG")" "2"
contains "  naming the command"          "$(cat "$LOG")" "apt-get install -y curl"
check    "  and the dpkg start, a number" "$(awk '$1 != "pkgs" {print ($3 ~ /^[0-9.]+$/) ? "yes":"no"}' "$LOG")" "yes"
contains "  and what it brought in, joined by the start" "$(awk 'NR==1{s=$1} $1=="pkgs"{print ($2==s) ? "joined" : "apart"}' "$LOG")" "joined"
contains "  with the package and its size" "$(grep '^pkgs' "$LOG")" "curl 0MB"
out=$(run aws "fail")
contains "a failing apt-get still fails the build" "$out" "rc=7"
check    "  and is logged, with no dpkg start" "$(grep -v '^pkgs' "$LOG" | tail -1 | awk '{print $3}')" "-"
: > "$LOG"; out=$(run host "install -y curl")
check    "on a machine of yours, nothing is written" "$(wc -c < "$LOG")" "0"

echo "2. the slowest are listed at the end"
cat > "$LOG" <<'D'
100.0 162.0 130.0 apt-get install -y nvidia-driver-615-open linux-modules-nvidia-615-open-7.0.0-1014-aws
170.0 200.0 - apt-get update
200.0 290.0 215.0 apt-get install -y xfce4 xfce4-goodies lightdm xserver-xorg x11-xserver-utils xclip
120.0 150.0 - update-initramfs -u -k 7.0.0-1014-aws
pkgs 100.0 3 410 libnvidia-compute-615 212MB nvidia-firmware-615 98MB libnvidia-gl-615 61MB
pkgs 200.0 612 1290 xfce4-goodies 4MB libgtk-3-0t64 20MB firefox 0MB
D
BLOCK=$(sed -n '/^if \[ -s \/var\/log\/ayis-timings.log \]/,/^fi$/p' lib/bootstrap.d/99-finish.sh | sed "s|/var/log/ayis-timings.log|$LOG|g")
out=$(bash -c 'set -euo pipefail; progress() { echo ">>> $*"; }; '"$BLOCK")
first=$(sed -n 1p <<<"$out")
contains "the slowest comes first"            "$first" "timing: 90s (fetch 15s, dpkg 75s) apt-get install -y xfce4"
contains "  with the fetch and dpkg split"      "$out" "(fetch 30s, dpkg 32s) apt-get install -y nvidia-driver-615-open"
contains "a command with no dpkg is plain"    "$out" "timing: 30s update-initramfs -u -k"
lacks    "  and has no split"                  "$(grep initramfs <<<"$out")" "fetch"
check    "all four are listed"                "$(grep -c '>>> timing: [0-9]' <<<"$out")" "4"
contains "the heaviest install says what it brought in" "$(sed -n 2p <<<"$out")" "timing:   brought in 612 packages, 1290 MB; largest: xfce4-goodies 4MB"
contains "  and the next one too"               "$out" "brought in 3 packages, 410 MB; largest: libnvidia-compute-615 212MB"
check    "only the three slowest are weighed" "$(grep -c 'brought in' <<<"$out")" "2"
lacks    "no word the progress reader takes for a failure" "$out" "failed"
check    "an absent log is silent"            "$(bash -c 'set -euo pipefail; progress() { echo "$*"; }; '"$(sed "s|$LOG|$T/none.log|g" <<<"$BLOCK")")" ""

echo "3. ubuntu-drivers is fetched only when the fallback needs it"
FNU=$(sed -n '/^      ubuntu_drivers() {/,/^      }/p' lib/bootstrap.d/40-nvidia.sh)
# A PATH of its own, so this machine's real ubuntu-drivers is never what answers.
mkdir -p "$T/only"; for b in bash cp chmod; do ln -sf "$(command -v $b)" "$T/only/$b"; done
cat > "$T/only/apt-get" <<'FAKE'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CALLS"
cp "$HOME/ubuntu-drivers.real" "$HOME/only/ubuntu-drivers"; chmod +x "$HOME/only/ubuntu-drivers"
FAKE
cat > "$T/ubuntu-drivers.real" <<'FAKE'
#!/usr/bin/env bash
echo "ubuntu-drivers $*" >> "$CALLS"
FAKE
chmod +x "$T/only/apt-get" "$T/ubuntu-drivers.real"
: > "$T/calls"
env -i PATH="$T/only" HOME="$T" CALLS="$T/calls" bash -c "$FNU"$'\n''ubuntu_drivers install'
check "missing: the package is installed first, then it runs" "$(tr '\n' '|' < "$T/calls")" "apt-get install -y ubuntu-drivers-common|ubuntu-drivers install|"
ln -sf "$T/ubuntu-drivers.real" "$T/only/ubuntu-drivers"   # now there
: > "$T/calls"
env -i PATH="$T/only" HOME="$T" CALLS="$T/calls" bash -c "$FNU"$'\n''ubuntu_drivers autoinstall'
check "there already: it just runs"                           "$(tr '\n' '|' < "$T/calls")" "ubuntu-drivers autoinstall|"
check    "the only install of it is the fallback's"    "$(grep -c 'apt-get install -y ubuntu-drivers-common' lib/bootstrap.d/40-nvidia.sh)" "1"
check    "  and nothing calls it bare"                 "$(grep -v '^ *#' lib/bootstrap.d/40-nvidia.sh | grep -cE '(^|[ (|;&])ubuntu-drivers (install|autoinstall)')" "0"

echo "4. the build installs and removes its timers"
base=$(<lib/bootstrap.d/10-base.sh); fin=$(<lib/bootstrap.d/99-finish.sh)
contains "the dpkg hook is set"            "$base" "99-ayis-build-timing"
contains "update-initramfs is timed"      "$base" "/usr/local/sbin/update-initramfs"
contains "both are taken out at the end"  "$fin" "rm -f /etc/apt/apt.conf.d/99-ayis-build-timing /usr/local/sbin/update-initramfs"

echo; echo "timings: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
