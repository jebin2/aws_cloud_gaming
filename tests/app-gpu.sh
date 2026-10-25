#!/usr/bin/env bash
# The app kept off the NVIDIA GPU of a laptop that has an Intel one too. Its
# GPU process loads the system's EGL even drawing in software, and a hung
# NVIDIA driver froze it: the window waited out its 5 s timer and opened late.
# The same rule as cg's (tests/moonlight-gpu.sh), set before anything starts.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
command -v node >/dev/null || { echo "  (no node - skipped)"; echo "app-gpu: 0 passed, 0 failed"; exit 0; }

machine() { # machine <intel|none> <nvidia|none>
  rm -rf "$T/root"; mkdir -p "$T/root/sys/class/drm/renderD128/device" "$T/root/sys/bus/pci/drivers/i915"
  [[ $1 == intel ]] && ln -s "$T/root/sys/bus/pci/drivers/i915" "$T/root/sys/class/drm/renderD128/device/driver"
  if [[ $2 == nvidia ]]; then mkdir -p "$T/root/dev"; touch "$T/root/dev/nvidiactl"; fi
  mkdir -p "$T/root/usr/share/glvnd/egl_vendor.d" "$T/root/usr/share/vulkan/icd.d" "$T/root/usr/lib/dri"
  touch "$T/root/usr/share/glvnd/egl_vendor.d/50_mesa.json" "$T/root/usr/share/vulkan/icd.d/intel_icd.x86_64.json" \
        "$T/root/usr/lib/dri/iHD_drv_video.so"
}
pick() { node -e '
  const { intelOnly } = require("./app/main/gpu");
  const env = JSON.parse(process.argv[2]);
  const r = intelOnly({ env, root: process.argv[1], arch: "x86_64" });
  console.log(r ? Object.entries(r).map(([k, v]) => k + "=" + v.split("/").pop()).join(" ") : "none");' "$T/root" "${1:-{\}}"; }

machine intel nvidia
check    "both GPUs: the app on Intel" "$(pick)" \
         "__GLX_VENDOR_LIBRARY_NAME=mesa __EGL_VENDOR_LIBRARY_FILENAMES=50_mesa.json VK_ICD_FILENAMES=intel_icd.x86_64.json VK_DRIVER_FILES=intel_icd.x86_64.json LIBVA_DRIVER_NAME=iHD"
check    "a choice already made is kept" "$(pick '{"__GLX_VENDOR_LIBRARY_NAME":"nvidia"}')" "none"
machine intel none
check    "Intel alone: nothing"  "$(pick)" "none"
machine none nvidia
check    "NVIDIA alone: nothing" "$(pick)" "none"
contains "set before anything starts" \
  "$(awk '/intelOnly\(\)/{a=NR} /app\.disableHardwareAcceleration|app\.whenReady/{if(!b)b=NR} END{print (a && b && a < b) ? "first" : "late"}' app/main/index.js)" "first"

echo; echo "app-gpu: $pass passed, $fail failed"; (( fail == 0 ))
