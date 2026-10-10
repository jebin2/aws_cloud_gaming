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
      { type: 'g4dn.xlarge', score: 9, gpu: 'T4', vram_gib: 16, ram_gib: 16, vcpu: 4,
        inr_hour_spot: 18, inr_hour_ondemand: 51, fits_spot: false, fits_ondemand: true },
      { type: 'g6.xlarge', score: 1, gpu: 'L4', vram_gib: 22.4, ram_gib: 16, vcpu: 4,
        inr_hour_spot: 46, inr_hour_ondemand: 85, fits_spot: false, fits_ondemand: true }]},
    { region: 'ap-southeast-5', city: 'Asia Pacific (Malaysia)', enabled: false, rtt_ms: 48,
      quota: null, best_score: 9, machines: [
      { type: 'g6.xlarge', score: 9, gpu: 'L4', vram_gib: 22.4, ram_gib: 16, vcpu: 4,
        inr_hour_spot: null, inr_hour_ondemand: 89, fits_spot: null, fits_ondemand: null }]},
    { region: 'ap-south-2', city: 'Asia Pacific (Hyderabad)', enabled: true, rtt_ms: 19,
      quota: { ondemand_vcpu: 4, spot_vcpu: 4 }, best_score: 1, machines: [
      { type: 'g6.xlarge', score: 1, gpu: 'L4', vram_gib: 22.4, ram_gib: 16, vcpu: 4,
        inr_hour_spot: 13, inr_hour_ondemand: 85, fits_spot: true, fits_ondemand: true }]},
  ],
};
const CONFIG = [
  { key: 'GAME_REGION', kind: 'region', note: 'region', default: 'ap-south-2',
    rule: null, secret: false, is_set: true, value: 'ap-south-1', effective: 'ap-south-1' },
  { key: 'GAME_INSTANCE_TYPE', kind: 'text', note: 'type', default: 'g6.xlarge',
    rule: null, secret: false, is_set: true, value: 'g4dn.xlarge', effective: 'g4dn.xlarge' },
  { key: 'GAME_SPOT', kind: 'choice', note: 'model', default: 'auto', rule: 'auto,1,0',
    secret: false, is_set: true, value: '0', effective: '0' },
  { key: 'GAME_DISK_GB', kind: 'number', note: 'disk', default: '50', rule: '30',
    secret: false, is_set: true, value: '50', effective: '50' },
];
const MACHINES = {
  region: 'ap-south-1', configured: 'g4dn.xlarge', spot: '0', inr_per_usd: 88,
  quota: { ondemand_vcpu: 4, spot_vcpu: 0 }, machines: [
  { type: 'g4dn.xlarge', vcpu: 4, gpu: 'T4', vram_gib: 16, ram_gib: 16, store_gb: 125,
    inr_hour_spot: 18, inr_hour_ondemand: 51, fits_spot: false, fits_ondemand: true }],
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
  await new Promise(r => setTimeout(r, 600));
  const out = ['JOBLINE: ' + document.getElementById('job-line').textContent];
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
  out.push('LEGEND | ' + document.getElementById('s-chooser-legend').innerText
                          .replace(/\s+/g, ' ').trim());
  // One line per painter, naming a DOM effect only that painter produces.
  out.push('PAINTED | status/spec | ' + document.getElementById('b-spec').children.length);
  out.push('PAINTED | status/chip | ' + document.getElementById('b-chip').textContent.trim());
  out.push('PAINTED | config | ' + document.getElementById('s-count').textContent.trim());
  out.push('PAINTED | guards | ' + document.getElementById('guard-cards').children.length);
  out.push('PAINTED | library | ' + document.getElementById('b-fit').textContent.trim());
  if (window.__errs.length) out.push('ERRORS: ' + window.__errs.join(' | '));
  out.push('BPICK | ' + document.getElementById('b-pick').textContent.trim());
  out.push('BNOTE | ' + document.getElementById('b-type-note').textContent.trim());
  out.push('BTABLE | ' + (document.getElementById('b-chooser') ? 'PRESENT' : 'absent'));
  out.push('BSETUP | ' + (document.getElementById('b-setup') ? 'present' : 'ABSENT'));
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
          ? amount.textContent.trim() + (reason ? ' [' + reason.textContent.trim() + ']' : '')
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

OUT=$("$BROWSER" --headless --disable-gpu --no-sandbox --virtual-time-budget=9000 \
      --user-data-dir="$T/chrome" --dump-dom "file://$T/r/index.html" 2>/dev/null \
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
# A painter that throws was invisible twice over: the catch wrote job-line, and
# updateHeader overwrote it - first in the same tick, then when any OTHER read
# finished. A read failure is sticky now, so idle really means all six worked.
lacks    "no painter failed"  "$OUT" "could not show cg"
lacks    "  nor could not run"  "$OUT" "could not run:"
contains "and it settles to idle" "$OUT" "JOBLINE: idle"
# Named effects, because "no error" is what passed while paintSpec was missing.
contains "paintSpec filled the spec grid"  "$OUT" "PAINTED | status/spec | 4"
contains "  and the build chip"            "$OUT" "PAINTED | status/chip | g4dn.xlarge · ap-south-1 · on demand"
contains "paintConfig counted the settings" "$OUT" "PAINTED | config | 4 of 4 set"
contains "paintGuards drew a card"          "$OUT" "PAINTED | guards | 1"
contains "paintLibrary sized the disk"      "$OUT" "PAINTED | library | "

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
contains "Mumbai is named"               "$OUT" "ap-south-1 | Mumbai | 22 ms | g4dn.xlarge"
contains "  and its second machine is bare" "$OUT" "|  |  |  | g6.xlarge"
contains "the city is shortened"         "$OUT" "| Hyderabad |"
lacks    "  not the full AWS name"       "$OUT" "Asia Pacific (Hyderabad)"

echo "4. what is configured is what is checked - all three at once"
# .env here is ap-south-1 + g4dn.xlarge + GAME_SPOT=0, so exactly one radio is
# checked and it is the on-demand price of that machine in that region.
check "exactly one radio is checked" "$(grep -c 'CHECKED' <<<"$OUT" || true)" "1"
contains "and it is Mumbai g4dn on demand" "$OUT" "g4dn.xlarge | T4 16 GB | 9/10 | OFF 18 [no quota] | CHECKED 51"

echo "5. a cell you cannot pick says why"
# The three refusals are different and lead to different actions.
contains "no spot quota in the region" "$OUT" "OFF 18 [no quota]"
contains "the region is not enabled"   "$OUT" "OFF 89 [needs opt-in]"
contains "no spot market at all"       "$OUT" "OFF - [no spot market]"
# Hyderabad has both quotas, so both of its prices are selectable - this is the
# control case proving the disabling is about quota, not about the region.
contains "and a usable row is selectable" "$OUT" "ap-south-2 | Hyderabad | 19 ms | g6.xlarge | L4 22.4 GB | 1/10 | FREE 13 | FREE 85"

echo "5b. Build states the choice without offering a second control"
# The one line that matters, from the same rows the table uses, so the two
# cannot disagree.
contains "the region, machine and model" "$OUT" "BPICK | ap-south-1 · g4dn.xlarge · on demand"
contains "  with the GPU"                "$OUT" "T4 16 GB"
contains "  and the hourly rate"         "$OUT" "INR 51/hr"

echo "6. capacity is shown next to price, which is the whole point"
contains "the good score is there" "$OUT" "9/10"
contains "and the bad one"         "$OUT" "1/10"
contains "the note explains what 1 means" "$OUT" "almost certainly be refused"
contains "the age of the scan is shown"   "$OUT" "scanned 5m ago"
contains "and what was left out"          "$OUT" "2 regions are too far"

echo "7. the three settings it owns have no second editor"
contains "the region row points at the table" "$OUT" "set in Machine, above"
reg_row=$(grep '^SETTING | ' <<<"$OUT" | grep -i 'region' | head -1)
contains "  the region row still shows its value" "$reg_row" "ap-south-1"
lacks    "  but offers no Edit button"            "$reg_row" "Edit"
disk_row=$(grep '^SETTING | ' <<<"$OUT" | grep -iE 'disk' | head -1)
contains "an unrelated setting keeps its editor" "$disk_row" "Edit"

echo "8. the radios line up, and look like the rest of the window"
contains "Settings is actually visible when measured" "$OUT" "VISIBLE | true"
# Without the line above every rectangle is 0x0 at (0,0) and alignment passes
# for free, so the measurement is checked for being a measurement at all.
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
contains "  unchecked uses outline"               "$OUT" "unchecked | appearance=none | w=12px | border=rgb(134, 148, 138)"
contains "  checked uses primary"                 "$OUT" "checked | appearance=none | w=12px | border=rgb(78, 222, 163)"
contains "  with a primary dot inside"            "$OUT" "rgb(78, 222, 163) 0px 0px 0px 2px inset"
contains "  disabled recedes to outline-variant"  "$OUT" "disabled | appearance=none | w=12px | border=rgb(60, 74, 66)"
lacks    "nothing is left at the browser default" "$OUT" "appearance=auto"

echo "9. a greyed-out price explains itself once, not in every cell"
# Half a column of repeated "no quota" read as broken rather than deliberate.
contains "the legend says what grey means" "$OUT" "would be refused at launch"
contains "  and names the quota case"      "$OUT" "no quota - Your G-instance quota"
contains "  the opt-in case"               "$OUT" "needs opt-in - This region is not enabled"
contains "  and the missing market"        "$OUT" "no spot market - AWS publishes no spot price"
# Only the reasons actually on screen: this fixture has no priceless row.
lacks    "  but not a reason nothing shows" "$OUT" "no price - The Pricing API"
# A row with nothing pickable recedes instead of looking broken. The fixture has
# Malaysia (opt-in) and Mumbai's two spot-only-blocked rows are NOT dim, because
# their on-demand price is pickable.
contains "rows with nothing pickable recede" "$OUT" "DIMROWS | 1"

echo ""
echo "chooser-dom: $pass passed, $fail failed"
(( fail == 0 ))
