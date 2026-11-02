#!/usr/bin/env bash
# Add disk, on the Machine page: how much room there is, what adding does (make
# the disk bigger while the game runs, or move the games onto a new disk and
# close Steam), what it costs an hour, and the one command it runs. cg says which
# of the two it is (cg disk --json); the window only asks how much.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "disk-dom: 0 passed, 0 failed"; exit 0; }

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
                   // cg disk add changes the machine, so it runs alone.
                   return Promise.resolve({ ok: true, id: window.__lastId, write: args[0] === 'disk' && args[1] === 'add' }); },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const sleep = (ms = 0) => new Promise(r => setTimeout(r, ms));
  const status = o => Object.assign({ running: true, disk_gb: 100, total_gb: 100, used_gb: 86, free_gb: 14,
                                      max_add_gb: 900, step_gb: 10, move: false }, o);
  // The id of the last command the window started: answered with its output.
  const answer = async (st) => {
    const id = window.__lastId;
    window.__emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(st) });
    window.__emit(id, { t: 'exit', rc: 0 });
    await sleep(50);
  };
  const text = id => document.getElementById(id).textContent.replace(/\s+/g, ' ').trim();
  const radios = () => [...document.querySelectorAll('#diskdlg-sizes input[type=radio]')];
  try {
    await sleep(300);
    // A disk that is there is made bigger: the game keeps running.
    openAddDisk();
    await sleep(50);
    out.push('ASKED | ' + window.__ran[window.__ran.length - 1]);
    out.push('LOOKING | ' + text('diskdlg-now') + ' | yes disabled=' + document.getElementById('diskdlg-yes').disabled);
    await answer(status({}));
    out.push('GROW | ' + text('diskdlg-now'));
    out.push('GROW SIZES | ' + radios().map(r => r.value + (r.checked ? '*' : '')).join(','));
    out.push('GROW WARN | ' + text('diskdlg-warn'));
    out.push('GROW YES | ' + text('diskdlg-yes') + ' disabled=' + document.getElementById('diskdlg-yes').disabled);
    // A size of your own is rounded up to the step.
    const other = document.querySelector('#diskdlg-sizes input[type=number]');
    other.value = '33'; other.dispatchEvent(new Event('input'));
    out.push('OTHER | ' + text('diskdlg-yes') + ' radios checked=' + radios().filter(r => r.checked).length);
    other.value = '901'; other.dispatchEvent(new Event('input'));
    out.push('TOO MUCH | disabled=' + document.getElementById('diskdlg-yes').disabled);
    radios()[0].click();
    out.push('PICKED 50 | ' + text('diskdlg-yes'));
    // Adding runs the one command, with the size.
    document.getElementById('diskdlg-yes').click();
    await sleep(50);
    out.push('RAN | ' + window.__ran[window.__ran.length - 1]);
    out.push('POPUP | ' + text('refdlg-title'));
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await sleep(100);
    out.push('DONE | refdlg open=' + document.getElementById('refdlg').open);
    document.getElementById('diskdlg').close();

    // A machine on its own drive: the games are moved, and Steam closes.
    openAddDisk();
    await sleep(50);
    await answer(status({ disk_gb: 0, total_gb: 232, used_gb: 186, free_gb: 46, max_add_gb: 1000, move: true }));
    out.push('MOVE | ' + text('diskdlg-now'));
    out.push('MOVE WARN | ' + text('diskdlg-warn'));
    document.getElementById('diskdlg').close();

    // Not running: nothing to add to.
    openAddDisk();
    await sleep(50);
    await answer(status({ running: false }));
    out.push('STOPPED | ' + text('diskdlg-now') + ' | yes disabled=' + document.getElementById('diskdlg-yes').disabled);
    document.getElementById('diskdlg').close();

    // As much as it can hold already.
    openAddDisk();
    await sleep(50);
    await answer(status({ disk_gb: 1000, max_add_gb: 0 }));
    out.push('FULL | ' + text('diskdlg-warn') + ' | yes disabled=' + document.getElementById('diskdlg-yes').disabled);
    document.getElementById('diskdlg').close();

    // The button is on the Machine page.
    out.push('BUTTON | ' + (document.getElementById('b-adddisk') ? document.getElementById('b-adddisk').textContent.trim() : 'none'));
  } catch (e) { out.push('THREW | ' + e.message + ' ' + e.stack); }
  out.push('ERRS | ' + ((window.__errs || []).join(' ;; ') || 'none'));
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

"$BROWSER" --headless --disable-gpu --no-sandbox --lang=en-IN --window-size=1280,900 \
  --virtual-time-budget=8000 --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
OUT=$(cat "$T/dom.html" | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")')
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "disk-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. asking cg, not guessing"
check    "it reads the disk first"        "$(row ASKED)" "ASKED | disk --json"
contains "  and waits, with nothing to press" "$(row LOOKING)" "yes disabled=true"

echo "2. a disk that is there grows"
contains "it says how full the space is"  "$(row GROW)" "Game space: 86 of 100 GB used, 14 GB free."
check    "  offers sizes, 100 chosen"      "$(row 'GROW SIZES')" "GROW SIZES | 50,100*,200,500"
contains "  the game keeps running"        "$(row 'GROW WARN')" "Your game keeps running"
contains "  and says the disk goes with the machine" "$(row 'GROW WARN')" "The disk is deleted with the machine."
contains "  and says AWS's once-in-six-hours rule" "$(row 'GROW WARN')" "once every 6 hours"
check    "  the button says how much"      "$(row 'GROW YES')" "GROW YES | Add 100 GB disabled=false"
check    "a size of your own is rounded up to 10 GB" "$(row OTHER)" "OTHER | Add 40 GB radios checked=0"
check    "  more than it can hold is refused" "$(row 'TOO MUCH')" "TOO MUCH | disabled=true"
check    "  picking a size again works"    "$(row 'PICKED 50')" "PICKED 50 | Add 50 GB"

echo "3. adding"
check    "it runs one command, with the size" "$(row RAN)" "RAN | disk add 50"
contains "  under its own heading"         "$(row POPUP)" "Adding space"
check    "  and the popup goes when it is done" "$(row DONE)" "DONE | refdlg open=false"

echo "4. a machine on its own drive moves the games"
contains "it says how much room"          "$(row MOVE)" "46 GB free"
contains "  and that Steam closes"         "$(row 'MOVE WARN')" "Steam closes while that happens"
lacks    "  without the six-hour rule that does not apply" "$(row 'MOVE WARN')" "once every 6 hours"

echo "5. what it will not do"
contains "a stopped machine cannot be changed" "$(row STOPPED)" "is not running"
contains "  and offers nothing"            "$(row STOPPED)" "yes disabled=true"
contains "the most it can hold is said"   "$(row FULL)" "already has the most game space"

echo "6. where it lives"
check    "the Machine page has the button" "$(row BUTTON)" "BUTTON | Add disk"
check    "nothing threw"                  "$(grep -c '^THREW' <<<"$OUT")" "0"
check    "  and nothing went wrong in the page" "$(row ERRS)" "ERRS | none"

echo "disk-dom: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
