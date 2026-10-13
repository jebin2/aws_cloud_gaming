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
# layout: two addresses, which is what the setting's own note invites.
cat > "$T/r/probe.js" <<'PROBE'
(() => {
  const R = [
    { key:'GAME_INSTANCE_TYPE', kind:'text', value:'g4dn.xlarge', default:'g4dn.xlarge',
      is_set:true, secret:false, note:'The GPU box.', label:'instance type', group:'The box' },
    { key:'GAME_DISK_GB', kind:'number', value:'80', default:'50', rule:'30',
      is_set:true, secret:false, note:'Root disk. Cannot be shrunk later.', label:'root disk (GB)', group:'The box' },
    { key:'GAME_STEAM_LOGIN', kind:'choice', value:null, default:'use', rule:'use,fresh',
      is_set:false, secret:false,
      note:'Whether a new box restores the archived Steam login, or asks you to sign in.', label:'Steam sign-in', group:'The box' },
    { key:'GAME_NTFY_URL', kind:'text', value:null, default:null, is_set:true, secret:true,
      note:'Phone notifications: an ntfy topic or full URL. Empty turns them off.', label:'phone notifications', group:'Notifications' },
    { key:'EMAIL_ALERTS', kind:'text', is_set:true, secret:false, default:null,
      value:'someone@example.com,someone.else.with.a.long.address@example.com',
      note:'Where budget alerts are sent. Comma separated for several.', label:'billing alerts to', group:'Notifications' },
    { key:'TAILSCALE_API_KEY', kind:'text', value:null, default:null, is_set:false, secret:true,
      note:'Tailscale API token. Prunes old nodes and turns off key expiry. Empty goes without.', label:'Tailscale API token', group:null },
  ];
  const out = [];
  const R2 = e => Math.round(e.getBoundingClientRect().right);
  try {
    paintConfig(R);
    for (const sec of document.querySelectorAll('main section[data-view]'))
      sec.hidden = sec.dataset.view !== 'settings';
    for (const r of R) {
      const row = [...document.querySelectorAll('#s-groups .row')]
        .find(el => el.textContent.includes(r.label || r.key));
      // A setting with a card of its own has no row in the list - see OWN_CARD.
      if (!row) { out.push(r.key + ' | NOROW'); continue; }
      const card = row.closest('.rounded-lg');
      const right = row.lastElementChild;
      const val = right.querySelector('span');
      const btns = [...right.querySelectorAll('button')];
      const cardRight = R2(card) - 24;   // the card's padding (p-space-lg)
      out.push([
        r.key,
        'card=' + card.firstElementChild.textContent.split(/[A-Z]/)[0].trim(),
        'group=' + card.querySelector('.uppercase').textContent.trim(),
        'valueFits=' + (val ? (R2(val) <= cardRight ? 'yes' : 'no (' + (R2(val) - cardRight) + 'px over)') : 'none'),
        'btnRight=' + (btns.length ? btns.map(b => R2(b)).join('/') : 'none'),
        'btnFits=' + (btns.every(b => R2(b) <= cardRight) ? 'yes' : 'no'),
        'labelW=' + Math.round(row.firstElementChild.getBoundingClientRect().width),
      ].join(' | '));
    }
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
  "$BROWSER" --headless --disable-gpu --no-sandbox --window-size="$1,900" \
    --virtual-time-budget=5000 --dump-dom "file://$T/r/index.html" 2>/dev/null \
  | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"geo\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")'
}
row() { grep -m1 "^$1 " <<<"$GEO" || true; }
field() { sed -n "s/.*| $2=\([^|]*\).*/\1/p" <<<"$(row "$1")" | tr -d ' '; }

for W in 1000 1280; do
  GEO=$(geo "$W")
  echo "at ${W}px wide"
  [[ $GEO == *"NO PROBE OUTPUT"* ]] && { echo "  FAIL the page did not render"; fail=$((fail+1)); continue; }

  # The one that broke. 60 characters of value must stay inside its own card.
  check "  a two-address value stays in its card" "$(field EMAIL_ALERTS valueFits)" "yes"
  check "    and its button too"                  "$(field EMAIL_ALERTS btnFits)"   "yes"
  # Zero is what the label column was: the name and note had nowhere to go.
  if (( $(field EMAIL_ALERTS labelW) > 100 )); then
    echo "  ok     leaving the name and note room to read"; pass=$((pass+1))
  else echo "  FAIL   the label column is $(field EMAIL_ALERTS labelW)px wide"; fail=$((fail+1)); fi

  # Alignment is one number: every button in a card ends at the same x.
  check "  Edit lines up with the secret row's Replace" \
        "$(field EMAIL_ALERTS btnRight)" "$(field GAME_NTFY_URL btnRight | cut -d/ -f2)"
  check "  a long note does not push a value out" "$(field GAME_NTFY_URL valueFits)" "yes"
  check "  nor a choice's label"                  "$(field GAME_STEAM_LOGIN valueFits)" "yes"
  check "  and nothing threw"                     "$(sed -n 's/^ERRS | //p' <<<"$GEO")" ""
done

echo "a setting with its own card has no row here"
# Two places to set one thing is exactly the drift this app keeps removing:
# the API token is shown and set on the Tailscale card, which can also say
# whether Tailscale accepts it.
GEO=$(geo 1280)
check "the Tailscale token has no row"  "$(field TAILSCALE_API_KEY card)" ""
contains "  and it is not filed as unknown" "$GEO" "TAILSCALE_API_KEY | NOROW"
contains "notifications is its own group"   "$(row GAME_NTFY_URL)" "group=Notifications"

echo "the Steam sign-in is filed with the build settings"
# Not in "Everything else", which is where a setting the app has never heard of
# lands - correct for a new key, wrong for one with a label and a home.
GEO=$(geo 1280)
check "  it is in The box"       "$(field GAME_STEAM_LOGIN group)" "Thebox"
contains "  and named for people" "$(row GAME_STEAM_LOGIN)" "GAME_STEAM_LOGIN"

echo ""
echo "settings-layout: $pass passed, $fail failed"
(( fail == 0 ))
