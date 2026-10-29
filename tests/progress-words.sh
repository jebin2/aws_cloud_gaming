#!/usr/bin/env bash
# Every progress line from the box has a chip in the app's build step.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
# Whether a line reads as a failure is a Go test now: internal/output/progress_test.go.

# Every progress line is also a chip in the app's "Installing the software"
# step - or the step says it is installing something it never lists. The two
# that are not pieces of software are named here and nowhere else.
missing=$(node -e '
const fs = require("fs");
const js = fs.readFileSync("app/renderer/app.js", "utf8");
const src = js.slice(js.indexOf("const BUILD_PARTS = ["), js.indexOf("];", js.indexOf("const BUILD_PARTS = [")) + 1);
const BUILD_PARTS = eval(src.replace("const BUILD_PARTS =", "(") + ")");
const lines = fs.readFileSync(0, "utf8").split("\n").filter(Boolean);
const skip = [/^finishing up/, /^installing \$NEWEST/, /^enabled the multilib repository/, /^the NVIDIA driver loads at the next boot/];
console.log(lines.filter(l => !skip.some(r => r.test(l)) && !BUILD_PARTS.some(([, re]) => re.test(l))).join("; "));
' < <(grep -hoE '^\s*progress "[^"]+"' lib/bootstrap.d/*.sh | sed -E 's/^\s*progress "//; s/"$//')) \
  || missing="(the check itself failed to run)"
if [[ -z $missing ]]; then echo "  ok   every progress line has a chip in the build step"; pass=$((pass+1))
else echo "  FAIL no chip for: $missing"; fail=$((fail+1)); fi

echo ""
echo "progress-words: $pass passed, $fail failed"
(( fail == 0 ))
