# --- Steam --------------------------------------------------------------------
# Sunshine ships a "Steam Big Picture" app entry by default whether or not Steam
# exists, so the app list is not evidence it is installed. i386 is required:
# the Steam bootstrap binary is still 32-bit.
progress "installing steam"
dpkg --add-architecture i386
apt-get update
apt-get install -y software-properties-common
add-apt-repository -y multiverse
apt-get update

# Valve's own .deb, not Ubuntu's `steam-installer`. The Ubuntu/Debian package is
# a stub: it ships no client, downloads the bootstrap on first run, and puts a
# zenity licence dialog in front of it that a headless first boot cannot answer -
# it reports "Installation cancelled" and leaves nothing installed. Valve's
# package ships bootstraplinux_ubuntu12_32.tar.xz inside the .deb and extracts it
# with no prompt, and installs the real hicolor icons system-wide, which is what
# the dock launcher needs to show the Steam logo rather than a generic package.
#
# Preseeded anyway: cheap, and stops any debconf note from blocking cloud-init.
export DEBIAN_FRONTEND=noninteractive
echo steam steam/question select "I AGREE" | debconf-set-selections
echo steam steam/license note '' | debconf-set-selections
# No gamescope: it has no installation candidate on 24.04, and apt fails the
# *entire* transaction over one missing package - which silently takes Steam
# down with it. Steam's own Big Picture covers the console-style UI.
apt-get install -y mesa-vulkan-drivers libgl1-mesa-dri:i386 \
  || echo "mesa i386 install failed - not fatal"
# Valve's package only *Recommends* the runtime libs, and they live in its own
# apt repo, so installing the .deb alone leaves them out - and the bootstrap
# client is 32-bit, so without them it will not start at all. Ubuntu carries the
# same package names in multiverse; fall back to the bare libraries if not.
# This exact list is what `steamdeps` asks for on a fresh 24.04 + L4 box. The
# i386 NVIDIA GL package name carries the driver version, so derive it from what
# 40-nvidia.sh actually installed rather than pinning a number that goes stale.
GLPKG=$(dpkg -l 2>/dev/null | grep -oE 'libnvidia-gl-[0-9]+' | head -1)
apt-get install -y steam-libs-amd64 steam-libs-i386 \
  libc6:i386 libegl1:i386 libgbm1:i386 libgl1-mesa-dri:i386 libgl1:i386 \
  ${GLPKG:+${GLPKG}:i386} \
  || echo "steam i386 runtime libs failed - steam may not start"
# Retry the download: a transient failure here means the box comes up with no
# Steam at all and nothing to retry it, which is the most expensive way to lose
# a build.
for try in 1 2 3; do
  curl -fsSL --connect-timeout 20 --max-time 300 -o /tmp/steam_latest.deb \
    https://repo.steampowered.com/steam/archive/stable/steam_latest.deb && break
  echo "steam .deb download attempt $try failed"
  rm -f /tmp/steam_latest.deb
  sleep $(( try * 10 ))
done
if [[ -s /tmp/steam_latest.deb ]]; then
  # apt-get, not dpkg -i: this pulls the package's own dependency tree.
  apt-get install -y /tmp/steam_latest.deb \
    || echo "steam install failed - not fatal, the desktop still works"
  rm -f /tmp/steam_latest.deb
else
  echo "could not download steam_latest.deb"
fi

# Valve's launcher runs `steamdeps` unconditionally on every start, and steamdeps
# re-execs itself inside a terminal whenever DISPLAY is set - literally:
#   gnome-terminal --wait -- sh -c '...; printf "Press return to continue: "; read'
# On a headless desktop nobody presses return, so the launcher sits there
# forever and the client never downloads. This is the same failure as Ubuntu's
# zenity licence dialog, just a different dialog, and it is why the build froze
# at 74 MB. The launcher only logs and continues when steamdeps fails:
#   if ! "$STEAMDEPS"; then log "Unable to install Steam dependencies ..."; fi
# so taking the executable bit off is a clean, permanent opt-out - the deps it
# would have installed are installed above.
# `|| true` matters: the whole bootstrap runs under `set -e`, so a bare
# `[[ -e X ]] && cmd` aborts the build when X is absent.
[[ -e /usr/bin/steamdeps ]] && chmod -x /usr/bin/steamdeps || true

# Valve installs to /usr/bin/steam; Ubuntu's stub used /usr/games/steam. Accept
# either so a fallback install still passes.
verify "steam launcher present" bash -c 'test -x /usr/bin/steam || test -x /usr/games/steam'
verify "steam bootstrap shipped" test -f /usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz
verify "steam icon installed" test -f /usr/share/icons/hicolor/256x256/apps/steam.png
verify "steamdeps cannot block a headless boot" bash -c '! test -x /usr/bin/steamdeps'
