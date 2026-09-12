# --- NVIDIA driver -----------------------------------------------------------
progress "installing nvidia driver (the slowest step, ~10 min)"
apt-get install -y ubuntu-drivers-common
# The desktop driver, not --gpgpu: we need the X11 display components, which
# the headless compute build omits.
# Sunshine's bundled ffmpeg needs NVENC API 13.1, which means driver 610 or
# newer. `ubuntu-drivers install` picks the distro's "recommended" driver,
# which was 595 - and Sunshine then silently falls back to libx264, which
# 4 vCPUs cannot sustain, giving a black screen rather than an error.
NEWEST=$(apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' 2>/dev/null \
  | grep -oE 'nvidia-driver-[0-9]+-open' | sort -uV | tail -1)
if [[ -n $NEWEST ]]; then
  progress "installing $NEWEST"
  apt-get install -y "$NEWEST" || ubuntu-drivers install || ubuntu-drivers autoinstall
else
  ubuntu-drivers install || ubuntu-drivers autoinstall
fi

verify "nvidia driver packages installed" dpkg -l nvidia-driver-610-open
