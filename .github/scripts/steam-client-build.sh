#!/usr/bin/env bash
# Installs Steam as a new box does (Valve's package, its 32-bit libraries), lets the
# client unpack and update itself on a virtual screen, and packs what it made.
# Run on an Ubuntu 24.04 runner as an ordinary user with sudo. The output folder
# is the one argument.
set -euo pipefail
out=${1:?usage: steam-client-build.sh <out folder>}
here=$(cd "$(dirname "$0")" && pwd)

sudo dpkg --add-architecture i386
sudo add-apt-repository -y multiverse
sudo apt-get update
echo steam steam/question select "I AGREE" | sudo debconf-set-selections
echo steam steam/license note '' | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mesa-vulkan-drivers libgl1-mesa-dri:i386 \
  steam-libs-amd64 steam-libs-i386 libc6:i386 libegl1:i386 libgbm1:i386 libgl1:i386 xvfb x11-xserver-utils zstd
curl -fsSL --retry 3 -o /tmp/steam_latest.deb https://repo.steampowered.com/steam/archive/stable/steam_latest.deb
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/steam_latest.deb
# It would open a terminal and wait for a key on a screen with nobody at it.
sudo chmod -x /usr/bin/steamdeps || true

Xvfb :99 -screen 0 1280x720x24 -nolisten tcp >/dev/null 2>&1 &
export DISPLAY=:99
for _ in $(seq 1 30); do xset q >/dev/null 2>&1 && break; sleep 1; done
steam +quit >/tmp/steam-run.log 2>&1 &

root="$HOME/.local/share/Steam"
size() { du -smL "$HOME/.steam" "$root" 2>/dev/null | awk '{t+=$1} END{print t+0}'; }
prev=-1; flat=0; waited=0
# Finished when the client is unpacked and its size has stopped growing for a
# minute: the same rule a box uses (lib/bootstrap.d/72-steam-prewarm.sh).
while [ "$waited" -lt 1500 ]; do
  cur=$(size)
  if [ -d "$root/ubuntu12_64" ] && [ "$waited" -ge 120 ] && [ "$cur" = "$prev" ]; then flat=$((flat+1)); else flat=0; fi
  [ "$flat" -ge 6 ] && break
  prev=$cur; sleep 10; waited=$((waited+10))
done
echo "settled at ${prev} MB after ${waited}s"
pkill -u "$(id -u)" -x steam || true
pkill -u "$(id -u)" -f '/ubuntu12_(32|64)/steam' || true
sleep 3
[ -d "$root/ubuntu12_64" ] || { echo "the client did not install"; tail -40 /tmp/steam-run.log; exit 1; }
bash "$here/steam-client-pack.sh" "$root" "$out"
