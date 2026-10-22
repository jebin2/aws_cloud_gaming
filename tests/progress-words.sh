#!/usr/bin/env bash
# A progress line from the box must not read as a failure.
#
# cg classifies each line by its words - "cannot", "failed", "error" and the
# rest mark a failure (lib/common.sh, _CG_RE_FAIL). The box's own progress
# message "disabling nvidia DRM KMS (NvFBC cannot capture with it on)" said
# "cannot", so a healthy build showed its driver step as failed, in red, while
# it carried on installing Steam. Every progress line is checked here.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
export HOME=$(mktemp -d); trap 'rm -rf "$HOME"' EXIT
# shellcheck source=lib/common.sh
source lib/common.sh 2>/dev/null

n=0
while IFS= read -r msg; do
  n=$((n+1))
  kind=$(_cg_kind "$msg")
  if [[ $kind == fail ]]; then
    echo "  FAIL reads as a failure: $msg"; fail=$((fail+1))
  else
    pass=$((pass+1))
  fi
done < <(grep -hoE '^\s*progress "[^"$]+"' lib/bootstrap.d/*.sh | sed -E 's/^\s*progress "//; s/"$//')
echo "  ok   $pass of $n progress lines read as progress"
(( n > 10 )) || { echo "  FAIL found only $n progress lines - did the pattern stop matching?"; fail=$((fail+1)); }

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
