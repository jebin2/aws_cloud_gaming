#!/usr/bin/env bash
# The Dependencies page, rendered.
#
# Its whole job is to be useful on a laptop where nothing works yet, so the two
# things it must never do are: draw an Install button that cannot install
# anything, and call a laptop ready when Tailscale is installed but signed out.
# Neither is visible in the source - both depend on which branch the painter
# takes - so this loads the real page and reads it back.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export HOME="$T"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

BROWSER=""
for b in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$b" >/dev/null && { BROWSER=$b; break; }
done
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "deps-dom: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/"
cp app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
window.__ran = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
window.cg = {
  run: (args) => { window.__ran.push(args.join(' ')); return Promise.resolve({ ok: true, id: window.__ran.length }); },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  onEvent() { return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(() => {
  const out = [];
  const g = id => {
    const el = document.getElementById(id);
    return el ? el.textContent.replace(/\s+/g, ' ').trim() : '(missing)';
  };
  const tool = (name, present) => ({
    tool: name, label: name === 'aws' ? 'AWS CLI v2' : name, present,
    why: name + ' is for something', plan: 'sudo pacman -S ' + name,
    manual: 'https://example.invalid/' + name,
  });
  const payload = (missing, extra) => Object.assign({
    tools: ['python3', 'ssh', 'curl', 'aws', 'tailscale', 'moonlight']
             .map(n => tool(n, !missing.includes(n))),
    package_manager: 'pacman', root: 'pkexec', root_blocked: null,
    tailscale_signed_in: true,
  }, extra || {});
  const read = label => {
    out.push(label + ' READY | ' + g('d-ready'));
    out.push(label + ' PM | ' + g('d-pm'));
    out.push(label + ' ROOT | ' + g('d-root'));
    out.push(label + ' ALL | ' + (document.getElementById('d-install-all').hidden
      ? 'hidden' : g('d-install-all-label')));
    out.push(label + ' ROWS | ' + [...document.querySelectorAll('#d-rows tr')]
      .map(r => [...r.cells].map(c => c.textContent.trim()).join('/')).join(' || '));
    out.push(label + ' NOTE | ' + g('d-log-note'));
  };
  try {
    paintDeps(payload(['aws', 'moonlight']));
    read('MISSING');
    window.__ran = [];
    document.getElementById('d-install-all').click();
    out.push('ALL RAN | ' + window.__ran.join(' ;; '));
    window.__ran = [];
    // The per-row button: the first Install in the table is the AWS CLI's.
    [...document.querySelectorAll('#d-rows button')][0].click();
    out.push('ROW RAN | ' + window.__ran.join(' ;; '));
    out.push('ROW LOG | ' + (document.getElementById('d-log').hidden ? 'hidden' : 'shown'));

    paintDeps(payload([]));
    read('ALLHERE');

    // Nothing can be root: no button may be drawn at all.
    paintDeps(payload(['aws'], { root: null,
      root_blocked: 'no terminal, and no desktop session for polkit to show a password prompt on' }));
    read('NOROOT');
    out.push('NOROOT BUTTONS | ' + document.querySelectorAll('#d-rows button').length);

    // No package manager: same, plus the manual link in the row.
    paintDeps(payload(['aws'], { package_manager: null }));
    read('NOPM');

    // Installed but signed out: nothing to install, and nothing works.
    paintDeps(payload([], { tailscale_signed_in: false }));
    read('SIGNEDOUT');
  } catch (e) { out.push('THREW | ' + e.message); }
  out.push('ERRS | ' + (window.__errs || []).join(' ;; '));
  const pre = document.createElement('pre');
  pre.id = 'probe-out'; pre.textContent = out.join('\n');
  document.body.append(pre);
})();
PROBE

python3 -I - "$T/r" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "index.html"
t = p.read_text()
t = t.replace('<script src="app.js"', '<script src="stub.js"></script>\n<script src="app.js"', 1)
t = t.replace('</body>', '<script src="probe.js"></script>\n</body>', 1)
p.write_text(t)
PY

OUT=$("$BROWSER" --headless --disable-gpu --no-sandbox --window-size=1280,900 \
      --virtual-time-budget=5000 --dump-dom "file://$T/r/index.html" 2>/dev/null \
  | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")')
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "deps-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. two tools missing"
contains "it counts them"             "$(row 'MISSING READY')" "2 of 6 missing"
contains "  and names the manager"    "$(row 'MISSING PM')"    "installs with pacman"
contains "the table lists every tool" "$(row 'MISSING ROWS')"  "TOOL/WHAT IT IS FOR/STATE"
contains "  what is installed"        "$(row 'MISSING ROWS')"  "python3/python3 is for something/installed"
contains "  and what is missing"      "$(row 'MISSING ROWS')"  "AWS CLI v2/aws is for something/missing/Install"
contains "the button says how many"   "$(row 'MISSING ALL')"   "Install 2 missing"
check    "  and installs them"        "$(row 'ALL RAN')"       "ALL RAN | deps install"
check    "a row installs just that one" "$(row 'ROW RAN')"     "ROW RAN | deps install aws"
check    "  and opens the log"        "$(row 'ROW LOG')"       "ROW LOG | shown"

echo "2. everything is here"
contains "it says so"                 "$(row 'ALLHERE READY')" "everything cg needs is here"
check    "  and offers nothing"       "$(row 'ALLHERE ALL')"   "ALLHERE ALL | hidden"

echo "3. how it would become root, said before anything is pressed"
contains "polkit is named"            "$(row 'MISSING ROOT')"  "desktop dialog (polkit)"
contains "no root: it says why"       "$(row 'NOROOT ROOT')"   "not possible from here"
contains "  quoting the reason"       "$(row 'NOROOT ROOT')"   "no desktop session"
# A button that cannot work is worse than no button: it fails inside pacman,
# where the reason is hardest to see.
check    "  and draws no button"      "$(row 'NOROOT BUTTONS')" "NOROOT BUTTONS | 0"
check    "  not even Install all"     "$(row 'NOROOT ALL')"    "NOROOT ALL | hidden"
contains "  handing over the link"    "$(row 'NOROOT ROWS')"   "https://example.invalid/aws"

echo "4. no package manager"
contains "it says there is none"      "$(row 'NOPM PM')"       "by hand"
check    "  and offers no button"     "$(row 'NOPM ALL')"      "NOPM ALL | hidden"
contains "  giving the link instead"  "$(row 'NOPM ROWS')"     "https://example.invalid/aws"

echo "5. installed, but signed out"
# Every tool present, and the laptop still cannot reach the box.
contains "it is not called ready"     "$(row 'SIGNEDOUT READY')" "Tailscale is not signed in"
lacks    "  not 'everything is here'" "$(row 'SIGNEDOUT READY')" "everything cg needs"
contains "  and says what to run"     "$(row 'SIGNEDOUT NOTE')"  "sudo tailscale up"

echo "6. nothing threw"
check "no painter threw"              "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors" "$(row 'ERRS')"        "ERRS | "

echo ""
echo "deps-dom: $pass passed, $fail failed"
(( fail == 0 ))
