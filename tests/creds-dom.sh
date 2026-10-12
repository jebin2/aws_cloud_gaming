#!/usr/bin/env bash
# The credentials card and the banner, actually rendered.
#
# The banner is what a new laptop reads first, and it used to say "AWS rejected
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
window.cg = {
  run: (args) => { window.__ran.push(args.join(' ')); return Promise.resolve({ ok: true, id: window.__ran.length }); },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  onEvent() { return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(() => {
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
  const bannerRead = label => {
    out.push(label + ' TITLE | ' + g('banner-title'));
    out.push(label + ' BODY | ' + g('banner-body'));
    out.push(label + ' FIXBTN | ' + (document.getElementById('banner-fix').hidden
      ? 'hidden' : g('banner-fix-label')));
    out.push(label + ' BANNER | ' + (document.getElementById('banner').hidden ? 'hidden' : 'shown'));
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
                 valid: null, error: 'the AWS CLI is not installed - cg check --fix installs it' });
    read('NOCLI');
    window.__ran = [];
    document.getElementById('creds-set').click();
    out.push('NOCLI RAN | ' + window.__ran.join(' ;; '));

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

    paintStatus(status('no-cli'));
    bannerRead('NOCLI');
    window.__ran = [];
    document.getElementById('banner-fix').click();
    out.push('NOCLI BANNERRAN | ' + window.__ran.join(' ;; '));

    paintStatus(status('rejected'));
    bannerRead('BAD');
    window.__ran = [];
    document.getElementById('banner-fix').click();
    out.push('BAD BANNERRAN | ' + window.__ran.join(' ;; '));
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
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "creds-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. no AWS CLI: the card says so, and offers the install"
contains "the state names the CLI"      "$(row 'NOCLI STATE')" "the AWS CLI is not installed"
contains "  and where it is installed" "$(row 'NOCLI DETAIL')" "Dependencies page"
contains "the button goes there"       "$(row 'NOCLI BTN')"    "Open Dependencies"
# Not a cg command: switching to the page that CAN install needs no root, while
# a button here that shelled out to sudo had nowhere to ask for a password.
check    "  and runs no command"       "$(row 'NOCLI RAN')"    "NOCLI RAN | "
# Nothing was rejected: there was nothing to reject it with.
lacks    "nothing is called rejected"  "$(row 'NOCLI STATE')"  "reject"

echo "2. a key AWS would not take"
contains "the key is named, masked"    "$(row 'BAD STATE')"   "****1234"
contains "  and called rejected"       "$(row 'BAD STATE')"   "rejected"
contains "  with AWS's reason"         "$(row 'BAD DETAIL')"  "InvalidClientTokenId"
contains "the button asks for a key"   "$(row 'BAD BTN')"     "Set access key"
check    "  by running cg creds set"   "$(row 'BAD RAN')"     "BAD RAN | creds set"

echo "3. a key that works"
contains "it says which key"           "$(row 'OK STATE')"    "****5678"
contains "  that it works"             "$(row 'OK STATE')"    "works"
# The account is the point: a key that works for the WRONG account looks
# perfectly healthy on every other screen.
contains "  and for which account"     "$(row 'OK DETAIL')"   "account 123456789012"
contains "  with the identity"         "$(row 'OK DETAIL')"   "user/example"
contains "  and where it came from"    "$(row 'OK DETAIL')"   "from ~/.aws/credentials"

echo "4. the banner names the right cause"
check    "it is shown"                 "$(row 'NOCLI BANNER')" "NOCLI BANNER | shown"
contains "no CLI is not a bad key"     "$(row 'NOCLI TITLE')"  "The AWS CLI is not installed"
contains "  pointing at the page"      "$(row 'NOCLI BODY')"   "Dependencies page does that"
lacks    "  and does not say rejected" "$(row 'NOCLI TITLE')"  "rejected"
contains "  its button goes to the page" "$(row 'NOCLI FIXBTN')" "Open Dependencies"
check    "  and runs no command"       "$(row 'NOCLI BANNERRAN')" "NOCLI BANNERRAN | "
contains "a rejected key says so"      "$(row 'BAD TITLE')"    "AWS rejected these credentials"
contains "  its button sets a key"     "$(row 'BAD FIXBTN')"   "Set AWS key"
check    "  running cg creds set"      "$(row 'BAD BANNERRAN')" "BAD BANNERRAN | creds set"
# The old text sent people to a Settings screen that had no field for a key.
contains "and it points at Settings"   "$(row 'BAD BODY')"     "Settings has the same button"

echo "5. nothing threw"
check "no painter threw"               "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors" "$(row 'ERRS')"        "ERRS | "

echo ""
echo "creds-dom: $pass passed, $fail failed"
(( fail == 0 ))
