#!/usr/bin/env bash
# Opening the app, actually rendered: Home in its final layout from the first
# frame, from what it showed last time, and a machine's state only once a live
# check has answered.
#
# What only a render can show:
#   * remembered machines are on screen at once - no blank Home, no welcome
#     flashed over a laptop that has machines, no cards popping in later;
#   * before its check answers, a card is what the machine is and a loading
#     line - no status and nothing to press;
#   * the check starts at launch, not after the machine list comes back;
#   * the answer replaces the loading state in place, with its buttons; a check
#     that fails says so, with Try again;
#   * what a card shows is remembered for next time, never its status.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "home-boot-dom: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

# Last time: two servers, no AWS. Each one's status read is held until the probe
# answers it - as a real one takes seconds - so the first frames can be seen.
cat > "$T/r/stub.js" <<'STUB'
window.__errs = []; window.__ran = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
if (!sessionStorage.getItem('seeded')) {
  sessionStorage.setItem('seeded', '1');
  localStorage.setItem('cg.home', JSON.stringify({ aws: false,
    hosts: [{ name: 'homebox', ssh: 'me@10.0.0.5', os: 'Linux', family: 'ubuntu', user: 'me' },
            { name: 'attic', ssh: 'me@10.0.0.6', os: 'Linux', family: 'arch', user: 'me' }],
    identity: { homebox: { os_name: 'Linux Mint 22.2', gpu: 'NVIDIA GeForce RTX 3060' } } }));
}
const HOSTS = [{ name: 'homebox', ssh: 'me@10.0.0.5', os: 'Linux', family: 'ubuntu', user: 'me' },
               { name: 'attic', ssh: 'me@10.0.0.6', os: 'Linux', family: 'arch', user: 'me' }];
const STATUS = { name: 'homebox', ssh: 'me@10.0.0.5', os: 'Linux', os_name: 'Linux Mint 22.2', family: 'ubuntu',
  tailnet_ip: '100.64.0.7', reachable: true, online: true, sunshine: true, login_ok: true, paired: true,
  set_up: true, desktop: 'x11', steam: true, gpu: 'NVIDIA GeForce RTX 3070' };
const tool = (tool, present) => ({ tool, label: tool, present, why: null, plan: null, manual: null, for: 'all' });
function reply(a) {
  if (a === 'deps --json') return { out: { tools: [tool('ssh', true), tool('tailscale', true), tool('moonlight', true)],
    package_manager: 'pacman', root: 'sudo', root_blocked: null, tailscale_signed_in: true } };
  if (a === 'creds --json') return { out: { cli: false, valid: null, reason: 'no-cli' } };
  if (a === 'creds tailscale --json') return { out: { signed_in: true, node: 'laptop', auth_key_stored: true, can_mint: false } };
  if (a === 'config --json') return { out: [{ key: 'GAME_REGION', kind: 'region', rule: null, default: 'ap-south-2', group: 'The box',
    note: '', label: 'region', secret: false, is_set: false, value: null, effective: 'ap-south-2' }] };
  if (a === 'host list --json') return { out: HOSTS, delay: 150 };
  if (a.startsWith('host status ')) return { held: a.split(' ')[2] };
  return { rc: 1, lines: ['the stub does not know: ' + a] };
}
let handler = null, next = 0;
const emit = (id, event) => handler && handler({ id, event });
window.__release = {};
window.cg = {
  run: args => {
    const a = args.join(' '); window.__ran.push(a);
    const id = ++next, r = reply(a);
    setTimeout(() => {
      if (r.held) {
        window.__release[r.held] = ok => {
          if (ok) emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(STATUS) });
          else emit(id, { t: 'error', text: 'attic did not answer over ssh' });
          emit(id, { t: 'exit', rc: ok ? 0 : 1 });
        };
        return;
      }
      for (const text of r.lines || []) emit(id, { t: 'line', text });
      if (r.out !== undefined) emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(r.out) });
      emit(id, { t: 'exit', rc: r.rc || 0 });
    }, r.delay || 5);
    return Promise.resolve({ ok: true, id, write: false });
  },
  answer: () => Promise.resolve(true),
  cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]), asks: () => Promise.resolve([]), engine: () => Promise.resolve({ found: true }),
  onEvent(cb) { handler = cb; return () => {}; },
};
STUB

cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const txt = e => (e ? e.textContent.replace(/\s+/g, ' ').trim() : '(missing)');
  const $$ = id => document.getElementById(id);
  const shown = id => ($$(id).hidden ? 'hidden' : 'shown');
  const card = n => document.querySelector(`#d-hosts [data-host="${n}"]`);
  const buttons = root => (root ? [...root.querySelectorAll('button')].map(b => b.textContent.trim()).join(', ') : '(missing)');
  try {
    // The first frame: before any read has answered.
    out.push('FIRST | welcome=' + shown('d-welcome') + ' machines=' + shown('d-machines')
             + ' cards=' + document.querySelectorAll('#d-hosts [data-host]').length);
    out.push('FIRST CARD | ' + (card('homebox') || {}).dataset?.state + ' ' + txt(card('homebox')));
    out.push('FIRST BUTTONS | ' + buttons(card('homebox')));
    await wait(60);
    const iStatus = window.__ran.indexOf('host status homebox --json');
    const iList = window.__ran.indexOf('host list --json');
    out.push('ORDER | status=' + (iStatus >= 0) + ' before-list=' + (iStatus >= 0 && iStatus < iList));
    await wait(300);
    // The list has answered; the checks have not.
    out.push('LISTED | ' + (card('homebox') || {}).dataset?.state + ' buttons=' + buttons(card('homebox'))
             + ' welcome=' + shown('d-welcome'));
    out.push('ASKED ONCE | ' + window.__ran.filter(a => a === 'host status homebox --json').length);
    window.__release.homebox(true);
    await wait(50);
    out.push('ANSWERED | ' + card('homebox').dataset.state + ' fade=' + card('homebox').classList.contains('card-in')
             + ' / ' + txt(card('homebox')));
    out.push('ANSWERED BUTTONS | ' + buttons(card('homebox')));
    out.push('OTHER STILL | ' + card('attic').dataset.state + ' buttons=' + buttons(card('attic')));
    window.__release.attic(false);
    await wait(50);
    out.push('FAILED | ' + card('attic').dataset.state + ' / ' + txt(card('attic')));
    out.push('FAILED BUTTONS | ' + buttons(card('attic')));
    const kept = JSON.parse(localStorage.getItem('cg.home'));
    out.push('KEPT | ' + kept.hosts.map(h => h.name).join(',') + ' gpu=' + kept.identity.homebox.gpu
             + ' status=' + JSON.stringify(kept).includes('set_up'));
  } catch (e) { out.push('THREW | ' + e.message + ' ' + (e.stack || '').split('\n')[1]); }
  out.push('ERRS | ' + window.__errs.join(' ;; '));
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

# Dumped to a file, not piped: see login-dom.sh for the 10-25 seconds a pipe costs.
"$BROWSER" --headless --disable-gpu --no-sandbox --virtual-time-budget=20000 --window-size=1280,900 \
  --user-data-dir="$T/chrome" --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
OUT=$(python3 -I -c '
import re, sys, html
d = open(sys.argv[1]).read()
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", d, re.S)
print(html.unescape(m.group(1)) if m else "PROBE DID NOT RUN")' "$T/dom.html")

[[ -n ${CG_DOM_DUMP:-} ]] && { printf '%s\n' "$OUT"; exit 0; }
if [[ $OUT == "PROBE DID NOT RUN" || -z $OUT ]]; then
  echo "  FAIL the page did not render at all"; echo; echo "home-boot-dom: $pass passed, 1 failed"; exit 1
fi
row() { grep "^$1 |" <<<"$OUT" | head -1; }

echo "1. the first frame is the final layout"
check    "remembered machines are there at once, no welcome" "$(row 'FIRST')" "FIRST | welcome=hidden machines=shown cards=2"
contains "  a card is loading"                    "$(row 'FIRST CARD')" "FIRST CARD | loading"
contains "  naming what the machine is"           "$(row 'FIRST CARD')" "Linux Mint 22.2 · NVIDIA GeForce RTX 3060"
contains "  and that it is connecting"            "$(row 'FIRST CARD')" "Connecting to homebox…"
check    "  with nothing to press"                "$(row 'FIRST BUTTONS')" "FIRST BUTTONS | "
check    "its check starts at launch, before the list returns" "$(row 'ORDER')" "ORDER | status=true before-list=true"

echo "2. the list answers: still loading, asked once"
check    "the list changes nothing on the card"   "$(row 'LISTED')" "LISTED | loading buttons= welcome=hidden"
check    "  and does not ask a second time"       "$(row 'ASKED ONCE')" "ASKED ONCE | 1"

echo "3. the answer, in place"
contains "the status replaces the loading state" "$(row 'ANSWERED')" "ANSWERED | Ready to play fade=true"
lacks    "  and the loading line is gone"         "$(row 'ANSWERED')" "Connecting to"
contains "  with what cg says the machine is now" "$(row 'ANSWERED')" "NVIDIA GeForce RTX 3070"
check    "  and only now its buttons"             "$(row 'ANSWERED BUTTONS' | tr -cd '[:print:]')" "ANSWERED BUTTONS | Play, Details"
check    "a card still checking is untouched"     "$(row 'OTHER STILL')" "OTHER STILL | loading buttons="
contains "a failed check says so"                 "$(row 'FAILED')" "Check failed"
contains "  with cg's reason"                     "$(row 'FAILED')" "attic did not answer over ssh"
check    "  and only Try again, and its details"  "$(row 'FAILED BUTTONS' | tr -cd '[:print:]')" "FAILED BUTTONS | Try again, Details"
lacks    "  the reason, not a prefix"            "$(row 'FAILED')" "could not run:"

echo "4. what is remembered for next time"
check    "the list and what each is, never a status" "$(row 'KEPT')" "KEPT | homebox,attic gpu=NVIDIA GeForce RTX 3070 status=false"

check "no errors on the page" "$(row 'ERRS')" "ERRS | "
lacks "  and the probe did not throw" "$OUT" "THREW |"

echo; echo "home-boot-dom: $pass passed, $fail failed"
(( fail == 0 ))
