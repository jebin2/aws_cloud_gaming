#!/usr/bin/env bash
# The Build page, play as a session, and the Games table.
# One of five files that were tests/startup-gate.sh; see lib/startup-gate-harness.sh.
GATE_NAME=startup-gate-build
source "$(dirname "$0")/lib/startup-gate-harness.sh"

echo "7. the Build page: a build is eight plain steps"
# cg reports a dozen steps of its own and the box a dozen more ("installing
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
contains "the confirm names the rate"        "$(row AFTER)" "Billed ₹16.44/hour while running."
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
  const run0 = window.cg.run;
  window.cg.run = args => run0(args).then(r => { if (args[0] === 'destroy') window.__delId = r.id; return r; });
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
  for (const t of ['preflight', 'arming the budget', 'reusing the existing box, already on the tailnet as gamevps', 'building the box'])
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
  // Cancel: cg is interrupted, then whatever it rented is deleted, and the
  // plan comes straight back.
  window.__answers['status --json'].box = null;
  run = null; boxNow = null; paintRun();
  let del = null;
  const orig = window.cg.run;
  window.cg.run = async a => { const r = await orig(a); if (a[0] === 'destroy') del = r.id; return r; };
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
contains "cancel interrupts cg"               "$(row AFTER)" "cancelled=true"
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

echo "7f. play is a session, as steps; closing Moonlight just ends it"
# cg open announces no steps, so the card used to say "Starting the stream" over
# an empty list for the whole session.
B6="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  const wait = () => new Promise(r => setTimeout(r, 30));
  const st = () => [...document.querySelectorAll('#b-steps [data-step]')].map(r => r.dataset.state).join(',');
  const card = () => (document.getElementById('b-plan').hidden ? '' : 'plan')
    + (document.getElementById('b-strip').hidden ? '' : 'run:' + document.getElementById('b-strip-title').textContent);
  const play = async () => {
    document.getElementById('b-open').click();
    await wait();
    return window.__lastId;
  };
  let id = await play();
  const line = t => window.__emit(id, { t: 'line', text: t });
  const starting = card() + ' ' + st();
  line('instance already running');
  line('  pong from game (100.64.0.2) via 1.2.3.4:41641 in 23ms');
  line('waiting for sunshine ok');
  line('disk:');
  await wait();
  const playing = card() + ' ' + st() + ' | ' + document.getElementById('b-steps').innerText.replace(/\\s+/g, ' ')
    + ' | ' + document.getElementById('b-strip-meta').textContent;
  line('session ended after 5m');
  window.__emit(id, { t: 'exit', rc: 0 });
  await wait();
  const kept = card() + 'panel:' + document.querySelector('#b-machine-card [data-f=title]').textContent;
  return 'starting=' + starting + ' | playing=' + playing + ' | kept=' + kept + ' | asked=' + document.getElementById('ask').open;
};"
ENGINE="$B6"
BOX='{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOX" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "play starts with the machine"     "$(row AFTER)" "starting=run:Starting session running,locked,locked,locked"
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
  // cg knows it too, for the reads after the session.
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
contains "play runs cg host open"            "$(row AFTER)" "ran=host open homebox"
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
  document.getElementById('b-open').click();
  await wait();
  const id = window.__lastId;
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
  document.getElementById('b-open').click();
  await wait();
  id = window.__lastId;
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
  window.cg.answer = (id, v) => { answered.push(v); return Promise.resolve(true); };
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
  // What a failure left, from cg's words: a move part-way, a setting half-applied.
  const left = 'move=' + libraryLeft('the copy stopped - nothing was deleted from ap-south-2; run the move again to finish it')
    + ' keep=' + libraryLeft('saved, but the cloud watchdog still counts the old days - run: cg watchdog install')
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
contains "  runs cg's forget"                "$(row AFTER)" "ran=library forget 2344520"
contains "  with the popup saying so"        "$(row AFTER)" "popup=true:Deleting Diablo IV"
contains "  and cg gets the word, no second dialog" "$(row AFTER)" "answered=FORGET askdlg=false"
contains "done: the popup reads the page again" "$(row AFTER)" "reading=Refreshing Games"
contains "  only the saved games, nothing else" "$(row AFTER)" "reads=library,elsewhere |"
contains "  and closes, still on Library"    "$(row AFTER)" "after=view=library popup=false"
contains "refused: the popup stays"          "$(row AFTER)" "refused=popup=true title=Deleting Diablo IV - not done"
contains "  with cg's reason"                "$(row AFTER)" "aborted - nothing was deleted"
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
  window.cg.answer = (id, v) => { answered.push(v); return Promise.resolve(true); };
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
  {\"bucket\": \"cg-library-old\", \"region\": \"ap-south-2\", \"error\": null, \"bytes\": 174813455930, \"games_bytes\": 174813206488, \"xregion_usd_gb\": 0.086,
   \"usd_month\": 4.07, \"login\": true, \"games\": [{\"appid\": \"2344520\", \"name\": \"Diablo IV\", \"installdir\": \"Diablo IV\",
   \"bytes\": 174813206488, \"usd_month\": 4.07, \"pushed\": \"2026-09-26T10:38:58Z\", \"kept\": \"$KEPT\"}]},
  {\"bucket\": \"cg-library-empty\", \"region\": \"ap-south-2\", \"error\": null, \"bytes\": 0, \"games_bytes\": 0,
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
lacks    "  an empty place is not a row"     "$(row AFTER)" "cg-library-empty"
c=$(row AFTER); lacks "  nor any bucket name on the page" "${c%% | move=*}" "cg-library"
contains "Move asks first, with the price"   "$(row AFTER)" "title=Move Diablo IV to Mumbai? body=162.8 GB is copied from Hyderabad to Mumbai"
contains "  about the one-time cost"         "$(row AFTER)" "One-time transfer: about ₹1,329"
contains "  runs cg's move from that place"  "$(row AFTER)" "ran=library move 2344520 --from cg-library-old"
contains "  in the popup, answered for cg"   "$(row AFTER)" "popup=Moving Diablo IV to Mumbai answered=MOVE"
contains "  and stays on Library"            "$(row AFTER)" "after=view=library popup=false"
contains "Reset needs no confirm"            "$(row AFTER)" "reset=ran=library reset 2344520 --from cg-library-old popup=Resetting timer for Diablo IV"
contains "Keep for applies at once"          "$(row AFTER)" "keep=ran=library keep-for 30 popup=Retention set to 30 days"
# The popup said "Keeping saved games for 14 days" twice - title and step.
contains "  under the title, a placeholder until cg speaks" "$(row AFTER)" "steps=before:● Working…"
contains "  then cg's own steps, each ticked as the next begins" "$(row AFTER)" "during:✓ Saving the setting, ● Updating auto-stop"
contains "  a place by its city, not its code" "$(row AFTER)" "● Deleting it from Hyderabad"
lacks    "  never the title again"           "$(row AFTER)" "during:● Keeping"
# And afterwards, only what Keep for can change - not the tools, the keys,
# Tailscale or the locations, which it used to read all over again.
contains "  then reads only what it changed" "$(row AFTER)" "reads=library,elsewhere,config,guards"
ENGINE=""

echo "7c. a line that sounds like failure does not fail a healthy build"
# What happened on a real build: the box's progress said "NvFBC cannot capture
# with it on", cg reads "cannot" as a failure, and the driver step went red
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

echo "5. nothing threw"
check "the page logged no errors"   "$(row ERRS)" "ERRS | "

gate_finish
