#!/usr/bin/env bash
# A controller: the D-pad moves to what is nearest that way, A presses, B
# leaves a popup by its own way out or goes Home, LB/RB change page - and
# nothing at all while the window is not the one in focus, because the same
# controller is playing a game in Moonlight then.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "pad-dom: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/"
cp app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
addEventListener('error', e => window.__errs.push(e.message));
window.__ran = [];
window.cg = {
  run: (args) => { window.__ran.push(args.join(' '));
                   window.__lastId = (window.__lastId || 0) + 1;
                   return Promise.resolve({ ok: true, id: window.__lastId }); },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]), openSignIn: () => Promise.resolve(true),
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const sleep = ms => new Promise(r => setTimeout(r, ms || 0));
  // One controller, every button up.
  const pad = { buttons: Array.from({ length: 17 }, () => ({ pressed: false })), axes: [0, 0, 0, 0] };
  const B = { a: 0, b: 1, lb: 4, rb: 5, up: 12, down: 13, left: 14, right: 15 };
  let t = 1000;
  const frame = (ms = 16) => { t += ms; padTick([pad], t); };
  // Pressed for a frame, then let go.
  const tap = async name => { pad.buttons[B[name]].pressed = true; frame(); pad.buttons[B[name]].pressed = false; frame(); await sleep(); };
  const at = () => { const e = document.activeElement;
    return !e || e === document.body ? 'none' : (e.id || e.dataset.view || e.textContent.trim().slice(0, 24)); };
  const viewNow = () => document.querySelector('.nav-item.on').dataset.view;
  try {
    await sleep(300);
    // Every page, as on a laptop that plays on AWS - a fresh one shows three.
    document.querySelectorAll('.nav-item').forEach(n => { n.hidden = false; });
    // Away: the window is not in focus - Moonlight is.
    window.padHasFocus = () => false;
    await tap('rb'); await tap('a');
    out.push('AWAY | view=' + viewNow() + ' focus=' + at() + ' pad=' + document.body.classList.contains('pad'));
    // Back, with A still held from the game: not a press.
    window.padHasFocus = () => true;
    pad.buttons[B.a].pressed = true; frame(); frame(); pad.buttons[B.a].pressed = false; frame();
    out.push('BACK HELD | view=' + viewNow() + ' focus=' + at());
    // The first move lands on the page you are on.
    await tap('down');
    out.push('FIRST | focus=' + at() + ' pad=' + document.body.classList.contains('pad')
             + ' hints=' + getComputedStyle(document.getElementById('pad-hints')).display
             + ' b=' + document.getElementById('pad-b').textContent);
    await tap('right');
    out.push('RIGHT | focus=' + at());
    // Held: one move, then repeats only after a beat.
    pad.buttons[B.right].pressed = true; frame(); frame(100); const one = at(); frame(400); const two = at();
    pad.buttons[B.right].pressed = false; frame();
    out.push('HELD | ' + one + ' then ' + two);
    // RB and LB change page, and focus goes with them.
    document.querySelector('.nav-item[data-view=dashboard]').click(); padFocus(document.querySelector('.nav-item.on'));
    await tap('rb');
    out.push('RB | view=' + viewNow() + ' focus=' + at());
    await tap('lb');
    out.push('LB | view=' + viewNow() + ' focus=' + at());
    await tap('lb');
    out.push('LB FIRST | view=' + viewNow());
    // A presses what has focus.
    await tap('right'); await tap('a');
    out.push('A | view=' + viewNow());
    // B, with no popup: Home.
    await tap('b');
    out.push('B HOME | view=' + viewNow() + ' focus=' + at());
    // A popup is the whole screen; B leaves it by its own Cancel.
    // Not awaited: headless Chromium closes a dialog without firing its close
    // event. What it closed WITH is the answer: Cancel's value, "no".
    askConfirm({ title: 'Delete it?', body: 'x', yes: 'Delete', danger: true });
    await sleep(50);
    const seen = new Set();
    for (const d of ['down', 'right', 'right', 'left', 'up', 'down']) { await tap(d); seen.add(at()); }
    out.push('POPUP | inside=' + [...seen].every(id => document.getElementById('confirm').contains(document.getElementById(id) || document.body) && id !== 'none')
             + ' seen=' + [...seen].join(',') + ' b=' + document.getElementById('pad-b').textContent);
    await tap('b');
    out.push('POPUP B | answer=' + document.getElementById('confirm').returnValue + ' open=' + document.getElementById('confirm').open);
    // A popup whose way out is held while a step runs: B waits, as Close does.
    const add = document.getElementById('adddlg');
    add.showModal(); document.getElementById('adddlg-close').disabled = true;
    await tap('b');
    const held = add.open;
    document.getElementById('adddlg-close').disabled = false;
    await tap('b'); await sleep(300);
    out.push('HELD POPUP | stays=' + held + ' then=' + add.open);
    // Down is down: a neighbour level with it, however close, is sideways.
    // Placed by script: the page's policy refuses inline style attributes.
    const box = document.createElement('div');
    Object.assign(box.style, { position: 'relative', height: '300px' });
    for (const [id, left, top, h] of [['pa', 0, 0, 40], ['pb', 110, 4, 46], ['pc', 0, 200, 40]]) {
      const b = document.createElement('button');
      b.id = id; b.textContent = id;
      Object.assign(b.style, { position: 'absolute', left: left + 'px', top: top + 'px', width: '100px', height: h + 'px' });
      box.append(b);
    }
    document.querySelector('main').prepend(box);
    document.getElementById('pa').focus();
    await tap('down'); const downTo = at();
    document.getElementById('pa').focus();
    await tap('right'); const rightTo = at();
    out.push('DIRECTION | down=' + downTo + ' right=' + rightTo);
    box.remove();
    // A list steps through its choices sideways.
    const sel = document.createElement('select'); sel.id = 'probe-sel';
    for (const v of ['7', '14', '30']) sel.append(new Option(v, v));
    let changed = 0; sel.onchange = () => changed++;
    document.querySelector('main').prepend(sel); sel.focus();
    await tap('right'); await tap('right'); await tap('right');
    out.push('SELECT | value=' + sel.value + ' changes=' + changed);
    sel.remove();
  } catch (e) { out.push('THREW | ' + e.message + ' ' + e.stack); }
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
t = t.replace('</body>', '<script>document.querySelectorAll("section[data-view]").forEach(s => s.hidden = s.dataset.view !== "guards")</script>\n<script src="probe.js"></script>\n</body>', 1)
p.write_text(t)
PY

# Written to a file and then catted, rather than piped straight into python:
# chromium's main process exits as soon as the DOM is dumped, but a child of
# it keeps the write end of a pipe open for another 10-25 SECONDS, and
# sys.stdin.read() waits for EOF. That idle wait, once per page load, was the
# whole cost of this suite - minutes of it, at 0.5s of actual work per load.
OUT=$("$BROWSER" --headless --disable-gpu --no-sandbox --lang=en-IN --window-size=1280,900 \
      --virtual-time-budget=5000 --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
    cat "$T/dom.html" \
  | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")')
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "pad-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. nothing while the window is not in focus"
check    "Moonlight in focus: nothing pressed" "$(row AWAY)" "AWAY | view=dashboard focus=none pad=false"
check    "  and a button held from the game is not a press" "$(row 'BACK HELD')" "BACK HELD | view=dashboard focus=none"

echo "2. moving"
contains "the first move lands on this page's tab" "$(row FIRST)" "FIRST | focus=dashboard pad=true"
contains "  with the hints shown"         "$(row FIRST)" "hints=flex b=Home"
check    "right: the next tab"            "$(row RIGHT)" "RIGHT | focus=build"
check    "held: one move, a beat, then repeats" "$(row HELD)" "HELD | library then guards"

echo "3. pages, A and B"
check    "RB: the next page, focus with it" "$(row RB)" "RB | view=build focus=build"
check    "LB: back"                       "$(row LB)" "LB | view=dashboard focus=dashboard"
check    "  and not past the first"       "$(row 'LB FIRST')" "LB FIRST | view=dashboard"
check    "A presses what has focus"       "$(row A)" "A | view=build"
check    "B with no popup: Home"          "$(row 'B HOME')" "B HOME | view=dashboard focus=dashboard"

echo "4. popups"
contains "a popup is the whole screen"    "$(row POPUP)" "POPUP | inside=true"
contains "  B says it closes"             "$(row POPUP)" "b=Close"
check    "B leaves by its own Cancel"     "$(row 'POPUP B')" "POPUP B | answer=no open=false"
check    "a held popup holds: B waits, as Close does" "$(row 'HELD POPUP')" "HELD POPUP | stays=true then=false"

check    "down skips a level neighbour; right takes it" "$(row DIRECTION)" "DIRECTION | down=pc right=pb"

echo "5. a list"
check    "sideways steps its choices, and stops at the end" "$(row SELECT)" "SELECT | value=30 changes=2"

echo "6. nothing threw"
check "no painter threw"                 "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors"  "$(row ERRS)" "ERRS | "

echo ""
echo "pad-dom: $pass passed, $fail failed"
(( fail == 0 ))
