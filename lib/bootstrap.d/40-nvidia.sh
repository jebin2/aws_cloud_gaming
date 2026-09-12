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

# Ubuntu's driver package ships nvidia-graphics-drivers-kms.conf containing
# `options nvidia_drm modeset=1`. NvFBC cannot create a capture session while
# DRM KMS owns the display - every stream then connects, sends no video at all,
# and the client is dropped a second later with:
#   Sunshine: Failed to start capture session: the display server is in modeset
#   Moonlight: No video traffic was ever received from the host!
# which reads as a network fault and is nothing of the sort. This box has no
# physical display and needs nothing KMS provides, so turn it off. The build
# reboots at the end anyway, which is when this takes effect.
progress "disabling nvidia DRM KMS (NvFBC cannot capture with it on)"
printf 'options nvidia_drm modeset=0 fbdev=0\n' > /etc/modprobe.d/zz-nvfbc-no-kms.conf
sed -i 's/^options nvidia_drm modeset=1/options nvidia_drm modeset=0/' \
  /etc/modprobe.d/nvidia-graphics-drivers-kms.conf 2>/dev/null || true
update-initramfs -u >/dev/null 2>&1 || true

verify "nvidia DRM KMS disabled" bash -c '! grep -rqs "nvidia_drm.*modeset=1" /etc/modprobe.d/'

