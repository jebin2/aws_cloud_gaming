'use strict';
// On a laptop with an Intel and an NVIDIA GPU, the app is kept off NVIDIA's.
//
// It draws in software (index.js), but Chromium still starts a GPU process,
// which loads the system's EGL - and through glvnd that is NVIDIA's too, which
// opens the card. A hung NVIDIA driver (Xid 109, seen on one such laptop)
// freezes any process that does: the window waited out the 5 s timer, painted
// nothing, and opened late. Mesa's EGL on the Intel GPU never touches it.
//
// The same rule as cg's moonlight_gpu (lib/session.sh), which keeps Moonlight
// off it for the same reason: both GPUs there, only what is installed set, and
// a choice already made in the environment left alone.

const fs = require('node:fs');
const path = require('node:path');

const CHOSEN = ['__GLX_VENDOR_LIBRARY_NAME', '__EGL_VENDOR_LIBRARY_FILENAMES',
                'LIBVA_DRIVER_NAME', 'VK_DRIVER_FILES', 'VK_ICD_FILENAMES'];

// The variables to set, or null to leave the environment as it is. `root` is
// for tests: a directory standing in for /.
function intelOnly({ env = process.env, root = '/', arch = process.arch === 'x64' ? 'x86_64' : process.arch } = {}) {
  if (process.platform !== 'linux' && root === '/') return null;
  if (CHOSEN.some(k => env[k])) return null;
  const at = p => path.join(root, p);
  const exists = p => { try { fs.statSync(at(p)); return true; } catch { return false; } };
  if (!exists('dev/nvidiactl') && !exists('proc/driver/nvidia/version')) return null;
  let intel = false;
  try {
    for (const d of fs.readdirSync(at('sys/class/drm'))) {
      if (!d.startsWith('renderD')) continue;
      try {
        const drv = path.basename(fs.realpathSync(at(`sys/class/drm/${d}/device/driver`)));
        if (drv === 'i915' || drv === 'xe') intel = true;
      } catch { /* a render node with no driver link */ }
    }
  } catch { return null; }
  if (!intel) return null;
  const out = { __GLX_VENDOR_LIBRARY_NAME: 'mesa' };
  const egl = 'usr/share/glvnd/egl_vendor.d/50_mesa.json';
  if (exists(egl)) out.__EGL_VENDOR_LIBRARY_FILENAMES = at(egl);
  const vk = [`usr/share/vulkan/icd.d/intel_icd.${arch}.json`, 'usr/share/vulkan/icd.d/intel_icd.json'].find(exists);
  if (vk) out.VK_DRIVER_FILES = out.VK_ICD_FILENAMES = at(vk);
  for (const dir of ['usr/lib/dri', 'usr/lib64/dri', 'usr/lib/x86_64-linux-gnu/dri']) {
    if (exists(`${dir}/iHD_drv_video.so`)) { out.LIBVA_DRIVER_NAME = 'iHD'; break; }
    if (exists(`${dir}/i965_drv_video.so`)) out.LIBVA_DRIVER_NAME = 'i965';
  }
  return out;
}

module.exports = { intelOnly };
