#!/usr/bin/env bash
# The Logs page: a fetch says it is fetching where it was asked, and the
# watchdog's log reads as what it decided, not forty copies of "nothing to do".
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "logs-dom: 0 passed, 0 failed"; exit 0; }

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
  try {
    document.querySelector('.nav-item[data-view="logs"]').click();
    await sleep();
    out.push('FILTERS | ' + [...document.querySelectorAll('[data-filter]')]
      .map(b => (b.classList.contains('btn-primary') ? '*' : '') + b.textContent.trim()).join(','));
    window.__ran = [];
    document.getElementById('log-cloud').click();
    await sleep();
    out.push('FETCHING | label=' + document.getElementById('log-cloud-label').textContent
      + ' disabled=' + document.getElementById('log-cloud').disabled
      + ' stop=' + !document.getElementById('cancel').hidden + ' ran=' + window.__ran.join(';'));
    const lines = [];
    for (let h = 14; h <= 16; h++) for (let m = 2; m < 60; m += 5) {
      lines.push(`2026-10-16T${h}:${String(m).padStart(2, '0')}:12 cg-watchdog: no running instance tagged gamevps - nothing to do`);
      if (m === 2 && h > 14) lines.push(`2026-10-16T${h}:02:12 cg-watchdog: archive: kept - last used ${h - 10}h ago; deleted in 6d ${26 - h}h unless a box is launched`);
    }
    window.__emit(window.__lastId, { t: 'raw', stream: 'stdout', text: lines.join('\n') });
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await sleep(); await sleep();
    out.push('FETCHED | label=' + document.getElementById('log-cloud-label').textContent
      + ' disabled=' + document.getElementById('log-cloud').disabled);
    out.push('DIGEST | ' + document.getElementById('log-cloud-out').textContent.replace(/\n/g, ' // '));
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
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "logs-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. the event stream's filters"
check    "three, with All chosen from the start" "$(row FILTERS)" "FILTERS | *All,Steps,Problems"

echo "2. Fetch says it is fetching, on itself"
contains "the button says so"            "$(row FETCHING)" "label=Loading… disabled=true"
contains "  and no Stop appears top right" "$(row FETCHING)" "stop=false"
contains "  it reads the watchdog's log" "$(row FETCHING)" "ran=watchdog logs"
contains "and is back when done"         "$(row FETCHED)"  "label=Load disabled=false"

echo "3. the log reads as what was decided"
contains "the 5-minute checks are one line" "$(row DIGEST)" "no running instance tagged gamevps - nothing to do  (36 checks)"
check    "  said once"                   "$(row DIGEST | grep -o 'nothing to do' | wc -l)" "1"
contains "the hourly decisions are kept" "$(row DIGEST)" "archive: kept - last used 5h ago"
contains "  each of them"                "$(row DIGEST)" "archive: kept - last used 6h ago"
lacks    "no UTC stamps left"            "$(row DIGEST)" "2026-10-16T"

echo "4. nothing threw"
check "no painter threw"                 "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors"  "$(row ERRS)" "ERRS | "

echo ""
echo "logs-dom: $pass passed, $fail failed"
(( fail == 0 ))
