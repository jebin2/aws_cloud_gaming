#!/usr/bin/env bash
# A failed build, as something to act on.
#
# cg writes for a terminal, where the answer to a problem is a command to type.
# In a window a command to type is a worse button, so the panel keeps cg's own
# words - they say more than any button can - and puts the two or three things
# worth doing on top of them.
#
# The mapping is keyed by the AWS error code, which is the stable part: the
# prose around it is prose.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "build-fail-dom: 0 passed, 0 failed"; exit 0; }

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

# The real thing, verbatim from a build that stopped tonight.
cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const sleep = () => new Promise(r => setTimeout(r, 0));
  const read = label => {
    out.push(label + ' HEAD | ' + document.getElementById('b-fail-head').textContent.trim());
    out.push(label + ' WHY | ' + document.getElementById('b-fail-why').textContent.replace(/\s+/g, ' ').trim());
    out.push(label + ' ACTS | ' + [...document.querySelectorAll('#b-fail-acts button')]
             .map(b => b.textContent.trim()).join(' || '));
    out.push(label + ' PANEL | ' + document.getElementById('b-fail').className);
    out.push(label + ' KEPT | ' + (document.getElementById('b-error').textContent.includes('Spot rents the machines')));
  };
  const CAPACITY = [
    'AWS has no spare g6.xlarge at the spot price in ap-south-2',
    '    nothing was launched, and nothing is billing',
    '    AWS said: Insufficient capacity.',
    '    error code: InsufficientInstanceCapacity',
    '  Spot rents the machines nobody else is paying full price for, and there',
    '  are none of those here at the moment.',
    '  Pay full price, and build now:',
    '      cg config set GAME_SPOT 0       (Settings > purchase model, in the app)',
  ];
  try {
    paintConfig([{ key: 'GAME_SPOT', kind: 'choice', secret: false, is_set: true,
                   value: '1', default: 'auto', rule: 'auto,1,0', note: 'model' }]);
    out.push('BEFORE | ' + document.getElementById('b-fail').className);
    for (const l of CAPACITY) buildFail(l);
    read('SPOT');
    window.__ran = [];
    [...document.querySelectorAll('#b-fail-acts button')][0].click();
    await sleep(); await sleep();
    out.push('SPOT RAN | ' + window.__ran.join(' ;; '));

    // A quota failure is a different answer: there is nothing to fall back to,
    // and the thing to do is ask for more.
    buildFailClear();
    out.push('CLEARED | ' + document.getElementById('b-fail').className
             + ' acts=' + document.querySelectorAll('#b-fail-acts button').length);
    for (const l of ['your AWS quota is too small for g6.xlarge in ap-south-2',
                     '    error code: VcpuLimitExceeded']) buildFail(l);
    read('QUOTA');

    // A code nothing is known about still gets the headline and the text.
    buildFailClear();
    for (const l of ['the instance could not be launched',
                     '    AWS said: Something nobody has seen.',
                     '    error code: SomeBrandNewError']) buildFail(l);
    read('UNKNOWN');
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
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "build-fail-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. nothing is shown until something fails"
contains "the panel starts hidden"     "$(row BEFORE)" "hidden"

echo "2. spot capacity, the one that keeps happening"
contains "cg's headline is the headline" "$(row 'SPOT HEAD')" "no spare g6.xlarge at the spot price"
# First, because it is the only fact that matters before reading anything else.
contains "it leads with the reassurance" "$(row 'SPOT WHY')"  "Nothing was launched, and nothing is billing"
contains "  then AWS's own words"        "$(row 'SPOT WHY')"  "Insufficient capacity"
contains "  and the code, in brackets"   "$(row 'SPOT WHY')"  "(InsufficientInstanceCapacity)"
# The three answers, as buttons rather than as commands to type.
contains "on demand is offered first"    "$(row 'SPOT ACTS')" "Build on demand instead"
contains "  then another region"         "$(row 'SPOT ACTS')" "Scan all regions"
contains "  then another machine"        "$(row 'SPOT ACTS')" "Pick another machine"
check    "and it does what it says"      "$(row 'SPOT RAN')"  "SPOT RAN | config set GAME_SPOT 0"
# cg said more than three buttons can, and it is kept.
contains "cg's full text is kept"        "$(row 'SPOT KEPT')" "true"

echo "3. a different code, a different answer"
contains "a quota failure says so"       "$(row 'QUOTA HEAD')" "quota is too small"
contains "  and offers the ask"          "$(row 'QUOTA ACTS')" "Ask AWS for GPU quota"
lacks    "  not on demand, which will not help" "$(row 'QUOTA ACTS')" "Build on demand"

echo "4. a code nothing is known about"
# No buttons is the honest answer; the headline and cg's text still carry it.
contains "the headline still shows"      "$(row 'UNKNOWN HEAD')" "could not be launched"
contains "  with AWS's words"            "$(row 'UNKNOWN WHY')"  "Something nobody has seen"
check    "  and no invented buttons"     "$(row 'UNKNOWN ACTS')" "UNKNOWN ACTS | "

echo "5. clearing it clears all of it"
contains "the panel hides again"         "$(row CLEARED)" "hidden"
contains "  and the buttons go"          "$(row CLEARED)" "acts=0"

echo "6. nothing threw"
check "no painter threw"                 "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors"  "$(row ERRS)" "ERRS | "

echo ""
echo "build-fail-dom: $pass passed, $fail failed"
(( fail == 0 ))
