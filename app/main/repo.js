'use strict';
// Where the scripts are.
//
// Its own module because it had a bug that shipped: a packaged build carries
// the scripts in resources/ayis/, so resources/ contains a DIRECTORY named ayis -
// and the old test was existsSync(dir + '/ayis'), which says yes to a directory
// just as happily as to a script. The packaged app therefore chose resources/
// as the repo and spawned `./ayis` against a directory. Node answers EACCES, and
// a failed spawn emits no 'exit' event, so the window sat on "refreshing"
// forever with no error anywhere. The standalone package could not run one
// command, and nothing caught it because this function lived inside index.js
// where a test cannot reach it without starting Electron.
const path = require('node:path');
const fs = require('node:fs');

// What the engine is called on this system.
const AYIS = process.platform === 'win32' ? 'ayis.exe' : 'ayis';

// findRepo({ env, dirname, resourcesPath, homedir }) -> directory holding `ayis`
//
// Order matters: a checkout beside the app wins over the bundled copy, because
// someone running from source is editing that one and expects their edits to
// take effect. The bundled copy is read-only, which is why ayis keeps its
// settings outside its own directory - see lib/env-file.sh.
function findRepo({ env = process.env, dirname = __dirname,
                    resourcesPath = process.resourcesPath,
                    homedir = require('node:os').homedir() } = {}) {
  const candidates = [
    env.AYIS_REPO,
    path.resolve(dirname, '..', '..'),            // a checkout: app/main -> repo
    resourcesPath && path.join(resourcesPath, 'ayis'),   // packaged
    path.join(homedir, 'ayis'),
  ].filter(Boolean);

  // `ayis` must be a FILE. This is the whole bug.
  for (const dir of candidates) {
    try { if (fs.statSync(path.join(dir, AYIS)).isFile()) return dir; } catch { /* next */ }
  }
  // Nothing matched. Return the checkout guess so the failure names a sensible
  // path, and let the spawn report it - which it now can, because a spawn error
  // settles the job instead of leaving it running.
  return candidates.find(c => c !== env.AYIS_REPO) || candidates[0];
}

module.exports = { findRepo, AYIS };
