#!/usr/bin/env bash
# The archived Steam login, actually rendered.
#
# It is 22 KB that decides which account a rebuilt box signs in as, and it was
# invisible on every screen while being COUNTED as an archived game - so a box
# with nothing archived reported "1 objects, 22KB" of games.
#
# The state this file exists for is the third one. `null` means "could not look",
# and painting that as "none archived" would invite someone to rebuild expecting
# a sign-in prompt and get a box already logged into an account they believed
# they had deleted. Source greps cannot see which branch a painter takes; this
# loads the real page and reads the text back out.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "login-dom: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/" 2>/dev/null
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true
cp app/renderer/*.css "$T/r/" 2>/dev/null || true

# The smallest cg that lets the page finish loading. No data is served: the
# probe calls the painter directly, so nothing here needs to pretend to be AWS.
cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
window.cg = {
  run: () => Promise.resolve({ ok: true, id: 1 }),
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  onEvent() { return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(() => {
  const out = [];
  const read = label => {
    const g = id => {
      const el = document.getElementById(id);
      return el ? el.textContent.replace(/\s+/g, ' ').trim() : '(missing)';
    };
    const trs = [...document.querySelectorAll('#lib-login-rows tr')];
    out.push(label + ' ROWS | ' + trs.map(tr => [...tr.children].map(td => td.textContent.trim()).join(' / ')).join(' || '));
    out.push(label + ' NOTE | ' + g('lib-login-note'));
    out.push(label + ' BTN | ' + [...document.querySelectorAll('#lib-login-rows button')].map(b => b.className).join(','));
    const sel = document.getElementById('b-login-choice');
    out.push(label + ' BUILD | ' + g('b-login') + ' / ' + (sel.hidden ? 'no choice'
      : [...sel.options].map(o => (o.selected ? '*' : '') + o.textContent).join(', ')));
  };
  const call = (label, arg) => {
    try { paintLogin(arg); read(label); }
    catch (e) { out.push(label + ' THREW | ' + e.message); }
  };

  call('PRESENT', { present: true, bytes: 22458, modified: '2026-10-10T16:30:03+00:00',
                    usd_month: 0.000001,
                    accounts: [{ steamid: '1', account: 'alice', persona: 'Alice',
                                 most_recent: true, last_used: 1791648428 }] });
  call('TWO', { present: true, bytes: 30000, modified: '2026-10-10T16:30:03+00:00',
                usd_month: 0.000001,
                accounts: [{ steamid: '1', account: 'alice', most_recent: false, last_used: 1 },
                           { steamid: '2', account: 'bob', most_recent: true, last_used: 2 }] });
  call('ABSENT', { present: false, accounts: [] });
  // The choice, on Build: picking "ask me" saves it through cg.
  const ran = [];
  window.cg.run = args => { ran.push(args.join(' ')); return Promise.resolve({ ok: true, id: 99 }); };
  paintLogin({ present: true, bytes: 22458, modified: null, usd_month: 0.000001,
               accounts: [{ steamid: '1', account: 'alice', most_recent: true }] });
  const sel = document.getElementById('b-login-choice');
  sel.value = 'fresh'; sel.dispatchEvent(new Event('change'));
  out.push('PICK RAN | ' + ran.join(' ;; '));
  config = [{ key: 'GAME_STEAM_LOGIN', kind: 'choice', value: 'fresh', default: 'use', rule: 'use,fresh' }];
  paintBuildLogin();
  read('FRESH');
  config = [];
  call('UNKNOWN', null);
  call('NONAMES', { present: true, bytes: 22458, modified: null, usd_month: 0.000001,
                    accounts: null });
  // A copy a region move left beside games elsewhere: its own row, used by nothing.
  elsewhereNow = { region: 'ap-south-1', places: [{ bucket: 'cg-library-old', region: 'ap-south-2', error: null,
    bytes: 1, login: true, games: [], login_detail: { present: true, bytes: 22290, modified: '2026-09-26T12:20:10+00:00',
      accounts: [{ steamid: '1', account: 'alice', most_recent: true }] } }] };
  call('ELSE', { present: true, bytes: 22458, modified: '2026-10-10T16:30:03+00:00', usd_month: 0.000001,
                 accounts: [{ steamid: '1', account: 'alice', persona: 'Alice', most_recent: true, last_used: 1 }] });
  elsewhereNow = null;

  // The build-time prompt, as the app actually shows it. cg sends the answers
  // it accepts in the event; the dialog used to ignore them and render a text
  // box, so a build stopped on a modal reading "choice [1]:" with no sign of
  // what the choices were - the options cg printed were in the log pane behind
  // the modal.
  const askRead = label => {
    const box = document.getElementById('ask-choices');
    const input = document.getElementById('ask-input');
    const rows = [...box.querySelectorAll('label')].map(l => {
      const r = l.querySelector('input[type=radio]');
      return (r && r.checked ? 'CHECKED ' : '') + l.textContent.trim();
    });
    out.push(label + ' PROMPT | ' + document.getElementById('ask-prompt').textContent.trim());
    out.push(label + ' BOX | ' + (box.hidden ? 'hidden' : 'shown'));
    out.push(label + ' INPUT | ' + (input.hidden ? 'hidden' : 'shown'));
    out.push(label + ' ROWS | ' + rows.join(' || '));
  };
  let answered = null;
  window.cg.answer = (id, v) => { answered = id + '=' + v; return Promise.resolve(true); };
  const dlg = () => document.getElementById('ask');
  // The dialog's own `close` event is dispatched as a queued task, and under
  // --virtual-time-budget a setTimeout can run BEFORE it - a race this probe
  // lost, reading null and making a working dialog look broken. So the close
  // HANDLER is invoked directly: that handler is the code under test, while the
  // browser choosing to fire it is the browser's business.
  const closeNow = () => { const d = dlg(); const h = d.onclose; d.close(); if (h) h(); };
  try {
    ask(7, { t: 'ask', id: 'session-end',
             prompt: '  [d] destroy (recommended)  [n] leave it running: ',
             default: 'd', choices: 'd,n' });
    askRead('CHOICE');
    // Dismissing without touching anything must answer the DEFAULT, not empty.
    closeNow();
    out.push('CHOICE ANSWER | ' + answered);

    // Picking the other one must answer that.
    ask(8, { t: 'ask', id: 'session-end', prompt: 'p', default: 'd', choices: 'd,n' });
    [...document.querySelectorAll('#ask-choices input')].find(r => r.value === 'n').checked = true;
    closeNow();
    out.push('PICK2 ANSWER | ' + answered);

    // A prompt with NO choices is still a text field, and still answers.
    ask(9, { t: 'ask', id: 'tailscale-key', prompt: 'auth key', default: 'abc' });
    askRead('TEXT');
    closeNow();
    out.push('TEXT ANSWER | ' + answered);
  } catch (e) { out.push('ASK THREW | ' + e.message); }

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
OUT=$("$BROWSER" --headless --disable-gpu --no-sandbox --virtual-time-budget=9000 \
      --user-data-dir="$T/chrome" --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
    cat "$T/dom.html" \
      | python3 -I -c '
import re, sys, html
d = sys.stdin.read()
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", d, re.S)
print(html.unescape(m.group(1)) if m else "PROBE DID NOT RUN")')

[[ -n ${CG_DOM_DUMP:-} ]] && { printf '%s\n' "$OUT"; exit 0; }
if [[ $OUT == "PROBE DID NOT RUN" || -z $OUT ]]; then
  echo "  FAIL the page did not render at all"
  echo ""; echo "login-dom: $pass passed, 1 failed"; exit 1
fi
row() { grep "^$1 " <<<"$OUT" | head -1; }

echo "1. a login is archived: one row"
contains "the account, its size and date" "$(row 'PRESENT ROWS')" "alice / "
contains "  the size is shown"        "$(row 'PRESENT ROWS')" "/ 21.9 KB / 10 Oct /"
contains "  and it is the one used"   "$(row 'PRESENT ROWS')" "/ signs in / Forget"
contains "  said once, below"         "$(row 'PRESENT NOTE')" "A new machine signs in as alice."
# Stated and dismissed in the same breath: 22 KB is not a saving, and offering a
# delete button next to a cost invites reading it as one.
contains "deleting is not sold as a saving" "$(row 'PRESENT NOTE')" "saves nothing"
contains "  Forget is offered, in red" "$(row 'PRESENT BTN')" "btn btn-danger"

echo "2. several accounts in one tarball"
contains "both are listed, in one row" "$(row 'TWO ROWS')" "alice, bob / "
contains "  the recent one is who signs in" "$(row 'TWO NOTE')" "A new machine signs in as bob."
contains "  and the whole-tarball caveat is said" "$(row 'TWO NOTE')" "come back together"
contains "  with how to keep one"     "$(row 'TWO NOTE')" "sign in as it on the machine"

echo "3. nothing archived"
contains "it says none"               "$(row 'ABSENT ROWS')" "No Steam login saved"
contains "  and what that means"      "$(row 'ABSENT ROWS')" "asks you to sign in"
check    "  Forget is not offered"    "$(row 'ABSENT BTN')"  "ABSENT BTN | "

echo "4. UNKNOWN is the one that must not read as 'none'"
# The whole reason this file is rendered rather than grepped.
contains "it admits it could not look" "$(row 'UNKNOWN ROWS')" "Could not read the saved login"
lacks    "  and never claims none"     "$(row 'UNKNOWN ROWS')" "No Steam login saved"
lacks    "  nor invites a sign-in"     "$(row 'UNKNOWN NOTE')" "asks you to sign in"
# No delete button for a state nobody can vouch for.
check    "  Forget is not offered"     "$(row 'UNKNOWN BTN')" "UNKNOWN BTN | "

echo "5. present, but the names could not be read"
contains "the login is still a row"    "$(row 'NONAMES ROWS')" "names unreadable / "
lacks    "  not as zero accounts"      "$(row 'NONAMES ROWS')" "0 accounts"

echo "5c. Steam sign-in is chosen on Build"
contains "the saved login is the default"  "$(row 'PRESENT BUILD')" "signed in as alice / *Sign in as alice, Ask me to sign in"
contains "with nothing saved there is no choice" "$(row 'ABSENT BUILD')" "/ no choice"
contains "picking 'ask me' saves it through cg" "$(row 'PICK RAN')" "config set GAME_STEAM_LOGIN fresh"
contains "  and Build then says so"        "$(row 'FRESH BUILD')" "sign in on the machine / Sign in as alice, *Ask me to sign in"

echo "5b. a copy left in another place"
contains "its own row, by its place"   "$(row 'ELSE ROWS')" "|| alice / ap-south-2 / 21.8 KB / 26 Sep"
contains "  used by nothing"           "$(row 'ELSE ROWS')" "/ not used / Forget"
contains "  after the one that signs in" "$(row 'ELSE ROWS')" "/ signs in / Forget ||"
check    "  its Forget is not red"     "$(row 'ELSE BTN')" "ELSE BTN | btn btn-danger,btn"

echo "6. a numbered prompt is a choice, not a text box"
contains "the question stands alone"   "$(row 'CHOICE PROMPT')" "leave it running"
check    "the radios are shown"        "$(row 'CHOICE BOX')"   "CHOICE BOX | shown"
check    "  and the text field is not" "$(row 'CHOICE INPUT')" "CHOICE INPUT | hidden"
contains "the first option says what it does" "$(row 'CHOICE ROWS')" "destroy the box"
contains "  and the second"            "$(row 'CHOICE ROWS')" "leave it running"
contains "  with the consequence spelled out" "$(row 'CHOICE ROWS')" "keeps billing"
contains "the default is preselected"  "$(row 'CHOICE ROWS')" "CHECKED d"
# Dismissing must answer the default, never an empty string: cg reads the reply
# and an empty one would fall through to its own default anyway, but a build
# that answers "" to a choice prompt is a thing nobody can debug.
check "closing answers the default"    "$(row 'CHOICE ANSWER')" "CHOICE ANSWER | 7=d"
check "picking the other answers it"   "$(row 'PICK2 ANSWER')"  "PICK2 ANSWER | 8=n"

echo "7. a prompt with no choices is still a text field"
check "the text field is shown" "$(row 'TEXT INPUT')" "TEXT INPUT | shown"
check "  and it answers what was typed" "$(row 'TEXT ANSWER')" "TEXT ANSWER | 9=abc"
check "  and no radios"         "$(row 'TEXT BOX')"   "TEXT BOX | hidden"

echo "8. nothing threw"
lacks "no painter threw"    "$OUT" "THREW"
lacks "  and the dialog did not" "$OUT" "ASK THREW"
check "and the page logged no errors" "$(row 'ERRS')" "ERRS | "

echo ""
echo "login-dom: $pass passed, $fail failed"
(( fail == 0 ))
