#!/usr/bin/env bash
# The Guards page: what stops the machine, in plain words and rupees.
#
# It used to read "tier 2", "armed", "dies with: a deleted schedule" and
# "$57 a month", and wrote "30 min" and "1 h" whatever the watchdog was set to.
# Everything here is fed the way `cg watcher --json` and `cg config --json`
# answer, and read back as the person sees it.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "guards-dom: 0 passed, 0 failed"; exit 0; }

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
  const text = id => document.getElementById(id).innerText.replace(/\s+/g, ' ').trim();
  const read = label => {
    out.push(label + ' HEAD | ' + text('g-head'));
    out.push(label + ' SUB | ' + text('g-sub'));
    out.push(label + ' WARN | ' + (document.getElementById('g-warn').hidden ? 'hidden' : text('g-warn')));
    [...document.getElementById('g-nets').children].forEach((r, i) =>
      out.push(label + ' NET' + (i + 1) + ' | ' + r.innerText.replace(/\s+/g, ' ').trim()));
    out.push(label + ' KNOBS | ' + text('g-knobs'));
    out.push(label + ' PAGE | ' + document.querySelector('section[data-view=guards]').innerText.replace(/\s+/g, ' '));
  };
  const net = (layer, extra) => Object.assign({ layer, name: 'x', catches: 'x', dies_with: 'x', reaction: 'x' }, extra);
  const W = (state, g2, g3, extra) => Object.assign({
    instance_state: state,
    guards: [net(1, { armed: null, state: 'always on' }), net(2, Object.assign({ idle_min: 15 }, g2)),
             net(3, Object.assign({ idle_min: 45, stuck_min: 90 }, g3))],
    shutdown_action: { value: null, expected: null, ok: false },
    budget: { usd: 57, alerts: 1 }, archive: 'archive line' }, extra);
  const tick = () => new Promise(r => setTimeout(r, 0));
  try {
    // On the Guards page, as a person would be: a save there goes back through
    // this page's own reads.
    goView('guards');
    await tick();
    const CFG = idle => [
      { key: 'GAME_BUDGET_INR', kind: 'number', secret: false, is_set: true, value: '5000', default: '5000',
        note: 'Monthly budget. It emails you; it stops nothing.', label: 'monthly budget (INR)', group: 'The guards' },
      { key: 'GAME_WATCHDOG_IDLE_MIN', kind: 'number', secret: false, is_set: true, value: idle, default: '30',
        note: 'n', label: 'cloud watchdog idle (min)', group: 'The guards' },
      // A laptop that plays on AWS: a region chosen is what makes it one.
      { key: 'GAME_REGION', kind: 'region', secret: false, is_set: true, value: 'ap-south-2', default: 'ap-south-2', effective: 'ap-south-2', note: 'n', label: 'region', group: 'The box' }];
    window.__CFG = CFG;
    paintConfig([
      { key: 'GAME_BUDGET_INR', kind: 'number', secret: false, is_set: true, value: '5000', default: '5000',
        note: 'Monthly budget. It emails you; it stops nothing.', label: 'monthly budget (INR)', group: 'The guards' },
      { key: 'GAME_WATCHDOG_IDLE_MIN', kind: 'number', secret: false, is_set: true, value: '45', default: '30',
        note: 'n', label: 'cloud watchdog idle (min)', group: 'The guards' },
      { key: 'GAME_NTFY_URL', kind: 'ntfy', secret: false, is_set: true, value: 'my-topic-q7', default: null,
        note: 'n', label: 'phone notifications', group: 'Notifications' },
      { key: 'GAME_WATCHDOG_STUCK_MIN', kind: 'number', secret: false, is_set: false, value: null, default: '60',
        note: 'n', label: 'stuck shutdown forced after (min)', group: 'The guards' },
      { key: 'GAME_REGION', kind: 'region', secret: false, is_set: true, value: 'ap-south-2', default: 'ap-south-2', effective: 'ap-south-2', note: 'n', label: 'region', group: 'The box' },
    ]);
    paintGuards(W('none', { armed: null, state: 'no box' },
                  { armed: true, state: 'armed', last_decision: 'nothing running - nothing to do', last_decision_age_s: 1500 }));
    read('IDLE');
    // Edit then Cancel changes nothing, so it reads nothing: it used to call
    // refresh(), and the Refresh popup came up over a row nobody changed.
    const knob = () => document.getElementById('g-knobs').children[0];
    const before = knob().innerText;
    window.__ran = [];
    knob().querySelector('button').click();
    out.push('EDITING | ' + !!knob().querySelector('input'));
    [...knob().querySelectorAll('button')].find(b => b.textContent === 'Cancel').click();
    await new Promise(r => setTimeout(r, 0));
    out.push('CANCEL RAN | ' + window.__ran.length);
    out.push('CANCEL ROW | ' + (knob().innerText === before) + ' ' + knob().classList.contains('editing'));
    out.push('CANCEL POPUP | ' + document.getElementById('refdlg').open);
    knob().querySelector('button').click();
    knob().querySelector('input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    out.push('ESC ROW | ' + (knob().innerText === before) + ' ' + window.__ran.length);

    const ntfyRow = [...document.getElementById('g-knobs').children]
      .find(r => r.innerText.includes('Phone alerts'));
    ntfyRow.querySelector('button').click();
    const ni = ntfyRow.querySelector('input');
    out.push('NTFY EDIT | ' + ni.type + ' ' + ni.value);
    [...ntfyRow.querySelectorAll('button')].find(b => b.textContent === 'Cancel').click();

    // Save: a refusal stays on the row with cg's words; a good value comes back
    // as the new value, read again from cg - not the old one left showing.
    const idleRow = () => [...document.getElementById('g-knobs').children]
      .find(r => r.innerText.includes('Stop after idle'));
    window.__ran = [];
    idleRow().querySelector('button').click();
    idleRow().querySelector('input').value = '5';
    idleRow().querySelector('.btn-primary').click();
    await tick();
    out.push('SAVE RAN | ' + window.__ran.join(' ;; '));
    const bad = window.__lastId;
    window.__emit(bad, { t: 'line', text: 'GAME_WATCHDOG_IDLE_MIN must be at least 10' });
    window.__emit(bad, { t: 'exit', rc: 1 });
    await tick(); await tick();
    const rep = idleRow().querySelector('.edit-reply');
    out.push('REFUSED | editing=' + !!idleRow().querySelector('input')
             + ' reply=' + (rep ? rep.textContent.trim() : 'none')
             + ' reads=' + (window.__ran.length - 1) + ' save=' + !idleRow().querySelector('.btn-primary').disabled);
    window.__ran = [];
    idleRow().querySelector('input').value = '50';
    idleRow().querySelector('input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await tick();
    const good = window.__lastId;
    window.__emit(good, { t: 'exit', rc: 0 });
    await tick(); await tick();
    out.push('SAVED RAN | ' + window.__ran.join(' ;; '));
    for (let id = good + 1; id <= window.__lastId; id++) {
      const cmd = window.__ran[id - good];
      const data = cmd === 'config --json' ? window.__CFG('50')
        : { instance_state: 'none', guards: [], budget: { usd: 57 }, shutdown_action: {} };
      window.__emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(data) });
      window.__emit(id, { t: 'exit', rc: 0 });
    }
    await tick(); await tick();
    out.push('SAVED ROW | ' + (idleRow() ? idleRow().innerText.replace(/\s+/g, ' ').trim() : 'gone')
             + ' editing=' + !!(idleRow() && idleRow().querySelector('input')));
    paintGuards(W('running', { armed: false, state: 'not armed' }, { armed: false, state: 'disabled' },
                  { shutdown_action: { value: 'stop', expected: 'terminate', ok: false }, budget: { usd: null, alerts: 0 } }));
    read('BAD');
    paintGuards(W('running', { armed: true, state: 'armed' }, { armed: true, state: 'armed' },
                  { shutdown_action: { value: 'terminate', expected: 'terminate', ok: true } }));
    read('GOOD');
    // Fresh AWS, nothing built: every build sets both up before it launches.
    paintGuards(W('none', { armed: null, state: 'no box' }, { armed: false, state: 'not installed' },
                  { budget: { usd: null, alerts: 0 } }));
    read('FRESH');
    // The machine page's "What is working", the same two, both ways.
    const checks = () => [...document.querySelectorAll('#b-checks [data-check]')]
      .filter(r => /Auto-stop in AWS|Budget alert/.test(r.dataset.check))
      .map(r => r.dataset.check + '=' + r.dataset.ok + ':' + r.lastChild.textContent).join(', ');
    statusNow = { box: null, budget: {} };
    paintAwsChecks();
    out.push('CHECKS FRESH | ' + checks());
    statusNow = { box: { state: 'running' }, budget: {}, tailnet: {} };
    watcher = W('running', { armed: true, state: 'armed' }, { armed: false, state: 'disabled' }, { budget: { usd: null } });
    paintAwsChecks();
    out.push('CHECKS BOXED | ' + checks());
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
t = t.replace('</body>', '<script>document.querySelectorAll("section[data-view]").forEach(s => s.hidden = s.dataset.view !== "guards")</script>\n<script src="probe.js"></script>\n</body>', 1)
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
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "guards-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. no machine: nothing to stop, and the nets say why they wait"
contains "the headline says so"          "$(row 'IDLE HEAD')" "No machine running"
contains "the last AWS check, aged"      "$(row 'IDLE SUB')"  'Last check 25m ago: idle.'
contains "nothing to warn about"         "$(row 'IDLE WARN')" "hidden"
contains "net 1 is the quit"             "$(row 'IDLE NET1')" "When you quit Closing Moonlight ends the session."
contains "  always on"                   "$(row 'IDLE NET1')" "Always on"
contains "net 2 waits for a machine"     "$(row 'IDLE NET2')" "Waits for a machine"
contains "  naming which machine"         "$(row 'IDLE NET2')" "On the AWS machine"
contains "  with its own minutes"        "$(row 'IDLE NET2')" "Shuts down after 15 min with no connection"
contains "net 3 has the minutes as set"  "$(row 'IDLE NET3')" "ends the machine after 45 min without a stream, or a shutdown stuck for 90 min"
contains "  and it is on"                "$(row 'IDLE NET3')" "On"
lacks    "  no 1 h left over"            "$(row 'IDLE NET3')" "1 h"

echo "2. the settings, in rupees and minutes"
contains "the budget in rupees"          "$(row 'IDLE KNOBS')" "₹5,000 a month"
contains "a minute setting in minutes"   "$(row 'IDLE KNOBS')" "45 min"
contains "  and an unset one says it is the default" "$(row 'IDLE KNOBS')" "60 min (default)"

# The topic is shown, like every other row's value, and Edit opens on it.
contains "phone notifications show the topic" "$(row 'IDLE KNOBS')" "Phone alerts ntfy topic. Empty disables phone alerts. my-topic-q7 Edit"
lacks    "  not 'set'"                   "$(row 'IDLE KNOBS')" "alerts off. Set"
lacks    "  nor Replace"                 "$(row 'IDLE KNOBS')" "Replace"
check    "  and Edit opens on it"        "$(row 'NTFY EDIT')" "NTFY EDIT | text my-topic-q7"

echo "2b. Edit then Cancel reads nothing"
contains "Edit opens the field"          "$(row EDITING)" "true"
check    "Cancel runs nothing"           "$(row 'CANCEL RAN')" "CANCEL RAN | 0"
check    "  puts the row back as it was" "$(row 'CANCEL ROW')" "CANCEL ROW | true false"
check    "  with no Refresh popup"       "$(row 'CANCEL POPUP')" "CANCEL POPUP | false"
check    "Esc does the same"             "$(row 'ESC ROW')" "ESC ROW | true 0"

echo "2c. Save on this page"
check    "Save runs cg config set"       "$(row 'SAVE RAN')" "SAVE RAN | config set GAME_WATCHDOG_IDLE_MIN 5"
contains "a refusal keeps the row open"  "$(row REFUSED)" "editing=true"
contains "  with cg's words under it"    "$(row REFUSED)" "reply=GAME_WATCHDOG_IDLE_MIN must be at least 10"
contains "  reads nothing"               "$(row REFUSED)" "reads=0"
contains "  and Save works again"        "$(row REFUSED)" "save=true"
contains "Enter saves"                   "$(row 'SAVED RAN')" "config set GAME_WATCHDOG_IDLE_MIN 50"
contains "  then the settings are read again" "$(row 'SAVED RAN')" "config --json"
contains "  and the new value shows"     "$(row 'SAVED ROW')" "50 min"
contains "  with the field closed"       "$(row 'SAVED ROW')" "editing=false"

echo "3. none of the old words"
for w in tier armed ARMED '$' 'dies with' 'box' 'audit' 'archive line' 'shutdown action'; do
  lacks "no '$w'" "$(row 'IDLE PAGE')" "$w"
done

echo "4. a running machine with things wrong says each one, in red, on top"
contains "a count, not all"              "$(row 'BAD HEAD')" "Machine running · 1 of 3 safeguards on"
contains "the AWS check is off"          "$(row 'BAD WARN')" "AWS auto-stop is disabled"
contains "the machine's check is off"    "$(row 'BAD WARN')" "The machine's own check is off"
contains "the wrong shutdown"            "$(row 'BAD WARN')" "Shutdown behavior is "stop"; expected "delete"."
contains "no spending alert"             "$(row 'BAD WARN')" "No budget alert set in AWS"
check    "nothing built yet: no red banner" "$(row 'FRESH WARN')" "FRESH WARN | hidden"
contains "  AWS auto-stop turns on when you build" "$(row 'FRESH NET3')" "Turns on when you build"
lacks    "  never Off"                    "$(row 'FRESH NET3')" "Off"
check    "the machine page: not yet, not a cross" "$(row 'CHECKS FRESH')" "CHECKS FRESH | Auto-stop in AWS=later:turns on when you build, Budget alert=later:set when you build"
check    "  with a machine, missing is a fault"  "$(row 'CHECKS BOXED')" "CHECKS BOXED | Auto-stop in AWS=no:off, Budget alert=no:not set"
contains "net 2 off"                     "$(row 'BAD NET2')" "Off"
contains "net 3 off"                     "$(row 'BAD NET3')" "Off"

echo "5. a running machine with everything on"
contains "all of them"                   "$(row 'GOOD HEAD')" "Machine running · all 3 safeguards on"
contains "  no warnings"                 "$(row 'GOOD WARN')" "hidden"
contains "a spot machine is deleted"     "$(row 'GOOD NET2')" "Then deleted."

echo "6. nothing threw"
check "no painter threw"                 "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors"  "$(row ERRS)" "ERRS | "

echo ""
echo "guards-dom: $pass passed, $fail failed"
(( fail == 0 ))
