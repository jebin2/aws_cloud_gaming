#!/usr/bin/env bash
# Machines in the app, actually rendered: a new laptop with no AWS at all,
# against a stub cg, from the first open to a server of its own being set up.
#
# What only a render can show:
#   * there is no setup screen: Home opens, and with no machines it asks the one
#     question - AWS, or a server of yours - and asks AWS nothing;
#   * adding a server walks this laptop's steps (never the AWS CLI), then the
#     server - its password asked once, hidden, in the form itself - then
#     setting it up, which happens on its card while the app stays usable;
#   * the card, and its detail: what it is ready for, each check, its actions;
#   * adding AWS walks AWS's own steps; an AWS machine that needs something says
#     so on its card, with the button that reopens them;
#   * a setup in flight is not cancelled by Try again, which cancels reads.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "hosts-dom: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

# A laptop with no AWS: the AWS CLI missing, no key, no region - signed in to
# Tailscale, with a machine key. cg's answers by command. `host add` asks for
# the server's password and finishes once it is answered; `config set` and
# `host add` change what later reads say, as they would.
cat > "$T/r/stub.js" <<'STUB'
window.__errs = []; window.__ran = []; window.__answers = []; window.__cancelled = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
const S = { region: false, hosts: [] };
const tool = (tool, present, extra) => ({ tool, label: tool, present, why: null, plan: null, manual: null, for: 'all', ...extra });
const CONFIG = () => [
  { key: 'GAME_REGION', kind: 'region', rule: null, default: 'ap-south-2', group: 'The box', note: '', label: 'region',
    secret: false, is_set: S.region, value: S.region ? 'ap-south-1' : null, effective: S.region ? 'ap-south-1' : 'ap-south-2' },
  { key: 'EMAIL_ALERTS', kind: 'email', rule: null, default: null, group: 'Notifications', note: '', label: 'alerts',
    secret: false, is_set: false, value: null, effective: null },
  { key: 'GAME_DISK_GB', kind: 'number', rule: '30', default: '50', group: 'The box', note: '', label: 'disk',
    secret: false, is_set: false, value: null, effective: '50' },
];
const STATUS = { name: 'homebox', ssh: 'me@10.0.0.5', os: 'Linux', os_name: 'Linux Mint 22.2', family: 'ubuntu',
  tailnet_ip: '100.64.0.7', reachable: true, online: true, sunshine: true, login_ok: true, paired: true,
  set_up: false, desktop: 'x11', steam: true, gpu: 'NVIDIA GeForce RTX 3060' };
function reply(a) {
  if (a === 'deps --json') return { out: { tools: [tool('python3', true), tool('ssh', true), tool('curl', true),
    tool('aws', false, { for: 'aws', label: 'the AWS CLI' }), tool('tailscale', true), tool('moonlight', true)],
    package_manager: 'pacman', root: 'sudo', root_blocked: null, tailscale_signed_in: true } };
  if (a === 'creds --json') return { out: { cli: false, valid: null, reason: 'no-cli' } };
  if (a === 'creds tailscale --json') return { out: { signed_in: true, node: 'laptop', auth_key_stored: true, can_mint: false } };
  if (a === 'config --json') return { out: CONFIG() };
  if (a === 'host list --json') return { out: S.hosts };
  if (a.startsWith('deps install')) return {};
  if (a === 'host add --ssh me@10.0.0.5') return {
    lines: ['reaching me@10.0.0.5 over ssh'],
    ask: { t: 'ask', id: 'host-ssh-password', prompt: '  password for me@10.0.0.5: ', default: '', secret: 1 },
    afterAnswer: () => { S.hosts = [{ name: 'homebox', ssh: 'me@10.0.0.5', os: 'Linux', family: 'ubuntu', user: 'me' }];
                         return ["added 'homebox'. Next: cg host setup homebox"]; } };
  // Slow, as an ssh round trip and a Sunshine check are.
  if (a === 'host status homebox --json') return { out: STATUS, delay: 300 };
  // Removing it: cg says whether the key came off, and forgets it either way.
  if (a === 'host remove homebox') { S.hosts = [];
    return { lines: S.removeDown
      ? ["could not reach it to take cg's key off - that one line stays in its ~/.ssh/authorized_keys", "forgot 'homebox'"]
      : ["took cg's key off it", "forgot 'homebox' - nothing else on the machine was changed"] }; }
  // Setup asks for sudo, then keeps going until the probe lets it finish.
  if (a === 'host setup homebox') return { ask: { t: 'ask', id: 'host-sudo', prompt: '  sudo password for me@10.0.0.5: ', default: '', secret: 1 },
    afterAnswer: Object.assign(() => ['>>> installing sunshine'], { hold: true }) };
  return { rc: 1, lines: ['the stub does not know: ' + a] };
}
let handler = null, next = 0;
const waiting = new Map();
const emit = (id, event) => handler && handler({ id, event });
window.cg = {
  run: args => {
    const a = args.join(' '); window.__ran.push(a);
    const id = ++next, r = reply(a);
    setTimeout(() => {
      for (const text of r.lines || []) emit(id, { t: 'line', text });
      if (r.out !== undefined) emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(r.out) });
      if (r.ask) emit(id, r.ask);
      if (r.afterAnswer) { waiting.set(id, r.afterAnswer); return; }
      if (!r.stay) emit(id, { t: 'exit', rc: r.rc || 0 });
    }, r.delay || 5);
    return Promise.resolve({ ok: true, id, write: false });
  },
  answer: (id, v) => {
    window.__answers.push(v);
    const then = waiting.get(id);
    if (then) { waiting.delete(id);
      setTimeout(() => { for (const text of then()) emit(id, { t: 'line', text });
        if (then.hold) window.__finish = () => emit(id, { t: 'exit', rc: 0 }); else emit(id, { t: 'exit', rc: 0 }); }, 5); }
    return Promise.resolve(true);
  },
  cancel: id => { window.__cancelled.push(id); return Promise.resolve(true); },
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
  const nav = () => [...document.querySelectorAll('.nav-item')].filter(n => !n.hidden).map(n => n.dataset.view).join(',');
  const stages = () => [...document.querySelectorAll('#onb-steps [data-stage]')].map(r => r.dataset.stage + ':' + r.dataset.state).join(' ');
  const buttons = root => [...root.querySelectorAll('button')].map(b => b.textContent.trim() + (b.disabled ? '(off)' : '')).join(', ');
  const button = (root, text) => [...root.querySelectorAll('button')].find(b => b.textContent.trim() === text);
  // The ask dialog's close handler, invoked directly: under virtual time the
  // close event can land after the next timer (see login-dom.sh).
  // Detached first, so the browser's own close event cannot answer a second time.
  const answer = v => { const d = $$('ask'); $$('ask-input').value = v; const h = d.onclose; d.onclose = null; d.close(); if (h) h(); };
  const AWS = /^(status|watcher|machines|sweep|library|cost|creds set|quota)\b/;
  try {
    await wait(400);
    out.push('OPEN WELCOME | ' + shown('d-welcome') + ' machines=' + shown('d-machines'));
    out.push('OPEN NAV | ' + nav());
    out.push('OPEN SETUP | ' + document.body.classList.contains('setup') + ' dialog=' + $$('adddlg').open);
    out.push('OPEN AWS | ' + window.__ran.filter(a => AWS.test(a)).join(', '));

    button($$('d-welcome'), 'Choose') && [...$$('d-welcome').querySelectorAll('[data-add="host"]')][0].click();
    await wait(300);
    out.push('ADD DIALOG | ' + $$('adddlg').open + ' ' + txt($$('onb-title')));
    out.push('ADD STAGES | ' + stages());
    // Moonlight missing as well as the AWS CLI: Install is for what a server needs.
    const deps = depsNow;
    depsNow = { ...deps, tools: deps.tools.map(t => t.tool === 'moonlight' ? { ...t, present: false } : t) };
    paintOnboard();
    button(document.querySelector('[data-stage="tools"]'), 'Install').click();
    await wait(100);
    out.push('INSTALL RAN | ' + window.__ran.filter(a => a.startsWith('deps install')).join(', '));
    depsNow = deps;
    paintOnboard();
    $$('add-addr').value = '10.0.0.5';
    $$('add-user').value = 'me';
    out.push('PW FIELDS | ' + [...serverForm.querySelectorAll('input')].map(i => i.id).join(','));
    out.push('PW UPFRONT | ' + !$$('add-pw-row').hidden);
    button(document.querySelector('[data-stage="server"]'), 'Connect').click();
    await wait(200);
    out.push('PW RAN | ' + window.__ran.filter(a => a.startsWith('host add')).join(', '));
    out.push('PW OPEN | ' + $$('ask').open);
    out.push('PW SHOWN | ' + !$$('add-pw-row').hidden + ' in-step:' + !!document.querySelector('[data-stage="server"] #add-pw'));
    out.push('PW PROMPT | ' + txt($$('add-pw-row')));
    out.push('PW INPUT | ' + $$('add-pw').type);
    out.push('PW BUTTONS | ' + buttons(document.querySelector('[data-stage="server"]')));
    button(document.querySelector('[data-stage="server"]'), 'Continue').click();
    await wait(50);
    out.push('PW EMPTY | ' + window.__answers.length);
    $$('add-pw').value = 'letmein';
    button(document.querySelector('[data-stage="server"]'), 'Continue').click();
    await wait(150);
    // Added, its status still on the way: the step waits for it.
    out.push('SERVER MID | ' + stages() + ' / ' + buttons(document.querySelector('[data-stage="server"]')));
    await wait(400);
    out.push('PW CLEARED | ' + serverForm.querySelector('#add-pw').value);
    out.push('PW ANSWER | ' + window.__answers.join(','));
    out.push('SERVER STAGES | ' + stages());
    out.push('SERVER DONE | ' + txt(document.querySelector('[data-stage="server"]')));
    out.push('SERVER BUTTONS | ' + buttons(document.querySelector('[data-stage="setup"]')));

    button(document.querySelector('[data-stage="setup"]'), 'Set up').click();
    await wait(300);
    out.push('SETUP DIALOG | ' + $$('adddlg').open);
    out.push('SETUP RAN | ' + window.__ran.filter(a => a.startsWith('host setup')).join(', '));
    out.push('SETUP STATE | ' + document.querySelector('[data-stage="setup"]').dataset.state
             + ' log=' + !$$('onb-log-setup').hidden);
    out.push('SUDO POPUP | ' + $$('pwdlg').open + ' generic=' + $$('ask').open + ' / ' + txt($$('pwdlg-title')) + ' / ' + txt($$('pwdlg-sub')));
    out.push('SUDO FIELD | ' + (document.activeElement && document.activeElement.id) + ' ' + $$('pwdlg-input').type
             + ' continue-off=' + $$('pwdlg-yes').disabled);
    out.push('SUDO LIVE | ' + txt($$('onb-live-setup')));
    out.push('SUDO BEHIND | ' + $$('adddlg').open);
    // Esc on the add dialog is stopped at the key.
    const esc = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
    $$('adddlg').dispatchEvent(esc);
    out.push('ESC | stopped=' + esc.defaultPrevented);
    $$('pwdlg-input').value = 'hunter2';
    $$('pwdlg-input').dispatchEvent(new Event('input'));
    $$('pwdlg-yes').click();
    await wait(100);
    out.push('SUDO ANSWER | ' + window.__answers.includes('hunter2') + ' closed=' + !$$('pwdlg').open
             + ' cleared=' + ($$('pwdlg-input').value === ''));
    out.push('SETUP LIVE | ' + txt($$('onb-live-setup')) + ' open=' + $$('adddlg').open);
    out.push('HOME WELCOME | ' + shown('d-welcome') + ' machines=' + shown('d-machines') + ' aws=' + shown('d-hero'));
    out.push('HOME NAV | ' + nav());
    out.push('HOME CARD | ' + txt(document.querySelector('#d-hosts [data-host="homebox"]')));
    out.push('HOME ADD | ' + buttons($$('d-addcard')));
    out.push('HOME NET | ' + txt($$('d-ts')));
    out.push('HOME MONEY | ' + shown('d-money') + ' games=' + shown('d-games-card') + ' safety=' + shown('d-protect-card'));

    await retryReads();
    const setupId = window.__ran.indexOf('host setup homebox') + 1;
    out.push('RETRY KEPT | ' + !window.__cancelled.includes(setupId));

    document.querySelector('#d-hosts [data-host="homebox"] [data-f="details"]').click();
    await wait(200);
    out.push('DETAIL VIEW | ' + view + ' aws=' + shown('b-aws') + ' own=' + shown('b-own') + ' title=' + txt($$('view-title')));
    const card = document.querySelector('#b-hosts [data-host="homebox"]');
    out.push('DETAIL CARD | ' + txt(card));
    out.push('DETAIL BUTTONS | ' + buttons(card));
    out.push('NO AWS | ' + window.__ran.filter(a => AWS.test(a)).join(', '));
    window.__finish();
    await wait(200);
    out.push('SETUP DONE | ' + document.querySelector('[data-stage="setup"]').dataset.state + ' open=' + $$('adddlg').open);
    await wait(1200);
    out.push('SETUP CLOSED | ' + $$('adddlg').open);

    goView('dashboard');
    $$('d-add-aws').click();
    await wait(400);
    out.push('AWS DIALOG | ' + txt($$('onb-title')));
    out.push('AWS STAGES | ' + stages());
    out.push('AWS TOOLS | ' + txt($$('onb-tools')));
    $$('adddlg-close').click();
    await wait(50);

    // AWS added - a region chosen - with the AWS CLI still missing.
    S.region = true;
    paintConfig(CONFIG());
    await wait(50);
    out.push('ADDED NAV | ' + nav());
    out.push('ADDED CARD | ' + shown('d-hero') + ' ' + txt($$('d-machine-card')) + ' / '
             + [...$$('d-hero').querySelectorAll('button')].filter(b => !b.hidden).map(b => b.textContent.trim()).join(', '));
    out.push('ADDED ADD | ' + shown('d-add-aws'));
    // A machine that is there is shown as itself, whatever the next build needs.
    statusNow = { box: { id: 'i-1', state: 'running', type: 'g6.xlarge', launched: new Date().toISOString(), ready: true, built: true },
                  rates: {}, budget: {}, config: {}, build: {} };
    paintMachineCards();
    out.push('RUNNING CARD | ' + txt($$('d-machine-card')) + ' fix=' + shown('d-fix'));
    statusNow = null;
    paintMachineCards();
    button($$('d-hero'), 'Finish setting up').click();
    await wait(300);
    out.push('FINISH | ' + $$('adddlg').open + ' ' + txt($$('onb-title')));
    $$('adddlg-close').click();
    await wait(50);

    // Removing it: one dialog asks, runs and reports.
    const vis = id => [...$$(id).querySelectorAll('button')].filter(b => !b.hidden).map(b => b.textContent.trim()).join(', ');
    const removeBtn = () => button(document.querySelector('#b-hosts [data-host="homebox"]'), 'Remove machine');
    goHost('homebox');
    await wait(200);
    removeBtn().click();
    await wait(50);
    out.push('REMOVE ASK | ' + $$('rundlg').open + ' ' + txt($$('rundlg-title')) + ' / ' + txt($$('rundlg-status')) + ' / ' + vis('rundlg'));
    $$('rundlg-cancel').click();
    await wait(50);
    out.push('REMOVE CANCEL | ' + $$('rundlg').open + ' ran=' + window.__ran.filter(a => a.startsWith('host remove')).length);
    removeBtn().click();
    await wait(50);
    $$('rundlg-go').click();
    await wait(0);
    out.push('REMOVE RUNNING | ' + $$('rundlg-status').textContent + ' / buttons=' + vis('rundlg'));
    await wait(100);
    out.push('REMOVE DONE | ' + $$('rundlg').open + ' ' + txt($$('rundlg-status')));
    await wait(1200);
    out.push('REMOVE CLOSED | ' + $$('rundlg').open + ' view=' + view + ' hosts=' + (hostsNow || []).length);
    // The machine was off: removed all the same, and that is left to be read.
    S.hosts = [{ name: 'homebox', ssh: 'me@10.0.0.5', os: 'Linux', family: 'ubuntu', user: 'me' }];
    S.removeDown = true;
    await refreshHosts();
    goHost('homebox');
    await wait(500);
    removeBtn().click();
    await wait(50);
    $$('rundlg-go').click();
    await wait(1400);
    out.push('REMOVE DOWN | ' + $$('rundlg').open + ' ' + txt($$('rundlg-status')) + ' / ' + vis('rundlg'));
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
  echo "  FAIL the page did not render at all"; echo; echo "hosts-dom: $pass passed, 1 failed"; exit 1
fi
row() { grep "^$1 |" <<<"$OUT" | head -1; }

echo "1. a new laptop opens on Home, and asks one question"
check    "the welcome, and no machines yet"      "$(row 'OPEN WELCOME')" "OPEN WELCOME | shown machines=hidden"
check    "  only Home and Activity: nothing to set yet" "$(row 'OPEN NAV')" "OPEN NAV | dashboard,logs"
check    "  no setup screen in front of it"      "$(row 'OPEN SETUP')" "OPEN SETUP | false dialog=false"
check    "  and AWS is asked nothing"            "$(row 'OPEN AWS')" "OPEN AWS | "

echo "2. adding a server of yours"
contains "a dialog of its steps"                 "$(row 'ADD DIALOG')" "true Add a server"
contains "  this laptop's, ticked"               "$(row 'ADD STAGES')" "tools:done tailnet:done authkey:done"
contains "  then the server"                     "$(row 'ADD STAGES')" "server:active setup:locked"
check    "Install installs what a server needs, no AWS CLI" "$(row 'INSTALL RAN')" "INSTALL RAN | deps install moonlight"
for gone in cli key email where; do
  lacks  "  no AWS step: $gone"                  "$(row 'ADD STAGES')" " $gone:"
done
check    "connecting is cg host add"             "$(row 'PW RAN')" "PW RAN | host add --ssh me@10.0.0.5"
check    "four fields, the password among them" "$(row 'PW FIELDS')" "PW FIELDS | add-addr,add-user,add-pw,add-name"
check    "  shown from the start"                "$(row 'PW UPFRONT')" "PW UPFRONT | true"
check    "its password is asked in the form, no popup" "$(row 'PW OPEN')" "PW OPEN | false"
check    "  the field appears in the server step" "$(row 'PW SHOWN')" "PW SHOWN | true in-step:true"
contains "  saying it is used once, not stored"   "$(row 'PW PROMPT')" "Used once to install an SSH key. Not stored."
check    "  hidden as it is typed"               "$(row 'PW INPUT')" "PW INPUT | password"
check    "  Connect becomes Continue"            "$(row 'PW BUTTONS')" "PW BUTTONS | Continue"
check    "  an empty one is not sent"            "$(row 'PW EMPTY')" "PW EMPTY | 0"
check    "  and handed to cg"                    "$(row 'PW ANSWER')" "PW ANSWER | letmein"
check    "  and not left in the field"           "$(row 'PW CLEARED')" "PW CLEARED | "
contains "added, it waits for what the machine is" "$(row 'SERVER MID')" "server:active setup:locked"
contains "  still connecting"                    "$(row 'SERVER MID')" "Connecting…"
contains "the server step is done"               "$(row 'SERVER STAGES')" "server:done setup:active"
contains "  naming what it found"                "$(row 'SERVER DONE')" "homebox · Linux Mint 22.2 · NVIDIA GeForce RTX 3060"
check    "  now, or later"                       "$(row 'SERVER BUTTONS')" "SERVER BUTTONS | Set up, Later"

echo "3. setting it up happens on its card"
check    "setup runs in the dialog, which stays open" "$(row 'SETUP DIALOG')" "SETUP DIALOG | true"
check    "  as cg host setup"                    "$(row 'SETUP RAN')" "SETUP RAN | host setup homebox"
check    "  in its step, the log open"           "$(row 'SETUP STATE')" "SETUP STATE | running log=true"
check    "sudo is asked in the compact popup"    "$(row 'SUDO POPUP')" "SUDO POPUP | true generic=false / Sudo password / homebox: used once for setup. Not stored."
check    "  one hidden field, focused; Continue waits for it" "$(row 'SUDO FIELD')" "SUDO FIELD | pwdlg-input password continue-off=true"
check    "  the step says what it waits for"     "$(row 'SUDO LIVE')" "SUDO LIVE | Waiting for the sudo password…"
check    "  over the add dialog, still open"     "$(row 'SUDO BEHIND')" "SUDO BEHIND | true"
check    "Esc does not close the add dialog"     "$(row 'ESC')" "ESC | stopped=true"
check    "  handed to cg, not left in the field" "$(row 'SUDO ANSWER')" "SUDO ANSWER | true closed=true cleared=true"
check    "its progress shows in the step"        "$(row 'SETUP LIVE')" "SETUP LIVE | >>> installing sunshine open=true"
check    "done: the step ticks"                  "$(row 'SETUP DONE')" "SETUP DONE | done open=true"
check    "  and then the dialog closes"          "$(row 'SETUP CLOSED')" "SETUP CLOSED | false"
check    "Home has its card, and no AWS one"     "$(row 'HOME WELCOME')" "HOME WELCOME | hidden machines=shown aws=hidden"
contains "  setting up"                          "$(row 'HOME CARD')" "Setting up"
contains "  with its own Stop"                   "$(row 'HOME CARD')" "Stop"
check    "AWS can still be added"                "$(row 'HOME ADD')" "HOME ADD | AWS, Your own server"
contains "the private network names it"          "$(row 'HOME NET')" "homebox: connected"
check    "nothing about money with no AWS"       "$(row 'HOME MONEY')" "HOME MONEY | hidden games=hidden safety=hidden"
check    "  nor its pages; Settings, now there is a machine" "$(row 'HOME NAV')" "HOME NAV | dashboard,logs,settings"
check    "Try again does not cancel the setup"   "$(row 'RETRY KEPT')" "RETRY KEPT | true"

echo "4. its detail"
check    "the Machine page, for it"              "$(row 'DETAIL VIEW')" "DETAIL VIEW | build aws=hidden own=shown title=homebox"
contains "every check cg made"                   "$(row 'DETAIL CARD')" "Moonlight paired"
contains "  where it is"                         "$(row 'DETAIL CARD')" "me@10.0.0.5"
contains "  and removing it"                     "$(row 'DETAIL BUTTONS')" "Remove machine(off)"
check    "not one read asked AWS"                "$(row 'NO AWS')" "NO AWS | "

echo "5. adding AWS"
contains "its own steps"                         "$(row 'AWS DIALOG')" "Add AWS"
contains "  the account, alerts and where"       "$(row 'AWS STAGES')" "email:"
contains "  with the AWS CLI now needed"         "$(row 'AWS TOOLS')" "the AWS CLI"
check    "added, its pages arrive"               "$(row 'ADDED NAV')" "ADDED NAV | dashboard,build,library,guards,cost,logs,settings"
contains "needing something, its card says so"   "$(row 'ADDED CARD')" "AWS needs you"
contains "  with the button that reopens it"     "$(row 'ADDED CARD')" "Finish setting up"
check    "  and it is not offered again"         "$(row 'ADDED ADD')" "ADDED ADD | hidden"
lacks    "a running machine is never 'needs you'" "$(row 'RUNNING CARD')" "AWS needs you"
contains "  and offers no Finish over it"        "$(row 'RUNNING CARD')" "fix=hidden"
check    "remove asks in its own dialog"         "$(row 'REMOVE ASK')" "REMOVE ASK | true Remove homebox / Revokes the app's SSH key on the machine and removes it from the app. Sunshine, Steam and games on it are not changed. / Cancel, Remove"
check    "  Cancel runs nothing"                 "$(row 'REMOVE CANCEL')" "REMOVE CANCEL | false ran=0"
check    "  while it runs, nothing to press - no Cancel" "$(row 'REMOVE RUNNING')" "REMOVE RUNNING | Revoking SSH key… / buttons="
check    "  Remove runs it in the same dialog"   "$(row 'REMOVE DONE')" "REMOVE DONE | true Removed."
check    "  which closes onto Home, machine gone" "$(row 'REMOVE CLOSED')" "REMOVE CLOSED | false view=dashboard hosts=0"
check    "unreachable: said, and left to read"   "$(row 'REMOVE DOWN')" "REMOVE DOWN | true Removed from the app. The SSH key could not be revoked (machine unreachable). / Done"
check    "which reopens its steps"               "$(row 'FINISH')" "FINISH | true Finish setting up AWS"

check "no errors on the page" "$(row 'ERRS')" "ERRS | "
lacks "  and the probe did not throw" "$OUT" "THREW |"

echo; echo "hosts-dom: $pass passed, $fail failed"
(( fail == 0 ))
