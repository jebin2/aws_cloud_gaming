#!/usr/bin/env bash
# The quota dialog: pick a limit, see what the case would say, create it, and
# then live with the case that exists.
#
# Two bugs got here before these assertions did, and both were silent. The ask
# was classified as a command that must run alone, so it was refused before it
# reached AWS while the screen behind it was reading - nothing threw, nothing
# logged, the button simply did nothing. Then the appeal was painted over what
# cg had said, so a request that HAD been filed read as homework.
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
# The rule itself, RUN rather than grepped: this list decides whether a command
# may start while something else is in flight, and getting it wrong is silent.
# The rule itself, run rather than grepped - and it now comes from cg, which
# is the only thing that knows which commands take locks. The app applies it;
# getting that wrong is silent, and did it three times.
sched=$(node -e '
const { execFileSync } = require("node:child_process");
const src = require("node:fs").readFileSync("app/main/index.js", "utf8");
const m = src.match(/const FLAG_TAKES_VALUE[\s\S]*?const isReadOnly = raw => !runsAlone\(raw\);/);
if (!m) { console.log("NO RULE FOUND"); process.exit(0); }
var CONTRACT = JSON.parse(execFileSync("./cg", ["--contract"], { encoding: "utf8" }));
eval(m[0].replace(/^const /gm, "var "));
const want = [
  [["quota", "--json"], true], [["quota", "request", "spot"], true],
  [["quota", "appeal", "spot"], true],
  [["status", "--json"], true], [["config", "--json"], true],
  [["regions", "enable", "ap-southeast-5"], true],
  // Flags come BEFORE the command, so a matcher that reads argv[0] sees
  // "--region" and calls a read a mutation - refused while any read is in
  // flight, silently, and the dialog shows nothing at all.
  [["--region", "ap-south-1", "quota", "--json"], true],
  [["--region", "ap-south-1", "quota", "request", "spot"], true],
  [["--json", "status"], true],
  [["--region", "ap-south-1", "destroy"], false],
  [["--region", "ap-south-1", "init"], false],
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
lacks    "nothing is misclassified"   "$sched" "WRONG"
# One list, published by the thing that takes the locks.
contains "cg publishes it"            "$(./cg --contract)" '"runs_alone"'
lacks    "  and the renderer keeps none" "$(cat app/renderer/app.js)" "const WRITES = new Set("
contains "  it is told instead"       "$(cat app/renderer/app.js)" "write: !!res.write"

BROWSER=""
for b in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$b" >/dev/null && { BROWSER=$b; break; }
done
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "quota-dom: $pass passed, $fail failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/"
cp app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

# cg, as a script: each command answers from a queue, so `quota --json` can say
# something different after the request than it did before it - which is what
# the dialog depends on.
cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
window.__ran = [];
window.__answers = {};
window.cg = {
  run: (args) => {
    const line = args.join(' ');
    window.__ran.push(line);
    const id = (window.__lastId = (window.__lastId || 0) + 1);
    const q = window.__answers[line];
    const reply = Array.isArray(q) ? (q.length > 1 ? q.shift() : q[0]) : q;
    if (reply !== undefined) {
      setTimeout(() => {
        for (const l of String(reply.out || '').split('\n'))
          if (l) window.__emit(id, { t: 'raw', stream: 'stdout', text: l });
        for (const l of String(reply.lines || '').split('\n'))
          if (l) window.__emit(id, { t: 'line', kind: 'info', text: l });
        window.__emit(id, { t: 'exit', rc: reply.rc === undefined ? 0 : reply.rc });
      }, 0);
    }
    return Promise.resolve({ ok: true, id });
  },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  openSignIn: (u) => { window.__opened = u; return Promise.resolve(true); },
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB

APPEAL='Requesting an appeal with detailed use case.\nWORKLOAD\nLow-latency remote desktop...'
q_json() { # q_json <spot-request-json>
  cat <<J
{"region":"ap-south-1","instance_type":"g6.xlarge","vcpus_needed":4,
 "ondemand":{"code":"L-DB2E81BA","value":4.0,"enough":true,"request":null},
 "spot":{"code":"L-3819A6DF","value":0.0,"enough":false,"request":$1}}
J
}
probe() { # probe <before-json> <after-json> <probe-body-file>
  cat > "$T/r/answers.js" <<JS
window.__answers = {
  '--region ap-south-1 quota --json': [ {out: \`$1\`}, {out: \`$2\`} ],
  '--region ap-southeast-5 quota --json': [ {out: \`$1\`} ],
  '--region ap-south-1 quota appeal spot': { out: '$APPEAL' },
  '--region ap-south-1 quota request spot': { lines: 'asked AWS for 4 vCPU. request req-abc' },
};
JS
  cp "$3" "$T/r/probe.js"
  python3 -I - "$T/r" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "index.html"
t = p.read_text()
if 'stub.js' not in t:
    t = t.replace('<script src="app.js"',
                  '<script src="stub.js"></script>\n<script src="answers.js"></script>\n<script src="app.js"', 1)
    t = t.replace('</body>', '<script src="probe.js"></script>\n</body>', 1)
    p.write_text(t)
PY
  # Written to a file and then catted, rather than piped straight into python:
  # chromium's main process exits as soon as the DOM is dumped, but a child of
  # it keeps the write end of a pipe open for another 10-25 SECONDS, and
  # sys.stdin.read() waits for EOF. That idle wait, once per page load, was the
  # whole cost of this suite - minutes of it, at 0.5s of actual work per load.
  "$BROWSER" --headless --disable-gpu --no-sandbox --window-size=1280,900 \
    --virtual-time-budget=6000 --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
  cat "$T/dom.html" \
  | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")'
}
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

cat > "$T/body.js" <<'PROBE'
(async () => {
  const out = [];
  const sleep = (n = 1) => new Promise(r => setTimeout(r, n));
  const read = label => {
    out.push(label + ' STATE | ' + document.getElementById('quota-state').textContent.replace(/\s+/g, ' ').trim());
    out.push(label + ' WHY | ' + document.getElementById('quota-explain').textContent.replace(/\s+/g, ' ').trim());
    out.push(label + ' PRE | ' + (document.getElementById('quota-pre-label').hidden ? 'hidden'
             : document.getElementById('quota-pre-label').textContent.trim()));
    out.push(label + ' BODY | ' + document.getElementById('quota-log').textContent.replace(/\s+/g, ' ').trim());
    out.push(label + ' BTN | go=' + document.getElementById('quota-go').hidden
             + '/' + document.getElementById('quota-go').disabled
             + ' refresh=' + document.getElementById('quota-refresh').hidden
             + ' caserow=' + document.getElementById('quota-case-row').hidden);
  };
  try {
    paintConfig([{ key: 'GAME_REGION', kind: 'text', secret: false, is_set: true,
                   value: 'ap-south-1', default: 'ap-south-2', note: 'region' }]);
    paintSweep({ cached: true, age_seconds: 60, regions: [
      { region: 'ap-south-1', city: 'Asia Pacific (Mumbai)', rtt_ms: 22, enabled: true, machines: [] },
      { region: 'ap-southeast-5', city: 'Asia Pacific (Malaysia)', rtt_ms: 47, enabled: true, machines: [] },
      { region: 'ap-southeast-3', city: 'Asia Pacific (Jakarta)', rtt_ms: 57, enabled: false, machines: [] },
    ], too_far: [], unreachable: [] });
    await openQuota();
    for (let i = 0; i < 6; i++) await sleep();
    read('PICK');
    out.push('PICK RAN | ' + window.__ran.filter(c => c.includes('quota')).join(' ;; '));

    document.getElementById('quota-kind').value = 'spot';
    document.getElementById('quota-kind').onchange();
    for (let i = 0; i < 6; i++) await sleep();
    read('CHOSEN');

    window.__ran = [];
    document.getElementById('quota-go').click();
    await sleep();
    read('CREATING');
    for (let i = 0; i < 10; i++) await sleep();
    read('MADE');
    out.push('MADE RAN | ' + window.__ran.filter(c => c.includes('quota')).join(' ;; '));
    out.push('MADE URL | ' + document.getElementById('quota-case-url').textContent.trim());
    document.getElementById('quota-case').click();
    out.push('OPENED | ' + window.__opened);

    // Closing and opening again: what is on the dialog belongs to the last
    // question, and showing it under a new one - even for half a second - is
    // an answer to something nobody asked.
    document.getElementById('quota-cancel').click();
    openQuota();
    out.push('REOPEN NOW | pre=' + document.getElementById('quota-pre-label').hidden
             + ' body=' + JSON.stringify(document.getElementById('quota-log').textContent)
             + ' caserow=' + document.getElementById('quota-case-row').hidden
             + ' kind=' + JSON.stringify(document.getElementById('quota-kind').value));
    out.push('REOPEN BUSY | kind=' + document.getElementById('quota-kind').disabled
             + ' refresh=' + document.getElementById('quota-refresh').disabled);
    for (let i = 0; i < 8; i++) await sleep();
    out.push('REOPEN SETTLED | ' + document.getElementById('quota-explain').textContent.trim()
             + ' | kindDisabled=' + document.getElementById('quota-kind').disabled);

    // Refresh: the old answer goes immediately, the controls lock while it
    // reads, and both come back when it lands.
    document.getElementById('quota-kind').value = 'spot';
    document.getElementById('quota-kind').onchange();
    for (let i = 0; i < 8; i++) await sleep();
    document.getElementById('quota-refresh').click();
    out.push('REFRESH NOW | state=' + document.getElementById('quota-state').textContent.trim()
             + ' body=' + JSON.stringify(document.getElementById('quota-log').textContent)
             + ' refresh=' + document.getElementById('quota-refresh').disabled
             + '/' + document.getElementById('quota-refresh').textContent.trim());
    for (let i = 0; i < 10; i++) await sleep();
    out.push('REFRESH SETTLED | ' + document.getElementById('quota-state').textContent.replace(/\s+/g, ' ').trim()
             + ' | refresh=' + document.getElementById('quota-refresh').disabled
             + '/' + document.getElementById('quota-refresh').textContent.trim());
  } catch (e) { out.push('THREW | ' + e.message + ' | ' + (e.stack || '').split('\n')[1]); }
  out.push('ERRS | ' + (window.__errs || []).join(' ;; '));
  const pre = document.createElement('pre');
  pre.id = 'probe-out'; pre.textContent = out.join('\n');
  document.body.append(pre);
})();
PROBE

OUT=$(probe "$(q_json null)" \
            "$(q_json '{"status":"CASE_OPENED","desired":4.0,"created":"2026-10-12T23:31:11+05:30","case_id":"100000000000001","last_updated":"2026-10-13T09:00:00+05:30"}')" \
            "$T/body.js")
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "quota-dom: $pass passed, $((fail+1)) failed"; exit 1; }

echo "2. opening it asks for nothing"
contains "it reads the quota"          "$(row 'PICK RAN')"  "--region ap-south-1 quota --json"
lacks    "  and files nothing"         "$(row 'PICK RAN')"  "quota request"
contains "it waits for a choice"       "$(row 'PICK WHY')"  "Pick one to see what it would ask for"
contains "  with the button dead"      "$(row 'PICK BTN')"  "go=false/true"

echo "3. choosing one says what the case would contain"
contains "it says what you have"       "$(row 'CHOSEN STATE')" "Your limit: 0 vCPU. One g6.xlarge needs 4"
contains "  and what would be created" "$(row 'CHOSEN PRE')"   "This sends AWS a request for"
contains "  the quota, by name"        "$(row 'CHOSEN BODY')"  "Spot GPU machines"
contains "  the value, as one box"     "$(row 'CHOSEN BODY')"  "New value: 4 vCPU (one machine)"
contains "  and that a refusal is step one" "$(row 'CHOSEN BODY')" "usually refuses within minutes"
contains "the button is live now"      "$(row 'CHOSEN BTN')"   "go=false/false"

echo "4. creating"
contains "it says it is working"       "$(row 'CREATING STATE')" "Sending the request"
check    "  and runs the request"      "$(row 'MADE RAN')"       "MADE RAN | --region ap-south-1 quota request spot ;; --region ap-south-1 quota --json ;; --region ap-south-1 quota appeal spot"

echo "5. and then the case exists"
contains "the status is AWS's own"     "$(row 'MADE STATE')"  "Being reviewed"
contains "  with the date asked"       "$(row 'MADE STATE')"  "asked 2026-10-12"
contains "  explained"                 "$(row 'MADE WHY')"    "usually refuses the first request"
# "I replied with the appeal and it still says case open" - it will. Replying
# is a correspondence on the case; the request only moves when AWS decides.
contains "  and that replying does not move it" "$(row 'MADE WHY')" "a person reviews it"
contains "when AWS last touched it"    "$(row 'MADE STATE')"  "AWS last moved it 2026-10-13"
# The label says WHEN to use it, because the refusal lands minutes after you
# have closed the window.
contains "the appeal is labelled"      "$(row 'MADE PRE')"    "If AWS refuses, reply to them with this"
contains "  and is the appeal"         "$(row 'MADE BODY')"   "Requesting an appeal"
contains "the case is linked"          "$(row 'MADE URL')"    "displayId=100000000000001"
check    "  and the link opens it"     "$(row OPENED)"        "OPENED | https://console.aws.amazon.com/support/home#/case/?displayId=100000000000001"
contains "Refresh is offered"          "$(row 'MADE BTN')"    "refresh=false"
# Asking again while a case is open is refused by AWS as a duplicate.
contains "  and Confirm is gone"       "$(row 'MADE BTN')"    "go=true"

echo "6. closing and opening again starts clean"
check    "the old appeal is gone at once" "$(row 'REOPEN NOW')" "REOPEN NOW | pre=true body=\"\" caserow=true kind=\"\""
# Locked while it reads: a dropdown you can change mid-read answers the
# previous question.
contains "  and the controls are locked" "$(row 'REOPEN BUSY')" "kind=true refresh=true"
contains "then it asks for a choice"     "$(row 'REOPEN SETTLED')" "Pick one to see what it would ask for"
contains "  with the controls back"      "$(row 'REOPEN SETTLED')" "kindDisabled=false"

echo "7. Refresh clears, locks, then reflects"
contains "the old answer goes"         "$(row 'REFRESH NOW')" 'body=""'
contains "  it says it is reading"     "$(row 'REFRESH NOW')" "reading"
contains "  and cannot be pressed twice" "$(row 'REFRESH NOW')" "refresh=true/Reading"
contains "then the state is back"      "$(row 'REFRESH SETTLED')" "Being reviewed"
contains "  and so is the button"      "$(row 'REFRESH SETTLED')" "refresh=false/Refresh"

echo "8. nothing threw"
check "no painter threw"               "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors" "$(row ERRS)" "ERRS | "

echo ""
echo "quota-dom: $pass passed, $fail failed"
(( fail == 0 ))
