#!/usr/bin/env bash
# The settings rows, measured rather than eyeballed.
#
# A value was free to take as much width as it wanted. Two alert addresses -
# 60 characters of code font - ran 83px PAST the right edge of its card, which
# pushed that row's Edit button 150px outside the card into the neighbouring
# column, and squeezed the name-and-note column to a width of exactly zero.
# The row read as scrambled text with a button floating somewhere else.
#
# Source greps cannot see that: every class involved was spelled correctly and
# the markup was the same for every row. Only layout says it. So this loads the
# real page, paints the real settings list, and asserts the geometry: nothing
# leaves its card, the buttons in a card share one right edge, and the label
# column keeps room to exist.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export HOME="$T"

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

BROWSER=""
for b in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$b" >/dev/null && { BROWSER=$b; break; }
done
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "settings-layout: 0 passed, 0 failed"; exit 0; }

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/"
cp app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

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

# The registry as cg reports it. EMAIL_ALERTS carries the shape that broke the
# layout - two addresses, which its own note invites - and lives on Guards now;
# the bitrate's value on Settings says what an hour of streaming costs, which
# makes it the longest value on that page.
cat > "$T/r/probe.js" <<'PROBE'
(() => {
  const R = [
    { key:'GAME_RES', kind:'text', value:'1920x1080', default:null, is_set:true, secret:false,
      note:'Moonlight resolution.', label:'stream resolution', group:'The stream' },
    { key:'GAME_FPS', kind:'number', value:null, default:'60', rule:'24', is_set:false, secret:false,
      note:'Moonlight frame rate.', label:'stream fps', group:'The stream' },
    { key:'GAME_BITRATE_KBPS', kind:'number', value:'20000', default:'20000', rule:'500', is_set:true, secret:false,
      note:'Moonlight bitrate.', label:'stream bitrate (kbps)', group:'The stream' },
    { key:'GAME_DISK_GB', kind:'number', value:'80', default:'50', rule:'30',
      is_set:true, secret:false, note:'Root disk. Cannot be shrunk later.', label:'root disk (GB)', group:'The box' },
    { key:'GAME_NTFY_URL', kind:'ntfy', value:'my-topic', default:null, is_set:true, secret:false,
      note:'Phone notifications: an ntfy topic or full URL. Empty turns them off.', label:'phone notifications', group:'Notifications' },
    { key:'EMAIL_ALERTS', kind:'text', is_set:true, secret:false, default:null,
      value:'someone@example.com,someone.else.with.a.long.address@example.com',
      note:'Where budget alerts are sent. Comma separated for several.', label:'billing alerts to', group:'Notifications' },
    { key:'GAME_REGION', kind:'region', value:'ap-south-1', default:'ap-south-2', is_set:true, secret:false,
      note:'Region.', label:'region', group:'The box' },
  ];
  const out = [];
  const R2 = e => Math.round(e.getBoundingClientRect().right);
  const measure = (page) => {
    for (const sec of document.querySelectorAll('main section[data-view]'))
      sec.hidden = sec.dataset.view !== page;
    for (const r of R) {
      const row = document.querySelector(`section[data-view="${page}"] .row[data-key="${r.key}"]`);
      if (!row) { out.push(page + ' ' + r.key + ' | NOROW'); continue; }
      const card = row.closest('.rounded-lg, .rounded-xl');
      const right = row.lastElementChild;
      const val = right.querySelector('span');
      const btns = [...right.querySelectorAll('button')];
      const cardRight = R2(card) - 24;   // the card's padding (p-space-lg)
      out.push([
        page + ' ' + r.key,
        'valueFits=' + (val ? (R2(val) <= cardRight ? 'yes' : 'no (' + (R2(val) - cardRight) + 'px over)') : 'none'),
        'btnRight=' + (btns.length ? btns.map(b => R2(b)).join('/') : 'none'),
        'btnFits=' + (btns.every(b => R2(b) <= cardRight) ? 'yes' : 'no'),
        'labelW=' + Math.round(row.firstElementChild.getBoundingClientRect().width),
      ].join(' | '));
    }
  };
  try {
    statusNow = { rates: { egress_gb: 0.1093, egress_free_gb: 100, inr_per_usd: 94.95 } };
    paintConfig(R);
    paintGuards({ instance_state: 'none', guards: [], budget: { usd: 57 }, shutdown_action: {} });
    measure('settings');
    measure('guards');
  } catch (e) { out.push('THREW | ' + e.message); }
  out.push('ERRS | ' + (window.__errs || []).join(' ;; '));
  const pre = document.createElement('pre');
  pre.id = 'geo'; pre.textContent = out.join('\n');
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

# Two widths, because the cards are a 1-column grid under xl and a 2-column one
# at or above it - and the narrow card is where an overflow shows first.
geo() { # geo <width>
  # Written to a file and then catted, rather than piped straight into python:
  # chromium's main process exits as soon as the DOM is dumped, but a child of
  # it keeps the write end of a pipe open for another 10-25 SECONDS, and
  # sys.stdin.read() waits for EOF. That idle wait, once per page load, was the
  # whole cost of this suite - minutes of it, at 0.5s of actual work per load.
  "$BROWSER" --headless --disable-gpu --no-sandbox --lang=en-IN --window-size="$1,900" \
    --virtual-time-budget=5000 --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
  cat "$T/dom.html" \
  | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"geo\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")'
}
row() { grep -m1 "^$1 " <<<"$GEO" || true; }
field() { sed -n "s/.*| $2=\([^|]*\).*/\1/p" <<<"$(row "$1")" | tr -d ' '; }

for W in 1000 1280; do
  GEO=$(geo "$W"); [[ -n ${CG_GEO_DUMP:-} ]] && printf "%s\n" "$GEO"
  echo "at ${W}px wide"
  [[ $GEO == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; fail=$((fail+1)); continue; }

  # The one that broke. 60 characters of value must stay inside its own card.
  check "  a two-address value stays in its card" "$(field 'guards EMAIL_ALERTS' valueFits)" "yes"
  check "    and its button too"                  "$(field 'guards EMAIL_ALERTS' btnFits)"   "yes"
  # Zero is what the label column was: the name and note had nowhere to go.
  if (( $(field 'guards EMAIL_ALERTS' labelW) > 100 )); then
    echo "  ok     leaving the name and note room to read"; pass=$((pass+1))
  else echo "  FAIL   the label column is $(field 'guards EMAIL_ALERTS' labelW)px wide"; fail=$((fail+1)); fi
  check "  the topic's Edit lines up with it" \
        "$(field 'guards EMAIL_ALERTS' btnRight)" "$(field 'guards GAME_NTFY_URL' btnRight)"
  # Settings' longest value: the bitrate, with what an hour of it costs.
  check "  the bitrate's cost stays in its card"  "$(field 'settings GAME_BITRATE_KBPS' valueFits)" "yes"
  check "    and its Edit lines up with the rest" \
        "$(field 'settings GAME_BITRATE_KBPS' btnRight)" "$(field 'settings GAME_FPS' btnRight)"
  if (( $(field 'settings GAME_BITRATE_KBPS' labelW) > 100 )); then
    echo "  ok     its name keeps room too"; pass=$((pass+1))
  else echo "  FAIL   the bitrate's label column is $(field 'settings GAME_BITRATE_KBPS' labelW)px wide"; fail=$((fail+1)); fi
  check "  and nothing threw"                     "$(sed -n 's/^ERRS | //p' <<<"$GEO")" ""
done

echo "each setting is on one page"
# Three copies of one setting is what Settings used to be.
GEO=$(geo 1280)
contains "the alerts are not on Settings"   "$GEO" "settings EMAIL_ALERTS | NOROW"
contains "  nor the region"                 "$GEO" "settings GAME_REGION | NOROW"
contains "  and the stream is not on Guards" "$GEO" "guards GAME_BITRATE_KBPS | NOROW"

echo ""
echo "settings-layout: $pass passed, $fail failed"
(( fail == 0 ))
