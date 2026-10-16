#!/usr/bin/env bash
# Tools that are missing, installed where they are noticed.
#
# There was a Dependencies page; setup now installs what is missing in place,
# so the page was only ever a row of ticks. What survives it is the rule it was
# built on: never draw an Install button that cannot install anything. When the
# laptop has no installer the app can use, or no way to become root, the
# button says how to do it by hand instead - and runs nothing.
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
  run: (args) => { window.__ran.push(args.join(' '));
                   window.__lastId = (window.__lastId || 0) + 1;
                   return Promise.resolve({ ok: true, id: window.__lastId }); },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const sleep = () => new Promise(r => setTimeout(r, 0));
  const tool = (name, present) => ({
    tool: name, label: name === 'aws' ? 'AWS CLI v2' : name, present,
    why: name + ' is for something', plan: 'sudo pacman -S ' + name,
    manual: 'sudo pacman -S ' + name + ' (by hand)',
  });
  const payload = (missing, extra) => Object.assign({
    tools: ['aws', 'tailscale', 'moonlight', 'python3'].map(n => tool(n, !missing.includes(n))),
    package_manager: 'pacman', root: 'pkexec', root_blocked: null, tailscale_signed_in: true,
  }, extra || {});
  try {
    out.push('NAV | ' + !!document.querySelector('.nav-item[data-view="deps"]'));
    out.push('PAGE | ' + !!document.querySelector('section[data-view="deps"]'));

    // A tool missing on a laptop that can install: Install, through the run dialog.
    paintDeps(payload(['moonlight']));
    let a = toolAction(['moonlight']);
    out.push('CAN LABEL | ' + a.label);
    window.__ran = [];
    a.go();
    await sleep();
    out.push('CAN RAN | ' + window.__ran.join(' ;; '));
    out.push('CAN DIALOG | ' + document.getElementById('rundlg').open + ' ' + document.getElementById('rundlg-title').textContent);
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await sleep(); await sleep();
    document.getElementById('rundlg').close();

    // No way to become root: no Install - the command, and nothing run.
    paintDeps(payload(['moonlight'], { root: null, root_blocked: 'no terminal, and polkit is not installed' }));
    a = toolAction(['moonlight']);
    out.push('NOROOT LABEL | ' + a.label);
    window.__ran = [];
    let asked = null;
    window.askConfirm = async o => { asked = o; return true; };
    a.go();
    await sleep();
    out.push('NOROOT RAN | ' + window.__ran.join(' ;; '));
    out.push('NOROOT SAYS | ' + (asked ? asked.title + ' :: ' + asked.body.replace(/\n/g, ' ') + ' :: no=' + asked.no : 'nothing'));

    // No package manager: the same.
    paintDeps(payload(['aws'], { package_manager: null }));
    a = toolAction(['aws']);
    out.push('NOPM LABEL | ' + a.label);
    asked = null; a.go(); await sleep();
    out.push('NOPM SAYS | ' + (asked ? asked.body.replace(/\n/g, ' ') : 'nothing'));

    // Not read yet: offer it; cg says so if it cannot.
    depsNow = null;
    out.push('UNREAD LABEL | ' + toolAction(['aws']).label);

    // The setup step for missing tools carries the same button.
    paintDeps(payload(['moonlight']));
    const step = prereqs().find(r => r.key === 'tools');
    out.push('STEP | ' + step.problem.label);

    // A region not switched on is not a tool: it is a place to pick.
    out.push('OPTIN | ' + FAIL_ACTS.OptInRequired().map(x => x[0]).join(','));
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

# Written to a file and then catted, rather than piped straight into python:
# chromium's main process exits as soon as the DOM is dumped, but a child of
# it keeps the write end of a pipe open for another 10-25 SECONDS, and
# sys.stdin.read() waits for EOF. That idle wait, once per page load, was the
# whole cost of this suite - minutes of it, at 0.5s of actual work per load.
OUT=$("$BROWSER" --headless --disable-gpu --no-sandbox --window-size=1280,900 \
      --virtual-time-budget=5000 --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
    cat "$T/dom.html" \
  | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")')
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "deps-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. no page"
check    "no Dependencies tab"          "$(row NAV)"  "NAV | false"
check    "  and no page"                "$(row PAGE)" "PAGE | false"

echo "2. a laptop that can install: Install, here"
check    "the button names the tool"    "$(row 'CAN LABEL')" "CAN LABEL | Install moonlight"
check    "  pressed, it installs that one" "$(row 'CAN RAN')" "CAN RAN | deps install moonlight"
contains "  in the run dialog"          "$(row 'CAN DIALOG')" "true Installing moonlight"

echo "3. a laptop that cannot: the command, and nothing run"
check    "no Install when it cannot become root" "$(row 'NOROOT LABEL')" "NOROOT LABEL | How to install moonlight"
check    "  pressed, it runs nothing"   "$(row 'NOROOT RAN')" "NOROOT RAN | "
contains "  it says why"                "$(row 'NOROOT SAYS')" "cannot get permission to install here (no terminal, and polkit is not installed)"
contains "  and the command to run"     "$(row 'NOROOT SAYS')" "sudo pacman -S moonlight (by hand)"
contains "  with nothing to cancel"     "$(row 'NOROOT SAYS')" "no=null"
check    "no package manager: the same" "$(row 'NOPM LABEL')" "NOPM LABEL | How to install AWS CLI v2"
contains "  and says so"                "$(row 'NOPM SAYS')" "no installer the app can use"
check    "not read yet: offered"        "$(row 'UNREAD LABEL')" "UNREAD LABEL | Install the Amazon tool"

echo "4. the places that sent you to the page"
check    "setup's missing-tools step installs" "$(row STEP)" "STEP | Install moonlight"
check    "a region not switched on picks another" "$(row OPTIN)" "OPTIN | Choose another location"

echo "5. nothing threw"
check "no painter threw"                "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors" "$(row ERRS)" "ERRS | "

echo ""
echo "deps-dom: $pass passed, $fail failed"
(( fail == 0 ))
