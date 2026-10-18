#!/usr/bin/env bash
# The Cost page: in rupees, at one rate, and honest about storage.
#
# It showed dollars beside rupees, a total at 88 to the dollar over rows at
# 94.95, a budget of Rs 5,412 for one set at 5,000, and "standby Rs 0" under a
# bill charging S3 every day - because the games sat in a bucket cg was not
# looking at. Fed the shape `cg cost --json` answers, read back as shown.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "cost-dom: 0 passed, 0 failed"; exit 0; }

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

cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  // The two shared cards: their parts by name, where these were ids.
  const SHARED = { 'c-month': '#c-month-card [data-f=total]', 'c-month-sub': '#c-month-card [data-f=sub]',
                   'c-cap-note': '#c-month-card [data-f=note]', 'c-cap-chip': '#c-month-card [data-f=chip]',
                   'c-standby': '#c-recurring-card [data-f=total]', 'c-standby-sub': '#c-recurring-card [data-f=sub]',
                   'c-bills': '#c-recurring-card', 'c-unknown': '#c-recurring-card [data-f=unknown]' };
  const find = id => SHARED[id] ? document.querySelector(SHARED[id]) : document.getElementById(id);
  const text = id => { const e = find(id); return e ? e.innerText.replace(/\s+/g, ' ').trim() : ''; };
  const day = (date, hours, compute, s3, disk, egress, api, other) =>
    ({ date, hours, compute, s3, disk, egress, api, other,
       total: +(compute + s3 + disk + egress + api + other).toFixed(4) });
  const days = [day('2026-10-10', 2.1, 1.24, 0.13, 0.02, 0, 0, 0.02), day('2026-10-13', 0, 0, 0.13, 0, 0, 0.02, 0),
                day('2026-10-15', 0.3, 0.06, 0.13, 0, 0, 0, 0.01)];
  const total = +days.reduce((a, d) => a + d.total, 0).toFixed(4);
  const COST = over => Object.assign({
    month: { days, total_usd: total, total_inr: Math.round(total * 94.95), projected_usd: 5.82,
             hours: { on_demand: 0, spot: 2.4 }, egress: { gb_used: 0.39, gb_free: 100, gb_left: 99.61 } },
    credits_usd: 135.38,
    resources: { instance: null, volumes_gb: 0, snapshots_gb: 0, images: 0, budget_usd: 57 },
    archive: { bucket: 'b', bytes: null, usd_month: null, decision: 'kept - deleted in 13d' },
    storage: { billed_usd_month: 3.9, known_usd_month: 0, unknown_usd_month: 3.9 },
    standby: { usd_month: 0, usd_day: 0, archive_usd_month: 0, volumes_usd_month: 0, snapshots_usd_month: 0 },
    rates: { s3_gb_month: 0.025, egress_gb: 0.1093, ce_call_usd: 0.01, inr_per_usd: 94.95 },
  }, over);
  const read = label => {
    for (const id of ['c-month', 'c-month-sub', 'c-cap-note', 'c-credits', 'c-credits-note', 'c-days-note',
                      'c-standby', 'c-standby-sub', 'c-bills', 'c-egress', 'c-egress-src', 'c-egress-note'])
      out.push(label + ' ' + id + ' | ' + text(id));
    out.push(label + ' UNKNOWN | ' + (find('c-unknown') ? text('c-unknown') : 'hidden'));
    out.push(label + ' CHIP | ' + (find('c-cap-chip') ? text('c-cap-chip') : 'hidden'));
    [...document.querySelectorAll('#c-rows tr, #c-foot tr')].forEach((tr, i) =>
      out.push(label + ' ROW' + i + ' | ' + [...tr.children].map(td => td.textContent).join(' / ')));
    out.push(label + ' PAGE | ' + document.querySelector('section[data-view=cost]').innerText.replace(/\s+/g, ' '));
  };
  try {
    paintConfig([{ key: 'GAME_BUDGET_INR', kind: 'number', secret: false, is_set: false, value: null,
                   default: '5000', effective: '5000', note: 'n', label: 'budget', group: 'The guards' }]);
    paintCost(COST({}));
    read('REAL');
    paintCost(COST({ resources: { instance: null, volumes_gb: 50, snapshots_gb: 0, images: 0, budget_usd: null },
                     archive: { bucket: 'b', bytes: 171986001052, usd_month: 4.0 },
                     storage: { billed_usd_month: 4.02, known_usd_month: 4.0, unknown_usd_month: 0.02 },
                     standby: { usd_month: 8.56, archive_usd_month: 4.0, volumes_usd_month: 4.56, snapshots_usd_month: 0 } }));
    read('KNOWN');
    // The games cg found in another place explain the storage: the page names
    // them instead of calling it a mystery, and does not ask AWS again.
    paintCost(COST({}));
    window.__ran = [];
    paintElsewhere({ error: null, places: [{ bucket: 'cg-library-old', region: 'ap-south-2', error: null,
      bytes: 174813455930, games_bytes: 174813206488, usd_month: 4.07,
      games: [{ name: 'Diablo IV', bytes: 174813206488 }], login: true }] });
    read('AWAY');
    // With prices known: the playing line, then a stopped machine as its own row.
    machinesNow = { region: 'ap-south-1', machines: [{ type: 'g6.xlarge', inr_hour_spot: 16, inr_hour_ondemand: 85 }] };
    statusNow = { instance_type: 'g6.xlarge', config: { spot: '1' }, rates: { inr_per_usd: 94.95 } };
    paintCostPage();
    out.push('PLAY | ' + text('c-bills'));
    boxNow = { type: 'g6.xlarge', lifecycle: 'spot', state: 'stopped' };
    statusNow = { box: boxNow, instance_type: 'g6.xlarge', config: { spot: '1' }, rates: { inr_per_usd: 94.95 } };
    costNow = COST({ resources: { instance: { id: 'i-1', state: 'stopped' }, volumes_gb: 50, budget_usd: 57 },
                     standby: { usd_month: 4.56, archive_usd_month: 0, volumes_usd_month: 4.56, snapshots_usd_month: 0 } });
    paintCostPage();
    out.push('STOPPED | ' + text('c-bills'));
    out.push('AWAY RAN | ' + window.__ran.length);
    [...document.querySelectorAll('#c-recurring-card button')].find(x => x.textContent.startsWith('Saved games')).click();
    out.push('WENT | ' + (document.querySelector('.nav-item.on') || {}).dataset?.view);
    const age = () => document.getElementById('refresh-age').textContent + ' stale=' + document.getElementById('refresh-age').classList.contains('out-of-date');
    paintCost(COST({}));
    out.push('AGE | ' + age());
    costNowAt = new Date(Date.now() - 2 * 86400000);
    paintRefreshAge();
    out.push('OLDAGE | ' + age());
    // Something since the check that changes the bill: the label says so.
    const ageTitle = () => age() + ' title=' + document.getElementById('refresh-age').title;
    paintCost(COST({}));
    out.push('FRESH | ' + ageTitle());
    noteBillChange('you built a machine');
    out.push('CHANGED | ' + ageTitle());
    out.push('HOME CHANGED | ' + document.getElementById('d-month-src').classList.contains('out-of-date'));
    const st = getComputedStyle(document.getElementById('refresh-age'));
    out.push('BEAT | anim=' + st.animationName + ' pointer=' + st.pointerEvents + ' opacity=' + st.opacity);
    paintCost(COST({}));
    out.push('RECHECKED | ' + ageTitle());
    // A machine seen running after the check counts, once.
    paintStatus({ box: { id: 'i-1', state: 'running', type: 'g6.xlarge', lifecycle: 'spot' }, rates: {}, budget: {} });
    paintStatus({ box: { id: 'i-1', state: 'running', type: 'g6.xlarge', lifecycle: 'spot' }, rates: {}, budget: {} });
    out.push('RUNNING | ' + billChanges().map(c => c.what).join(','));
    paintCost(COST({}));
    // Status arriving after a Refresh reaches both copies of the card, not just Home's.
    statusNow = null; paintCostPage();
    paintStatus({ box: { id: 'i-1', state: 'running', type: 'g6.xlarge', lifecycle: 'spot' }, rates: {}, budget: {} });
    const playOf = id => (document.querySelector('#' + id + ' [data-f=play]') || {}).textContent || 'none';
    out.push('SAME PLAY | ' + playOf('c-recurring-card') + ' == ' + playOf('d-recurring-card'));
    // The hourly price as billed. Spot zones differ, and nothing pins the zone:
    // a machine not built yet is the spread; one that runs is its own zone's
    // price. Both carry the address and the disk, which bill by the hour too.
    //   machine 0.10 or 0.15 $/h, address 0.005 $/h, 100 GB disk at 0.0912 a
    //   GB-month over a 720-hour month: x 100 rupees to the dollar.
    const RATES = { inr_per_usd: 100, ipv4_hour: 0.005, ebs_gb_month: 0.0912, month_hours: 720 };
    machinesNow = { region: 'ap-south-2', machines: [{ type: 'g6.xlarge', usd_hour_spot: 0.10, usd_hour_spot_max: 0.15,
      inr_hour_spot: 10, spot_usd_by_az: { 'ap-south-2a': 0.10, 'ap-south-2b': 0.15 }, usd_hour_ondemand: 0.9664 }] };
    boxNow = null;
    statusNow = { region: 'ap-south-2', instance_type: 'g6.xlarge', config: { spot: '1', disk_gb: 100 }, rates: RATES };
    out.push('PLANNED | ' + machineFacts().priceText);
    boxNow = { type: 'g6.xlarge', lifecycle: 'spot', state: 'running', az: 'ap-south-2b', disk_gb: 100 };
    statusNow = { ...statusNow, box: boxNow };
    out.push('IN ZONE | ' + machineFacts().priceText);
    // A bigger disk costs more by the hour.
    boxNow = { ...boxNow, disk_gb: 200 }; statusNow = { ...statusNow, box: boxNow };
    out.push('BIG DISK | ' + machineFacts().priceText);
    // A restart: nothing in this window, the last bill on this laptop.
    const kept = JSON.parse(localStorage.getItem('cg.lastCost'));
    kept.at = new Date(Date.now() - 2 * 86400000).toISOString();
    if (new Date(kept.at).getMonth() !== new Date().getMonth()) kept.at = new Date(new Date().getFullYear(), new Date().getMonth(), 1, 0, 1).toISOString();
    localStorage.setItem('cg.lastCost', JSON.stringify(kept));
    costNow = null; costNowAt = null;
    document.getElementById('c-month-card').textContent = '';
    restoreBill();
    out.push('RESTORED | ' + text('c-month') + ' ' + age()
             + ' expect=' + (Date.now() - Date.parse(kept.at) > 86400000));
    // The app closed in the middle of a build: the box runs, but has not set
    // itself up. It is building, not ready - no Play - and the build is picked
    // up again, once, without leaving the page.
    const card = () => ['title', 'sub'].map(f => (document.querySelector('#d-machine-card [data-f=' + f + ']') || {}).textContent).join(' / ');
    const onPage = view;
    window.__ran = [];
    const half = { id: 'i-half', state: 'running', type: 'g6.xlarge', lifecycle: 'spot', launched: new Date().toISOString(), ready: false, built: false };
    paintStatus({ box: half, rates: {}, budget: {}, config: {} });
    out.push('HALF | ' + card() + ' | play=' + !document.getElementById('d-open').hidden
             + ' | ran=' + window.__ran.filter(r => r.startsWith('init')).length + ' | stayed=' + (view === onPage));
    paintStatus({ box: half, rates: {}, budget: {}, config: {} });
    out.push('HALF AGAIN | ran=' + window.__ran.filter(r => r.startsWith('init')).length);
  } catch (e) { out.push('THREW | ' + e.message + ' ' + e.stack); }
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
t = t.replace('</body>', '<script>document.querySelectorAll("section[data-view]").forEach(s => s.hidden = s.dataset.view !== "guards")</script>\n<script src="probe.js"></script>\n</body>', 1)
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
[[ $OUT == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; echo "cost-dom: 0 passed, 1 failed"; exit 1; }
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

echo "1. the month, in rupees at cg's one rate"
contains "the total in rupees"           "$(row 'REAL c-month')" "₹167"
contains "  hours played and the pace"   "$(row 'REAL c-month-sub')" "so far · 2.4 h of machine time · on pace for ₹553 by 31 Oct"
contains "the budget is yours, as set"   "$(row 'REAL c-cap-note')" "Budget ₹5,000 a month. AWS emails you if you pass it; it stops nothing."
lacks    "  not AWS's dollars turned back" "$(row 'REAL c-cap-note')" "5,412"
contains "  and the bar's verdict"       "$(row 'REAL CHIP')" "under the budget"
contains "credits in rupees"             "$(row 'REAL c-credits')" "₹12,854 left"
contains "  and how long they last"      "$(row 'REAL c-credits-note')" "about 23 months at this pace"
contains "the rate is said once"         "$(row 'REAL c-days-note')" "₹94.95 to the dollar"
# How old the bill on screen is, on the Refresh that renews it: red and
# blinking once it is more than a day old.
contains "Refresh says when it was checked" "$(row AGE)" "AGE | Checked today"
contains "  not stale today"             "$(row AGE)" "stale=false"
contains "a day-old bill blinks red"      "$(row OLDAGE)" "stale=true"
echo "5b. a bill gone out of date by something since"
contains "a fresh check is not marked"   "$(row FRESH)" "stale=false title="
contains "an action since marks it"       "$(row CHANGED)" "stale=true"
contains "  and the hover says what, and when" "$(row CHANGED)" "Since then: you built a machine (today"
contains "  and that the bill runs a day behind" "$(row CHANGED)" "about a day behind"
check    "  on Home too"                  "$(row 'HOME CHANGED')" "HOME CHANGED | true"
# A heartbeat, at full strength, and hoverable - the old dimming class it once
# shared a name with turned the pointer off, hiding the reason.
contains "  it beats"                    "$(row BEAT)" "anim=cg-heartbeat"
contains "  can be hovered"              "$(row BEAT)" "pointer=auto"
contains "a new check clears it"          "$(row RECHECKED)" "stale=false"
check    "a running machine counts, once" "$(row RUNNING)" "RUNNING | a machine was running"
contains "the last bill comes back at start" "$(row RESTORED)" "RESTORED | ₹167"
# stale exactly when it is over a day old (on the 1st, a kept bill is younger).
r=$(row RESTORED); check "  marked with its age" "$(sed -E 's/.*stale=([a-z]+).*/\1/' <<<"$r")" "$(sed -E 's/.*expect=([a-z]+).*/\1/' <<<"$r")"

echo "2. day by day, in four plain columns"
check    "a day: played, machine, storage, other, total" "$(row 'REAL ROW0')" "REAL ROW0 | 10 Oct / 2.1 h / ₹118 / ₹14 / ₹1.90 / ₹134"
check    "an idle day says so"           "$(row 'REAL ROW1')" "REAL ROW1 | 13 Oct / – / – / ₹12 / ₹1.90 / ₹14"
contains "the month row adds up"         "$(row 'REAL ROW3')" "Month so far / 2.4 h"
contains "  to the same total"           "$(row 'REAL ROW3')" "/ ₹167"

echo "3. storage the bill charges that cg cannot see is not guessed at"
# The bill runs days behind: a game just deleted read as lost storage.
check    "no lost-storage warning"       "$(row 'REAL UNKNOWN')" "REAL UNKNOWN | hidden"
lacks    "  nor counted in the total"    "$(row 'REAL c-standby')" "₹370"
lacks    "no saved games, no Saved games row" "$(row 'REAL c-bills')" "Saved games"
contains "  and nothing stored says so"  "$(row 'REAL c-bills')" "Nothing is stored, so nothing is charged."
# A disk left behind is a row only when there is one; "none" only raised
# the question of what it was.
lacks    "  and no empty disk row"         "$(row 'REAL c-bills')" "disk"
contains "a bucket that explains it raises nothing" "$(row 'KNOWN UNKNOWN')" "hidden"
contains "  and standby is what cg knows" "$(row 'KNOWN c-standby')" "₹813 a month"
contains "  saved games with their size" "$(row 'KNOWN c-bills')" "Saved games →₹380 a month"
contains "  a disk left behind is named" "$(row 'KNOWN c-bills')" "Disk left by a deleted machine50 GB · ₹433 a month"
contains "no budget in AWS is said, in red" "$(row 'KNOWN c-cap-note')" "No budget alert is set up in AWS"

echo "3b. storage explained by games in another place"
# One Saved games row for every location, with the other place said under it.
contains "they are counted in one row"   "$(row 'AWAY c-bills')" "Saved games →₹386 a month"
# A list, each row pointing at its page - where the games are is on Games.
lacks    "  with no note under it"        "$(row 'AWAY c-bills')" "which your machine does not use"
contains "recurring is what charges whether or not you play" "$(row 'REAL c-standby-sub')" "Charged every month, whether or not you play."
lacks    "  not a row of their own"      "$(row 'AWAY c-bills')" "Saved in ap-south-2"
contains "  and counted in standby"      "$(row 'AWAY c-standby')" "₹386 a month"
contains "  so nothing is a mystery"     "$(row 'AWAY UNKNOWN')" "hidden"
check    "  and AWS was not asked again" "$(row 'AWAY RAN')" "AWAY RAN | 0"
check    "Saved games opens the Games page" "$(row WENT)" "WENT | library"

echo "3c. what playing adds, and a machine that exists"
contains "playing adds the machine, by the hour" "$(row PLAY)" "Playing adds ₹16 an hour for the machine."
# 0.10 x 100 + 0.5 + 100 x 0.0912 / 720 x 100 = 10 + 0.5 + 1.27 = 11.77; 0.15 -> 16.77
check    "a machine not built yet: the spread across zones" "$(row PLANNED)" "PLANNED | ₹11.77–₹16.77"
check    "  one that runs: its own zone, address and disk"  "$(row 'IN ZONE')" "IN ZONE | ₹16.77"
check    "  the disk counts by its size"  "$(row 'BIG DISK')" "BIG DISK | ₹18.03"
contains "closed mid-build: the card says it is building" "$(row HALF)" "HALF | Building your machine"
contains "  and offers no Play"            "$(row HALF)" "play=false"
contains "  the build is picked up again"  "$(row HALF)" "ran=1"
contains "  without leaving the page"      "$(row HALF)" "stayed=true"
check    "  once, not on every status"     "$(row 'HALF AGAIN')" "HALF AGAIN | ran=1"
contains "status after a Refresh reaches Spending's card too" "$(row 'SAME PLAY')" "Playing adds ₹16 an hour for the machine. == Playing adds ₹16 an hour for the machine."
contains "a stopped machine is its own row"  "$(row STOPPED)" "Machine (stopped) →₹433 a month"
lacks    "  not a disk left behind"           "$(row STOPPED)" "Disk left by a deleted machine"

echo "4. free streaming"
contains "used of free"                  "$(row 'REAL c-egress')" "0.4 of 100 GB used this month"
# What was used is measured; the hours are the most the quality setting could
# use, so they are a floor - "at least".
contains "used, from the bill"           "$(row 'REAL c-egress-src')" "From your bill."
contains "  the worst case, as a floor"  "$(row 'REAL c-egress-note')" "Even at your full quality (20 Mbps, 60 fps, Moonlight's own resolution: about 9 GB an hour), at least 11 more hours are free. After that, ₹10 a GB."

echo "5. none of the old words"
for w in '$' 'box' 'S3' 'egress' 'Cost Explorer' 'elastic' 'lambda' 'standby' 'COMPUTE' 'API'; do
  lacks "no '$w'" "$(row 'REAL PAGE')" "$w"
done

echo "6. nothing threw"
check "no painter threw"                 "$(grep -c '^THREW' <<<"$OUT")" "0"
check "  and the page logged no errors"  "$(row ERRS)" "ERRS | "

echo ""
echo "cost-dom: $pass passed, $fail failed"
(( fail == 0 ))
