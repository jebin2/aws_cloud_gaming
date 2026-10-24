#!/usr/bin/env bash
# The machine chooser, actually rendered.
#
# Every other renderer test in here reads app.js as text. That is why three UI
# bugs shipped: a picker that was below the fold at narrow widths, a packaged
# app that could not spawn cg, and - found by writing this file - a paint that
# threw and was silent because updateHeader() overwrote the error in the same
# tick. Source assertions cannot see any of those. This loads the real page in
# headless chromium, feeds it recorded `cg --json` answers, and reads the table
# back out of the DOM.
#
# Two things it pins that only a render can show:
#   * a price cell is DISABLED for a stated reason - no quota, needs opt-in, no
#     spot market - because "why can I not pick this" was half the confusion the
#     table was built to remove;
#   * the radio that is checked matches what cg says is configured, across all
#     three settings at once. A table that quietly disagrees with .env would be
#     worse than the dropdowns it replaced.
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
if [[ -z $BROWSER ]]; then
  echo "  (no chromium - skipped)"; echo "chooser-dom: 0 passed, 0 failed"; exit 0
fi

# The page is copied out of the repo and never edited in place: a test that
# injects scripts into app/renderer can leave them behind, and a stub shipped
# inside the app would be far worse than no test.
mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js app/renderer/tailwind.css "$T/r/"

# Recorded answers. Written here rather than captured from AWS so the suite is
# offline and deterministic: ap-south-1 has capacity for g4dn but NO spot quota,
# ap-south-2 has both quotas and no capacity, and ap-southeast-5 has capacity
# but is not enabled. Those are the three refusals the table has to explain.
cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
const SWEEP = {
  cached: true, age_seconds: 300, scanned_at: '2026-10-10T08:00:00Z',
  max_ms: 80, configured: 'ap-south-1', inr_per_usd: 88, measured: true,
  too_far: [{ region: 'us-east-1', rtt_ms: 214 }, { region: 'eu-west-1', rtt_ms: 142 }],
  unreachable: [],
  regions: [
    { region: 'ap-south-1', city: 'Asia Pacific (Mumbai)', enabled: true, rtt_ms: 22.4,
      quota: { ondemand_vcpu: 4, spot_vcpu: 0 }, best_score: 9, machines: [
      { type: 'g4dn.xlarge', score: 9, gpu: 'T4', vram_gib: 16, ram_gib: 16, vcpu: 4, store_gb: 125,
        inr_hour_spot: 18, inr_hour_ondemand: 51, fits_spot: false, fits_ondemand: true },
      { type: 'g6.xlarge', score: 1, gpu: 'L4', vram_gib: 22.4, ram_gib: 16, vcpu: 4, store_gb: 250,
        inr_hour_spot: 46, inr_hour_ondemand: 85, fits_spot: false, fits_ondemand: true }]},
    { region: 'ap-southeast-5', city: 'Asia Pacific (Malaysia)', enabled: false, rtt_ms: 48,
      quota: null, best_score: 9, machines: [
      { type: 'g6.xlarge', score: 9, gpu: 'L4', vram_gib: 22.4, ram_gib: 16, vcpu: 4, store_gb: 250,
        inr_hour_spot: null, inr_hour_ondemand: 89, fits_spot: null, fits_ondemand: null }]},
    { region: 'ap-south-2', city: 'Asia Pacific (Hyderabad)', enabled: true, rtt_ms: 19,
      quota: { ondemand_vcpu: 4, spot_vcpu: 4 }, best_score: 1, machines: [
      { type: 'g6.xlarge', score: 1, gpu: 'L4', vram_gib: 22.4, ram_gib: 16, vcpu: 4, store_gb: 250,
        inr_hour_spot: 13, inr_hour_ondemand: 85, fits_spot: true, fits_ondemand: true }]},
  ],
};
const CONFIG = [
  { key: 'GAME_REGION', kind: 'region', note: 'region', default: 'ap-south-2',
    rule: null, secret: false, is_set: true, value: 'ap-south-1', effective: 'ap-south-1' , label: 'region', group: 'The box' },
  { key: 'GAME_INSTANCE_TYPE', kind: 'text', note: 'type', default: 'g6.xlarge',
    rule: null, secret: false, is_set: true, value: 'g4dn.xlarge', effective: 'g4dn.xlarge' , label: 'instance type', group: 'The box' },
  { key: 'GAME_SPOT', kind: 'choice', note: 'model', default: 'auto', rule: 'auto,1,0',
    secret: false, is_set: true, value: '0', effective: '0' , label: 'purchase model', group: 'The box' },
  { key: 'GAME_DISK_GB', kind: 'number', note: 'disk', default: '50', rule: '30',
    secret: false, is_set: true, value: '50', effective: '50' , label: 'root disk (GB)', group: 'The box' },
];
const MACHINES = {
  region: 'ap-south-1', configured: 'g4dn.xlarge', spot: '0', inr_per_usd: 88,
  quota: { ondemand_vcpu: 4, spot_vcpu: 0 }, machines: [
  { type: 'g4dn.xlarge', vcpu: 4, gpu: 'T4', vram_gib: 16, ram_gib: 16, store_gb: 125,
    inr_hour_spot: 18, inr_hour_ondemand: 51, fits_spot: false, fits_ondemand: true },
  // Offered here, and far beyond a 4 vCPU quota: the table leaves these out,
  // because picking one would be refused at launch.
  { type: 'g5.12xlarge', vcpu: 48, gpu: 'A10G', vram_gib: 96, ram_gib: 192, store_gb: 3800,
    inr_hour_spot: 200, inr_hour_ondemand: 600, fits_spot: false, fits_ondemand: false },
  { type: 'g6e.48xlarge', vcpu: 192, gpu: 'L40S', vram_gib: 384, ram_gib: 1536, store_gb: 7600,
    inr_hour_spot: 800, inr_hour_ondemand: 2400, fits_spot: false, fits_ondemand: false }],
};
// The real shape of `cg status --json`, with every identifier replaced. Built
// from the live command rather than written by hand, because hand-written
// fixtures only contain the fields whoever wrote them remembered - and the two
// painter crashes that reached a user's machine were both a field this file did
// not have: s.tailnet.node and s.local.tailscale.
const STATUS = {
    "account": {
      "credits": "138.38",
      "id": "000000000000",
      "plan": "PAID"
    },
    "archive": {
      "bucket": "cg-library-test",
      "bytes": 174813455930,
      "decision": "kept - a box exists (i-0123456789abcdef0)  (checked 2 min ago)",
      "expiry_days": 14,
      "objects": 6289,
      "usd_month": 4.07
    },
    "box": null,
    "budget": {
      "alerts": 2,
      "limit": 57.0,
      "spent": 0.0
    },
    "config": {
      "alert_email": "yes",
      "disk_gb": 50,
      "instance_type": "g4dn.xlarge",
      "notifications": true,
      "spot": "0",
      "tailscale_api_key": "yes"
    },
    "host": "gamevps",
    "instance_type": "g4dn.xlarge",
    "local": {
      "auth_key": true,
      "moonlight": true,
      "ssh_key": true,
      "tailscale": true
    },
    "quota": {
      "on_demand": 4.0,
      "spot": 0.0,
      "vcpus": 4
    },
    "region": "ap-south-1",
    "res": {
      "elastic_ips": 0,
      "images": 0,
      "key_pair": "gamevps",
      "security_group": "sg-05822edde423b6956",
      "snapshots": 0,
      "volumes_gb": 50
    },
    "session": null,
    "spec": {
      "gpu": "T4",
      "gpu_memory_mib": 16384,
      "memory_mib": 16384,
      "vcpus": 4
    },
    "tailnet": {
      "node": "gamevps",
      "online": false
    }
  };

// All SIX reads the app makes at startup. Leaving two out meant two painters
// never ran in here at all - and paintSpec, which paintStatus calls on its
// first line, was deleted and shipped.
const LIBRARY = {
  bucket: 'cg-library-test', games: [], total_bytes: 0, usd_month: 0,
  orphan_bytes: 0, orphan_usd_month: 0, disk_gb: 50, selectable_gb: 209,
  usd_per_gb_month: 0.025,
};
const GUARDS = { guards: [
  { name: 'idle watchdog', armed: true, state: 'armed', catches: 'a box left running' },
] };
const DATA = { sweep: SWEEP, config: CONFIG, machines: MACHINES, status: STATUS,
               library: LIBRARY, guards: GUARDS };
const MAP = [[['sweep'], 'sweep'], [['config'], 'config'],
             [['machines'], 'machines'], [['status'], 'status'],
             [['library', 'list'], 'library'], [['watcher'], 'guards']];
let nextId = 1; const handlers = [];
window.cg = {
  run(args) {
    const id = nextId++;
    const hit = MAP.find(([a]) => a.every((v, i) => args[i] === v));
    // 60ms, not 0: runCg registers the job only AFTER awaiting run(), so events
    // fired in the same tick arrive for an id it has not stored and vanish.
    setTimeout(() => {
      if (hit) for (const h of handlers)
        h({ id, event: { t: 'raw', stream: 'stdout', text: JSON.stringify(DATA[hit[1]]) } });
      for (const h of handlers) h({ id, event: { t: 'exit', rc: 0 } });
    }, 60);
    return Promise.resolve({ ok: true, id });
  },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]),
  onEvent(h) { handlers.push(h); return () => {}; },
};
STUB

# Reads the table back as text, one line per row, with each radio's state.
cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  await new Promise(r => setTimeout(r, 1500));
  // Navigate to Settings FIRST. Nothing inside a hidden <section> has geometry,
  // so measuring alignment without this reports every x as 0 and happily calls
  // the column aligned - which is exactly how the first version of this passed
  // while the radios were visibly ragged.
  document.querySelector('.nav-item[data-view="settings"]').click();
  // The chooser is a dialog now, opened over whatever page you are on.
  openMachines();
  await new Promise(r => setTimeout(r, 600));
  // The header's running/failure line is gone - the first-run pipeline carries
  // that in words now - so a failed read is read where it is kept.
  const out = ['FAILURES: ' + [...readFailures].map(([k, v]) => k + '=' + v).join(' ;; ')];
  out.push('VISIBLE | ' + !document.querySelector('section[data-view=settings]').hidden);

  // Geometry: a radio column is aligned when every radio in it shares one x.
  const radios = [...document.querySelectorAll('#s-chooser input[type=radio]')];
  const xs = {};
  for (const r of radios) {
    const td = r.closest('td');
    const col = [...td.parentNode.children].indexOf(td);
    (xs[col] = xs[col] || []).push(Math.round(r.getBoundingClientRect().left));
  }
  for (const col of Object.keys(xs)) {
    const u = [...new Set(xs[col])];
    out.push(`XCOL | ${col} | n=${xs[col].length} | distinct=${u.length} | x=${u[0]}`);
  }
  // Theme: the native control is an OS blue dot, the one thing in this window
  // that would not come from the theme, so it must be redrawn.
  for (const [name, el] of [['unchecked', radios.find(r => !r.disabled && !r.checked)],
                            ['checked', radios.find(r => r.checked)],
                            ['disabled', radios.find(r => r.disabled)]]) {
    if (!el) { out.push('STYLE | ' + name + ' | none'); continue; }
    const s = getComputedStyle(el);
    out.push(`STYLE | ${name} | appearance=${s.appearance} | w=${s.width}`
           + ` | border=${s.borderTopColor} | shadow=${s.boxShadow}`);
  }
  out.push('DIMROWS | ' + document.querySelectorAll('#s-chooser tr.dim').length);
  // Before any scan: one region, and only the machines its quota can launch.
  // This is what a fresh laptop sees, and "why is only one machine showing?"
  // is the question it used to leave you with.
  paintSweep({ regions: [] });
  out.push('NOSWEEP ROWS | ' + document.querySelectorAll('#s-chooser tbody tr').length);
  out.push('NOSWEEP LEGEND | ' + document.getElementById('s-chooser-legend').innerText
                          .replace(/\s+/g, ' ').trim());
  out.push('NOSWEEP BTN | ' + [...document.querySelectorAll('#s-chooser-legend button')]
             .filter(b => b.textContent.trim() === 'Check all regions').length);
  // Nothing this quota can launch, anywhere: the table is empty, and asking AWS
  // for more is the way on - it used to be offered only beside a greyed price.
  const keepMachines = machinesNow;
  paintMachines({ region: 'ap-south-1', inr_per_usd: 88, machines: (keepMachines.machines || [])
    .map(m => ({ ...m, fits_spot: false, fits_ondemand: false })) });
  out.push('EMPTY ROWS | ' + document.querySelectorAll('#s-chooser tbody tr').length
           + ' ' + document.getElementById('s-chooser').textContent.trim().slice(0, 60));
  out.push('EMPTY BTN | ' + [...document.querySelectorAll('#s-chooser-legend button')]
             .map(b => b.textContent.trim()).join(','));
  paintMachines(keepMachines);
  paintSweep(DATA.sweep);
  // Mid-scan the popup is locked: no price, no button, no Esc. It used to stay
  // live, so a choice could land on a table about to be replaced.
  const dlgEl = document.getElementById('machdlg');
  const lockState = () => {
    const radios = [...document.querySelectorAll('#s-chooser input[type=radio]')];
    const btns = [...dlgEl.querySelectorAll('button')];
    const esc = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
    dlgEl.dispatchEvent(esc);
    const cancel = new Event('cancel', { cancelable: true });
    dlgEl.dispatchEvent(cancel);
    return 'radios=' + radios.filter(r => !r.disabled).length + '/' + radios.length
      + ' buttons=' + btns.filter(b => !b.disabled).length + '/' + btns.length
      + ' esc=' + (esc.defaultPrevented || cancel.defaultPrevented ? 'blocked' : 'closes')
      // How a price looks under the pointer: a highlight on one that cannot
      // change is what made a locked table look live.
      + ' cursor=' + (radios[0] ? getComputedStyle(radios[0].closest('label')).cursor : 'none')
      + ' popup=' + document.getElementById('refdlg').open + ':' + document.getElementById('refdlg-title').textContent;
  };
  scanRegions(document.getElementById('s-sweep'));
  out.push('SCANNING | ' + lockState());
  const popEsc = new Event('cancel', { cancelable: true });
  document.getElementById('refdlg').dispatchEvent(popEsc);
  out.push('POPESC | ' + popEsc.defaultPrevented);
  await new Promise(r => setTimeout(r, 300));
  out.push('SCANNED | ' + lockState());
  out.push('LEGEND | ' + document.getElementById('s-chooser-legend').innerText
                          .replace(/\s+/g, ' ').trim());
  // One line per painter, naming a DOM effect only that painter produces.
  // The machine on one line - there is no spec card any more.
  out.push('PAINTED | status/spec | ' + document.querySelector('#b-machine-card [data-f=what]').textContent.trim());
  out.push('PAINTED | config | ' + document.querySelectorAll('#s-groups .row').length);
  out.push('PAINTED | guards | ' + document.getElementById('g-nets').children.length);
  out.push('PAINTED | library | ' + document.getElementById('b-fit').textContent.trim());
  // The same payload with the box's disk left out, which is what a failed or
  // older read gives. Nothing here may invent a number: the app used to fill in
  // 209 GB, which reads exactly like an answer.
  const noCap = { ...DATA.library, selectable_gb: null,
                  games: [{ appid: '1', name: 'A game', bytes: 53687091200,
                            usd_month: 1.25, pushed: '2026-10-01T00:00:00Z' }],
                  total_bytes: 53687091200 };
  paintLibrary(noCap);
  document.querySelector('#b-games input[type=checkbox]').click();
  out.push('NOCAP | fit | ' + document.getElementById('b-fit').textContent.trim());
  out.push('NOCAP | pct | ' + document.getElementById('b-fit-pct').textContent.trim());
  out.push('NOCAP | build | ' + (document.getElementById('b-build').disabled ? 'OFF' : 'on'));
  // A g4dn.xlarge's disk, and a game bigger than all of it: not offered, and
  // the row says why - ticking it could never work, whatever else is unticked.
  const small = { ...DATA.library, disk_type: 'g4dn.xlarge', disk_gb: 116, selectable_gb: 96,
                  games: [{ appid: '9', name: 'Big game', bytes: 175 * 1073741824, usd_month: 4.4, pushed: '2026-10-01T00:00:00Z' },
                          { appid: '8', name: 'Small game', bytes: 3 * 1073741824, usd_month: 0.1, pushed: '2026-10-01T00:00:00Z' }],
                  total_bytes: 178 * 1073741824 };
  paintLibrary(small);
  const boxes = [...document.querySelectorAll('#b-games input[type=checkbox]')];
  out.push('SMALL | fit | ' + document.getElementById('b-fit').textContent.trim());
  out.push('SMALL | big | ' + (boxes[0].disabled ? 'off' : 'on') + ' | ' + boxes[0].closest('tr').textContent.replace(/\s+/g, ' ').trim());
  out.push('SMALL | small | ' + (boxes[1].disabled ? 'off' : 'on'));
  boxes[0].closest('tr').click();
  out.push('SMALL | clicked | ' + boxes[0].checked);
  paintLibrary(DATA.library);
  if (window.__errs.length) out.push('ERRORS: ' + window.__errs.join(' | '));
  const card = f => (document.querySelector('#b-machine-card [data-f=' + f + ']') || {}).textContent || '';
  out.push('BPICK | ' + card('what'));
  // A number column's heading sits over its numbers.
  out.push('HEADALIGN | ' + [...document.querySelectorAll('#s-chooser th')]
    .filter(th => /Game disk|Spot availability/.test(th.textContent)).map(th => getComputedStyle(th).textAlign).join(','));
  out.push('BWHERE | ' + card('where'));
  out.push('BNOTE | ' + card('warn'));
  // The why-mark in a greyed cell, even on a greyed row, is not greyed itself.
  const marks = [...document.querySelectorAll('#s-chooser .reason')];
  const live = m => { const st = getComputedStyle(m), a = getComputedStyle(m.closest('label').querySelector('.amount'));
    return st.color !== a.color && getComputedStyle(m.closest('td')).opacity === '1' && st.cursor === 'help' && !!m.title; };
  out.push('MARKS | ' + marks.length + ' live=' + marks.filter(live).length);
  // The checked price and the card's price are one number, from one function.
  const picked = document.querySelector('#s-chooser input:checked');
  out.push('SAMEPRICE | ' + (picked ? card('where').includes(picked.closest('label').querySelector('.amount').textContent + '/hour') : 'none'));
  out.push('BTABLE | ' + (document.getElementById('b-chooser') ? 'PRESENT' : 'absent'));
  out.push('BSETUP | ' + (document.getElementById('b-change') ? 'present' : 'ABSENT'));
  for (const id of ['s-chooser']) {
    const tb = document.getElementById(id);
    out.push('TABLE ' + id + (tb ? '' : ' MISSING'));
    if (tb) for (const tr of tb.querySelectorAll('tr')) {
      out.push('ROW ' + id + ' | ' + [...tr.children].map(td => {
        const r = td.querySelector('input[type=radio]');
        const mark = r ? (r.checked ? 'CHECKED' : r.disabled ? 'OFF' : 'FREE') : '';
        // The price and the reason are separate spans, so read them separately -
        // joining textContent would print "18no quota" and hide whether the two
        // are actually distinct elements.
        const amount = td.querySelector('.amount');
        const reason = td.querySelector('.reason');
        const body = amount
          ? amount.textContent.trim() + (reason ? ' [' + td.querySelector('label').title.split(':')[0] + ']' : '')
          : td.textContent.trim();
        return (mark + ' ' + body).trim();
      }).join(' | '));
    }
    const n = document.getElementById(id === 'b-chooser' ? 'b-type-note' : 's-type-note');
    const a = document.getElementById(id === 'b-chooser' ? 'b-sweep-age' : 's-sweep-age');
    out.push('AGE ' + id + ' | ' + (a ? a.textContent.trim() : ''));
    out.push('NOTE ' + id + ' | ' + (n ? n.textContent.trim() : ''));
  }
  // The settings rows for the three the table owns must not offer their own
  // editor: three controls for one decision is what made this confusing.
  for (const row of document.querySelectorAll('#s-groups .row'))
    out.push('SETTING | ' + row.textContent.replace(/\s+/g, ' ').trim());
  const pre = document.createElement('pre');
  pre.id = 'probe-out'; pre.textContent = out.join('\n');
  document.body.append(pre);
})();
PROBE

python3 - "$T/r" <<'PY'
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
  echo ""; echo "chooser-dom: $pass passed, 1 failed"; exit 1
fi

echo "1. the page renders, every painter runs, and nothing throws"
lacks    "no uncaught error" "$OUT" "ERRORS:"
# A painter that throws was invisible twice over: the catch wrote a header line,
# and updateHeader overwrote it - first in the same tick, then when any OTHER
# read finished. A read failure is sticky now, so an empty map really does mean
# all six reads worked.
lacks    "no painter failed"  "$OUT" "could not show cg"
lacks    "  nor could not run"  "$OUT" "could not run:"
contains "and no read failed at all" "$OUT" "FAILURES: "
# Named effects, because "no error" is what passed while paintSpec was missing.
contains "the machine is one line"         "$OUT" "PAINTED | status/spec | g4dn.xlarge"
# Of the four, only the disk is Settings' own: region, machine and purchase
# model are the chooser's, and nothing else repeats them.
contains "paintConfig drew Settings' own rows" "$OUT" "PAINTED | config | 1"
contains "paintGuards drew a net"           "$OUT" "PAINTED | guards | 1"
contains "paintLibrary sized the disk"      "$OUT" "PAINTED | library | "

echo "1b. a disk size cg did not give is not guessed"
contains "the meter is labelled plainly"   "$OUT" "NOCAP | fit | Disk space"
contains "  and counts what is picked, with no fraction of an unknown" \
         "$OUT" "NOCAP | pct | 50.0 GB · capacity unknown"
# The box checks the real limit at boot. Refusing the build here on a number
# nobody has would be guessing in the other direction.
contains "  and Build is still allowed"    "$OUT" "NOCAP | build | on"
check    "number headings are right-aligned, over their numbers" "$(grep '^HEADALIGN' <<<"$OUT")" "HEADALIGN | right,right"
contains "the machine card says how much room it has" "$(grep '^BPICK' <<<"$OUT")" " GB"
contains "the meter names the machine"     "$OUT" "SMALL | fit | Disk space (g4dn.xlarge)"
contains "a game bigger than its disk is not offered" "$OUT" "SMALL | big | off"
contains "  and says why"                  "$OUT" "Exceeds g4dn.xlarge capacity (96 GB). Choose a larger disk."
contains "  a game that fits still is"     "$OUT" "SMALL | small | on"
contains "  and clicking its row does nothing" "$OUT" "SMALL | clicked | false"

echo "2. the table lives on Settings, and only there"
contains "the Settings screen has it"  "$OUT" "TABLE s-chooser"
lacks    "  and it is not missing"     "$OUT" "TABLE s-chooser MISSING"
# Two copies of a control writing the same three settings is the original
# confusion in a new shape, so Build carries a summary and a button instead.
contains "Build has no table"          "$OUT" "BTABLE | absent"
contains "  but does have the button"  "$OUT" "BSETUP | present"
s_rows=$(grep -c '^ROW s-chooser' <<<"$OUT" || true)
# header + 2 Mumbai + 1 Malaysia + 1 Hyderabad
check "one row per region AND type" "$s_rows" "5"

echo "3. a region is named once, and its machines sit under it"
contains "Mumbai is named"               "$OUT" "Mumbai | Close (22 ms) | g4dn.xlarge"
contains "  and its second machine is bare" "$OUT" "|  |  | g6.xlarge"
contains "the city is shortened"         "$OUT" "| Hyderabad |"
lacks    "  not the full AWS name"       "$OUT" "Asia Pacific (Hyderabad)"

echo "4. what is configured is what is checked - all three at once"
# .env here is ap-south-1 + g4dn.xlarge + GAME_SPOT=0, so exactly one radio is
# checked and it is the on-demand price of that machine in that region.
check "exactly one radio is checked" "$(grep -c 'CHECKED' <<<"$OUT" || true)" "1"
contains "and it is Mumbai g4dn on demand" "$OUT" "g4dn.xlarge | NVIDIA T4, 16 GB | 125 GB | 9/10 | OFF ₹18 [Over GPU quota] | CHECKED ₹51"

echo "5. a cell you cannot pick says why"
# The three refusals are different and lead to different actions.
contains "no spot quota in the region" "$OUT" "OFF ₹18 [Over GPU quota]"
contains "the region is not enabled"   "$OUT" "OFF ₹89 [Region not enabled]"
contains "no spot market at all"       "$OUT" "OFF none [No spot price]"
# Hyderabad has both quotas, so both of its prices are selectable - this is the
# control case proving the disabling is about quota, not about the region.
contains "and a usable row is selectable" "$OUT" "Hyderabad | Close (19 ms) | g6.xlarge | NVIDIA L4, 22.4 GB | 250 GB | 1/10 | FREE ₹13 | FREE ₹85"

echo "5b. Build states the choice without offering a second control"
# The one line that matters, from the same rows the table uses, so the two
# cannot disagree.
contains "the machine, once"             "$OUT" "BPICK | g4dn.xlarge"
contains "  then where and how it is bought" "$OUT" "· On-demand"
contains "  with the GPU"                "$(grep -m1 '^BPICK ' <<<"$OUT")" "NVIDIA T4, 16 GB"
contains "every why-mark is live, not greyed" "$OUT" "MARKS | 4 live=4"
contains "the table and the card agree on the price" "$OUT" "SAMEPRICE | true"
contains "  and the hourly rate, in rupees" "$(grep -m1 '^BWHERE ' <<<"$OUT")" "₹51/hour"

echo "6. capacity is shown next to price, which is the whole point"
contains "the good score is there" "$OUT" "9/10"
contains "and the bad one"         "$OUT" "1/10"
contains "the column says what the score means" "$OUT" "Spot availability"
contains "spot and standard, told apart"  "$OUT" "Spot is cheaper but can be reclaimed mid-session. On-demand is not."
contains "the age of the scan is shown"   "$OUT" "Checked 5m ago"
contains "and what was left out"          "$OUT" "2 regions hidden (over 80 ms)"

echo "7. the three settings it owns have no second editor"
# Not even a pointer: Settings does not list region, machine or purchase model.
check    "no region row on Settings"            "$(grep '^SETTING | ' <<<"$OUT" | grep -ci 'region' || true)" "0"
disk_row=$(grep '^SETTING | ' <<<"$OUT" | grep -iE 'disk' | head -1)
contains "the disk keeps its editor"            "$disk_row" "Edit"
contains "  in plain words"                     "$disk_row" "System disk"

echo "8. the radios line up, and look like the rest of the window"
contains "Settings is actually visible when measured" "$OUT" "VISIBLE | true"
# Without the line above every rectangle is 0x0 at (0,0) and alignment passes
# for free, so the measurement is checked for being a measurement at all.
# Columns 6 and 7: Game disk sits before the score since machines differ in it.
for col in 6 7; do
  row=$(grep "^XCOL | $col | " <<<"$OUT")
  n=$(sed -E 's/.*n=([0-9]+).*/\1/' <<<"$row")
  d=$(sed -E 's/.*distinct=([0-9]+).*/\1/' <<<"$row")
  x=$(sed -E 's/.*x=([0-9]+).*/\1/' <<<"$row")
  check "column $col has every radio at one x" "$d" "1"
  if [[ ${n:-0} -ge 4 ]]; then echo "  ok     and it measured $n of them"; pass=$((pass+1));
  else echo "  FAIL   only $n radios measured"; fail=$((fail+1)); fi
  if [[ ${x:-0} -gt 0 ]]; then echo "  ok     at a real position, not 0"; pass=$((pass+1));
  else echo "  FAIL   x is 0 - nothing was laid out"; fail=$((fail+1)); fi
done
# The theme's own tokens: outline #86948a, primary #4edea3, outline-variant
# #3c4a42. A browser default would be appearance=auto and an OS blue.
contains "the control is redrawn, not the OS one" "$OUT" "STYLE | unchecked | appearance=none"
contains "  sized by the theme"                   "$OUT" "w=12px"
contains "  unchecked uses outline"               "$OUT" "unchecked | appearance=none | w=12px | border=rgb(139, 148, 167)"
contains "  checked uses primary"                 "$OUT" "checked | appearance=none | w=12px | border=rgb(61, 220, 151)"
contains "  with a primary dot inside"            "$OUT" "rgb(61, 220, 151) 0px 0px 0px 2px inset"
contains "  disabled recedes to outline-variant"  "$OUT" "disabled | appearance=none | w=12px | border=rgb(42, 49, 66)"
lacks    "nothing is left at the browser default" "$OUT" "appearance=auto"

echo "9. a greyed-out price explains itself once, not in every cell"
# Half a column of repeated "no quota" read as broken rather than deliberate.
row() { grep -m1 "^$1 " <<<"$OUT" || true; }
contains "the legend says what grey means" "$OUT" "would be refused at launch"
# "Why is only one machine showing?" - because the other two need more vCPU
# than any quota here allows, and the table used to drop them in silence. Only
# before a scan: a sweep shows every region, where "how many are hidden" has no
# single answer.
check    "one row before a scan"          "$(row 'NOSWEEP ROWS')" "NOSWEEP ROWS | 1"
# "Why is Mumbai not showing?" - because the scan is remembered per laptop, and
# this one has never run it. The table was showing .env's region alone and
# calling it the whole picture.
contains "  it says it is one region"     "$(row 'NOSWEEP LEGEND')" "Showing ap-south-1 only"
contains "  and what compares them all"   "$(row 'NOSWEEP LEGEND')" "Check all regions"
# The button is IN that line, not named by it: the real one is at the top of a
# long screen, which is where "how do I see the others" went unanswered.
contains "  as a button in the line"      "$(row 'NOSWEEP BTN')" "NOSWEEP BTN | 1"
echo "6c. mid-scan, the popup is locked"
contains "no price can be picked"          "$(row SCANNING)" "radios=0/"
contains "  no button pressed"             "$(row SCANNING)" "buttons=0/"
contains "  and Esc does not close it"     "$(row SCANNING)" "esc=blocked"
contains "  and nothing looks pickable"    "$(row SCANNING)" "cursor=wait"
# A popup over it says what it is waiting for, with a backdrop over the rest.
contains "a popup says what is happening" "$(row SCANNING)" "popup=true:Checking all regions"
check    "  and Esc does not close it"     "$(row POPESC)" "POPESC | true"
contains "  gone once the scan is in"     "$(row SCANNED)" "popup=false"
lacks    "after it, they look pickable again" "$(row SCANNED)" "cursor=wait"
contains "after it, Esc closes it again"   "$(row SCANNED)" "esc=closes"
lacks    "  and the buttons are back"      "$(row SCANNED)" "buttons=0/"
contains "an empty table says why"        "$(row 'EMPTY ROWS')" "No machine type fits your GPU quota here"
contains "  and offers to ask AWS for more" "$(row 'EMPTY BTN')" "Request quota increase"
contains "  with the price of asking"     "$(row 'NOSWEEP LEGEND')" "takes ~90 s. No charge."
lacks    "  not said after a scan"        "$(row 'LEGEND')" "only. Scan all regions"
contains "  and the legend says why"      "$(row 'NOSWEEP LEGEND')" "2 more GPU types here exceed your quota"
contains "  naming the limit"             "$(row 'NOSWEEP LEGEND')" "exceed your quota"
contains "  with both ways round it"      "$(row 'NOSWEEP LEGEND')" "exceed your quota."
lacks    "  and not after one"            "$(row 'LEGEND')" "more GPU machines are offered here"
contains "  and names the quota case"      "$OUT" "Over GPU quota: GPU quota here"
contains "  the opt-in case"               "$OUT" "Region not enabled: this region is not enabled"
contains "  and the missing market"        "$OUT" "No spot price: no spot market for this type"
# Only the reasons actually on screen: this fixture has no priceless row.
lacks    "  but not a reason nothing shows" "$OUT" "no price - The Pricing API"
# A row with nothing pickable recedes instead of looking broken. The fixture has
# Malaysia (opt-in) and Mumbai's two spot-only-blocked rows are NOT dim, because
# their on-demand price is pickable.
contains "rows with nothing pickable recede" "$OUT" "DIMROWS | 1"

echo ""
echo "chooser-dom: $pass passed, $fail failed"
(( fail == 0 ))
