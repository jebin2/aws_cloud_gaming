#!/usr/bin/env bash
# The packaged app could not run a single command, and said nothing about it.
#
# Reported from a fresh Omarchy VM: the header sat on
# `running: cg refresh, cg config, cg machines` forever. Two bugs, and the
# second is what made the first invisible:
#
#   1. findRepo tested existsSync(dir + "/cg"), which is TRUE for a directory
#      named cg. A packaged build puts the scripts in resources/cg/, so
#      resources/ contains exactly that - and resources/ was chosen as the repo,
#      making every command spawn `./cg` against a directory. Node: EACCES.
#   2. A spawn that fails emits 'error' and 'close' but NOT 'exit'. The app
#      deletes a job when it sees 'exit', so the job stayed in the map for the
#      life of the window: permanently "running", and because note() is behind
#      isWrite, a failed READ printed nothing anywhere.
#
# Neither was caught because findRepo lived inside index.js, which cannot be
# required without starting Electron. It is main/repo.js now, so this can.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export HOME="$T"          # nothing here may read the real home

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

command -v node >/dev/null || { echo "  (node missing - skipped)"; echo "app-packaged: 0 passed, 0 failed"; exit 0; }

REPO=$PWD

echo "1. the packaged layout, which is the one that was broken"
# Exactly what electron-builder produces: resources/app.asar, and the scripts in
# resources/cg/ - so resources/ holds a DIRECTORY called cg.
mkdir -p "$T/pkg/resources/cg/lib" "$T/pkg/resources/app.asar/main"
printf '#!/usr/bin/env bash\necho hi\n' > "$T/pkg/resources/cg/cg"
chmod +x "$T/pkg/resources/cg/cg"
got=$(node -e '
const { findRepo } = require(process.argv[1] + "/app/main/repo.js");
console.log(findRepo({
  env: {},
  dirname: process.argv[2] + "/pkg/resources/app.asar/main",
  resourcesPath: process.argv[2] + "/pkg/resources",
  homedir: process.argv[2],
}));' "$REPO" "$T")
check "the repo is resources/cg, where the script is" "$got" "$T/pkg/resources/cg"
# The old behaviour, pinned so it cannot come back: resources/ must NOT win just
# because something called cg exists inside it.
if [[ $got != "$T/pkg/resources" ]]; then echo "  ok     and never resources/ itself"; pass=$((pass+1));
else echo "  FAIL   it chose resources/ again - the directory won"; fail=$((fail+1)); fi
# The directory it used to choose really does contain a `cg` entry, so this is
# a live trap and not a hypothetical one.
check "  the trap is real: resources/cg exists as a directory" \
      "$([[ -d $T/pkg/resources/cg ]] && echo yes)" "yes"

echo "2. a checkout still wins over the bundled copy"
mkdir -p "$T/src/app/main"
printf '#!/usr/bin/env bash\n' > "$T/src/cg"; chmod +x "$T/src/cg"
got=$(node -e '
const { findRepo } = require(process.argv[1] + "/app/main/repo.js");
console.log(findRepo({ env: {},
  dirname: process.argv[2] + "/src/app/main",
  resourcesPath: process.argv[2] + "/pkg/resources",
  homedir: process.argv[2] }));' "$REPO" "$T")
check "source beside the app is preferred" "$got" "$T/src"

echo "3. CG_REPO overrides both"
got=$(node -e '
const { findRepo } = require(process.argv[1] + "/app/main/repo.js");
console.log(findRepo({ env: { CG_REPO: process.argv[2] + "/src" },
  dirname: process.argv[2] + "/pkg/resources/app.asar/main",
  resourcesPath: process.argv[2] + "/pkg/resources",
  homedir: process.argv[2] }));' "$REPO" "$T")
check "CG_REPO is taken" "$got" "$T/src"
# An override pointing nowhere must not be returned as if it worked.
got=$(node -e '
const { findRepo } = require(process.argv[1] + "/app/main/repo.js");
console.log(findRepo({ env: { CG_REPO: "/nope/nowhere" },
  dirname: process.argv[2] + "/pkg/resources/app.asar/main",
  resourcesPath: process.argv[2] + "/pkg/resources",
  homedir: process.argv[2] }));' "$REPO" "$T")
check "a dead CG_REPO falls through to the real copy" "$got" "$T/pkg/resources/cg"

echo "4. a directory named cg never beats a real script"
# The bug shape itself: an EARLIER candidate holds a directory called cg, a
# later one holds the script. The earlier one used to win.
mkdir -p "$T/trap/cg"
got=$(node -e '
const { findRepo } = require(process.argv[1] + "/app/main/repo.js");
console.log(findRepo({ env: {}, dirname: process.argv[2] + "/trap/a/b",
  resourcesPath: process.argv[2] + "/pkg/resources", homedir: process.argv[2] }));' "$REPO" "$T")
check "the real script wins over the directory" "$got" "$T/pkg/resources/cg"
# And with nothing anywhere, the documented fallback: the checkout guess, so the
# spawn error names a path someone recognises rather than undefined.
got=$(node -e '
const { findRepo } = require(process.argv[1] + "/app/main/repo.js");
console.log(findRepo({ env: {}, dirname: process.argv[2] + "/bare/a/b",
  resourcesPath: null, homedir: process.argv[2] + "/empty" }));' "$REPO" "$T")
check "with no script anywhere it names the checkout" "$got" "$T/bare"

echo "5. every job ends in exactly one exit, even one that cannot start"
# This is what turned a wrong path into a permanent "refreshing".
events() { # events <cwd> - the event kinds the runner emits, in order
  node -e '
const { run } = require(process.argv[1] + "/app/main/runner.js");
const seen = [];
run({ repo: process.argv[2], args: ["status"], onEvent: e => seen.push(e.t) });
setTimeout(() => console.log(seen.join(",")), 900);' "$REPO" "$1"
}
mkdir -p "$T/isdir/cg"
out=$(events "$T/isdir")
contains "spawning a directory reports the error" "$out" "error"
contains "  AND emits an exit, so the job clears" "$out" "exit"
check    "  exactly one exit, never two" "$(grep -o exit <<<"$out" | wc -l)" "1"

echo "6. a normal run still ends in one exit"
mkdir -p "$T/good"
printf '#!/usr/bin/env bash\nexit 3\n' > "$T/good/cg"; chmod +x "$T/good/cg"
out=$(events "$T/good")
check "one exit and no spawn error" "$out" "exit"
rc=$(node -e '
const { run } = require(process.argv[1] + "/app/main/runner.js");
let rc = "none";
run({ repo: process.argv[2], args: ["status"], onEvent: e => { if (e.t === "exit") rc = e.rc; } });
setTimeout(() => console.log(rc), 900);' "$REPO" "$T/good")
check "  and it carries the real exit code" "$rc" "3"

echo "7. the runner says so in source, so the reason survives a refactor"
runner=$(cat app/main/runner.js)
contains "exit is emitted once, from a settle" "$runner" "const settle = rc =>"
contains "  a spawn error settles it"          "$runner" "settle(127)"
contains "  and close is a backstop"           "$runner" "child.on('close', () => settle(1))"

echo "8. a failed READ is no longer silent"
js=$(cat app/renderer/app.js)
contains "a non-zero read is reported"   "$js" "job.json && (event.rc !== 0 || failure)"
contains "  naming why it could not run" "$js" "could not run:"
contains "  and the reason is kept"      "$js" "if (event.t === 'error' && event.text) job.err"
# The message goes on the same line the header rewrites, so it has to be set
# after updateHeader - put before it, it was overwritten in the same tick.
handler=$(awk '/if \(event.t === .exit.\)/,/if \(isWrite\(job.cmd\)\)/' app/renderer/app.js)
order=$(grep -nE "updateHeader\(\);|event.rc !== 0 \|\| failure" <<<"$handler" \
        | sed -E 's/.*(updateHeader|\|\| failure).*/\1/' | tr '\n' ' ')
check "the failure is painted after updateHeader" "$order" "updateHeader || failure "
# A painter that THREW was silent for the same reason: the catch wrote job-line
# and updateHeader overwrote it in the same tick. Found by rendering the page.
contains "a throwing painter is reported too" "$js" "could not show cg"
contains "  and names the painter it could not find" "$js" "no painter for"
# And the colour has to go back, or one failure paints every later idle red.
contains "the header resets the colour too" "$js" "\$('job-line').className = JOB_LINE_OK"
contains "  from the class the markup ships" "$js" "text-on-surface-variant"

echo ""
echo "app-packaged: $pass passed, $fail failed"
(( fail == 0 ))
