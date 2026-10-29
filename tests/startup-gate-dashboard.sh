#!/usr/bin/env bash
# Choosing a location, the location popup, and the dashboard: what is billing, in rupees.
# One of five files that were tests/startup-gate.sh; see lib/startup-gate-harness.sh.
GATE_NAME=startup-gate-dashboard
source "$(dirname "$0")/lib/startup-gate-harness.sh"

echo "4d. a region that cannot rent the machine is not 'ready'"
# An enabled region with no GPU quota looks completely set up and cannot build.
# That is the Malaysia case, and it read as a broken app rather than a step.
OUT=$(probe "{$READY, \"machines --json\": $machines_noquota, \"sweep --cached --json\": $FULL_SWEEP}")
contains "the pipeline stays up"       "$(row ONB)" "ONB | shown"
contains "  with where it runs active" "$(row STAGES)" "where=active"
contains "  naming the place, not a code" "$(row STAGETEXT)" "Hyderabad has no GPU quota for this machine"
contains "  offering the choice"       "$(row BUTTONS)" "where=Choose region"

echo "4d2. a region nobody chose is not a choice"
# A fresh laptop names no region, cg falls back to its default, the default
# rents the machine - and the stage used to tick itself. The pipeline finished
# and vanished without ever showing the list to choose from.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 20));
  const popup = document.getElementById('whereto').open;
  const usable = !document.getElementById('whereto-use').disabled;
  const useLabel = document.getElementById('whereto-use').textContent.trim();
  // From here on cg reports the region as written, the way the real one would.
  window.__answers['config --json'] = [
    {key: 'EMAIL_ALERTS', kind: 'text', secret: false, is_set: true, value: 'a@b.c'},
    {key: 'GAME_REGION', kind: 'text', secret: false, is_set: true, value: 'ap-south-2'}];
  window.__ran = [];
  document.getElementById('whereto-use').click();
  const wh = () => document.querySelector('#onb-steps [data-stage=\"where\"]');
  const during = wh().dataset.state + ':stop=' + [...wh().querySelectorAll('button')].some(b => /^Stop/.test(b.textContent.trim()))
    + ':close=' + (document.getElementById('adddlg-close').disabled ? 'off' : 'on');
  await new Promise(r => setTimeout(r, 60));
  const at = n => n === 'onb' ? (document.getElementById('adddlg').open ? 'shown' : 'hidden') : document.getElementById(n).hidden ? 'hidden' : 'shown';
  // The last step just went green: the finished list is held for a beat.
  // Redraw on purpose, 50ms after the change: the tick must still be there,
  // carrying on from 50ms in rather than starting again.
  await new Promise(r => setTimeout(r, 50));
  paintOnboard();
  const tick = document.querySelector('[data-stage=\"where\"] .onb-tick');
  const closeAfter = document.getElementById('adddlg-close').disabled ? 'off' : 'on';
  const held = 'closeAfter=' + closeAfter + ' held=' + at('onb') + '/' + at('d-main') + ' count='
             + document.getElementById('onb-count').textContent.trim()
             + ' tick=' + !!tick
             // Redrawn since the change, so it must be resuming, not restarting.
             + ' resumed=' + (tick ? parseFloat(tick.style.animationDelay) < 0 : 'none');
  await new Promise(r => setTimeout(r, 1200));
  return held + ' then=' + at('onb') + '/' + at('d-main') + ' during=' + during
       + ' use=' + useLabel + ' popup=' + popup + ' usable=' + usable
       + ' saved=' + window.__ran.includes('config set GAME_REGION ap-south-2')
       + ' reread=' + window.__ran.includes('config --json')
       + ' where=' + document.querySelector('#onb-steps [data-stage=\"where\"]').dataset.state
       + ' status=' + window.__ran.includes('status --json');
};"
# A scan where Hyderabad can rent the machine, so it can be picked.
FIT_SWEEP='{"cached": true, "age_seconds": 90, "too_far": [], "unreachable": [],
            "regions": [{"region": "ap-south-2", "city": "Asia Pacific (Hyderabad)",
                         "rtt_ms": 19, "enabled": true,
                         "machines": [{"type": "g6.xlarge", "fits_spot": true, "fits_ondemand": true,
                                       "inr_hour_spot": 16, "inr_hour_ondemand": 85}]}]}'
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $FIT_SWEEP,
              \"config set GAME_REGION ap-south-2\": {}}")
contains "the pipeline stays up"        "$(row ONB)" "ONB | shown"
contains "  with where it runs active"  "$(row STAGES)" "where=active"
contains "  asking, not blaming"        "$(row STAGETEXT)" "Choose a region. Lower latency is better."
# Saving a region is a write to .env, done in a blink: no Stop while it runs.
contains "saving the region offers no Stop" "$(row AFTER)" "during=running:stop=false"
# Closed mid-step, the step carried on unseen: Close waits for it.
contains "  nor Close while it runs"        "$(row AFTER)" ":close=off"
contains "  and Close is back once it is done" "$(row AFTER)" "closeAfter=on"
lacks    "  and no region is accused"   "$(row STAGETEXT)" "no GPU quota"
# The stage is judged on cg machines, which is behind the gate: it must not
# be what keeps the gate shut, or the list it opens has nothing in it.
contains "the reads behind the gate ran" "$(row RAN)" "machines --json"
contains "  and so did the scan"        "$(row RAN)" "sweep --cached --json"
contains "its button opens the list"    "$(row AFTER)" "popup=true"
contains "  with the region in use offered" "$(row AFTER)" "usable=true"
contains "  on a button that names it"  "$(row AFTER)" "use=Use Hyderabad"
contains "using it reaches cg"          "$(row AFTER)" "saved=true"
# Not a write by cg's contract, so the popup has to ask for the read itself -
# without it the stage sat on "Pick where it runs" after you had picked.
contains "  and the setting is re-read" "$(row AFTER)" "reread=true"
contains "  so the stage is done"       "$(row AFTER)" "where=done"
# Everything behind the gate is per region, so it is read again for the new one.
contains "  and the box is read for it" "$(row AFTER)" "status=true"
# A checklist you watched finish is held for a beat - six ticks replaced in
# 200ms reads as a glitch - and then the dashboard arrives.
contains "the finished list is held"    "$(row AFTER)" "held=shown/shown"
contains "  counting it"                "$(row AFTER)" "count=6 of 6 done"
contains "  the tick lands, animated"   "$(row AFTER)" "tick=true"
contains "  and a redraw resumes it"    "$(row AFTER)" "resumed=true"
contains "  then it closes on Home"     "$(row AFTER)" "then=hidden/shown"
ENGINE=""

echo "4d3. choosing the location waits for that location's reads"
# Saving the region ticked the last step before the reads for the new region
# had started, so the beat ran out with nothing to wait for and the dashboard
# opened on "Stop refresh". The reads start with the save, and the beat is a
# minimum, not a deadline.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 20));
  window.__answers['config --json'] = [
    {key: 'EMAIL_ALERTS', kind: 'text', secret: false, is_set: true, value: 'a@b.c'},
    {key: 'GAME_REGION', kind: 'text', secret: false, is_set: true, value: 'ap-south-2'}];
  window.__slow = ['status --json']; window.__slowMs = 1500;
  document.getElementById('whereto-use').click();
  const at = n => n === 'onb' ? (document.getElementById('adddlg').open ? 'shown' : 'hidden') : document.getElementById(n).hidden ? 'hidden' : 'shown';
  await new Promise(r => setTimeout(r, 1200));
  const mid = at('onb') + '/' + at('d-main');
  await new Promise(r => setTimeout(r, 1500));
  return 'mid=' + mid + ' end=' + at('onb') + '/' + at('d-main') + ' stop=' + at('cancel');
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $FIT_SWEEP,
              \"config set GAME_REGION ap-south-2\": {}}")
contains "past the beat, the box still out: held" "$(row AFTER)" "mid=shown/shown"
contains "  then it closes, the card filled"     "$(row AFTER)" "end=hidden/shown"
contains "  with nothing left running"           "$(row AFTER)" "stop=hidden"
ENGINE=""

echo "4d4. choosing a location saves the machine it showed"
# The popup shows a machine for each location and saved only the location: a
# g4dn.xlarge chosen for Mumbai went to Hyderabad, which has none, and the
# build stopped at its first step. The machine already chosen is kept where
# it is offered; elsewhere the one shown is saved, before the location.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 20));
  const shown = document.querySelector('#whereto-table tr[data-region=\"ap-south-2\"]').textContent;
  window.__ran = [];
  document.getElementById('whereto-use').click();
  await new Promise(r => setTimeout(r, 200));
  const at = c => window.__ran.indexOf(c);
  return 'shown=' + shown.includes('g6.xlarge')
       + ' type=' + (at('config set GAME_INSTANCE_TYPE g6.xlarge') >= 0)
       + ' first=' + (at('config set GAME_INSTANCE_TYPE g6.xlarge') < at('config set GAME_REGION ap-south-2'));
};"
cfg_g4dn='[{"key":"EMAIL_ALERTS","kind":"text","secret":false,"is_set":true,"value":"a@b.c","default":null,"note":"n"},
  {"key":"GAME_INSTANCE_TYPE","kind":"text","secret":false,"is_set":true,"value":"g4dn.xlarge","default":"g6.xlarge","note":"n"}]'
OUT=$(probe "{$READY, \"config --json\": $cfg_g4dn, \"sweep --cached --json\": $FIT_SWEEP,
              \"config set GAME_INSTANCE_TYPE g6.xlarge\": {}, \"config set GAME_REGION ap-south-2\": {}}")
contains "the location shows the machine it has" "$(row AFTER)" "shown=true"
contains "  and using it saves that machine"     "$(row AFTER)" "type=true"
contains "  before the location"                 "$(row AFTER)" "first=true"
OUT=$(probe "{$READY, \"config --json\": ${cfg_g4dn//g4dn.xlarge/g6.xlarge}, \"sweep --cached --json\": $FIT_SWEEP,
              \"config set GAME_REGION ap-south-2\": {}}")
lacks    "a machine it offers is left alone"     "$(row AFTER)" "type=true"
ENGINE=""

echo "4e. the location popup on a laptop that has never measured"
# It opened on an empty table with two greyed buttons and only Cancel live -
# while the measuring it needed was running, twice: the app had started one by
# itself and the popup started another on top.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 30));
  const at = n => n === 'onb' ? (document.getElementById('adddlg').open ? 'shown' : 'hidden') : document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'busy=' + at('whereto-busy') + ' list=' + at('whereto-list')
       + ' use=' + at('whereto-use') + ' measure=' + at('whereto-measure')
       + ' sweeps=' + window.__ran.filter(c => c === 'sweep --json').length;
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $EMPTY_SWEEP}")
contains "it says it is measuring"        "$(row AFTER)" "busy=shown"
contains "  instead of an empty table"    "$(row AFTER)" "list=hidden"
contains "  with nothing greyed to press" "$(row AFTER)" "use=hidden measure=hidden"
contains "  and measures once, not twice" "$(row AFTER)" "sweeps=1"

echo "4e2. measuring again shows it is measuring"
# Pressing "Measure again" with a table already up used to change one grey line
# and nothing else - it looked like the button did nothing.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 30));
  document.getElementById('whereto-measure').click();
  await new Promise(r => setTimeout(r, 30));
  const at = n => n === 'onb' ? (document.getElementById('adddlg').open ? 'shown' : 'hidden') : document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'busy=' + at('whereto-busy') + ' spinner=' + !!document.querySelector('#whereto-busy .spinner')
       + ' text=' + document.getElementById('whereto-busy-text').textContent.trim()
       + ' list=' + at('whereto-list') + ' stale=' + document.getElementById('whereto-list').classList.contains('stale')
       + ' use=' + at('whereto-use');
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $FIT_SWEEP}")
contains "a spinner, while it measures"   "$(row AFTER)" "busy=shown spinner=true"
contains "  saying it is measuring again"  "$(row AFTER)" "text=Measuring again"
contains "  the old table kept, faded"     "$(row AFTER)" "list=shown stale=true"
contains "  and not choosable meanwhile"   "$(row AFTER)" "use=hidden"
ENGINE=""

echo "4f. a measurement that fails says why, and offers another go"
ENGINE="window.__broken = ['sweep --json'];
window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 30));
  const at = n => n === 'onb' ? (document.getElementById('adddlg').open ? 'shown' : 'hidden') : document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'busy=' + at('whereto-busy') + ' err=' + at('whereto-err')
       + ' why=' + document.getElementById('whereto-err').textContent.trim()
       + ' measure=' + document.getElementById('whereto-measure').textContent.trim()
       + '/' + at('whereto-measure');
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $EMPTY_SWEEP}")
contains "it stops saying measuring"      "$(row AFTER)" "busy=hidden"
contains "  says it failed"               "$(row AFTER)" "err=shown"
contains "  in cg's words"                "$(row AFTER)" "could not reach AWS"
contains "  and offers another go"        "$(row AFTER)" "measure=Try again/shown"
ENGINE=""

echo "6. the dashboard: what is billing, item by item, in rupees"
# It used to say "nothing is billing by the hour" and stop there - while the game
# archive, a disk left behind or a reserved address billed by the month. Now it
# lists each thing that costs money with what it costs, or says there are none.
DASH="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const t = id => document.getElementById(id).innerText.replace(/\\s+/g, ' ').trim();
  const q = s => { const e = document.querySelector(s); return e ? e.innerText.replace(/\\s+/g, ' ').trim() : ''; };
  const shown = id => !document.getElementById(id).hidden;
  return 'title=' + q('#d-machine-card [data-f=title]') + ' | machine=' + q('#d-machine-card [data-f=what]')
       + ' | where=' + q('#d-machine-card [data-f=where]') + ' | same=' + (q('#d-machine-card [data-f=where]') === q('#b-machine-card [data-f=where]'))
       // Home's tile as a machine of yours's: its name, and Details, not Delete.
       + ' | name=' + document.querySelector('#d-machine-card p').textContent.trim()
       + ' | bill=' + t('d-recurring-card')
       + ' | month=' + q('#d-month-card [data-f=total]') + ' | monthsub=' + q('#d-month-card [data-f=sub]')
       + ' | src=' + t('d-month-src')
       + ' | price=' + t('d-cost-price')
       + ' | games=' + t('d-games')
       + ' | protect=' + t('d-protect')
       + ' | buttons=' + ['d-build', 'd-open', 'd-destroy', 'd-details'].filter(shown).join(',')
       + ' | destroy=' + t('b-destroy');
};"

ENGINE="$DASH"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0, "snapshots": 0, "elastic_ips": 0}' '{"limit": 57, "spent": 4.5, "alerts": 2}')}")
contains "no machine, said plainly"        "$(row AFTER)" "title=No machine running"
lacks    "  not 'nothing is billed'"        "$(row AFTER)" "billed by the hour"
contains "  what it would be"              "$(row AFTER)" "machine=g6.xlarge · NVIDIA L4"
contains "  where, how, and what it would cost" "$(row AFTER)" "where=Hyderabad · Spot, else on-demand · ₹16.44/hour"
contains "  the same card as the Machine page" "$(row AFTER)" "same=true"
contains "  named, as a machine of yours is" "$(row AFTER)" "name=AWS"
lacks    "  and no build time on Home"     "$(row AFTER)" "ready in about"
# Recurring cost is the Spending page's card, from the bill: unchecked, it waits.
contains "recurring waits for the bill"    "$(row AFTER)" "bill=— Exact cost reads the bill."
# The month is the bill, checked on request. AWS Budgets' figure is after
# credits - it read Rs 0 while Rs 285 had been used - so it is not shown.
contains "the month waits for a check"     "$(row AFTER)" "month=— | monthsub=Use Exact cost to load it."
lacks    "  not Budgets' after-credit figure" "$(row AFTER)" "₹396"
contains "the exact figure's price, in rupees" "$(row AFTER)" "price=₹0.88"
contains "no games yet"                    "$(row AFTER)" "games=No saved games"
contains "the budget is protection"        "$(row AFTER)" "Budget alert at ₹5,016 · emails 2 addresses"
contains "one action: build, and details"  "$(row AFTER)" "buttons=d-build,d-details |"
lacks    "no dollars anywhere on it"       "$(row AFTER)" "$"

OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st '{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "public_ip": "13.1.1.1", "launched": "2026-01-01T00:00:00Z"}' \
     '{"bytes": 136365211648, "usd_month": 3.18, "expiry_days": 14}' \
     '{"volumes_gb": 50, "snapshots": 0, "elastic_ips": 0}' '{"limit": 57, "spent": 4.5, "alerts": 2}')}")
contains "a running machine: ready"        "$(row AFTER)" "title=Ready to play"
# Home shows the bill as last checked, like Spending - not what exists this
# minute. A build showed on Home and not on Spending; now both wait for a check.
lacks    "  the bill's view, not a live list" "$(row AFTER)" "Public IP address"
contains "play and details, nothing else"  "$(row AFTER)" "buttons=d-open,d-details |"
# Delete is the Machine page's, as removing a machine of yours is.
contains "  delete, on the Machine page"   "$(row AFTER)" "destroy=Delete machine"
lacks    "    anywhere on the page"         "$(row AFTER)" "Destroy"

OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 30, "snapshots": 2, "snapshots_gb": 80, "elastic_ips": 1}' '{"limit": 57, "spent": 4.5, "alerts": 2}')}")
# Leftovers are the bill's to say, on both pages: not drawn on Home from the
# live read any more. (A disk left behind is a Recurring cost row - cost-dom.)
lacks    "leftovers are not a live list on Home" "$(row AFTER)" "Snapshots ·"
echo "6b. the dashboard: Tailscale"
TS="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const t = id => document.getElementById(id).innerText.replace(/\\s+/g, ' ').trim();
  return 'ts=' + t('d-ts') + ' | signin=' + !document.getElementById('d-ts-signin').hidden
       + ' | pings=' + window.__ran.filter(c => c === 'ping --json').length;
};"
ENGINE="$TS"
KEPT_ENGINE="$ENGINE"
echo "6b2. games in another location count, by name; the last bill check is remembered"
# Diablo IV sits in Hyderabad, billing, while the machine's location has none:
# Home said "No billing items" and "No games saved yet" over it.
HOMEGAMES="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const t = id => document.getElementById(id).innerText.replace(/\\s+/g, ' ').trim();
  const q = s => { const e = document.querySelector(s); return e ? e.innerText.replace(/\\s+/g, ' ').trim() : ''; };
  const before = 'bill=' + t('d-recurring-card') + ' | games=' + t('d-games') + ' | month=' + q('#d-month-card [data-f=total]');
  // A bill check, as Spending makes one.
  paintSpend({ month: { total_usd: 3.0, total_inr: 285, projected_usd: 5.82, projected_inr: 553,
                        hours: { on_demand: 0, spot: 3.8 } },
               rates: { inr_per_usd: 95 }, resources: { budget_usd: 57 },
               standby: { usd_month: 0, archive_usd_month: 0 }, archive: {} });
  const remembered = 'bill=' + t('d-recurring-card') + ' | month=' + q('#d-month-card [data-f=total]')
    + ' | monthsub=' + q('#d-month-card [data-f=sub]') + ' | src=' + t('d-month-src');
  costNow = null; costNowAt = null;
  localStorage.setItem('cg.lastCost', JSON.stringify({ total_inr: 999, at: '2020-01-05T10:00:00Z' }));
  paintDash();
  const stale = 'month=' + q('#d-month-card [data-f=total]');
  document.getElementById('d-bill-more').click();
  const went = document.querySelector('.nav-item.on').dataset.view;
  document.querySelector('.nav-item[data-view=dashboard]').click();
  window.__ran = [];
  document.getElementById('d-cost').click();
  await new Promise(r => setTimeout(r, 30));
  const exact = 'view=' + document.querySelector('.nav-item.on').dataset.view
    + ' popup=' + document.getElementById('refdlg').open + ':' + document.getElementById('refdlg-title').textContent
    + ' ran=' + window.__ran.filter(l => l.startsWith('cost')).join(';');
  return before + ' | remembered: ' + remembered + ' | stale: ' + stale
       + ' | went=' + went + ' | exact: ' + exact;
};"
ENGINE="$HOMEGAMES"
HG_ELSE='{"error": null, "region": "ap-south-1", "inr_per_usd": 88, "expiry_days": 14, "places": [
  {"bucket": "cg-library-old", "region": "ap-south-2", "error": null, "bytes": 174813455930, "usd_month": 4.07,
   "games": [{"appid": "2344520", "name": "Diablo IV", "bytes": 174813206488}], "login": false}]}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"library list --json\": {\"games\": [], \"total_bytes\": 0, \"bucket\": \"b\", \"login\": {\"present\": false}},
  \"library elsewhere --json\": $HG_ELSE,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "unchecked, recurring waits"     "$(row AFTER)" "bill=— Exact cost reads the bill."
contains "  games elsewhere listed by name" "$(row AFTER)" "games=Diablo IV"
# Once the bill is checked, the games in Hyderabad are in it, on Home as on Spending.
contains "checked, games elsewhere count"  "$(row AFTER)" "remembered: bill=₹387 a month"
contains "  the month from the bill"       "$(row AFTER)" "month=₹285"
contains "  with its pace"                 "$(row AFTER)" "projected ₹553"
contains "  and when it was checked"       "$(row AFTER)" "src=Checked today"
contains "a check from another month is not this one" "$(row AFTER)" "stale: month=—"
contains "Show details opens Spending"     "$(row AFTER)" "went=cost"
contains "Exact cost opens Spending and refreshes it" "$(row AFTER)" "exact: view=cost popup=true:Refreshing Spending ran=cost --json"
ENGINE="$KEPT_ENGINE"

OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "the laptop, by name"             "$(row AFTER)" "This device: signed in as laptop"
contains "  no machine yet, said as what happens" "$(row AFTER)" "Machine: joins on build"
contains "  and no path to measure"        "$(row AFTER)" "pings=0"
contains "  nothing to sign in to"         "$(row AFTER)" "signin=false"

ONLINE=$(st '{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}' '{"bytes": 0}' '{"volumes_gb": 50}' '{"limit": 57}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d["tailnet"]={"node":"gamevps","online":True}; print(json.dumps(d))')
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP, \"status --json\": $ONLINE,
  \"ping --json\": {\"node\": \"gamevps\", \"path\": \"direct\", \"median_ms\": 18}}")
contains "a running machine, online"       "$(row AFTER)" "Machine: connected"
contains "  the path, measured once"       "$(row AFTER)" "Direct connection · 18 ms"
contains "  only once"                     "$(row AFTER)" "pings=1"

OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP, \"status --json\": $ONLINE,
  \"ping --json\": {\"node\": \"gamevps\", \"path\": \"DERP\", \"median_ms\": 74}}")
contains "a relayed path says it is slower" "$(row AFTER)" "Relayed · 74 ms · higher latency"

ENGINE="$DASH"
# An older cg sends no price table: every figure is unknown, never ₹0.
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": {\"box\": null, \"region\": \"ap-south-2\", \"instance_type\": \"g6.xlarge\",
     \"archive\": {\"bytes\": 1073741824, \"usd_month\": 0.03}, \"res\": {\"volumes_gb\": 0},
     \"budget\": {\"limit\": 57, \"spent\": 4.5}, \"config\": {}, \"local\": {}, \"account\": {}}}")
contains "no price table: nothing is invented" "$(row AFTER)" "bill=— Exact cost reads the bill."
lacks    "  never zero"                    "$(row AFTER)" "₹0.00"
ENGINE=""


gate_finish
