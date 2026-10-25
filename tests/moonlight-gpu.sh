#!/usr/bin/env bash
# Moonlight on the Intel GPU of a laptop that has an NVIDIA one too. A hung
# NVIDIA driver freezes any process that opens it, and Moonlight tries every
# GPU before it streams - so it sat at "connecting", the host never asked for
# anything. Run on Intel alone it streamed. Only what is installed is set, a
# choice already made is kept, and a machine without both GPUs is left alone.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

# machine <intel|none> <nvidia|none> - a fake root with those GPUs, Intel's
# graphics and video drivers installed as Arch installs them.
machine() {
  rm -rf "$T/root"; mkdir -p "$T/root/sys/class/drm/renderD128/device" "$T/root/sys/bus/pci/drivers"/{i915,nvidia}
  [[ $1 == intel ]] && ln -s "$T/root/sys/bus/pci/drivers/i915" "$T/root/sys/class/drm/renderD128/device/driver"
  if [[ $2 == nvidia ]]; then mkdir -p "$T/root/dev"; touch "$T/root/dev/nvidiactl"; fi
  mkdir -p "$T/root/usr/share/glvnd/egl_vendor.d" "$T/root/usr/share/vulkan/icd.d" "$T/root/usr/lib/dri"
  touch "$T/root/usr/share/glvnd/egl_vendor.d/50_mesa.json" "$T/root/usr/share/vulkan/icd.d/intel_icd.$(uname -m).json" \
        "$T/root/usr/lib/dri/iHD_drv_video.so"
}
env_of() { ( env -i PATH="$PATH" HOME="$T" CG_GPU_ROOT="$T/root" "$@" bash -c '
  source lib/common.sh; source lib/session.sh
  echo "gpu=${MOONLIGHT_GPU:-none} glx=${__GLX_VENDOR_LIBRARY_NAME:-} egl=${__EGL_VENDOR_LIBRARY_FILENAMES##*/} vk=${VK_DRIVER_FILES##*/} va=${LIBVA_DRIVER_NAME:-}"' ); }

echo "1. both GPUs: Moonlight on Intel"
machine intel nvidia
out=$(env_of)
check    "every Intel driver chosen" "$out" "gpu=the Intel GPU (NVIDIA left alone) glx=mesa egl=50_mesa.json vk=intel_icd.$(uname -m).json va=iHD"
rm "$T/root/usr/lib/dri/iHD_drv_video.so"; touch "$T/root/usr/lib/dri/i965_drv_video.so"
contains "an older Intel: its own video driver" "$(env_of)" "va=i965"
rm "$T/root/usr/share/vulkan/icd.d/intel_icd.$(uname -m).json"; touch "$T/root/usr/share/vulkan/icd.d/intel_icd.json"
contains "Ubuntu's name for the Vulkan driver" "$(env_of)" "vk=intel_icd.json"

echo "2. only what is there"
machine intel none
check    "Intel alone: nothing set"  "$(env_of)" "gpu=none glx= egl= vk= va="
machine none nvidia
check    "NVIDIA alone: nothing set" "$(env_of)" "gpu=none glx= egl= vk= va="

echo "3. a choice already made is kept"
machine intel nvidia
check    "set by you: left as it is" "$(env_of __GLX_VENDOR_LIBRARY_NAME=nvidia)" "gpu=none glx=nvidia egl= vk= va="
contains "set by the app (Intel): said" "$(env_of __GLX_VENDOR_LIBRARY_NAME=mesa LIBVA_DRIVER_NAME=iHD)" "gpu=the Intel GPU (NVIDIA left alone) glx=mesa"

echo "4. the session says so"
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\necho "ml $LIBVA_DRIVER_NAME"\n' > "$T/bin/moonlight"; chmod +x "$T/bin/moonlight"
out=$( env -i PATH="$T/bin:$PATH" HOME="$T" XDG_CACHE_HOME="$T/cache" CG_GPU_ROOT="$T/root" CG_COLOR=never bash -c '
  source lib/common.sh; source lib/session.sh; stream_play 100.64.0.9 Desktop' 2>&1 )
contains "the run names the GPU"     "$out" "decoding on the Intel GPU (NVIDIA left alone)"
contains "  and Moonlight runs on it" "$(cat "$T/cache/cg/moonlight.log")" "ml iHD"

echo; echo "moonlight-gpu: $pass passed, $fail failed"; (( fail == 0 ))
