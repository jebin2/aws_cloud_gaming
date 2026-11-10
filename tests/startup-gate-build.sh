#!/usr/bin/env bash
# The Build page, play as a session, and the Games table.
# One of five files that were tests/startup-gate.sh; see lib/startup-gate-harness.sh.
GATE_NAME=startup-gate-build
source "$(dirname "$0")/lib/startup-gate-harness.sh"

echo "7. the Build page: a build is eight plain steps"
# ayis reports a dozen steps of its own and the box a dozen more ("installing
# nvidia driver", "configuring headless X"); the page shows eight, in plain
# words, with the bill in the heading from the moment the machine is rented.
BUILD="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  const plan = !document.getElementById('b-plan').hidden;
  const chip = (document.querySelector('#b-machine-card [data-f=where]') || {}).textContent;
  // The confirm dialog is its own suite's business; here it is answered yes,
  // and what it would have asked is kept.
  let ask = '';
  window.askConfirm = async o => { ask = o.body.replace(/\\s+/g, ' '); return true; };
  document.getElementById('b-build').click();
  await new Promise(r => setTimeout(r, 30));
  const id = window.__lastId;
  const step = t => window.__emit(id, { t: 'step', text: t });
  const line = t => window.__emit(id, { t: 'line', text: t });
  for (const t of ['updating the cloud watchdog: settings changed', 'preflight',
                   'arming the budget before anything launches', 'provisioning instance']) step(t);
  line('launching g6.xlarge (spot)');
  step('waiting for the box to join the tailnet');
  step('building the box - live progress below (10-20 min)');
  step('installing base packages');
  step('installing nvidia driver (the slowest step, ~10 min)');
  line('nvidia-driver-580 unpacked');
  await new Promise(r => setTimeout(r, 30));
  const st = () => [...document.querySelectorAll('#b-steps [data-step]')]
    .map(r => r.dataset.step + '=' + r.dataset.state).join(',');
  const mid = 'mid=' + st() + ' | title=' + document.getElementById('b-strip-title').textContent
    + ' | meta=' + document.getElementById('b-strip-meta').textContent
    + ' | now=' + document.getElementById('b-run-now').textContent
    + ' | count=' + document.getElementById('b-run-step').textContent
    + ' | tiles=' + (document.getElementById('b-run-tiles').hidden ? 'hidden'
      : document.getElementById('b-run-tiles').innerText.replace(/\\s+/g, ' '))
    + ' | text=' + document.getElementById('b-steps').innerText.replace(/\\s+/g, ' ')
    + ' | plan=' + !document.getElementById('b-plan').hidden;
  window.__emit(id, { t: 'line', kind: 'fail', text: 'the driver did not install' });
  window.__emit(id, { t: 'exit', rc: 1 });
  await new Promise(r => setTimeout(r, 30));
  const failed = 'failed=' + st() + ' | head=' + document.getElementById('b-strip-title').textContent
    + ' | acts=' + [...document.querySelectorAll('#b-run-acts button')].map(b => b.textContent.trim()).join(',')
    + ' | panelIn=' + (document.getElementById('b-fail').closest('[data-step]') || {}).dataset?.step
    + ' | headed=' + !document.getElementById('b-run-head').hidden + ',' + !document.getElementById('b-run-tiles').hidden;
  return 'plan=' + plan + ' | chip=' + chip + ' | ask=' + ask + ' || ' + mid + ' || ' + failed;
};"
ENGINE="$BUILD"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "before a build: the plan"          "$(row AFTER)" "plan=true"
contains "  saying what Build starts billing" "$(row AFTER)" "chip=Hyderabad · Spot, else on-demand · ₹16.44/hour"
contains "the confirm names the rate"        "$(row AFTER)" "Billed ₹16.44/hour from now until you stop or delete it."
# Mid-build: setup, budget, machine and Tailscale done; the box's own steps
# (base packages, the driver) are one step, installing.
contains "four steps done, the fifth running" "$(row AFTER)" "mid=0=done,1=done,2=done,3=done,4=running,5=locked,6=locked,7=locked"
contains "  in plain words"                   "$(row AFTER)" "Checked your setup"
contains "    the rental, with when billing began" "$(row AFTER)" "Machine launched · billing from"
contains "    the box's steps as one"         "$(row AFTER)" "Installing the software"
contains "    with the line it is on"         "$(row AFTER)" "nvidia-driver-580 unpacked"
contains "  the heading is the build"         "$(row AFTER)" "title=Building"
contains "  with the rate in it"              "$(row AFTER)" "₹16.44 an hour"
contains "  the step it is on, large"         "$(row AFTER)" "now=Installing the software |"
contains "  and how far through"              "$(row AFTER)" "count=Step 5 of 8. You can leave this screen; the build carries on."
contains "  time against the usual build"     "$(row AFTER)" "tiles=Elapsed under a minute Usually about 20 min"
contains "  the bill since the rental"        "$(row AFTER)" "Cost so far ₹0.00 Billing since"
contains "  and the plan is put away"         "$(row AFTER)" "plan=false"
contains "a failure stops at its step"        "$(row AFTER)" "failed=0=done,1=done,2=done,3=done,4=failed,5=skipped"
contains "  the heading says so"              "$(row AFTER)" "head=Build failed"
contains "  the reason sits in that step"     "$(row AFTER)" "panelIn=4"
contains "  with try again, or close"         "$(row AFTER)" "acts=Try again,Close"
contains "  and no step heading or tiles"     "$(row AFTER)" "headed=false,false"
ENGINE=""

echo "7b. a rental that fails bills nothing; a build that finishes is ready to play"
B2="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  window.askConfirm = async () => true;
  const go = async (steps, rc) => {
    document.getElementById('b-build').click();
    await new Promise(r => setTimeout(r, 30));
    const id = window.__lastId;
    for (const t of steps) window.__emit(id, { t: 'step', text: t });
    window.__emit(id, { t: 'exit', rc });
    await new Promise(r => setTimeout(r, 30));
    return document.getElementById('b-strip-title').textContent + ' / '
      + document.getElementById('b-strip-meta').textContent + ' / '
      + [...document.querySelectorAll('#b-run-acts button')].map(b => b.textContent.trim()).join(',');
  };
  const a = await go(['preflight', 'arming the budget', 'provisioning instance'], 1);
  const del = window.__ran.includes('destroy --no-push');
  // The same failure with a machine there after all - launched, then the
  // build stopped inside the launching step: said, never 'nothing was billed'.
  const boxWas = boxNow;
  boxNow = { id: 'i-0295', state: 'running' };
  paintRun();
  const a2 = document.getElementById('b-strip-meta').textContent;
  boxNow = boxWas;
  run = null; paintRun();
  const b = await go(['preflight', 'arming the budget', 'provisioning instance', 'waiting for the box to join the tailnet',
                      'building the box', 'finishing up', 'moonlight pairing', 'waiting for Steam to finish installing'], 0);
  const st = [...document.querySelectorAll('#b-steps [data-step]')].map(r => r.dataset.state).join(',');
  return 'failed=' + a + ' | left=' + a2 + ' | done=' + b + ' | steps=' + st + ' | del=' + del;
};"
ENGINE="$B2"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a failed rental: nothing was billed" "$(row AFTER)" "failed=Build failed / Nothing was billed"
contains "  and nothing is deleted"           "$(row AFTER)" "del=false"
contains "  unless a machine is there after all: said, with what to do" "$(row AFTER)" "left=A machine is running - delete it to stop billing"
# The panel above is the machine, with Play and Delete; this is its record.
contains "a finished build: how it was built"  "$(row AFTER)" "done=How it was built / built in"
contains "  with no buttons of its own"       "$(row AFTER)" " /  | steps="
contains "  and all eight steps ticked"        "$(row AFTER)" "steps=done,done,done,done,done,done,done,done"

echo "7b2. a build that fails with its machine rented deletes it, as Cancel does"
# It used to stop and leave the machine billing - "delete it to stop billing" -
# until the cloud watchdog ended it, near an hour on. Deleted under the failed
# build, so why it failed stays on screen.
ENGINE="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  const meta = () => document.getElementById('b-strip-meta').textContent;
  const acts = () => [...document.querySelectorAll('#b-run-acts button')].map(b => b.textContent.trim() + (b.disabled ? '(off)' : '')).join(',');
  window.askConfirm = async () => true;
  document.getElementById('b-build').click();
  await new Promise(r => setTimeout(r, 30));
  const id = window.__lastId;
  window.__ran = [];
  // The delete's own id: the reads a write starts take later ones.
  const run0 = window.ayis.run;
  window.ayis.run = args => run0(args).then(r => { if (args[0] === 'destroy') window.__delId = r.id; return r; });
  for (const t of ['preflight', 'arming the budget', 'provisioning instance', 'waiting for the box to join the tailnet'])
    window.__emit(id, { t: 'step', text: t });
  window.__emit(id, { t: 'line', kind: 'fail', text: 'no new node joined after 30 min.' });
  window.__emit(id, { t: 'exit', rc: 1 });
  await new Promise(r => setTimeout(r, 30));
  const del = window.__delId;
  const during = 'ran=' + window.__ran.includes('destroy --no-push') + ' meta=' + meta() + ' acts=' + acts()
    + ' title=' + document.getElementById('b-strip-title').textContent;
  window.__emit(del, { t: 'step', text: 'terminating instance' });
  window.__emit(del, { t: 'exit', rc: 0 });
  await new Promise(r => setTimeout(r, 60));
  const after = 'meta=' + meta() + ' acts=' + acts() + ' title=' + document.getElementById('b-strip-title').textContent
    + ' why=' + document.getElementById('b-fail-head').textContent.trim();
  // A build that picked up a machine already there - resumed, its games maybe
  // an hour into restoring - fails the same way: that machine is left alone.
  run = null; paintRun();
  document.getElementById('b-build').click();
  await new Promise(r => setTimeout(r, 30));
  const id2 = window.__lastId;
  window.__ran = [];
  for (const t of ['preflight', 'arming the budget', 'reusing the existing box, already on the tailnet as ayis', 'building the box'])
    window.__emit(id2, { t: 'step', text: t });
  window.__emit(id2, { t: 'exit', rc: 1 });
  await new Promise(r => setTimeout(r, 30));
  const reused = 'deleted=' + window.__ran.includes('destroy --no-push');
  return 'during=' + during + ' | after=' + after + ' | reused=' + reused;
};"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "the machine is deleted"               "$(row AFTER)" "during=ran=true"
contains "  said while it goes"                 "$(row AFTER)" "Deleting the machine…"
contains "  and no new build meanwhile"         "$(row AFTER)" "acts=Try again(off),Close"
contains "  under the failure, not in its place" "$(row AFTER)" "title=Build failed | after"
contains "then said, once gone"                 "$(row AFTER)" "Machine deleted, so nothing more is billed"
contains "  with try again back"                "$(row AFTER)" "acts=Try again,Close title=Build failed"
contains "  and why it failed still there"      "$(row AFTER)" "why=no new node joined after 30 min."
contains "a machine the build picked up is kept" "$(row AFTER)" "reused=deleted=false"
ENGINE=""
ENGINE=""

echo "7d. the Build screen shows the machine, wherever you have been"
# Leaving mid-build and coming back used to show the plan again, and "Back to
# dashboard" threw the finished build away - so the card swapped between the
# plan and the run depending on where you had clicked, not on the machine.
B4="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const nav = v => document.querySelector('.nav-item[data-view=' + v + ']').click();
  const card = () => (document.getElementById('b-plan').hidden ? '' : 'plan')
    + (document.getElementById('b-strip').hidden ? '' : 'run:' + document.getElementById('b-strip-title').textContent);
  const acts = () => [...document.querySelectorAll('#b-run-acts button')].map(b => b.textContent.trim()).join(',');
  const wait = () => new Promise(r => setTimeout(r, 30));
  nav('build');
  window.askConfirm = async () => true;
  document.getElementById('b-build').click();
  await wait();
  let id = window.__lastId;
  for (const t of ['preflight', 'arming the budget', 'provisioning instance']) window.__emit(id, { t: 'step', text: t });
  await wait();
  const during = card() + ' acts=' + acts();
  nav('dashboard'); nav('build');
  const back = card();
  for (const t of ['waiting for the box to join the tailnet', 'building the box', 'finishing up',
                   'moonlight pairing', 'waiting for Steam to finish installing']) window.__emit(id, { t: 'step', text: t });
  // The status read after the build finds the machine it made.
  window.__answers['status --json'].box = { id: 'i-1', state: 'running', type: 'g6.xlarge', lifecycle: 'spot',
                                            launched: new Date().toISOString() };
  window.__emit(id, { t: 'exit', rc: 0 });
  await wait();
  const panel = () => document.querySelector('#b-machine-card [data-f=title]').textContent + ' '
    + ['b-open', 'b-destroy'].filter(b => !document.getElementById(b).hidden).join(',');
  const done = card() + ' acts=' + acts() + ' folded=' + !!document.querySelector('#b-steps details:not([open])')
    + ' panel=' + panel();
  nav('dashboard'); nav('build');
  const done2 = card();
  // Cancel: ayis is interrupted, then whatever it rented is deleted, and the
  // plan comes straight back.
  window.__answers['status --json'].box = null;
  run = null; boxNow = null; paintRun();
  let del = null;
  const orig = window.ayis.run;
  window.ayis.run = async a => { const r = await orig(a); if (a[0] === 'destroy') del = r.id; return r; };
  document.getElementById('b-build').click();
  await wait();
  id = window.__lastId;
  window.__emit(id, { t: 'step', text: 'provisioning instance' });
  await wait();
  window.__ran = [];
  [...document.querySelectorAll('#b-run-acts button')].find(b => b.textContent === 'Cancel').click();
  await wait(); await wait();
  const cancel = 'cancelled=' + window.__cancelled.includes(id) + ' ran=' + window.__ran.join(';') + ' ' + card();
  window.__emit(del, { t: 'exit', rc: 0 });
  await wait();
  return 'during=' + during + ' | back=' + back + ' | done=' + done + ' | done2=' + done2
    + ' | cancel=' + cancel + ' | after=' + card();
};"
ENGINE="$B4"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a build shows the run"              "$(row AFTER)" "during=run:Building acts=Cancel"
contains "  and still does after leaving"     "$(row AFTER)" "back=run:Building |"
# The panel is the machine, with Play and Delete; under it, how it was built.
contains "a finished build is the machine"    "$(row AFTER)" "done=run:How it was built acts= folded=true panel=Ready to play b-open,b-destroy"
contains "  and stays it after leaving"       "$(row AFTER)" "done2=run:How it was built |"
contains "cancel interrupts ayis"               "$(row AFTER)" "cancelled=true"
contains "  then deletes what it rented"      "$(row AFTER)" ";destroy --no-push;"
contains "  shown as the delete"              "$(row AFTER)" "run:Deleting the machine"
contains "  and the plan is back after it"    "$(row AFTER)" "after=plan"
ENGINE=""

echo "7e. a machine that exists is never shown as a plan"
B5="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 30));
  const q = f => (document.querySelector('#b-machine-card [data-f=' + f + ']') || {}).textContent;
  return 'plan=' + !document.getElementById('b-plan').hidden
    + ' | strip=' + !document.getElementById('b-strip').hidden
    + ' | title=' + q('title') + ' | word=' + q('word')
    + ' | meta=' + q('sub')
    + ' | acts=' + ['b-open', 'b-destroy', 'b-change'].filter(b => !document.getElementById(b).hidden).join(',');
};"
ENGINE="$B5"
BOX='{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOX" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "no plan beside a machine"   "$(row AFTER)" "plan=false"
# Opened again with a machine there: the panel says it all; no run to show.
contains "  nor an empty run"         "$(row AFTER)" "strip=false"
contains "  the machine, ready"       "$(row AFTER)" "title=Ready to play | word=Online"
contains "  how long it has been up"  "$(row AFTER)" "meta=Up "
contains "  play, or delete it"       "$(row AFTER)" "acts=b-open,b-destroy"
ENGINE=""

echo "7e2. a stopped machine is started by Play; one AWS is removing offers nothing"
B5S="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 30));
  const q = f => (document.querySelector('#b-machine-card [data-f=' + f + ']') || {}).textContent;
  return 'title=' + q('title') + ' | word=' + q('word') + ' | meta=' + q('sub')
    + ' | play=' + document.getElementById('b-open').textContent.trim()
    + ' | acts=' + ['b-open', 'b-destroy'].filter(b => !document.getElementById(b).hidden).join(',')
    + ' | ts=' + ((document.querySelector('#b-checks [data-check=Tailscale]') || {}).dataset || {}).ok
    + ' | where=' + q('where');
};"
ENGINE="$B5S"
BOXS='{"id": "i-1", "state": "stopped", "type": "g4dn.xlarge", "lifecycle": "normal", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOXS" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "stopped: says so"               "$(row AFTER)" "title=Machine stopped | word=Stopped"
contains "  and what is kept"             "$(row AFTER)" "Your setup is kept; games come back from Saved games on start. Only the disk is billed."
contains "  Play starts it"               "$(row AFTER)" "Start and play | acts=b-open"
contains "  and Delete is still there"    "$(row AFTER)" "acts=b-open,b-destroy"
BOXD='{"id": "i-1", "state": "shutting-down", "type": "g4dn.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOXD" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "being removed: no Delete"  "$(row AFTER)" "Play | acts="
BOXT='{"id": "i-1", "state": "stopping", "type": "g4dn.xlarge", "lifecycle": "normal", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOXT" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "stopping: it is saving, and says when billing ends" "$(row AFTER)" "meta=Saving and shutting down. Billing by the hour ends once it has stopped"
lacks    "  and no Delete while it saves on its way down" "$(row AFTER)" "b-destroy"
contains "  Tailscale is not a fault while it is off" "$(row AFTER)" "ts=later"
ENGINE=""

echo "7e3. a stopped machine's games disk: what it costs, when it goes, and whether it may be removed"
B5D="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1500));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  const q = f => (document.querySelector('#b-machine-card [data-f=' + f + ']') || {}).textContent;
  const rd = document.getElementById('b-removedisk');
  return 'note=' + q('stopnote') + ' | remove=' + (rd.hidden ? 'hidden' : rd.disabled ? 'disabled' : 'ready')
    + ' | why=' + rd.title;
};"
ENGINE="$B5D"
for D in '{"state":"stopped","extra_gb":160,"removable":true,"stopped_at":"2026-11-08T12:00:00Z","expiry_days":14}' \
         '{"state":"stopped","extra_gb":160,"removable":false,"why":"Saved games has no complete save from this machine.","stopped_at":"2026-11-08T12:00:00Z","expiry_days":14}' \
         '{"state":"stopped","extra_gb":0,"removable":false,"stopped_at":"2026-11-08T12:00:00Z","expiry_days":0}'; do
  OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP, \"disk --json\": $D,
    \"status --json\": $(st "$BOXS" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
  case $D in
    *'"removable":true'*)
      contains "can be removed: the disk and its cost"  "$(row AFTER)" "note=Games disk 160 GB, about "
      contains "  and the day it would be deleted"      "$(row AFTER)" "Deleted automatically on "
      contains "  the button is ready"                  "$(row AFTER)" "remove=ready" ;;
    *'"extra_gb":160'*)
      contains "not saved yet: the button waits"        "$(row AFTER)" "remove=disabled"
      contains "  and says what it waits for"           "$(row AFTER)" "why=Saved games has no complete save" ;;
    *)
      contains "no added disk: no button"               "$(row AFTER)" "remove=hidden"
      lacks    "  and no deletion date when it is off"  "$(row AFTER)" "Deleted automatically" ;;
  esac
done
ENGINE=""

echo "7e4. playing a machine whose games disk was removed asks which games to bring back"
B5P="window.__after = async () => {
  localStorage.setItem('ayis-disk-removed', JSON.stringify({'i-1': 1}));
  // Until the machine and its disk have both been read, not for a moment.
  for (let i = 0; i < 120 && !(statusNow && stoppedDisk); i++) await new Promise(r => setTimeout(r, 20));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 30));
  const wait = () => new Promise(r => setTimeout(r, 30));
  const btn = document.getElementById('b-open');
  const label = btn.textContent.trim().replace(/^[^A-Za-z]+/, '');
  btn.click();
  await wait();
  const dlg = document.getElementById('playdlg');
  const rows = [...dlg.querySelectorAll('#playdlg-games label')].map(l => l.innerText.replace(/\\s+/g, ' ').trim());
  const price = document.getElementById('playdlg-gb').value;
  const ticks = [...dlg.querySelectorAll('#playdlg-games input')].map(i => i.checked ? 'x' : '-').join('');
  const diskHidden0 = document.getElementById('playdlg-disk').hidden + ' minusOff0=' + document.getElementById('playdlg-minus').disabled;
  // Tick the big one, which does not fit what is left of the fast drive, then start.
  dlg.querySelectorAll('#playdlg-games input')[0].click();
  const price2 = document.getElementById('playdlg-gb').value;
  // Lower than the games need is refused: minus is off, and a typed 10 comes back up.
  const minusOff = document.getElementById('playdlg-minus').disabled;
  const gbIn = document.getElementById('playdlg-gb');
  gbIn.value = '10'; gbIn.onchange();
  const typedLow = gbIn.value;
  // Raising it is allowed.
  document.getElementById('playdlg-plus').click();
  const raised = gbIn.value;
  document.getElementById('playdlg-minus').click();
  const diskBox = document.getElementById('playdlg-disk-note').textContent + ' minusOff=' + minusOff + ' typedLow=' + typedLow + ' raised=' + raised + ' back=' + gbIn.value;
  // The page's own close handler, called here: a close event is queued behind the
  // virtual clock this page runs on and may not arrive before the answer is read.
  dlg.close('yes');
  dlg.onclose();
  // The run waits for any read still in flight, so look for it rather than for a moment.
  for (let i = 0; i < 100 && !window.__ran.some(l => l.includes('--extra-gb')); i++) await new Promise(r => setTimeout(r, 30));
  // The machine is getting ready: the progress window is open, one row per game.
  const pd = document.getElementById('restoredlg');
  const jid = window.__lastId;
  const rd = () => [...pd.querySelectorAll('#restoredlg-games > div')].map(d => d.innerText.replace(/\\s+/g, ' ').trim()).join(';');
  const opened = 'progressOpen=' + pd.open + ' rows0=' + rd();
  window.__emit(jid, { t: 'step', id: 'open.start', text: 'starting the machine' });
  window.__emit(jid, { t: 'restore', id: '111', state: 'copying', got: 50 * 1073741824, of: 100 * 1073741824 });
  window.__emit(jid, { t: 'restore', id: '222', state: 'waiting', got: 0, of: 10 * 1073741824 });
  const mid = 'mid=' + rd() + ' bar=' + pd.querySelector('#restoredlg-games > div .bg-primary').style.width;
  // One game does not come back whole: it is named, and Try again is offered.
  window.__emit(jid, { t: 'restore', id: '111', state: 'done', got: 100 * 1073741824, of: 100 * 1073741824 });
  window.__emit(jid, { t: 'restore', id: '222', state: 'failed', got: 1073741824, of: 10 * 1073741824 });
  window.__emit(jid, { t: 'exit', rc: 1 });
  const failedUi = 'failedTitle=' + document.getElementById('restoredlg-title').textContent
    + ' retry=' + !document.getElementById('restoredlg-retry').hidden + ' cancel=' + !document.getElementById('restoredlg-cancel').hidden;
  document.getElementById('restoredlg-retry').click();
  for (let i = 0; i < 60 && window.__ran.filter(l => l.startsWith('open')).length < 2; i++) await new Promise(r => setTimeout(r, 30));
  const retried = 'retry=' + window.__ran.filter(l => l.startsWith('open')).slice(-1)[0];
  // Then a clean run: the stream's own step closes the window.
  await new Promise(r => setTimeout(r, 60));   // the retried job is registered a moment after ayis is asked
  const openJob = [...jobs].filter(([, j]) => j.cmd[0] === 'open').pop()[0];   // reads also take ids; the session is the open job
  window.__emit(openJob, { t: 'restore', id: '222', state: 'done', got: 10 * 1073741824, of: 10 * 1073741824 });
  window.__emit(openJob, { t: 'step', id: 'open.sunshine', text: 'starting the game stream' });
  const stillOpen = pd.open;
  window.__emit(openJob, { t: 'step', id: 'open.play', text: 'playing' });
  const closed = 'closedByItself=' + !pd.open + ' openWhileStreamStarts=' + stillOpen;
  return opened + ' | ' + mid + ' | ' + failedUi + ' | ' + retried + ' | ' + closed + ' |||| ' + 'label=' + label + ' | open=' + dlg.open + ' | rows=' + rows.join(';') + ' | ticks=' + ticks + ' | diskHidden0=' + diskHidden0 + ' | price=' + price + ' | price2=' + price2 + ' | diskBox=' + diskBox
    + ' | ran=' + window.__ran.filter(l => l.includes('--extra-gb')).join(',') + ' | again=' + (localStorage.getItem('ayis-disk-removed') || '');
};"
ENGINE="$B5P"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"disk --json\": {\"state\":\"stopped\",\"extra_gb\":0,\"removable\":false,\"stopped_at\":\"2026-11-08T12:00:00Z\",\"expiry_days\":14},
  \"library list --json\": {\"games\": [{\"appid\": 111, \"name\": \"Big Game\", \"bytes\": 107374182400}, {\"appid\": 222, \"name\": \"Small Game\", \"bytes\": 10737418240}], \"bucket\": \"b\", \"total_bytes\": 118111600640, \"selectable_gb\": 60, \"reserve_gb\": 20},
  \"status --json\": $(st "$BOXS" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "the button says it starts the machine"  "$(row AFTER)" "label=Start and play"
contains "the popup lists the saved games, biggest first" "$(row AFTER)" "rows=Big Game 100.0 GB;Small Game 10.0 GB"
contains "  the first time only the game that fits the fast drive is ticked" "$(row AFTER)" "ticks=-x"
contains "  the disk field is there, at 0, and cannot go lower" "$(row AFTER)" "diskHidden0=false minusOff0=true | price=0"
contains "  ticking one that does not fit raises it to what it needs" "$(row AFTER)" "price2=130"
contains "  and says how much did not fit"          "$(row AFTER)" "diskBox=The ticked games need 100.0 GB more than the machine has free, so at least 130 GB."
contains "  it cannot be lowered below that, by button or by typing" "$(row AFTER)" "minusOff=true typedLow=130"
contains "  but it can be raised, and lowered back to the need" "$(row AFTER)" "raised=140 back=130"
contains "starting opens the progress window with a row per game" "$(row AFTER)" "progressOpen=true rows0=Big Game waiting"
contains "  each shows how far it is"                "$(row AFTER)" "Big Game 50.0 GB of 100.0 GB · 50%"
contains "  and the bar is that full"                "$(row AFTER)" "bar=50%"
contains "a game that did not come back is named"    "$(row AFTER)" "failedTitle=Some games did not come back retry=true cancel=false"
contains "  Try again asks for that game only"       "$(row AFTER)" "retry=open --extra-gb 130 --extra-apps 111 --games 222:10737418240"
contains "  and the window closes by itself once the stream's steps begin" "$(row AFTER)" "closedByItself=true openWhileStreamStarts=true"
contains "starting passes the size, the disk's games and every game" "$(row AFTER)" "ran=open --extra-gb 130 --extra-apps 111 --games 111:107374182400,222:10737418240"
ENGINE=""

echo "7e4b. no saved games: Play is the same flow - the popup (with the disk), then the progress window"
B5N="window.__after = async () => {
  for (let i = 0; i < 120 && !statusNow; i++) await new Promise(r => setTimeout(r, 20));
  await new Promise(r => setTimeout(r, 300));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  document.getElementById('b-open').click();
  const dlg = document.getElementById('playdlg');
  for (let i = 0; i < 100 && !document.getElementById('playdlg-yes').disabled === false; i++) await new Promise(r => setTimeout(r, 30));
  for (let i = 0; i < 100 && document.getElementById('playdlg-yes').disabled; i++) await new Promise(r => setTimeout(r, 30));
  const says = document.getElementById('playdlg-games').innerText.replace(/\\s+/g, ' ').trim();
  const disk = 'disk=' + !document.getElementById('playdlg-disk').hidden + ' gb=' + document.getElementById('playdlg-gb').value;
  const opened = 'popup=' + dlg.open;
  dlg.close('yes'); dlg.onclose();
  for (let i = 0; i < 100 && !window.__ran.some(l => l.startsWith('open')); i++) await new Promise(r => setTimeout(r, 30));
  return opened + ' | says=' + says + ' | ' + disk + ' | progress=' + document.getElementById('restoredlg').open
    + ' | sub=' + document.getElementById('restoredlg-sub').textContent + ' | ran=' + window.__ran.filter(l => l.startsWith('open')).join(',');
};"
ENGINE="$B5N"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"disk --json\": {\"state\":\"stopped\",\"extra_gb\":0,\"removable\":false,\"stopped_at\":\"2026-11-08T12:00:00Z\",\"expiry_days\":14},
  \"library list --json\": {\"games\": [], \"bucket\": \"b\", \"total_bytes\": 0, \"selectable_gb\": 60, \"reserve_gb\": 20},
  \"status --json\": $(st "$BOXS" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "no saved games: the same popup opens"     "$(row AFTER)" "popup=true"
contains "  and says there are none yet"            "$(row AFTER)" "says=No saved games yet."
contains "  with the disk field, at 0"              "$(row AFTER)" "disk=true gb=0"
contains "  then the progress window, as with games" "$(row AFTER)" "progress=true | sub=Connecting to your machine and starting the stream."
contains "  and the machine is started"             "$(row AFTER)" "ran=open"
ENGINE=""

echo "7e4c. a stopped machine: games last seen on the root disk or the games disk are already on it, not copied again"
B5R="try { localStorage.setItem('ayis-box-games', JSON.stringify({id: 'i-1', games: [{appid: '111', disk: 'root'}, {appid: '222', disk: 'extra'}]})); } catch (e) {}
window.__after = async () => {
  for (let i = 0; i < 120 && !statusNow; i++) await new Promise(r => setTimeout(r, 20));
  await new Promise(r => setTimeout(r, 300));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  document.getElementById('b-open').click();
  for (let i = 0; i < 100 && document.getElementById('playdlg-yes').disabled; i++) await new Promise(r => setTimeout(r, 30));
  const rows = [...document.querySelectorAll('#playdlg-games label')].map(l => l.innerText.replace(/\\s+/g, ' ').trim() + (l.querySelector('input').disabled ? ' [locked]' : '')).join(';');
  return 'rows=' + rows;
};"
ENGINE="$B5R"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"disk --json\": {\"state\":\"stopped\",\"extra_gb\":0,\"removable\":false,\"stopped_at\":\"2026-11-08T12:00:00Z\",\"expiry_days\":14},
  \"library list --json\": {\"games\": [{\"appid\": 111, \"name\": \"Root Game\", \"bytes\": 10737418240}, {\"appid\": 222, \"name\": \"Disk Game\", \"bytes\": 5368709120}], \"bucket\": \"b\", \"total_bytes\": 16106127360, \"selectable_gb\": 60, \"reserve_gb\": 20},
  \"status --json\": $(st "$BOXS" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a game on the root disk is already on the stopped machine, and locked" "$(row AFTER)" "Root Game already on the machine · root disk [locked]"
contains "  one on a games disk that is gone is offered again"   "$(row AFTER)" "Disk Game 5.0 GB"
ENGINE=""

echo "7e5. Stop machine: one window - the games grouped by what happens to them, then the run in the same window"
B5K="window.__slow = ['stop --yes --skip 111,333']; window.__slowMs = 1500;
window.__after = async () => {
  for (let i = 0; i < 120 && !statusNow; i++) await new Promise(r => setTimeout(r, 20));
  await new Promise(r => setTimeout(r, 300));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  const btn = document.getElementById('b-stopmachine');
  const shown = 'stopShown=' + !btn.hidden;
  btn.click();
  const dlg = document.getElementById('keepdlg');
  const reading = 'readingAtOnce=' + dlg.open;
  for (let i = 0; i < 100 && !dlg.querySelector('#keepdlg-games input'); i++) await new Promise(r => setTimeout(r, 30));
  const groups = [...dlg.querySelectorAll('#keepdlg-games > div')].map(g => g.innerText.replace(/\\s+/g, ' ').trim()).join(' / ');
  const ticks = [...dlg.querySelectorAll('#keepdlg-games input')].map(i => i.disabled ? '_' : i.checked ? 'x' : '-').join('');
  const sum0 = document.getElementById('keepdlg-summary').textContent;
  const yes0 = document.getElementById('keepdlg-yes').textContent;
  const boxes = [...dlg.querySelectorAll('#keepdlg-games input')].filter(i => !i.disabled);
  // A game on the games disk survives a stop: unticked, it says so; then ticked again.
  boxes[2].click();
  const diskNote = [...dlg.querySelectorAll('#keepdlg-games p.pl-\\\\[1\\\\.6rem\\\\]')].filter(n => !n.hidden).map(n => n.textContent).join(' / ');
  boxes[2].click();
  boxes[0].click(); boxes[1].click();
  const yes1 = document.getElementById('keepdlg-yes').textContent;
  const sum1 = document.getElementById('keepdlg-summary').textContent;
  const notes = [...dlg.querySelectorAll('#keepdlg-games p.pl-\\\\[1\\\\.6rem\\\\]')].filter(n => !n.hidden).map(n => n.textContent).join(' / ');
  document.getElementById('keepdlg-yes').click();
  for (let i = 0; i < 150 && !window.__ran.some(l => l.startsWith('stop')); i++) await new Promise(r => setTimeout(r, 30));
  await new Promise(r => setTimeout(r, 300));
  const steps = () => [...document.querySelectorAll('#keepdlg-steps [data-step]')].map(r => r.firstChild.textContent + (r.firstChild.classList.contains('spinner') ? '◌' : '') + r.dataset.step).join('/');
  const mid = 'midOpen=' + dlg.open + ' midTitle=' + document.getElementById('keepdlg-title').textContent + ' refdlg=' + document.getElementById('refdlg').open + ' steps=' + steps();
  const sj = [...jobs].filter(([, j]) => j.cmd[0] === 'stop').pop();
  let bar0 = 'none', bar1 = 'none';
  if (sj) {
    window.__emit(sj[0], { t: 'step', text: 'Saving your Steam login and the games you kept to Saved games' });
    window.__emit(sj[0], { t: 'save', id: 'all', text: 'Measuring what to save', got: 0, of: 0 });
    const r0 = document.getElementById('keepdlg-save');
    bar0 = r0 ? r0.innerText.trim() + ' moving=' + !r0.lastChild.classList.contains('determinate') + ' under=' + r0.previousElementSibling.dataset.step : 'none';
    window.__emit(sj[0], { t: 'save', id: 'all', text: 'Saving your games', got: 2 * 1073741824, of: 8 * 1073741824 });
    const r1 = document.getElementById('keepdlg-save');
    bar1 = r1 ? r1.innerText.trim() + ' width=' + r1.lastChild.firstChild.style.width : 'none';
  }
  const steps2 = 'steps2=' + steps();
  let live = 'none';
  if (sj) {
    window.__emit(sj[0], { t: 'step', text: 'Stopping the machine at AWS (billing ends once it has stopped)' });
    window.__emit(sj[0], { t: 'wait', id: 'box.stopped', state: 'waiting', text: 'stopping', secs: 80, of: 600 });
    window.__emit(sj[0], { t: 'line', kind: 'cont', text: '  machine: ayis-library: pushing ZERO PARADES' });
    const lr = document.getElementById('keepdlg-live');
    live = lr ? lr.textContent.replace(/\n/g, ' | ') + ' under=' + lr.previousElementSibling.dataset.step : 'none';
  }
  await new Promise(r => setTimeout(r, 1500));
  const after = 'afterOpen=' + dlg.open;
  return shown + ' | ' + reading + ' | groups=' + groups + ' | ticks=' + ticks + ' | sum0=' + sum0 + ' | yes0=' + yes0
    + ' | yes1=' + yes1 + ' | sum1=' + sum1 + ' | notes=' + notes + ' | diskNote=' + diskNote + ' | ' + mid + ' | bar0=' + bar0 + ' | bar1=' + bar1 + ' | ' + steps2 + ' | live=' + live + ' | ' + after
    + ' | ran=' + window.__ran.filter(l => l.startsWith('library forget') || l.startsWith('stop')).join(',');
};"
ENGINE="$B5K"
BOXR='{"id": "i-1", "state": "running", "type": "g4dn.xlarge", "lifecycle": "normal", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"library forget 111\": {}, \"stop --yes --skip 111,333\": {}, \"disk --json\": {\"state\": \"running\", \"extra_gb\": 0},
  \"library list --json\": {\"games\": [{\"appid\": 111, \"name\": \"Saved Game\", \"bytes\": 10737418240}], \"bucket\": \"b\", \"total_bytes\": 10737418240, \"selectable_gb\": 60, \"reserve_gb\": 20},
  \"games --json --box\": {\"games\": [{\"appid\": \"111\", \"name\": \"Saved Game\", \"state\": \"installed\", \"bytes\": 10737418240}, {\"appid\": \"333\", \"name\": \"New Game\", \"state\": \"installed\", \"bytes\": 2147483648, \"disk\": \"nvme\"}, {\"appid\": \"666\", \"name\": \"Disk Game\", \"state\": \"installed\", \"bytes\": 1073741824, \"disk\": \"extra\"}, {\"appid\": \"555\", \"name\": \"Half Game\", \"state\": \"downloading\", \"bytes\": 3221225472, \"percent\": 61}, {\"appid\": \"444\", \"name\": \"Only Saved\", \"state\": \"in S3 only\", \"bytes\": 1073741824}, {\"appid\": \"1493710\", \"name\": \"Proton Experimental\", \"state\": \"installed\", \"bytes\": 1503238553, \"tool\": true}], \"disk\": {\"used_bytes\": 1, \"free_bytes\": 2}},
  \"status --json\": $(st "$BOXR" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "an on-demand machine that is running offers Stop machine" "$(row AFTER)" "stopShown=true"
contains "  the window opens at once, reading"   "$(row AFTER)" "readingAtOnce=true"
contains "  games grouped by what happens to them" "$(row AFTER)" "groups=IN SAVED GAMES Saved Game 10.0 GB / NEW ON THIS MACHINE New Game 2.0 GB · fast drive Disk Game 1.0 GB · games disk / NOT SAVED Half Game 3.0 GB · downloading 61% Still downloading: not saved. Steam downloads it again next time."
lacks    "  not the ones only in Saved games"  "$(row AFTER)" "Only Saved"
lacks    "  nor Steam's own tools, which are never saved" "$(row AFTER)" "Proton Experimental"
contains "  all ticked; a download cannot be"  "$(row AFTER)" "ticks=xxx_"
contains "  one line says what will happen"    "$(row AFTER)" "sum0=Saves 2 new games (3.0 GB), updates 1. | yes0=Save and stop"
contains "  unticking a saved one: the button says it deletes" "$(row AFTER)" "yes1=Delete 1 game and stop"
contains "  and the line too"                  "$(row AFTER)" "sum1=Saves 1 new game (1.0 GB), deletes 1 saved game."
contains "  each unticked game says what happens to it" "$(row AFTER)" "notes=Deleted from Saved games. Cannot be undone. / Not saved. Gone when the machine stops."
contains "  one on the games disk is not lost by a stop, and says so" "$(row AFTER)" "diskNote=Not saved. It stays on the games disk."
contains "  the run is in the SAME window, retitled, nothing else on top" "$(row AFTER)" "midOpen=true midTitle=Stopping the machine refdlg=false"
contains "  every step listed from the start"   "$(row AFTER)" "Getting ready/✓Deleting Saved Game from Saved games/"
contains "  steps to come are shown as to come" "$(row AFTER)" "○Stopping the machine at AWS"
contains "  the save's bar is there at once, under its step, moving" "$(row AFTER)" "bar0=Measuring what to save moving=true under=Saving your games and Steam login"
contains "  then sized"                         "$(row AFTER)" "bar1=Saving your games · 2.0 GB of 8.0 GB width=25%"
contains "  while AWS stops it: AWS's state and the machine's last line, under that step" "$(row AFTER)" "live=AWS says: stopping · 1 min 20 s | Machine: ayis-library: pushing ZERO PARADES under=Stopping the machine at AWS"
contains "  the window closes once it is done"   "$(row AFTER)" "afterOpen=false"
contains "  the saved one is deleted, then the stop leaves both out" "$(row AFTER)" "ran=library forget 111,stop --yes --skip 111,333"
ENGINE=""

echo "7e5c. the games disk at Stop: unticked by default; ticked and locked once nothing on it is kept; deleted after the stop"
B5D2="window.__after = async () => {
  for (let i = 0; i < 120 && !statusNow; i++) await new Promise(r => setTimeout(r, 20));
  await new Promise(r => setTimeout(r, 300));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  document.getElementById('b-stopmachine').click();
  const dlg = document.getElementById('keepdlg');
  for (let i = 0; i < 100 && !dlg.querySelector('#keepdlg-games input'); i++) await new Promise(r => setTimeout(r, 30));
  const boxes = [...dlg.querySelectorAll('#keepdlg-games input')];
  const diskCb = boxes[boxes.length - 1];
  const state = () => 'disk=' + (diskCb.checked ? 'x' : '-') + (diskCb.disabled ? 'L' : '') + ' yes=' + document.getElementById('keepdlg-yes').textContent
    + ' sum=' + document.getElementById('keepdlg-summary').textContent;
  const head = [...dlg.querySelectorAll('#keepdlg-games .section-label')].map(h => h.textContent).join(',');
  const s0 = state();
  diskCb.click();
  const s1 = state() + ' note=' + [...dlg.querySelectorAll('#keepdlg-games p.pl-\\\\[1\\\\.6rem\\\\]')].filter(n => !n.hidden).map(n => n.textContent).join(' / ');
  diskCb.click();
  boxes[0].click();
  const s2 = state() + ' note=' + [...dlg.querySelectorAll('#keepdlg-games p.pl-\\\\[1\\\\.6rem\\\\]')].filter(n => !n.hidden).map(n => n.textContent).join(' / ');
  boxes[0].click();
  const s3 = state();
  boxes[0].click();
  document.getElementById('keepdlg-yes').click();
  for (let i = 0; i < 150 && !window.__ran.some(l => l.startsWith('disk remove')); i++) await new Promise(r => setTimeout(r, 30));
  await new Promise(r => setTimeout(r, 200));
  return 'head=' + head + ' | s0=' + s0 + ' | s1=' + s1 + ' | s2=' + s2 + ' | s3=' + s3
    + ' | ran=' + window.__ran.filter(l => l.startsWith('stop') || l.startsWith('disk remove')).join(',') + ' | closed=' + !dlg.open;
};"
ENGINE="$B5D2"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"stop --yes --skip 666\": {}, \"disk remove\": {},
  \"disk --json\": {\"state\": \"running\", \"extra_gb\": 160},
  \"library list --json\": {\"games\": [], \"bucket\": \"b\", \"total_bytes\": 0, \"selectable_gb\": 60, \"reserve_gb\": 20},
  \"games --json --box\": {\"games\": [{\"appid\": \"666\", \"name\": \"Disk Game\", \"state\": \"installed\", \"bytes\": 1073741824, \"disk\": \"extra\"}], \"disk\": null},
  \"status --json\": $(st "$BOXR" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "the games disk has its own section"          "$(row AFTER)" "head=New on this machine,Games disk · 160 GB"
contains "  unticked by default while a game on it is kept" "$(row AFTER)" "s0=disk=- yes=Save and stop"
contains "  ticked by hand: the button and line say so" "$(row AFTER)" "s1=disk=x yes=Save, stop and delete disk sum=Saves 1 new game (1.0 GB), deletes the games disk."
contains "  and a kept game on it is saved first"      "$(row AFTER)" "Saved, then the disk is deleted."
contains "  nothing on it kept: ticked and locked"     "$(row AFTER)" "s2=disk=xL yes=Stop and delete disk"
contains "  and the game on it is gone with it"        "$(row AFTER)" "⚠ Not saved. Gone with the games disk."
contains "  saying why it is locked"                   "$(row AFTER)" "Nothing on it is kept, so it is deleted. Tick a game on it to keep the disk."
contains "  ticking a game on it again unlocks and unticks it" "$(row AFTER)" "s3=disk=- yes=Save and stop"
contains "  the stop leaves the game out, then the disk is removed" "$(row AFTER)" "ran=stop --yes --skip 666,disk remove"
contains "  and the window closes"                     "$(row AFTER)" "closed=true"
ENGINE=""

echo "7e5d. the games disk going, with a saved game on it unticked: both copies go, and it says so"
B5S2="window.__after = async () => {
  for (let i = 0; i < 120 && !statusNow; i++) await new Promise(r => setTimeout(r, 20));
  await new Promise(r => setTimeout(r, 300));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  document.getElementById('b-stopmachine').click();
  const dlg = document.getElementById('keepdlg');
  for (let i = 0; i < 100 && !dlg.querySelector('#keepdlg-games input'); i++) await new Promise(r => setTimeout(r, 30));
  const boxes = [...dlg.querySelectorAll('#keepdlg-games input')];
  boxes[0].click();
  const notes = [...dlg.querySelectorAll('#keepdlg-games p.pl-\\\\[1\\\\.6rem\\\\]')].filter(n => !n.hidden).map(n => n.textContent).join(' / ');
  return 'disk=' + (boxes[boxes.length - 1].checked ? 'x' : '-') + (boxes[boxes.length - 1].disabled ? 'L' : '') + ' | notes=' + notes
    + ' | yes=' + document.getElementById('keepdlg-yes').textContent;
};"
ENGINE="$B5S2"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"disk --json\": {\"state\": \"running\", \"extra_gb\": 160},
  \"library list --json\": {\"games\": [{\"appid\": 777, \"name\": \"Saved On Disk\", \"bytes\": 1073741824}], \"bucket\": \"b\", \"total_bytes\": 1073741824, \"selectable_gb\": 60, \"reserve_gb\": 20},
  \"games --json --box\": {\"games\": [{\"appid\": \"777\", \"name\": \"Saved On Disk\", \"state\": \"installed\", \"bytes\": 1073741824, \"disk\": \"extra\"}], \"disk\": null},
  \"status --json\": $(st "$BOXR" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "unticked, saved, on a disk that goes: both copies go" "$(row AFTER)" "disk=xL | notes=⚠ Deleted from Saved games, and gone with the games disk. Cannot be undone."
contains "  and the button says both"            "$(row AFTER)" "yes=Delete 1 game, stop and delete disk"
ENGINE=""

echo "7e5b. a stop that fails says what finished, what did not, and offers Try again"
B5F="window.__broken = ['stop --yes'];
window.__after = async () => {
  for (let i = 0; i < 120 && !statusNow; i++) await new Promise(r => setTimeout(r, 20));
  await new Promise(r => setTimeout(r, 300));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  document.getElementById('b-stopmachine').click();
  const dlg = document.getElementById('keepdlg');
  for (let i = 0; i < 100 && !dlg.querySelector('#keepdlg-games input'); i++) await new Promise(r => setTimeout(r, 30));
  document.getElementById('keepdlg-yes').click();
  for (let i = 0; i < 100 && document.getElementById('keepdlg-retry').hidden; i++) await new Promise(r => setTimeout(r, 30));
  const steps = [...document.querySelectorAll('#keepdlg-steps [data-step]')].map(r => r.firstChild.textContent + r.dataset.step).join('/');
  return 'open=' + dlg.open + ' | title=' + document.getElementById('keepdlg-title').textContent
    + ' | retry=' + !document.getElementById('keepdlg-retry').hidden + ' close=' + !document.getElementById('keepdlg-close').hidden
    + ' | steps=' + steps + ' | why=' + document.getElementById('keepdlg-steps').innerText.replace(/\\s+/g, ' ')
    + ' | note=' + document.getElementById('keepdlg-run-note').textContent;
};"
ENGINE="$B5F"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"library list --json\": {\"games\": [], \"bucket\": \"b\", \"total_bytes\": 0, \"selectable_gb\": 60, \"reserve_gb\": 20},
  \"games --json --box\": {\"games\": [{\"appid\": \"333\", \"name\": \"New Game\", \"state\": \"installed\", \"bytes\": 2147483648}], \"disk\": null},
  \"disk --json\": {\"state\": \"running\", \"extra_gb\": 0},
  \"status --json\": $(st "$BOXR" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a failed stop keeps the window, says not done" "$(row AFTER)" "open=true | title=Stopping the machine - not done"
contains "  with Try again and Close"           "$(row AFTER)" "retry=true close=true"
contains "  what finished is ticked, the step that failed crossed" "$(row AFTER)" "✓Getting ready/✗Closing Steam"
contains "  and the reason under it"             "$(row AFTER)" "could not reach AWS"
contains "  and that it is still billing"        "$(row AFTER)" "note=The machine is still running and billing."
ENGINE=""

echo "7e6. a Stop machine that never finished is said on the card, with the way to finish it"
B5U="try { localStorage.setItem('ayis-flow-pending', JSON.stringify({kind: 'stop', id: 'i-1', skip: ['333'], at: 1})); } catch (e) {}
window.__after = async () => {
  for (let i = 0; i < 120 && !statusNow; i++) await new Promise(r => setTimeout(r, 20));
  await new Promise(r => setTimeout(r, 300));
  document.querySelector('.nav-item[data-view=build]').click();
  await new Promise(r => setTimeout(r, 60));
  const u = document.getElementById('b-unfinished');
  return 'shown=' + !u.hidden + ' | text=' + u.innerText.replace(/\\s+/g, ' ').trim() + ' | kept=' + (localStorage.getItem('ayis-flow-pending') !== null);
};"
ENGINE="$B5U"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOXR" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "running after a stop that was cut off: the card says so" "$(row AFTER)" "shown=true | text=Your last Stop machine did not finish, so the machine is still running and billing"
contains "  with the way to finish it"            "$(row AFTER)" "Stop machine now"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOXS" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "stopped after all: nothing is said, and the note is gone" "$(row AFTER)" "shown=false | text="
contains "  and forgotten"                        "$(row AFTER)" "kept=false"
ENGINE=""

echo "7f. play is a session, as steps; closing Moonlight just ends it"
# ayis open announces no steps, so the card used to say "Starting the stream" over
# an empty list for the whole session.
B6="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  const wait = () => new Promise(r => setTimeout(r, 30));
  const st = () => [...document.querySelectorAll('#b-steps [data-step]')].map(r => r.dataset.state).join(',');
  const card = () => (document.getElementById('b-plan').hidden ? '' : 'plan')
    + (document.getElementById('b-strip').hidden ? '' : 'run:' + document.getElementById('b-strip-title').textContent);
  const play = () => window.__playThrough();
  let id = await play();
  const line = t => window.__emit(id, { t: 'line', text: t });
  const starting = card() + ' ' + st();
  const stage = (t, sid) => window.__emit(id, { t: 'step', text: t, id: sid });
  line('instance already running');
  stage('connecting over Tailscale', 'open.tailscale');
  line('  pong from game (100.64.0.2) via 1.2.3.4:41641 in 23ms');
  stage('starting the game stream', 'open.sunshine');
  line('waiting for sunshine ok');
  line('disk:');
  stage('playing', 'open.play');
  await wait();
  const playing = card() + ' ' + st() + ' | ' + document.getElementById('b-steps').innerText.replace(/\\s+/g, ' ')
    + ' | ' + document.getElementById('b-strip-meta').textContent;
  stage('session ended', 'open.ended');
  line('session ended after 5m');
  window.__emit(id, { t: 'exit', rc: 0 });
  await wait();
  const kept = card() + 'panel:' + document.querySelector('#b-machine-card [data-f=title]').textContent;
  return 'starting=' + starting + ' | playing=' + playing + ' | kept=' + kept + ' | asked=' + document.getElementById('ask').open
    + ' | sessionInLog=' + document.getElementById('b-log').textContent.includes('waiting for sunshine ok');
};"
ENGINE="$B6"
BOX='{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOX" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "play starts with the machine"     "$(row AFTER)" "starting=run:Starting session running,locked,locked,locked"
contains "  the Machine page's log is the build's: a session's lines are not in it" "$(row AFTER)" "sessionInLog=false"
contains "  then is playing"                "$(row AFTER)" "playing=run:Playing done,done,done,running"
contains "  saying how to stop, and what stays" "$(row AFTER)" "Close Moonlight to end the session. The machine keeps running until auto-stop or Delete."
contains "  and what it costs"              "$(row AFTER)" "so far"
# Kept: the panel is the machine again, and there is no run under it.
contains "ended: back to the machine"       "$(row AFTER)" "kept=panel:Ready to play"
contains "  with nothing asked"             "$(row AFTER)" "asked=false"
ENGINE=""

echo "7f2. play on a machine of yours: the same session card, on its page"
# It used to run as a log folded under the machine's card, while the AWS
# machine's session had steps - two ways of showing one thing.
B6H="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const wait = () => new Promise(r => setTimeout(r, 30));
  hostsNow = [{ name: 'homebox', ssh: 'me@10.0.0.5', os: 'Linux', family: 'ubuntu' }];
  hostStatus.set('homebox', { name: 'homebox', set_up: true, sunshine: true, reachable: true, online: true,
                              login_ok: true, paired: true, gpu: 'NVIDIA GeForce RTX 3060' });
  // ayis knows it too, for the reads after the session.
  window.__answers['host list --json'] = hostsNow;
  window.__answers['host status homebox --json'] = hostStatus.get('homebox');
  paintHostCards();
  const strip = document.getElementById('b-strip');
  const where = () => (strip.closest('#b-own') ? 'own' : strip.closest('#b-aws') ? 'aws' : 'none') + ':' + (strip.hidden ? 'hidden' : 'shown');
  const st = () => [...document.querySelectorAll('#b-steps [data-step]')].map(r => r.dataset.state).join(',');
  const txt = id => document.getElementById(id).textContent.trim();
  playOn('homebox');
  await wait();
  const id = window.__lastId;
  const ran = window.__ran.slice(-1)[0];
  window.__emit(id, { t: 'step', text: 'checking homebox is ready to stream' });
  await wait();
  const starting = 'view=' + view + ' tab=' + machineTab + ' card=' + where() + ' steps=' + st()
    + ' kicker=' + txt('b-run-kicker') + ' now=' + txt('b-run-now') + ' count=' + txt('b-run-step');
  window.__emit(id, { t: 'step', text: 'streaming from homebox' });
  window.__emit(id, { t: 'line', text: '    stream: --fps 60' });
  await wait();
  const playing = 'title=' + txt('b-strip-title') + ' steps=' + st()
    + ' text=' + document.getElementById('b-steps').innerText.replace(/\\s+/g, ' ') + ' meta=' + txt('b-strip-meta');
  // The AWS machine's page never shows it.
  machineTab = 'aws'; paintMachineTab();
  const aws = where();
  machineTab = 'homebox'; paintMachineTab();
  window.__emit(id, { t: 'line', text: 'session ended after 1m' });
  window.__emit(id, { t: 'exit', rc: 0 });
  // The panel keeps what it showed while it is read again - never 'loading'.
  await new Promise(r => setTimeout(r, 0));
  const kept = 'kept=' + hostStatus.has('homebox') + ' title=' + ((document.querySelector('#b-hosts [data-f=title]') || {}).textContent || 'none');
  await wait();
  // Ended: the page read again with the popup up, as an AWS session ends.
  const dlg = document.getElementById('refdlg');
  const popup = 'open=' + dlg.open + ' title=' + txt('refdlg-title') + ' reads='
    + [...document.querySelectorAll('#refdlg-list [data-read]')].map(r => r.dataset.read).join(',');
  await new Promise(r => setTimeout(r, 400));
  return 'ran=' + ran + ' | starting=' + starting + ' | playing=' + playing + ' | aws=' + aws
    + ' | ' + kept + ' | popup=' + popup + ' | after=' + where() + ' closed=' + !dlg.open + ' tab=' + machineTab;
};"
ENGINE="$B6H"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
contains "play runs ayis host open"            "$(row AFTER)" "ran=host open homebox"
contains "  on that machine's page"          "$(row AFTER)" "view=build tab=homebox card=own:shown"
contains "  as steps, the first running"     "$(row AFTER)" "steps=running,locked"
contains "  named for the machine, with no bill" "$(row AFTER)" "kicker=Starting session · homebox · NVIDIA GeForce RTX 3060 · Your machine"
contains "  the step as its heading"         "$(row AFTER)" "now=Checking the machine count=Step 1 of 2."
contains "then playing"                      "$(row AFTER)" "title=Playing steps=done,running"
contains "  saying how to end it"            "$(row AFTER)" "Close Moonlight to end the session."
lacks    "  and never a price"               "$(row AFTER)" "₹"
contains "not on the AWS machine's page"     "$(row AFTER)" "aws=aws:hidden"
contains "closed: the popup reads it again, as for AWS" "$(row AFTER)" "title=Refreshing Machine reads=hosts,host:homebox"
contains "  then back to the machine"        "$(row AFTER)" "after=own:hidden closed=true tab=homebox"
contains "  which never turns to loading"    "$(row AFTER)" "kept=true"
ENGINE=""

echo "7g. Refresh is a popup over the whole window, gone once the page is redrawn"
B7="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const wait = () => new Promise(r => setTimeout(r, 30));
  const rows = () => [...document.querySelectorAll('#refdlg-list [data-read]')]
    .map(r => r.dataset.read + ':' + r.dataset.state).join(',');
  document.getElementById('refresh').click();
  const dlg = document.getElementById('refdlg');
  const cancel = new Event('cancel', { cancelable: true }), key = new KeyboardEvent('keydown', { key: 'Escape', cancelable: true });
  dlg.dispatchEvent(cancel); dlg.dispatchEvent(key);
  const esc = 'esc=' + (cancel.defaultPrevented && key.defaultPrevented ? 'refused' : 'allowed');
  const during = esc + ' open=' + document.getElementById('refdlg').open + ' title='
    + document.getElementById('refdlg-title').textContent + ' rows=' + rows();
  await wait();
  const after = 'open=' + document.getElementById('refdlg').open;
  window.__broken = ['watcher --json'];
  document.getElementById('refresh').click();
  await wait();
  const failed = 'open=' + document.getElementById('refdlg').open + ' rows=' + rows()
    + ' close=' + !document.getElementById('refdlg-menu').hidden
    + ' text=' + document.getElementById('refdlg-list').innerText.replace(/\\s+/g, ' ');
  return 'during=' + during + ' | after=' + after + ' | failed=' + failed;
};"
ENGINE="$B7"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "refresh opens a popup"           "$(row AFTER)" "open=true title=Refreshing Home"
contains "  which Esc does not close"      "$(row AFTER)" "during=esc=refused open=true"
contains "  listing what it reads"         "$(row AFTER)" "rows=status:reading,guards:reading"
contains "  and closes once it has read"   "$(row AFTER)" "after=open=false"
contains "a failed read keeps it open"     "$(row AFTER)" "failed=open=true rows=status:done,guards:failed"
contains "  with a way to close it"        "$(row AFTER)" "close=true"
contains "  and the reason"                "$(row AFTER)" "could not reach AWS"
ENGINE=""

echo "7h. stopping a session: the popup reads the page again, and it is ready to play"
B8="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  const wait = () => new Promise(r => setTimeout(r, 30));
  const card = () => (document.getElementById('b-plan').hidden ? '' : 'plan')
    + (document.getElementById('b-strip').hidden ? '' : 'run:' + document.getElementById('b-strip-title').textContent);
  const id = await window.__playThrough();
  for (const [t, sid] of [['connecting over Tailscale', 'open.tailscale'], ['starting the game stream', 'open.sunshine'], ['playing', 'open.play']]) window.__emit(id, { t: 'step', text: t, id: sid });
  for (const l of ['instance already running', 'waiting for sunshine ok', 'disk:']) window.__emit(id, { t: 'line', text: l });
  await wait();
  const playing = card();
  window.__ran = [];
  window.__emit(id, { t: 'exit', rc: 130 });
  const popup = 'open=' + document.getElementById('refdlg').open + ' title=' + document.getElementById('refdlg-title').textContent;
  await wait(); await wait();
  return 'playing=' + playing + ' | popup=' + popup + ' | after=' + card() + 'panel:' + document.querySelector('#b-machine-card [data-f=title]').textContent + ' closed=' + !document.getElementById('refdlg').open
    + ' fail=' + !document.getElementById('b-fail').classList.contains('hidden')
    + ' | statusReads=' + window.__ran.filter(l => l === 'status --json').length + ' stillReading=' + jobs.size
    + ' rows=' + document.querySelectorAll('#refdlg-list [data-read]').length;
};"
ENGINE="$B8"
BOX='{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOX" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a session is playing"            "$(row AFTER)" "playing=run:Playing"
contains "stopping it opens the popup"     "$(row AFTER)" "popup=open=true title=Refreshing Machine"
contains "  which leaves it ready to play" "$(row AFTER)" "after=panel:Ready to play closed=true"
contains "  and calls nothing a failure"   "$(row AFTER)" "fail=false"
# One round of reads, under the popup: not the page's, then all of them again.
contains "  read once, all under the popup" "$(row AFTER)" "statusReads=1 stillReading=0 rows=11"
ENGINE=""

echo "7i. after a session, the machine is still the build: its steps and its log"
B9="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  window.askConfirm = async () => true;
  const wait = () => new Promise(r => setTimeout(r, 30));
  document.getElementById('b-build').click();
  await wait();
  let id = window.__lastId;
  for (const t of ['preflight', 'arming the budget', 'provisioning instance', 'waiting for the box to join the tailnet',
                   'building the box', 'finishing up', 'moonlight pairing', 'waiting for Steam to finish installing'])
    window.__emit(id, { t: 'step', text: t });
  window.__answers['status --json'].box = { id: 'i-1', state: 'running', type: 'g6.xlarge', lifecycle: 'spot',
                                            launched: new Date().toISOString() };
  window.__emit(id, { t: 'exit', rc: 0 });
  await wait(); await wait();
  id = await window.__playThrough();
  window.__emit(id, { t: 'line', text: 'session-only line' });
  window.__emit(id, { t: 'exit', rc: 130 });
  await wait(); await wait();
  const log = document.getElementById('b-log').textContent;   // folded, so not innerText
  return 'title=' + document.getElementById('b-strip-title').textContent
    + ' | built=' + ((document.querySelector('#b-steps details summary') || {}).textContent || 'none')
    + ' | buildlog=' + log.includes('provisioning instance') + ' sessionlog=' + log.includes('session-only line')
    + ' | logbox=' + !document.getElementById('b-logbox').hidden;
};"
ENGINE="$B9"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "after a session: how it was built" "$(row AFTER)" "title=How it was built"
contains "  with how it was built"         "$(row AFTER)" "built=Build details"
contains "  and the build's own log"       "$(row AFTER)" "buildlog=true sessionlog=false"
contains "  shown"                         "$(row AFTER)" "logbox=true"
ENGINE=""

echo "7j. forgetting a game: one typed confirm, and it all happens on Library"
B10="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const wait = () => new Promise(r => setTimeout(r, 30));
  const view = () => document.querySelector('.nav-item.on').dataset.view;
  document.querySelector('.nav-item[data-view=library]').click();
  await wait();
  let asked = null;
  window.askConfirm = async o => { asked = o; return true; };
  const answered = [];
  window.ayis.answer = (id, v) => { answered.push(v); return Promise.resolve(true); };
  [...document.querySelectorAll('#lib-rows button')].find(b => b.textContent === 'Delete').click();
  await wait();
  const id = window.__lastId;
  window.__emit(id, { t: 'ask', id: 'forget-game', prompt: 'type FORGET to confirm: ' });
  const during = 'view=' + view() + ' word=' + (asked && asked.word) + ' ran=' + window.__ran.slice(-1)[0]
    + ' popup=' + document.getElementById('refdlg').open + ':' + document.getElementById('refdlg-title').textContent
    + ' answered=' + answered.join(',') + ' askdlg=' + document.getElementById('ask').open;
  window.__emit(id, { t: 'exit', rc: 0 });
  const reading = document.getElementById('refdlg-title').textContent
    + ' reads=' + [...document.querySelectorAll('#refdlg-list [data-read]')].map(r => r.dataset.read).join(',');
  await wait(); await wait();
  const after = 'view=' + view() + ' popup=' + document.getElementById('refdlg').open;
  [...document.querySelectorAll('#lib-rows button')].find(b => b.textContent === 'Delete').click();
  await wait();
  const id2 = window.__lastId;
  window.__emit(id2, { t: 'line', text: 'aborted - nothing was deleted' });
  window.__emit(id2, { t: 'exit', rc: 1 });
  await wait(); await wait();
  const refused = 'popup=' + document.getElementById('refdlg').open + ' title=' + document.getElementById('refdlg-title').textContent
    + ' why=' + document.getElementById('refdlg-list').innerText.replace(/\\s+/g, ' ')
    + ' close=' + !document.getElementById('refdlg-menu').hidden + ' view=' + view()
    + ' sub=' + document.getElementById('refdlg-sub').textContent;
  // What a failure left, from ayis's words: a move part-way, a setting half-applied.
  const left = 'move=' + libraryLeft('the copy stopped - nothing was deleted from ap-south-2; run the move again to finish it')
    + ' keep=' + libraryLeft('saved, but the cloud watchdog still counts the old days - run: ayis watchdog install')
    + ' forget=' + libraryLeft('only part of Diablo IV was deleted from ap-south-2 - what is left still bills; run the delete again to finish it')
    + ' moved=' + libraryLeft('moved Diablo IV to ap-south-1, but part of it is still in ap-south-2 and still bills there - delete it there to finish')
    + ' clean=' + libraryLeft('could not delete 2 of them (2 in all) - they still bill; run the clean up again');
  return 'during=' + during + ' | reading=' + reading + ' | after=' + after + ' | refused=' + refused + ' | left=' + left;
};"
ENGINE="$B10"
LIB='{"games": [{"appid": "2344520", "name": "Diablo IV", "bytes": 96636764160, "usd_month": 2.21, "pushed": "2026-10-12T00:00:00Z"}],
      "total_bytes": 96636764160, "usd_month": 2.21, "selectable_gb": 209, "bucket": "b", "login": {"present": false}}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP, \"library list --json\": $LIB,
  \"status --json\": $(st null '{"bytes": 96636764160}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "forget stays on Library"           "$(row AFTER)" "during=view=library word=DELETE"
contains "  runs ayis's forget"                "$(row AFTER)" "ran=library forget 2344520"
contains "  with the popup saying so"        "$(row AFTER)" "popup=true:Deleting Diablo IV"
contains "  and ayis gets the word, no second dialog" "$(row AFTER)" "answered=FORGET askdlg=false"
contains "done: the popup reads the page again" "$(row AFTER)" "reading=Refreshing Games"
contains "  only the saved games, nothing else" "$(row AFTER)" "reads=library,elsewhere |"
contains "  and closes, still on Library"    "$(row AFTER)" "after=view=library popup=false"
contains "refused: the popup stays"          "$(row AFTER)" "refused=popup=true title=Deleting Diablo IV - not done"
contains "  with ayis's reason"                "$(row AFTER)" "aborted - nothing was deleted"
contains "  a Close, and still on Library"   "$(row AFTER)" "close=true view=library"
contains "  and nothing was changed"         "$(row AFTER)" "sub=Nothing was changed."
contains "a move stopped part-way says so"   "$(row AFTER)" "move=The game is still where it was, untouched. Part of it may already be copied"
contains "a half-applied keep-for says so"   "$(row AFTER)" "keep=The setting was saved, but auto-stop still counts the old days."
contains "a half-done delete says what bills" "$(row AFTER)" "forget=Part of the game was deleted; the rest still bills."
contains "a move half-deleted at the source"  "$(row AFTER)" "moved=The game was moved, but part of it is still in its old region"
contains "a half-done clean up"               "$(row AFTER)" "clean=Some leftover files were deleted; the rest still bill."
ENGINE=""

echo "7k. one Games table: every game with its place and date; Reset, Move, Keep for"
# A region move left Diablo IV in Hyderabad, billing, with nothing pointing at
# it. It is a row like any other now: where it is, what it costs, when the
# watchdog deletes it - and Reset, Move and Forget, each through the popup.
B11="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const wait = () => new Promise(r => setTimeout(r, 30));
  const view = () => document.querySelector('.nav-item.on').dataset.view;
  document.querySelector('.nav-item[data-view=library]').click();
  await wait();
  // A card per game; its marked fields, in order, as the table's cells were.
  const rowText = () => [...document.querySelectorAll('#lib-rows [data-game]')]
    .map(c => [...c.querySelectorAll('[data-f]')].map(x => x.textContent.trim()).join(' / ')).join(' || ');
  const table = 'rows=' + rowText() + ' foot=' + document.getElementById('lib-foot').textContent.replace(/\\s+/g, ' ')
    + ' keepfor=' + (document.querySelector('#lib-keepfor [aria-checked=true]') || { dataset: {} }).dataset.value + ' note=' + document.getElementById('lib-keep').textContent;
  let asked = null;
  window.askConfirm = async o => { asked = o; return true; };
  const answered = [];
  window.ayis.answer = (id, v) => { answered.push(v); return Promise.resolve(true); };
  const btn = (row, label) => [...document.querySelectorAll('#lib-rows [data-game]')][row].querySelector('[data-f=acts]')
    .querySelectorAll('button').values().find(b => b.textContent === label);
  btn(1, 'Move to Mumbai').click();
  await wait();
  let id = window.__lastId;
  window.__emit(id, { t: 'ask', id: 'move-game', prompt: 'type MOVE to confirm: ' });
  const move = 'title=' + asked.title + ' body=' + asked.body.replace(/\\n/g, ' ') + ' ran=' + window.__ran.slice(-1)[0]
    + ' popup=' + document.getElementById('refdlg-title').textContent + ' answered=' + answered.join(',');
  window.__emit(id, { t: 'exit', rc: 0 });
  await wait(); await wait();
  const after = 'view=' + view() + ' popup=' + document.getElementById('refdlg').open;
  btn(1, 'Keep').click();
  await wait();
  id = window.__lastId;
  const reset = 'ran=' + window.__ran.slice(-1)[0] + ' popup=' + document.getElementById('refdlg-title').textContent;
  window.__emit(id, { t: 'exit', rc: 0 });
  await wait(); await wait();
  // A pill per choice: pressing 30 days applies it.
  document.querySelector('#lib-keepfor [data-value=\"30\"]').click();
  await wait();
  const keep = 'ran=' + window.__ran.slice(-1)[0] + ' popup=' + document.getElementById('refdlg-title').textContent;
  const steps = () => [...document.querySelectorAll('#refdlg-list [data-step]')]
    .map(r => (r.querySelector('.spinner') ? '● ' : '✓ ') + r.dataset.step).join(', ');
  const before = steps();
  id = window.__lastId;
  window.__emit(id, { t: 'step', text: 'saving the setting' });
  window.__emit(id, { t: 'step', text: 'updating auto-stop' });
  const during = steps();
  window.__emit(id, { t: 'step', text: 'deleting it from ap-south-2' });
  const city = steps();
  window.__emit(id, { t: 'exit', rc: 0 });
  const reads = [...document.querySelectorAll('#refdlg-list [data-read]')].map(r => r.dataset.read).join(',');
  return 'table=' + table + ' | move=' + move + ' | after=' + after + ' | reset=' + reset + ' | keep=' + keep
    + ' | steps=before:' + before + ' during:' + during + ' city:' + city + ' | reads=' + reads;
};"
ENGINE="$B11"
SEEN=$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ); KEPT=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
# The dates the rows should show, counted from the same instants the app counts
# from, in the same local time - not from "now": KEPT is an hour ago, and in the
# hour after midnight that is yesterday, so "+14 days from now" was a day out
# and the check failed every night from 00:00 to 01:00.
D13=$(date -d "$SEEN + 14 days" '+%-d %b'); D14=$(date -d "$KEPT + 14 days" '+%-d %b')
LIB2="{\"games\": [{\"appid\": \"1174180\", \"name\": \"Red Dead 2\", \"installdir\": \"RDR2\", \"bytes\": 128849018880, \"usd_month\": 3.0, \"pushed\": \"2026-10-12T00:00:00Z\", \"kept\": null}],
      \"total_bytes\": 128849018880, \"usd_month\": 3.0, \"selectable_gb\": 209, \"bucket\": \"b\", \"login\": {\"present\": false},
      \"region\": \"ap-south-1\", \"inr_per_usd\": 94.95, \"expiry_days\": 14, \"last_seen\": \"$SEEN\", \"marks_read\": true}"
ELSE="{\"error\": null, \"region\": \"ap-south-1\", \"inr_per_usd\": 94.95, \"expiry_days\": 14,
  \"last_seen\": \"$SEEN\", \"marks_read\": true, \"bytes\": 174813455930, \"usd_month\": 4.07, \"places\": [
  {\"bucket\": \"ayis-library-old\", \"region\": \"ap-south-2\", \"error\": null, \"bytes\": 174813455930, \"games_bytes\": 174813206488, \"xregion_usd_gb\": 0.086,
   \"usd_month\": 4.07, \"login\": true, \"games\": [{\"appid\": \"2344520\", \"name\": \"Diablo IV\", \"installdir\": \"Diablo IV\",
   \"bytes\": 174813206488, \"usd_month\": 4.07, \"pushed\": \"2026-09-26T10:38:58Z\", \"kept\": \"$KEPT\"}]},
  {\"bucket\": \"ayis-library-empty\", \"region\": \"ap-south-2\", \"error\": null, \"bytes\": 0, \"games_bytes\": 0,
   \"usd_month\": 0, \"games\": [], \"login\": false}]}"
TWO_SWEEP='{"cached": true, "age_seconds": 90, "too_far": [], "unreachable": [],
  "regions": [{"region": "ap-south-2", "city": "Asia Pacific (Hyderabad)", "rtt_ms": 19, "enabled": true, "machines": []},
              {"region": "ap-south-1", "city": "Asia Pacific (Mumbai)", "rtt_ms": 12, "enabled": true, "machines": []}]}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $TWO_SWEEP, \"library list --json\": $LIB2,
  \"library elsewhere --json\": $ELSE,
  \"status --json\": $(st null '{"bytes": 128849018880}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "the machine's place first"         "$(row AFTER)" "rows=Red Dead 2 / Mumbai / 120.0 GB / ₹285 a month / Deleted on $D13 unless you play it or keep it / KeepDelete"
contains "  then the other place's, with Move" "$(row AFTER)" "Diablo IV / Hyderabad / 162.8 GB / ₹386 a month / Deleted on $D14 unless you play it or keep it / Move to MumbaiKeepDelete"
contains "  its Reset counts from the Reset" "$(row AFTER)" "Deleted on $D14 unless"
contains "  one total"                       "$(row AFTER)" "foot=2 games · 282.8 GB · ₹671 a month"
contains "  and how long, as set"            "$(row AFTER)" "keepfor=14 note=Deleted 14 days after last played."
lacks    "  an empty place is not a row"     "$(row AFTER)" "ayis-library-empty"
c=$(row AFTER); lacks "  nor any bucket name on the page" "${c%% | move=*}" "ayis-library"
contains "Move asks first, with the price"   "$(row AFTER)" "title=Move Diablo IV to Mumbai? body=162.8 GB is copied from Hyderabad to Mumbai"
contains "  about the one-time cost"         "$(row AFTER)" "One-time transfer: about ₹1,329"
contains "  runs ayis's move from that place"  "$(row AFTER)" "ran=library move 2344520 --from ayis-library-old"
contains "  in the popup, answered for ayis"   "$(row AFTER)" "popup=Moving Diablo IV to Mumbai answered=MOVE"
contains "  and stays on Library"            "$(row AFTER)" "after=view=library popup=false"
contains "Reset needs no confirm"            "$(row AFTER)" "reset=ran=library reset 2344520 --from ayis-library-old popup=Resetting timer for Diablo IV"
contains "Keep for applies at once"          "$(row AFTER)" "keep=ran=library keep-for 30 popup=Retention set to 30 days"
# The popup said "Keeping saved games for 14 days" twice - title and step.
contains "  under the title, a placeholder until ayis speaks" "$(row AFTER)" "steps=before:● Working…"
contains "  then ayis's own steps, each ticked as the next begins" "$(row AFTER)" "during:✓ Saving the setting, ● Updating auto-stop"
contains "  a place by its city, not its code" "$(row AFTER)" "● Deleting it from Hyderabad"
lacks    "  never the title again"           "$(row AFTER)" "during:● Keeping"
# And afterwards, only what Keep for can change - not the tools, the keys,
# Tailscale or the locations, which it used to read all over again.
contains "  then reads only what it changed" "$(row AFTER)" "reads=library,elsewhere,config,guards"
ENGINE=""

echo "7c. a line that sounds like failure does not fail a healthy build"
# What happened on a real build: the box's progress said "NvFBC cannot capture
# with it on", ayis reads "cannot" as a failure, and the driver step went red
# while the build carried on installing Steam.
B3="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  window.askConfirm = async () => true;
  document.getElementById('b-build').click();
  await new Promise(r => setTimeout(r, 30));
  const id = window.__lastId;
  for (const t of ['preflight', 'arming the budget', 'provisioning instance',
                   'waiting for the box to join the tailnet', 'building the box'])
    window.__emit(id, { t: 'step', text: t });
  window.__emit(id, { t: 'line', kind: 'fail', text: 'disabling nvidia DRM KMS (NvFBC cannot capture with it on)' });
  for (let i = 0; i < 80; i++) window.__emit(id, { t: 'line', text: 'installing steam ' + i });
  await new Promise(r => setTimeout(r, 30));
  const parts = [...document.querySelectorAll('#b-parts [data-part]')]
    .map(c => c.dataset.part + ':' + c.dataset.state).join(',');
  window.__emit(id, { t: 'line', text: 'finishing up (reboots, then waits for the game restore to finish)' });
  await new Promise(r => setTimeout(r, 30));
  const st = () => [...document.querySelectorAll('#b-steps [data-step]')].map(r => r.dataset.state).join(',');
  const mid = 'parts=' + parts + ' | mid=' + st() + ' failpanel=' + !document.getElementById('b-fail').classList.contains('hidden')
    + ' stripScrolls=' + (document.getElementById('b-strip').scrollHeight > document.getElementById('b-strip').clientHeight + 1);
  window.__emit(id, { t: 'step', text: 'moonlight pairing' });
  window.__emit(id, { t: 'step', text: 'waiting for Steam to finish installing' });
  window.__emit(id, { t: 'exit', rc: 0 });
  await new Promise(r => setTimeout(r, 30));
  return mid + ' | end=' + document.getElementById('b-strip-title').textContent + ' ' + st();
};"
ENGINE="$B3"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "the driver step is not failed"   "$(row AFTER)" "mid=done,done,done,done,done,running"
contains "  'finishing up' is the games step" "$(row AFTER)" ",running,locked,locked"
contains "  and no failure is shown"       "$(row AFTER)" "failpanel=false"
# The step installs far more than a driver; each piece is a chip, ticked as the
# box moves on to the next.
contains "the parts are listed"            "$(row AFTER)" "parts=Base system:"
contains "  the driver, done once Steam starts" "$(row AFTER)" "NVIDIA driver:done"
contains "  Steam, in progress"            "$(row AFTER)" "Steam:running"
contains "  Firefox and audio still to come" "$(row AFTER)" "Firefox:waiting,Audio:waiting"
# Under the panels now, so the page may scroll too; the card stays bounded.
contains "a long build scrolls in its card" "$(row AFTER)" "stripScrolls=true"
contains "it finishes as how it was built" "$(row AFTER)" "end=How it was built done,done,done,done,done,done,done,done"
ENGINE=""

echo "7d. a wait ayis reports: how long, against what, and only the first and last in the log"
# ayis sends a wait event every few seconds. The step shows the latest as its live
# line, a short limit as a real bar, and the Log keeps the start and the end -
# not one row per poll.
B7="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  window.askConfirm = async () => true;
  document.getElementById('b-build').click();
  await new Promise(r => setTimeout(r, 30));
  const id = window.__lastId;
  const wait = (state, secs, of, text) => window.__emit(id, { t: 'wait', id: 'init.tailnet', state, text: text || 'waiting for the box to join the tailnet', secs, of });
  for (const t of ['preflight', 'provisioning instance', 'waiting for the box to join the tailnet']) window.__emit(id, { t: 'step', text: t });
  wait('waiting', 0, 1800); wait('waiting', 10, 1800); wait('waiting', 20, 1800);
  await new Promise(r => setTimeout(r, 30));
  const live = () => (document.querySelector('#b-steps [data-state=running] p') || {}).textContent;
  const bar = () => (document.querySelector('#b-steps [data-state=running] .onb-progress') || { classList: { contains: () => false } }).classList.contains('determinate');
  const long = 'long=' + live() + ' bar=' + bar();
  // A short limit is a measure, so the bar fills.
  window.__emit(id, { t: 'wait', id: 'open.sunshine', state: 'waiting', text: 'waiting for sunshine', secs: 30, of: 120 });
  await new Promise(r => setTimeout(r, 30));
  const short = 'short=' + live() + ' bar=' + bar()
    + ' width=' + ((document.querySelector('#b-steps [data-state=running] .onb-progress i') || {}).style || {}).width;
  // Its end clears the line; the next step does too.
  window.__emit(id, { t: 'wait', id: 'open.sunshine', state: 'done', text: 'waiting for sunshine', secs: 40, of: 120 });
  await new Promise(r => setTimeout(r, 30));
  const done = 'done=' + live();
  const rows = [...document.querySelectorAll('#log .log-row')].map(r => r.textContent).filter(t => /tailnet \\(/.test(t));
  return long + ' | ' + short + ' | ' + done + ' | logrows=' + rows.length;
};"
ENGINE="$B7"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a long wait says how long it has gone" "$(row AFTER)" "long=waiting for the box to join the tailnet · 20 s bar=false"
contains "a short limit is a bar"                 "$(row AFTER)" "short=waiting for sunshine · 30 s of 2 min bar=true width=25%"
contains "its end puts the step's last line back"            "$(row AFTER)" "done=waiting for the box to join the tailnet"
contains "the Log keeps one row for the wait"     "$(row AFTER)" "logrows=1"
ENGINE=""

echo "5. nothing threw"
check "the page logged no errors"   "$(row ERRS)" "ERRS | "

gate_finish
