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
  const text = id => document.getElementById(id).innerText.replace(/\s+/g, ' ').trim();
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
                      'c-standby', 'c-bills', 'c-egress', 'c-egress-note'])
      out.push(label + ' ' + id + ' | ' + text(id));
    out.push(label + ' UNKNOWN | ' + (document.getElementById('c-unknown').hidden ? 'hidden' : text('c-unknown')));
    out.push(label + ' CHIP | ' + (document.getElementById('c-cap-chip').hidden ? 'hidden' : text('c-cap-chip')));
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
    out.push('AWAY RAN | ' + window.__ran.length);
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
contains "  hours played and the pace"   "$(row 'REAL c-month-sub')" "so far · 2.4 h played · on pace for ₹553 by 31 Oct"
contains "the budget is yours, as set"   "$(row 'REAL c-cap-note')" "Budget ₹5,000 a month - it emails you, it stops nothing."
lacks    "  not AWS's dollars turned back" "$(row 'REAL c-cap-note')" "5,412"
contains "  and the bar's verdict"       "$(row 'REAL CHIP')" "under the budget"
contains "credits in rupees"             "$(row 'REAL c-credits')" "₹12,854 left"
contains "  and how long they last"      "$(row 'REAL c-credits-note')" "about 23 months at this pace"
contains "the rate is said once"         "$(row 'REAL c-days-note')" "₹94.95 to the dollar"
contains "  and what a Refresh costs"    "$(row 'REAL c-days-note')" "each Refresh costs ₹0.95"

echo "2. day by day, in four plain columns"
check    "a day: played, machine, storage, other, total" "$(row 'REAL ROW0')" "REAL ROW0 | 10 Oct / 2.1 h / ₹118 / ₹14 / ₹1.90 / ₹134"
check    "an idle day says so"           "$(row 'REAL ROW1')" "REAL ROW1 | 13 Oct / – / – / ₹12 / ₹1.90 / ₹14"
contains "the month row adds up"         "$(row 'REAL ROW3')" "Month so far / 2.4 h"
contains "  to the same total"           "$(row 'REAL ROW3')" "/ ₹167"

echo "3. storage the bill charges that cg cannot see"
contains "the warning is said"           "$(row 'REAL UNKNOWN')" "AWS bills ₹370 a month more storage than your saved games explain"
contains "  and counted in standby"      "$(row 'REAL c-standby')" "₹370 a month"
contains "the saved games, as cg sees them" "$(row 'REAL c-bills')" "Saved gamesnone · ₹0"
contains "a bucket that explains it raises nothing" "$(row 'KNOWN UNKNOWN')" "hidden"
contains "  and standby is what cg knows" "$(row 'KNOWN c-standby')" "₹813 a month"
contains "  saved games with their size" "$(row 'KNOWN c-bills')" "Saved games160.2 GB · ₹380 a month"
contains "  a leftover disk is named"    "$(row 'KNOWN c-bills')" "Leftover disks50 GB · ₹433 a month"
contains "no budget in AWS is said, in red" "$(row 'KNOWN c-cap-note')" "No spending alert exists in AWS"

echo "3b. storage explained by games in another place"
contains "they are named in the list"    "$(row 'AWAY c-bills')" "Saved in ap-south-2162.8 GB · ₹386 a month - not used, see Library"
contains "  and counted in standby"      "$(row 'AWAY c-standby')" "₹386 a month"
contains "  so nothing is a mystery"     "$(row 'AWAY UNKNOWN')" "hidden"
check    "  and AWS was not asked again" "$(row 'AWAY RAN')" "AWAY RAN | 0"

echo "4. free streaming"
contains "used of free"                  "$(row 'REAL c-egress')" "0.4 of 100 GB used this month"
contains "  hours left, then the price an hour" "$(row 'REAL c-egress-note')" "About 11 h of play left free, then ₹10 a GB - about ₹93 an hour at your quality."

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
