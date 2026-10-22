#!/usr/bin/env bash
# The credentials card, actually rendered.
#
# A warning strip above every page used to say "AWS rejected
# these credentials - ... Settings - or cg check --fix - takes a new key" on a
# laptop that had no AWS CLI to reject anything, pointing at a Settings screen
# with no field for a key. Three claims, none true.
#
# What a source grep cannot see is which branch the painter takes, so this loads
# the real page and reads the words back out of the three states.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "creds-dom: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/"
cp app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

# Every cg call is recorded instead of run, so the test can assert which command
# a button would have run.
cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
window.__ran = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
window.__answers = [];
window.__opened = [];
window.cg = {
  run: (args) => { window.__ran.push(args.join(' '));
                   window.__lastId = (window.__lastId || 0) + 1;
                   return Promise.resolve({ ok: true, id: window.__lastId }); },
  answer: (id, v) => { window.__answers.push(v); return Promise.resolve(true); },
  cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  openSignIn: (url) => { window.__opened.push(url); return Promise.resolve(true); },
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const g = id => {
    const el = document.getElementById(id);
    return el ? el.textContent.replace(/\s+/g, ' ').trim() : '(missing)';
  };
  const read = label => {
    out.push(label + ' STATE | ' + g('creds-state'));
    out.push(label + ' DETAIL | ' + g('creds-detail'));
    out.push(label + ' BTN | ' + g('creds-set'));
  };
  // A status payload with only what paintStatus needs to reach the banner.
  const status = cause => ({
    host: 'gamevps', region: 'ap-south-1', instance_type: 'g4dn.xlarge',
    box: null, session: null, archive: {}, config: {}, local: {}, quota: {}, spec: {},
    account: { id: 'NO CREDENTIALS', plan: '?', credits: '?' }, budget: {}, res: {},
    tailnet: {}, old_volume: {}, login: null,
    error: { cause, credentials: cause === 'no-cli'
      ? 'The AWS CLI is not installed, so nothing here could be read - everything below is UNKNOWN, not empty.'
      : 'AWS rejected these credentials - everything below is UNKNOWN, not empty. Check: aws sts get-caller-identity' },
  });
  try {
    paintCreds({ cli: false, source: null, key_id: null, account: null, arn: null,
                 valid: null, error: 'The AWS CLI is not installed - cg check --fix installs it' });
    read('NOCLI');
    window.__ran = [];
    document.getElementById('creds-set').click();
    await new Promise(r => setTimeout(r, 0));
    out.push('NOCLI RAN | ' + window.__ran.join(' ;; '));
    // It installs in the run dialog; finish it, so the page behind is usable.
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await new Promise(r => setTimeout(r, 0));
    document.getElementById('rundlg').close();

    window.__ran = [];
    paintCreds({ cli: true, source: '~/.aws/credentials, profile default', key_id: '****1234',
                 account: null, arn: null, valid: false,
                 error: 'An error occurred (InvalidClientTokenId) ...' });
    read('BAD');
    document.getElementById('creds-set').click();
    out.push('BAD RAN | ' + window.__ran.join(' ;; '));

    window.__ran = [];
    paintCreds({ cli: true, source: '~/.aws/credentials, profile default', key_id: '****5678',
                 account: '123456789012', arn: 'arn:aws:iam::123456789012:user/example',
                 valid: true, error: null });
    read('OK');

    // --- the key dialog, driven end to end ------------------------------
    const dlg = document.getElementById('awskey');
    const sleep = () => new Promise(r => setTimeout(r, 0));
    paintCreds({ cli: true, source: 's', key_id: '****1234', account: null, arn: null,
                 valid: false, error: 'rejected' });
    document.getElementById('creds-set').click();
    out.push('FORM OPEN | ' + dlg.open);
    out.push('FORM FIELDS | id=' + document.getElementById('awskey-id').type
             + ' secret=' + document.getElementById('awskey-secret').type);

    // Nothing typed: it says so, and runs nothing.
    window.__ran = [];
    document.getElementById('awskey-go').click();
    await sleep();
    out.push('EMPTY ERR | ' + document.getElementById('awskey-err').textContent.trim());
    out.push('EMPTY RAN | ' + window.__ran.join(' ;; '));
    out.push('EMPTY OPEN | ' + dlg.open);

    // A key AWS will not take: the error belongs in the dialog, which stays up.
    document.getElementById('awskey-id').value = 'AKIABADBADBADBAD9999';
    document.getElementById('awskey-secret').value = 'bad-secret';
    window.__ran = []; window.__answers = [];
    const bad = document.getElementById('awskey-go').click();
    await sleep();
    out.push('SUBMIT RAN | ' + window.__ran.join(' ;; '));
    out.push('SUBMIT BTN | ' + document.getElementById('awskey-go').textContent.trim()
             + ' disabled=' + document.getElementById('awskey-go').disabled);
    // cg asks its two questions; the form answers them.
    window.__emit(window.__lastId, { t: 'ask', id: 'aws-access-key-id', prompt: 'id: ', default: '' });
    window.__emit(window.__lastId, { t: 'ask', id: 'aws-secret-access-key', prompt: 'secret: ', default: '', secret: 1 });
    out.push('SUBMIT ANSWERS | ' + window.__answers.join(' ;; '));
    out.push('SUBMIT MODALS | ' + document.getElementById('ask').open);
    window.__emit(window.__lastId, { t: 'line', kind: 'info', text: 'AWS credentials: paste an access key (IAM > Users > …)' });
    window.__emit(window.__lastId, { t: 'line', kind: 'fail', text: 'AWS rejected that key: An error occurred (InvalidClientTokenId) …' });
    window.__emit(window.__lastId, { t: 'line', kind: 'cont', text: '  nothing was saved - the key you had before is untouched' });
    window.__emit(window.__lastId, { t: 'exit', rc: 1 });
    await sleep(); await sleep();
    out.push('FAIL OPEN | ' + dlg.open);
    out.push('FAIL ERR | ' + document.getElementById('awskey-err').textContent.replace(/\s+/g, ' ').trim());
    out.push('FAIL BTN | ' + document.getElementById('awskey-go').textContent.trim()
             + ' disabled=' + document.getElementById('awskey-go').disabled);

    // And one it takes: the dialog closes.
    document.getElementById('awskey-id').value = 'AKIAGOODGOODGOOD1234';
    document.getElementById('awskey-secret').value = 'good-secret';
    window.__ran = [];
    document.getElementById('awskey-go').click();
    await sleep();
    out.push('OK RAN | ' + window.__ran.join(' ;; ') + ' lastId=' + window.__lastId);
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await sleep(); await sleep();
    // Saved: it stays, checking, until the key has been read back.
    const credsReads = [...jobs].filter(([, j]) => j.json === 'creds').map(([id]) => id);
    out.push('OK CHECKING | ' + dlg.open + ' ' + document.getElementById('awskey-go').textContent.trim()
             + ' reading=' + (credsReads.length > 0));
    // The key read back - whichever read of it is under way.
    for (const id of credsReads) {
      window.__emit(id, { t: 'raw', stream: 'stdout',
        text: JSON.stringify({ cli: true, key_id: 'AKIDEXAMPLE', valid: true, account: '123456789012' }) });
      window.__emit(id, { t: 'exit', rc: 0 });
    }
    await new Promise(r => setTimeout(r, 400));     // its closing motion
    out.push('OK OPEN | ' + dlg.open);

    // --- the Tailscale card, which fails in two independent ways --------
    const tsRead = label => {
      out.push(label + ' TS | ' + document.getElementById('tskey-state').textContent.replace(/\s+/g, ' ').trim()
               + ' // ' + document.getElementById('tskey-detail').textContent.replace(/\s+/g, ' ').trim()
               + ' // ' + document.getElementById('tskey-set').textContent.trim()
               + ' // ' + document.getElementById('tskey-auth').textContent.replace(/\s+/g, ' ').trim());
    };
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: true, node: 'laptop', auth_key_stored: false, can_mint: false });
    tsRead('TSNONE');
    paintTskey({ present: true, valid: false, state: 'rejected', detail: '401',
                 signed_in: true, node: 'laptop' });
    tsRead('TSBAD');
    paintTskey({ present: true, valid: null, state: 'unreachable', detail: '000',
                 signed_in: false, node: null });
    tsRead('TSDOWN');
    paintTskey({ present: true, valid: true, state: 'ok', detail: null,
                 signed_in: true, node: 'laptop', auth_key_stored: false, can_mint: true });
    tsRead('TSOK');
    paintTskey({ present: true, valid: true, state: 'ok', detail: null,
                 signed_in: true, node: 'laptop', auth_key_stored: true, can_mint: true });
    tsRead('TSKEPT');

    const tsdlg = document.getElementById('onefield');
    document.getElementById('tskey-set').click();
    out.push('TSFORM OPEN | ' + tsdlg.open + ' type=' + document.getElementById('onefield-input').type);
    window.__ran = [];
    document.getElementById('onefield-go').click();
    await sleep();
    out.push('TSEMPTY | ' + document.getElementById('onefield-err').textContent.trim()
             + ' ran=' + window.__ran.join(','));
    document.getElementById('onefield-input').value = 'tskey-api-nope';
    window.__ran = []; window.__answers = [];
    document.getElementById('onefield-go').click();
    await sleep();
    out.push('TSSUBMIT RAN | ' + window.__ran.join(' ;; '));
    window.__emit(window.__lastId, { t: 'ask', id: 'tailscale-api-token', prompt: 't: ', default: '', secret: 1 });
    out.push('TSSUBMIT ANSWERS | ' + window.__answers.join(' ;; '));
    window.__emit(window.__lastId, { t: 'line', kind: 'info', text: 'Tailscale API token (NOT an auth key): https://…' });
    window.__emit(window.__lastId, { t: 'line', kind: 'fail', text: 'Tailscale rejected that token (401) - nothing was saved' });
    window.__emit(window.__lastId, { t: 'exit', rc: 1 });
    await sleep(); await sleep();
    out.push('TSFAIL | open=' + tsdlg.open + ' err=' + document.getElementById('onefield-err').textContent.replace(/\s+/g, ' ').trim());
    document.getElementById('onefield-input').value = 'tskey-api-good';
    document.getElementById('onefield-go').click();
    await sleep();
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await sleep(); await sleep();
    out.push('TSOKCLOSE | ' + tsdlg.open);

    // --- the Tailscale sign-in, from the window --------------------------
    // The button only exists when there is a way to be root: `tailscale up`
    // needs it, and in a window that means polkit.
    paintDeps({ tools: [], package_manager: 'pacman', root: null,
                root_blocked: 'no terminal, and polkit (pkexec) is not installed',
                tailscale_signed_in: false });
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: false, node: null });
    out.push('NOROOT SIGNIN | ' + document.getElementById('tskey-signin-go').hidden);
    paintDeps({ tools: [], package_manager: 'pacman', root: 'pkexec', root_blocked: null,
                tailscale_signed_in: false });
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: false, node: null });
    out.push('SIGNEDOUT SIGNIN | ' + document.getElementById('tskey-signin-go').hidden);
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: true, node: 'laptop' });
    out.push('SIGNEDIN SIGNIN | ' + document.getElementById('tskey-signin-go').hidden);

    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: false, node: null });
    window.__ran = [];
    document.getElementById('tskey-signin-go').click();
    await sleep();
    const tsup = document.getElementById('rundlg');
    out.push('SIGNIN DIALOG | ' + tsup.open);
    out.push('SIGNIN STATUS | ' + document.getElementById('rundlg-status').textContent.replace(/\s+/g, ' ').trim());
    out.push('SIGNIN BUTTONS | cancel=' + document.getElementById('rundlg-cancel').hidden
             + ' done=' + document.getElementById('rundlg-done').hidden
             + ' retry=' + document.getElementById('rundlg-retry').hidden);
    out.push('SIGNIN RAN | ' + window.__ran.join(' ;; '));
    out.push('SIGNIN LINK EARLY | ' + document.getElementById('rundlg-link').hidden);
    // cg relays what `tailscale up` printed while it is still waiting.
    window.__emit(window.__lastId, { t: 'line', kind: 'info', text: 'finishing the sign-in needs a browser - the link appears below' });
    window.__emit(window.__lastId, { t: 'line', kind: 'info', text: 'sign in here: https://login.tailscale.com/a/abc123def456' });
    out.push('SIGNIN LINKNOW | ' + document.getElementById('rundlg-link').hidden);
    out.push('SIGNIN LOG | ' + document.getElementById('rundlg-log').textContent.replace(/\s+/g, ' ').trim());
    window.__opened = [];
    document.getElementById('rundlg-link').click();
    out.push('SIGNIN OPENED | ' + window.__opened.join(' ;; '));
    out.push('SIGNIN WAITING | ' + document.getElementById('rundlg-status').textContent.replace(/\s+/g, ' ').trim());
    // Signed in: the card behind has already been re-read, so the dialog only
    // has to say so and get out of the way.
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: true, node: 'laptop' });
    window.__emit(window.__lastId, { t: 'exit', rc: 0 });
    await sleep(); await sleep();
    out.push('SIGNIN OKSTATUS | ' + document.getElementById('rundlg-status').textContent.replace(/\s+/g, ' ').trim());
    out.push('SIGNIN OKBUTTONS | cancel=' + document.getElementById('rundlg-cancel').hidden
             + ' done=' + document.getElementById('rundlg-done').hidden
             + ' label=' + document.getElementById('rundlg-done').textContent.trim()
             + ' link=' + document.getElementById('rundlg-link').hidden);
    document.getElementById('rundlg-done').click();
    await new Promise(r => setTimeout(r, 400));     // its closing motion
    out.push('SIGNIN CLOSED | ' + tsup.open);

    // Cancelling has to reach cg: tailscale up is waiting on a browser that is
    // never going to answer.
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: false, node: null });
    window.__cancelled = [];
    window.cg.cancel = id => { window.__cancelled.push(id); return Promise.resolve(true); };
    document.getElementById('tskey-signin-go').click();
    await sleep();
    document.getElementById('rundlg-cancel').click();
    out.push('SIGNIN CANCEL | cancelled=' + window.__cancelled.join(',') + ' open=' + tsup.open);
    window.__emit(window.__lastId, { t: 'exit', rc: 130 });
    await sleep(); await sleep();

    // What the window looked like when the sign-in did nothing: the panel is
    // the place that was asked to show the answer, so it is the place that has
    // to show a refusal, a stderr line nobody wrapped in an event, and an exit.
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: false, node: null });
    document.getElementById('tskey-signin-go').click();
    await sleep();
    // pkexec with no polkit agent says this on plain stderr - no cg event.
    window.__emit(window.__lastId, { t: 'raw', stream: 'stderr',
      text: 'Error executing command as another user: No authentication agent found.' });
    window.__emit(window.__lastId, { t: 'exit', rc: 127 });
    await sleep(); await sleep();
    out.push('SIGNIN DEAD | ' + document.getElementById('rundlg-log').textContent.replace(/\s+/g, ' ').trim());
    out.push('SIGNIN DEADSTATUS | ' + document.getElementById('rundlg-status').textContent.replace(/\s+/g, ' ').trim());
    out.push('SIGNIN DEADBUTTONS | cancel=' + document.getElementById('rundlg-cancel').hidden
             + ' retry=' + document.getElementById('rundlg-retry').hidden
             + ' done=' + document.getElementById('rundlg-done').textContent.trim());
    document.getElementById('rundlg-done').click();

    // And a run that was refused because something else holds the lock.
    const realRun = window.cg.run;
    window.cg.run = () => Promise.resolve({ ok: false, reason: 'busy', args: ['init'] });
    document.getElementById('tskey-signin-go').click();
    await sleep(); await sleep();
    out.push('SIGNIN BUSY | ' + document.getElementById('rundlg-log').textContent.replace(/\s+/g, ' ').trim());
    out.push('SIGNIN BUSYBTN | ' + document.getElementById('tskey-signin-go').disabled);
    window.cg.run = realRun;

    paintDeps({ tools: [], package_manager: 'pacman', root: 'pkexec', root_blocked: null,
                tailscale_signed_in: true });
    paintTskey({ present: false, valid: null, state: 'absent', detail: null,
                 signed_in: true, node: 'laptop', auth_key_stored: false, can_mint: false });
    paintCreds({ cli: false, source: null, key_id: null, account: null, arn: null,
                 valid: null, error: 'The AWS CLI is not installed' });
    paintStatus(status('no-cli'));
    // On a screen other than the dashboard, with the CLI gone and then the key
    // rejected: no strip appears above the page - setup checked these once.
    document.querySelector('.nav-item[data-view="logs"]').click();
    out.push('NOCLI STRIP | ' + !!document.getElementById('banner')
             + ' ' + document.querySelector('main').innerText.includes('The AWS CLI is not installed'));
    paintCreds({ cli: true, source: 's', key_id: '****1234', account: null, arn: null,
                 valid: false, error: 'InvalidClientTokenId' });
    paintStatus(status('rejected'));
    out.push('BAD STRIP | ' + !!document.getElementById('banner')
             + ' ' + document.querySelector('main').innerText.includes('AWS rejected this access key'));
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
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "creds-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. no AWS CLI: the card says so, and offers the install"
contains "the state names the CLI"      "$(row 'NOCLI STATE')" "The AWS CLI is not installed"
contains "  and that it is installed here" "$(row 'NOCLI DETAIL')" "Install it, then add your key."
# Installed right here, through the same password dialog setup uses - there is
# no Dependencies page to send anyone to any more. Drawing the card runs nothing.
contains "the button installs it"      "$(row 'NOCLI BTN')"    "Install "
check    "  and pressed, runs the install" "$(row 'NOCLI RAN')" "NOCLI RAN | deps install aws"
lacks    "  it installs nothing itself" "$(row 'NOCLI RAN')"   "check --fix"
lacks    "  and sets no key"            "$(row 'NOCLI RAN')"   "creds set"
# Nothing was rejected: there was nothing to reject it with.
lacks    "nothing is called rejected"  "$(row 'NOCLI STATE')"  "reject"

echo "2. a key AWS would not take"
contains "the key is named, masked"    "$(row 'BAD STATE')"   "****1234"
contains "  and called rejected"       "$(row 'BAD STATE')"   "rejected"
contains "  with AWS's reason"         "$(row 'BAD DETAIL')"  "InvalidClientTokenId"
contains "the button asks for a key"   "$(row 'BAD BTN')"     "Update access key"
# The button opens the form; cg runs when the form is submitted.
check    "  and runs nothing yet"      "$(row 'BAD RAN')"     "BAD RAN | "

echo "3. a key that works"
contains "it says which key"           "$(row 'OK STATE')"    "****5678"
contains "  that it works"             "$(row 'OK STATE')"    "is working"
# The account is the point: a key that works for the WRONG account looks
# perfectly healthy on every other screen.
contains "  and for which account"     "$(row 'OK DETAIL')"   "account 123456789012"
# The ARN and the credentials file are plumbing; the account number is the
# one fact that catches a key for the wrong account.
lacks    "  not the ARN"               "$(row 'OK DETAIL')"   "user/example"
lacks    "  nor the file it came from" "$(row 'OK DETAIL')"   "~/.aws"

echo "4. no warning strip above the pages"
# There was one; setup checks all of this before the app is usable, and a
# strip for a breakage that rarely comes was judged not worth its place.
check    "a missing CLI shows none"    "$(row 'NOCLI STRIP')" "NOCLI STRIP | false false"
check    "  nor a rejected key"        "$(row 'BAD STRIP')"   "BAD STRIP | false false"

echo "4b. the key is one form, and it says what happened"
# It used to be two prompts in a row with the failure landing in the log pane
# behind them - so a rejected key looked like nothing had happened at all.
check    "the button opens a form"     "$(row 'FORM OPEN')"    "FORM OPEN | true"
contains "  with both halves"          "$(row 'FORM FIELDS')"  "id=text secret=password"
contains "an empty form says so"       "$(row 'EMPTY ERR')"    "are both required"
check    "  and runs nothing"          "$(row 'EMPTY RAN')"    "EMPTY RAN | "
check    "  staying open"              "$(row 'EMPTY OPEN')"   "EMPTY OPEN | true"
check    "submitting runs cg creds set" "$(row 'SUBMIT RAN')"  "SUBMIT RAN | creds set"
contains "  the button shows it is working" "$(row 'SUBMIT BTN')" "Checking with AWS"
contains "  and cannot be pressed twice"    "$(row 'SUBMIT BTN')" "disabled=true"
# cg still asks its two questions; the form answers them, so no second modal
# appears on top of the one being looked at.
check    "the form answers cg's questions" "$(row 'SUBMIT ANSWERS')" "SUBMIT ANSWERS | AKIABADBADBADBAD9999 ;; bad-secret"
check    "  with no extra prompt"      "$(row 'SUBMIT MODALS')" "SUBMIT MODALS | false"
check    "a rejected key keeps the form open" "$(row 'FAIL OPEN')" "FAIL OPEN | true"
contains "  showing AWS's reason there" "$(row 'FAIL ERR')"    "InvalidClientTokenId"
contains "  and that nothing was saved" "$(row 'FAIL ERR')"    "nothing was saved"
# The line telling you where to find a key is noise when you are holding one.
lacks    "  without the how-to line"   "$(row 'FAIL ERR')"     "paste an access key"
contains "  and the button comes back" "$(row 'FAIL BTN')"     "Connect disabled=false"
check    "saved, it stays to check the key back" "$(row 'OK CHECKING')" "OK CHECKING | true Connected. Checking… reading=true"
check    "a key that works closes it"  "$(row 'OK OPEN')"      "OK OPEN | false"

echo "4c. Tailscale is its own card, and fails in two ways"
# Signed in with no token is normal; a token with no sign-in is useless. They
# are separate facts and the card shows both.
contains "no token says what is given up" "$(row 'TSNONE TS')" "No access token"
contains "  while signed in is fine"      "$(row 'TSNONE TS')" "Signed in as laptop"
contains "  and the button offers to set" "$(row 'TSNONE TS')" "Add access token"
contains "a rejected token says so"       "$(row 'TSBAD TS')"  "Access token was rejected"
contains "  offering to replace it"       "$(row 'TSBAD TS')"  "Update access token"
# Unreachable is not rejected: a new token is not the fix for a flat network.
contains "unreachable is not rejected"    "$(row 'TSDOWN TS')" "Tailscale did not respond"
lacks    "  and is not called rejected"   "$(row 'TSDOWN TS')" "rejected"
contains "  signed out is said plainly"   "$(row 'TSDOWN TS')" "Not signed in"
contains "a working token"                "$(row 'TSOK TS')"   "Access token is working"

echo "4c2. the box's own key, which is not the token"
# `tailscale up` takes a node registration key and will not take the API token,
# and the token must not travel in user-data where the auth key has to live. So
# the card says where the box's key comes from, which is what decides whether a
# build stops to ask for one.
contains "no token: the build will ask"  "$(row 'TSNONE TS')"  "The next build asks for one"
contains "a token mints it"              "$(row 'TSOK TS')"    "generated from the access token at the next build"
contains "a stored key is checked"       "$(row 'TSKEPT TS')"  "Auth key saved"

echo "4d. the token form, like the key form"
contains "it opens, as a password field"  "$(row 'TSFORM OPEN')" "true type=password"
contains "an empty one says so"           "$(row 'TSEMPTY')"     "Required."
contains "  running nothing"              "$(row 'TSEMPTY')"     "ran="
check    "submitting runs the set"        "$(row 'TSSUBMIT RAN')" "TSSUBMIT RAN | creds set tailscale"
check    "  answering cg's question"      "$(row 'TSSUBMIT ANSWERS')" "TSSUBMIT ANSWERS | tskey-api-nope"
contains "a refusal stays in the form"    "$(row 'TSFAIL')"      "open=true"
contains "  with Tailscale's reason"      "$(row 'TSFAIL')"      "rejected that token (401)"
lacks    "  without the how-to line"      "$(row 'TSFAIL')"      "NOT an auth key"
check    "a good token closes it"         "$(row 'TSOKCLOSE')"   "TSOKCLOSE | false"

echo "4e. signing in to Tailscale from the window"
# `sudo tailscale up` is not an answer in a window, and a button that cannot
# become root is worse than the sentence telling you what to type.
check    "no way to be root: no button" "$(row 'NOROOT SIGNIN')"    "NOROOT SIGNIN | true"
check    "signed out, with polkit: a button" "$(row 'SIGNEDOUT SIGNIN')" "SIGNEDOUT SIGNIN | false"
check    "already signed in: no button" "$(row 'SIGNEDIN SIGNIN')"  "SIGNEDIN SIGNIN | true"
check    "it runs the sign-in"          "$(row 'SIGNIN RAN')"       "SIGNIN RAN | creds tailscale signin"
# The URL only exists WHILE the command waits on it, so the link cannot appear
# before it is printed and must appear the moment it is.
check    "no link before one is printed" "$(row 'SIGNIN LINK EARLY')" "SIGNIN LINK EARLY | true"
check    "  and one as soon as it is"    "$(row 'SIGNIN LINKNOW')"   "SIGNIN LINKNOW | false"
contains "what cg said is shown"         "$(row 'SIGNIN LOG')"       "the link appears below"
check    "the link opens that URL"       "$(row 'SIGNIN OPENED')"    "SIGNIN OPENED | https://login.tailscale.com/a/abc123def456"

echo "4f. a sign-in that goes nowhere says so"
# "starting…" and then silence is what a dead run looked like: pkexec's own
# complaint is plain stderr, not a cg event, so the panel never showed it.
contains "stderr reaches the panel"    "$(row 'SIGNIN DEAD')"    "No authentication agent found"
lacks    "  with no stale starting line" "$(row 'SIGNIN DEAD')"  "starting -"
contains "  the status says it failed" "$(row 'SIGNIN DEADSTATUS')" "Sign-in failed"
contains "  offering another go"        "$(row 'SIGNIN DEADBUTTONS')" "retry=false"
contains "  and a way out"              "$(row 'SIGNIN DEADBUTTONS')" "done=Close"
# A write is refused outright while anything else runs - it is not queued - and
# the only sign of that used to be a line in the header.
# Named, not spelled: "cg init" is the command, "the build" is the thing that
# is keeping you waiting - see CG_WORDS.
contains "a refusal says what holds it" "$(row 'SIGNIN BUSY')"   "Waiting for the build to finish"
contains "  and the dialog says so too" "$(row 'SIGNIN BUSY')" "Waiting for the build to finish"
lacks    "  without spelling the command" "$(row 'SIGNIN BUSY')" "cg init is still"

echo "4g. the sign-in dialog, start to end"
# `tailscale up` prints a link and then waits for a browser. That is a thing
# happening, not a state to read, so it is in front of you while it happens.
check    "the button opens a dialog"   "$(row 'SIGNIN DIALOG')"  "SIGNIN DIALOG | true"
contains "  saying what comes first"   "$(row 'SIGNIN STATUS')"  "password prompt may open behind this window"
contains "  warning it can be behind"  "$(row 'SIGNIN STATUS')"  "behind this window"
contains "only Cancel while it runs"   "$(row 'SIGNIN BUTTONS')" "cancel=false done=true retry=true"
contains "the wait is explained"       "$(row 'SIGNIN WAITING')" "Complete sign-in in your browser"
contains "signed in says who"          "$(row 'SIGNIN OKSTATUS')" "signed in as laptop"
contains "  Cancel goes away"          "$(row 'SIGNIN OKBUTTONS')" "cancel=true"
contains "  Done appears"              "$(row 'SIGNIN OKBUTTONS')" "done=false label=Done"
contains "  and the dead link goes"    "$(row 'SIGNIN OKBUTTONS')" "link=true"
check    "Done closes it"              "$(row 'SIGNIN CLOSED')"  "SIGNIN CLOSED | false"
# Closing the dialog does not tell cg anything: the command is still waiting on
# a browser that is never going to answer.
contains "Cancel reaches cg"           "$(row 'SIGNIN CANCEL')"  "cancelled="
contains "  and closes the dialog"     "$(row 'SIGNIN CANCEL')"  "open=false"

echo "5. nothing threw"
check "no painter threw"               "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors" "$(row 'ERRS')"        "ERRS | "

echo ""
echo "creds-dom: $pass passed, $fail failed"
(( fail == 0 ))
