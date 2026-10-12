#!/usr/bin/env bash
# The quota button, from the click to the command.
#
# It opened the dialog, showed the appeal, and filed nothing - because
# `cg quota request` was not in the main process's read-only list, which makes
# it a mutating command, and a mutating command is refused outright while any
# read is in flight. On the screen that offers the button, a read is always in
# flight. The dialog then overwrote the refusal with the appeal, so the whole
# thing read as "here is some text, go and do it yourself".
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

echo "1. the scheduler lets the ask through"
# Both halves in one place, because they have to agree: the renderer decides
# what counts as a write for its own bookkeeping, the main process decides
# whether it may run at all.
# The rule itself, run rather than grepped: the list decides whether a command
# may start while something else is in flight, and getting it wrong is silent -
# the ask was refused before it reached AWS, every time.
sched=$(node -e '
const src = require("node:fs").readFileSync("app/main/index.js", "utf8");
const m = src.match(/const READ_ONLY[\s\S]*?const isReadOnly = args =>[\s\S]*?;\n/);
if (!m) { console.log("NO RULE FOUND"); process.exit(0); }
eval(m[0].replace(/^const /gm, "var "));
const want = [
  [["quota", "--json"], true], [["quota", "request", "spot"], true],
  [["status", "--json"], true], [["config", "--json"], true],
  [["init"], false], [["destroy"], false], [["open"], false],
  [["creds", "set"], false], [["deps", "install"], false],
  [["creds", "tailscale", "signin"], false], [["library", "forget", "1"], false],
];
for (const [args, w] of want) {
  const got = isReadOnly(args);
  if (got !== w) console.log("WRONG " + args.join(" ") + " got " + got + " want " + w);
}
console.log("checked");
' 2>&1)
contains "the rule was found"         "$sched" "checked"
# A quota ask collides with nothing - it is one API call, and it takes none of
# the locks a build or a destroy takes. Classifying it as mutating made it wait
# for every read, and a read is always running on the screen with the button.
lacks    "nothing is misclassified"   "$sched" "WRONG"
contains "the renderer still counts it as a write" \
         "$(cat app/renderer/app.js)" "cmd[0] === 'quota' && cmd[1] === 'request'"

BROWSER=""
for b in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$b" >/dev/null && { BROWSER=$b; break; }
done
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "quota-dom: $pass passed, $fail failed"; exit 0; }

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
  busy: () => Promise.resolve([]), openSignIn: (u) => { window.__opened = u; return Promise.resolve(true); },
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const sleep = () => new Promise(r => setTimeout(r, 0));
  try {
    paintConfig([{ key: 'GAME_SPOT', kind: 'choice', secret: false, is_set: true,
                   value: '1', default: 'auto', rule: 'auto,1,0', note: 'model' }]);
    openQuota('spot');
    out.push('OPEN | ' + document.getElementById('quota').open
             + ' | ' + document.getElementById('quota-title').textContent.trim());
    out.push('BUTTONS | go=' + document.getElementById('quota-go').hidden
             + ' copy=' + document.getElementById('quota-copy').hidden
             + ' case=' + document.getElementById('quota-case').hidden);
    // Nothing has been asked for yet: the dialog says what WILL be asked.
    const writes = () => window.__ran.filter(c => !c.includes('--json')).join(' ;; ');
    out.push('BEFORE RAN | ' + writes());

    window.__ran = [];
    document.getElementById('quota-go').click();
    await sleep();
    out.push('ASK RAN | ' + writes());
    // cg's own lines, as the app collects them.
    window.__emit(window.__lastId, { t: 'line', kind: 'ok',
      text: 'asked AWS for 4 vCPU. request req-abc' });
    window.__emit(window.__lastId, { t: 'line', kind: 'cont',
      text: '  case 100000000000001 - https://console.aws.amazon.com/support/home#/case/?displayId=100000000000001' });
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await sleep(); await sleep();
    out.push('AFTER RAN | ' + writes());
    // The appeal is captured on stdout.
    const appealJob = window.__lastId;
    window.__emit(appealJob, { t: 'raw', stream: 'stdout', text: 'Requesting an appeal with detailed use case.' });
    window.__emit(appealJob, { t: 'raw', stream: 'stdout', text: 'WORKLOAD' });
    window.__emit(appealJob, { t: 'exit', rc: 0 });
    await sleep(); await sleep();
    out.push('LOG | ' + document.getElementById('quota-log').textContent.replace(/\s+/g, ' ').trim());
    out.push('END BUTTONS | copy=' + document.getElementById('quota-copy').hidden
             + ' case=' + document.getElementById('quota-case').hidden);
    document.getElementById('quota-case').click();
    out.push('OPENED | ' + window.__opened);
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
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "quota-dom: $pass passed, $((fail+1)) failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "2. the dialog, before anything is asked"
contains "it opens"                   "$(row OPEN)"    "true"
contains "  naming the model"         "$(row OPEN)"    "spot GPU quota"
contains "  with only the ask"        "$(row BUTTONS)" "go=false copy=true case=true"
# Opening the dialog must not file anything: the ask is a button, not a side
# effect of reading about it.
check    "and asks for nothing yet"   "$(row 'BEFORE RAN')" "BEFORE RAN | "

echo "3. pressing it files the request"
check    "it runs the request"        "$(row 'ASK RAN')"   "ASK RAN | quota request spot"
check    "  then drafts the appeal"   "$(row 'AFTER RAN')" "AFTER RAN | quota request spot ;; quota appeal spot"
contains "what cg said is kept"       "$(row LOG)"         "asked AWS for 4 vCPU. request req-abc"
contains "  with the case it opened"  "$(row LOG)"         "case 100000000000001"
# The appeal sits under it, not over it.
contains "and the appeal is below"    "$(row LOG)"         "the appeal, for when the refusal arrives"
contains "  with its text"            "$(row LOG)"         "Requesting an appeal"
contains "copy and the case appear"   "$(row 'END BUTTONS')" "copy=false case=false"
check    "the case link is that case" "$(row OPENED)" "OPENED | https://console.aws.amazon.com/support/home#/case/?displayId=100000000000001"

echo "4. nothing threw"
check "no painter threw"              "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors" "$(row ERRS)" "ERRS | "

echo ""
echo "quota-dom: $pass passed, $fail failed"
(( fail == 0 ))
