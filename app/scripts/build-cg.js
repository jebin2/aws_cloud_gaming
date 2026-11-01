'use strict';
// Builds the cg that goes into the package: one static Go program, named for the
// system it is built for (cg.exe on Windows, cg elsewhere), in the repo root where
// the packager and a checkout both look for it.
//
// CG_GOOS / CG_GOARCH build for another system than the one running this - how one
// macOS runner makes both the Intel and the Apple Silicon app.
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const NODE_OS = { win32: 'windows', darwin: 'darwin', linux: 'linux' };
const goos = process.env.CG_GOOS || NODE_OS[process.platform] || process.platform;
const goarch = process.env.CG_GOARCH || '';
const out = goos === 'windows' ? 'cg.exe' : 'cg';

const env = { ...process.env, CGO_ENABLED: '0', GOOS: goos };
if (goarch) env.GOARCH = goarch;

const r = spawnSync('go', ['build', '-trimpath', '-ldflags', '-s -w', '-o', out, './cmd/cg'], {
  cwd: path.resolve(__dirname, '..', '..'), env, stdio: 'inherit',
});
if (r.error) { console.error(`could not run go: ${r.error.message}`); process.exit(1); }
process.exit(r.status === null ? 1 : r.status);
