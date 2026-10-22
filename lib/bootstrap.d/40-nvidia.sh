# --- NVIDIA driver -----------------------------------------------------------
# An NVIDIA card with no driver gets one: always on the AWS box; on a machine of
# yours only when it has the card and NO driver installed at all, which is then
# loaded at the next boot - this never reboots your machine.
#
# Not "nvidia-smi does not answer": a driver that is installed and waiting on a
# reboot, or that has hung, does not answer either - and installing another over
# it left a machine with no working display. Whatever is installed is yours.
NVIDIA_ADDED=""
# The checks below read all of their input (no grep -q, no head): the build runs
# under pipefail, and a reader that stops at its first match kills the writer
# still writing - exit 141 - so a found driver read as none, and one was
# installed over it. grep -m1 stops the reader too, so it reads a short lspci.
nvidia_card() { lspci 2>/dev/null | grep -E " (VGA compatible|3D) controller: " | grep -i -m1 nvidia; }
nvidia_driver_installed() {
  case $FAMILY in
    ubuntu|debian) dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'nvidia-driver-*' 2>/dev/null \
                     | awk '$2 == "installed"' | grep . >/dev/null ;;
    arch) pacman -Qq 2>/dev/null | grep -E '^nvidia(-open)?(-dkms|-lts)?$|^nvidia-[0-9]+xx(-dkms)?$' >/dev/null ;;
    *) return 1 ;;
  esac || lsmod 2>/dev/null | grep '^nvidia ' >/dev/null
}
# The open kernel modules need a Turing chip or newer (TU, GA, GH, AD, GB): a
# GTX 10xx and older have none. Told by the chip lspci names, never guessed -
# an unnamed one counts as older.
nvidia_open_ok() { nvidia_card | grep -E '\b(TU|GA|GH|AD|GB)[0-9]{3}\b' >/dev/null; }
NVIDIA_OWN_OLD=""
if ! aws_box && [[ -n $(nvidia_card) ]] && nvidia_driver_installed && ! nvidia-smi >/dev/null 2>&1; then
  progress "an NVIDIA driver is installed but not answering yet (a reboot may load it) - leaving it as it is"
fi
if ! aws_box && [[ -n $(nvidia_card) ]] && ! nvidia_driver_installed && ! nvidia_open_ok; then
  NVIDIA_OWN_OLD=1
fi
if aws_box || { [[ -n $(nvidia_card) ]] && ! nvidia_driver_installed; }; then
  case $FAMILY in
    ubuntu|debian)
      progress "installing nvidia driver (the slowest step, ~10 min)"
      apt-get install -y ubuntu-drivers-common
      # The desktop driver, not --gpgpu: we need the X11 display components, which
      # the headless compute build omits.
      # Sunshine's bundled ffmpeg needs NVENC API 13.1, which arrived in driver 610.
      # `ubuntu-drivers install` picks the distro's "recommended" driver, which was
      # 595 - and Sunshine then silently falls back to libx264, which 4 vCPUs cannot
      # sustain, giving a black screen rather than an error. So the requirement is a
      # version FLOOR: install the newest open driver the archive offers, then check
      # the floor rather than a package name.
      NVIDIA_MIN=610
      NEWEST=$(apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' 2>/dev/null \
        | grep -oE 'nvidia-driver-[0-9]+-open' | sort -uV | tail -1 || true)
      # An older card of yours: the driver Ubuntu recommends for it, and no
      # floor - the newest open driver does not run on it at all.
      if [[ -n $NVIDIA_OWN_OLD ]]; then
        progress "installing nvidia driver (the one Ubuntu recommends for this older card)"
        ubuntu-drivers install || ubuntu-drivers autoinstall
      elif [[ -n $NEWEST ]]; then
        progress "installing $NEWEST"
        apt-get install -y "$NEWEST" || ubuntu-drivers install || ubuntu-drivers autoinstall
      else
        ubuntu-drivers install || ubuntu-drivers autoinstall
      fi

      # The highest nvidia-driver-NNN actually installed, whatever its name. Asking
      # dpkg for one hardcoded name - it was nvidia-driver-610-open - meant the check
      # failed the day Ubuntu's archive moved on to 615: the install had done exactly
      # what it was told, picked the newest, and the verify then demanded a package
      # that was deliberately not installed. Under `set -e` a failed verify aborts
      # user-data, so the build died before xorg, steam and sunshine, and a perfectly
      # good driver reported as a broken GPU.
      nvidia_driver_version() {
        dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'nvidia-driver-*' 2>/dev/null \
          | awk '$2 == "installed" { print $1 }' \
          | sed -nE 's/^nvidia-driver-([0-9]+).*/\1/p' \
          | sort -n | tail -1
      }
      nvidia_driver_ok() {
        local v
        v=$(nvidia_driver_version) || v=
        [[ -n $v ]] && (( v >= NVIDIA_MIN ))
      }
      # In a variable, not inline: the pipeline exits 0 with NO output when nothing
      # matches, so `|| echo none` would never fire and the line would read blank.
      NV_FOUND=$(nvidia_driver_version) || NV_FOUND=
      progress "installed nvidia driver: ${NV_FOUND:-none} (need $NVIDIA_MIN+)"
      if [[ -n $NVIDIA_OWN_OLD ]]; then
        verify "nvidia driver installed (the one Ubuntu recommends for this card)" nvidia_driver_installed
      else
        verify "nvidia driver $NVIDIA_MIN or newer installed" nvidia_driver_ok
      fi
      ;;
    arch)
      # Arch carries the open driver only; an older card's is a legacy one from
      # the AUR, which is yours to choose.
      if [[ -n $NVIDIA_OWN_OLD ]]; then
        echo ">>> FAILED: this NVIDIA card is older than Turing, and its driver is not in the Arch repositories - install its legacy driver from the AUR yourself, then run setup again"
        exit 1
      fi
      progress "installing nvidia driver"
      pkg nvidia-open-dkms nvidia-utils
      verify "nvidia driver installed" pacman -Q nvidia-utils ;;
    *) echo ">>> FAILED: this NVIDIA card has no driver, and cg installs one only on Ubuntu, Debian or Arch"
       exit 1 ;;
  esac
  NVIDIA_ADDED=1
fi

# NvFBC capture on the AWS box's headless X - never on a machine of yours, where
# turning kernel modesetting off would break a Wayland desktop.
if aws_box; then
# Ubuntu's driver package ships nvidia-graphics-drivers-kms.conf containing
# `options nvidia_drm modeset=1`. NvFBC cannot create a capture session while
# DRM KMS owns the display - every stream then connects, sends no video at all,
# and the client is dropped a second later with:
#   Sunshine: Failed to start capture session: the display server is in modeset
#   Moonlight: No video traffic was ever received from the host!
# which reads as a network fault and is nothing of the sort. This box has no
# physical display and needs nothing KMS provides, so turn it off. The build
# reboots at the end anyway, which is when this takes effect.
# Worded with no failure word in it: cg reads "cannot", "failed" or "error"
# in a progress line as a failure, and this one is a normal step.
progress "disabling nvidia DRM KMS (NvFBC needs it off to capture)"
printf 'options nvidia_drm modeset=0 fbdev=0\n' > /etc/modprobe.d/zz-nvfbc-no-kms.conf
sed -i 's/^options nvidia_drm modeset=1/options nvidia_drm modeset=0/' \
  /etc/modprobe.d/nvidia-graphics-drivers-kms.conf 2>/dev/null || true
update-initramfs -u >/dev/null 2>&1 || true

verify "nvidia DRM KMS disabled" bash -c '! grep -rqs "nvidia_drm.*modeset=1" /etc/modprobe.d/'
fi
