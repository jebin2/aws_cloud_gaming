#!/usr/bin/env bash
# On your game PC, on the Games page: what the machine has and how far each
# download has got, read from the machine itself (cg games --json --box), every
# 15 s while something downloads. Not there with no machine; a read that fails
# keeps the last answer and says so.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "games-progress-dom: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/"
cp app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
window.__ran = [];
window.__timers = [];
const __st = window.setTimeout;
window.setTimeout = (f, ms, ...a) => { if (ms >= 15000) window.__timers.push(ms); return __st(f, ms, ...a); };
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
  const text = id => document.getElementById(id).textContent.replace(/\s+/g, ' ').trim();
  const GB = 1073741824;
  const answer = async (st, rc = 0) => {
    const id = window.__lastId;
    if (st) window.__emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(st) });
    window.__emit(id, { t: 'exit', rc });
    await sleep(80);
  };
  const downloading = o => Object.assign({
    games: [
      { appid: '1', name: 'Red Dead Redemption 2', state: 'downloading', bytes: 76 * GB, percent: 38,
        minutes_left: 125, total_bytes: 200 * GB, left_bytes: 124 * GB },
      { appid: '2', name: 'Hades', state: 'installed', bytes: 14 * GB },
      { appid: '1493710', name: 'Proton Experimental', state: 'downloading', bytes: GB, percent: 40, total_bytes: GB, left_bytes: 0 },
      { appid: '228980', name: 'Steamworks Common Redistributables', state: 'downloading', bytes: 0 },
    ],
    disk: { used_bytes: 112 * GB, free_bytes: 48 * GB }, inbound_bytes_per_sec: 14e6 }, o);
  const card = () => document.getElementById('lib-pc');
  try {
    await sleep(300);
    // No machine: no card.
    view = 'library'; boxNow = null;
    boxGamesStart();
    out.push('NO BOX | hidden=' + card().hidden);
    // A machine that is not running: said, and nothing asked of it.
    boxNow = { state: 'stopped' };
    const before = window.__ran.length;
    boxGamesStart();
    out.push('STOPPED | ' + text('lib-pc-note') + ' | asked=' + (window.__ran.length - before));
    // Running: it asks the machine alone, not S3.
    boxNow = { state: 'running' };
    boxGamesStart();
    await sleep(50);
    out.push('ASKED | ' + window.__ran[window.__ran.length - 1]);
    out.push('READING | ' + text('lib-pc-note'));
    await answer(downloading({}));
    out.push('ROWS | ' + [...document.querySelectorAll('#lib-pc-rows > div')].map(r => [...r.querySelectorAll('span')].map(s => s.textContent).join(' ')).join(' || '));
    out.push('TOOLS | ' + text('lib-pc-rows'));
    out.push('BAR | ' + document.querySelector('#lib-pc-rows .bg-primary').style.width);
    out.push('SPACE | ' + text('lib-pc-space'));
    out.push('NEED | hidden=' + document.getElementById('lib-pc-need').hidden + ' | ' + text('lib-pc-need-text'));
    out.push('AGE | ' + text('lib-pc-age'));
    out.push('BEAT DOWNLOADING | ' + window.__timers.join(','));
    // Add disk from here is the same window as the Machine page's.
    document.getElementById('lib-pc-adddisk').click();
    await sleep(50);
    out.push('ADD DISK | ' + window.__ran[window.__ran.length - 1]);
    document.getElementById('diskdlg').close();

    // The room is enough: no warning. Nothing downloading: the slow beat.
    window.__timers.length = 0;
    clearTimeout(pcTimer); pcTimer = null;
    boxGamesStart();
    await sleep(50);
    await answer({ games: [{ appid: '2', name: 'Hades', state: 'installed', bytes: 14 * GB }],
                   disk: { used_bytes: 20 * GB, free_bytes: 140 * GB }, inbound_bytes_per_sec: 0 });
    out.push('IDLE | need hidden=' + document.getElementById('lib-pc-need').hidden + ' | ' + [...document.querySelectorAll('#lib-pc-rows span')].map(s => s.textContent).join(' ') + ' | beat=' + window.__timers.join(','));

    // A read that fails keeps the last answer, and says so.
    clearTimeout(pcTimer); pcTimer = null;
    boxGamesStart();
    await sleep(50);
    await answer(null, 1);
    out.push('FAILED | ' + text('lib-pc-note') + ' | still shows ' + document.querySelector('#lib-pc-rows span').textContent.slice(0, 5));

    // Leaving the page stops it.
    document.querySelector('.nav-item[data-view="dashboard"]').click();
    out.push('LEFT | timer=' + (pcTimer === null ? 'none' : 'running'));
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

echo "1. no machine, a stopped one, a running one"
check    "no machine: no card"            "$(row 'NO BOX')" "NO BOX | hidden=true"
contains "a stopped machine is said"      "$(row STOPPED)" "Your game PC is not running"
contains "  and nothing is asked of it"    "$(row STOPPED)" "asked=0"
check    "a running one is asked alone, not S3" "$(row ASKED)" "ASKED | games --json --box"
contains "  and the card says it is reading" "$(row READING)" "Reading your game PC"

echo "2. a download in progress"
contains "the game and its state"         "$(row ROWS)" "Red Dead Redemption 2 downloading"
contains "  how far, how much, how fast, how long" "$(row ROWS)" "38% · 76 GB of 200 GB · 14 MB/s · about 2 h 5 min left"
check    "  the bar is that full"          "$(row BAR)" "BAR | 38%"
check    "Steam's own tools are not rows of their own" "$(grep -c 'Proton Experimental' <<<"$(row ROWS)")" "0"
contains "  one quiet line says they are being fetched" "$(row TOOLS)" "Steam is also fetching its own tools"
contains "the games that are done are listed too" "$(row ROWS)" "Hades installed 14 GB"
contains "the room is said"               "$(row SPACE)" "Space: 112 GB used · 48 GB free"
contains "more than there is free says so" "$(row NEED)" "hidden=false | The downloads need 124 GB more and 48 GB is free."
contains "it says when the answer was given" "$(row AGE)" "AGE | updated "
check    "it asks again in 15 s"          "$(row 'BEAT DOWNLOADING')" "BEAT DOWNLOADING | 15000"
check    "Add disk opens the disk window" "$(row 'ADD DISK')" "ADD DISK | disk --json"

echo "3. nothing downloading, a read that fails, leaving"
check    "enough room: no warning, and the slow beat" "$(row IDLE)" "IDLE | need hidden=true | Hades installed 14 GB | beat=60000"
contains "a failed read says so"          "$(row FAILED)" "Could not read your game PC just now"
contains "  and keeps the last answer"     "$(row FAILED)" "still shows Hades"
check    "leaving the page stops it"      "$(row LEFT)" "LEFT | timer=none"

echo "4. where it lives"
check    "nothing threw"                  "$(grep -c '^THREW' <<<"$OUT")" "0"
check    "  and nothing went wrong in the page" "$(row ERRS)" "ERRS | none"
check    "games read beside a session"    "$(grep -c "\['games'\]" app/main/index.js)" "1"

echo "games-progress-dom: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
