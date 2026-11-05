#!/usr/bin/env bash
# The chips on the Build screen: which pieces of the machine are waiting, running
# or done. On a supervised build pieces run together and say when each is done; on
# any other build the latest one to start is the one running, as always.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
command -v node >/dev/null || { echo "  (no node - skipped)"; echo "parts: 0 passed, 0 failed"; exit 0; }
js() { # js <expression using partStates>
  node -e "
const src = require('fs').readFileSync('app/renderer/app.js', 'utf8');
const parts = src.match(/const BUILD_PARTS = \[[\s\S]*?\n\];/)[0];
const fn = src.match(/function partStates\([\s\S]*?\n}\n/)[0];
eval(parts + fn + '; globalThis.out = ' + process.argv[1]);
console.log(globalThis.out);" "$1"
}
states='x => x.map(([n, s]) => n + ":" + s).join(",")'

echo "1. a build with no word of which pieces are done: the latest to start is running"
check "the last started runs, earlier ones are done" \
  "$(js "($states)(partStates(['base','disk','nvidia'], false)).split(',').slice(0,7).join(',')")" \
  "Base system:done,Game disk:done,Auto-stop:waiting,Tailscale:waiting,Game library:waiting,Desktop:waiting,NVIDIA driver:running"

echo "2. a supervised build: started and not finished means running, however many"
check "two together" \
  "$(js "($states)(partStates(['nvidia','steam','steam-update','desktop'], false, new Set(['nvidia','steam']))).split(',').filter(s => /running|done/.test(s)).join(',')")" \
  "Desktop:running,NVIDIA driver:done,Steam:done,Steam client:running"
check "one that has not started is waiting" \
  "$(js "($states)(partStates(['nvidia'], false, new Set(['base']))).split(',').find(s => s.startsWith('Firefox'))")" \
  "Firefox:waiting"

echo "3. when the step is over everything is done"
check "all done" "$(js "(partStates(['nvidia'], true, new Set(['base']))).every(([, s]) => s === 'done')")" "true"

echo; echo "parts: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
