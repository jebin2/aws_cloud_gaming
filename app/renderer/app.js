'use strict';
// The view. It knows which cg command fills which panel, and renders the fields
// cg hands it - no AWS, no prices of its own, and no parsing of the human
// tables that arrive inside a report event.

const $ = id => document.getElementById(id);

// Several runs can be in flight: reading status, the watcher and the archive
// index are independent, so they go together. Each job remembers which screen
// started it and what to do with its answer.
const jobs = new Map();          // id -> { cmd, view, json, panel, collect, age, out, resolve }
let view = 'dashboard';

// What a run is called, so a button can say what it stops rather than "Stop".
const RUN_NAME = {
  init: 'build', destroy: 'destroy', open: 'session', check: 'check', library: 'archive change',
  status: 'refresh', watcher: 'refresh', library: 'refresh', cost: 'cost fetch',
};
const runName = cmd => RUN_NAME[cmd[0]] || cmd[0];
// Runs long enough to be worth going back to.
const WATCHABLE = new Set(['init', 'destroy', 'open']);
const watchable = cmd => WATCHABLE.has(cmd[0]) || (cmd[0] === 'library' && LIBRARY_WRITES.has(cmd[1]));
const jobsHere = () => [...jobs.values()].filter(j => j.view === view);

// A screen's button answers for that screen. The one real dependency is that a
// build or a destroy runs alone - cg refuses anything else while one is in
// flight - so those disable the rest. Reads never block each other.
const WRITES = new Set(['init', 'destroy', 'open']);
// `library` is both: `list` is a free read that runs on every refresh, while
// `clean` and `forget` delete from S3 for good. The main process draws the same
// line in isReadOnly(); these two must not drift apart.
const LIBRARY_WRITES = new Set(['push', 'pull', 'forget', 'clean', 'account']);
const isWrite = cmd => WRITES.has(cmd[0]) || (cmd[0] === 'library' && LIBRARY_WRITES.has(cmd[1]));
const writing = () => [...jobs.values()].some(j => isWrite(j.cmd));
const runningHere = cmd => jobsHere().some(j => j.cmd[0] === cmd);
const jobsFor = cmd => [...jobs.values()].some(j => j.cmd[0] === cmd);

// job-line carries both the running list and a failure, so its colour has to be
// set back as well as its text - otherwise one failed read left every later
// "idle" painted as an error.
const JOB_LINE_OK  = 'font-code-sm text-code-sm text-on-surface-variant';
const JOB_LINE_ERR = 'font-code-sm text-code-sm text-error';

function updateHeader() {
  const mine = jobsHere();
  const busy = writing();
  const names = [...new Set([...jobs.values()].map(j => runName(j.cmd)))];

  // The dashboard's refresh is two commands - status and the watcher - but one
  // action to you, so count what they are called, not how many there are.
  const hereNames = [...new Set(mine.map(j => runName(j.cmd)))];
  $('cancel').hidden = !mine.length;
  if (mine.length) $('cancel-label').textContent =
    hereNames.length === 1 ? `Stop ${hereNames[0]}` : `Stop ${hereNames.length} runs`;

  // Point at a run only when it is worth watching: a build or a destroy takes
  // minutes and has its own screen. A refresh finishes in seconds and paints
  // itself, so sending you to another tab for it is noise.
  const elsewhere = [...jobs.values()].find(j => watchable(j.cmd) && j.view !== view);
  $('goto').hidden = !elsewhere;
  if (elsewhere) {
    $('goto-label').textContent = `${runName(elsewhere.cmd)} running - show it`;
    $('goto').dataset.view = elsewhere.view;
  }

  // Cost has a Refresh like every screen, but it carries its price: one Cost
  // Explorer call, $0.01. It is never fetched automatically - only this click.
  $('refresh').hidden = (!NEEDS[view] && view !== 'cost') || !!mine.length;
  $('refresh').disabled = busy;                    // only a build or destroy blocks a read
  $('refresh-cost').hidden = view !== 'cost';
  $('check').disabled = busy || runningHere('check');
  // These change something, so they wait for whatever else is running.
  for (const b of ['b-build', 'b-open', 'b-destroy', 'd-open', 'd-destroy', 'd-build'])
    $(b).disabled = jobs.size > 0;
  for (const b of ['b-open', 'd-open']) if (sessionNow) $(b).disabled = true;

  $('job-line').textContent = jobs.size
    ? `running: ${names.map(n => 'cg ' + n).join(', ')}` : 'idle';
  $('job-line').className = JOB_LINE_OK;
}

// The dashboard's activity list: what cg did in this window. The app keeps no
// history beyond it - the durable record is the watchdog's own log, shown on
// the Guards screen.
function note(text, tone) {
  activity.unshift({ at: new Date(), text, tone });
  activity.length = Math.min(activity.length, 8);
  const wrap = $('d-activity');
  if (!wrap) return;
  wrap.textContent = '';
  if (!activity.length) {
    const el = document.createElement('span');
    el.className = 'text-outline';
    el.textContent = 'nothing yet';
    wrap.append(el);
    return;
  }
  for (const a of activity) {
    const row = document.createElement('div');
    row.className = 'flex gap-space-sm';
    const t = document.createElement('span');
    t.className = 'text-outline shrink-0';
    t.textContent = a.at.toLocaleTimeString();
    const b = document.createElement('span');
    b.className = a.tone || 'text-on-surface-variant';
    b.textContent = a.text;
    row.append(t, b);
    wrap.append(row);
  }
}

// The event stream, filtered. Rows carry their kind so a filter can hide them
// without the app keeping a second copy of the log.
let logFilter = 'all';
let logCount = 0;

function logKind(event) {
  if (event.t === 'raw') return 'raw';
  if (event.t === 'error' || event.kind === 'fail') return 'problems';
  if (event.t === 'step' || event.t === 'step_end') return 'steps';
  return 'other';
}

function logLine(event) {
  const kind = event.kind || event.t;
  const row = document.createElement('div');
  row.dataset.group = logKind(event);
  row.className = 'log-row';
  row.hidden = logFilter !== 'all' && row.dataset.group !== logFilter;
  row.innerHTML = '<time></time><span class="k"></span><span class="t"></span>';
  row.querySelector('time').textContent = (event.at || '').slice(11, 19)
    || new Date().toLocaleTimeString();
  row.querySelector('.k').textContent = event.t === 'line' ? (event.kind || '') : event.t;
  row.querySelector('.k').className = 'k ' + kind;
  row.querySelector('.t').textContent =
    event.text || event.prompt || (event.t === 'exit' ? `exit ${event.rc}` : '');
  const log = $('log');
  log.append(row);
  // A long build is thousands of lines; the window keeps the last 2000.
  while (log.children.length > 2000) log.firstChild.remove();
  logCount += 1;
  $('log-count').textContent = `${logCount} event${logCount === 1 ? '' : 's'}`;
  if ($('log-follow').checked) log.scrollTop = log.scrollHeight;
}

function applyLogFilter(which) {
  logFilter = which;
  for (const row of $('log').children) {
    row.hidden = which !== 'all' && row.dataset.group !== which;
  }
  for (const b of document.querySelectorAll('[data-filter]')) {
    b.classList.toggle('btn-primary', b.dataset.filter === which);
  }
}

// The app's own confirmation. window.confirm draws a native alert box that
// belongs to no design and says the app's name in its title bar.
function askConfirm({ title, body, yes = 'Continue', danger = false }) {
  return new Promise(resolve => {
    $('confirm-title').textContent = title;
    $('confirm-body').textContent = body;
    const btn = $('confirm-yes');
    btn.textContent = yes;
    btn.className = 'btn ' + (danger ? 'btn-danger' : 'btn-primary');
    const dlg = $('confirm');
    dlg.onclose = () => resolve(dlg.returnValue === 'yes');
    dlg.showModal();
  });
}

function ask(id, event) {
  $('ask-prompt').textContent = event.prompt || event.id;
  const input = $('ask-input');
  input.value = event.default || '';
  input.type = event.secret ? 'password' : 'text';
  $('ask').showModal();
  input.focus();
  $('ask').onclose = () => window.cg.answer(id, input.value);
}

const GB = bytes => (bytes / 1073741824).toFixed(1) + ' GB';
function uptime(iso) {
  if (!iso) return '—';
  const mins = Math.max(0, Math.round((Date.now() - new Date(iso)) / 60000));
  return mins < 60 ? `${mins}m` : `${Math.floor(mins / 60)}h ${mins % 60}m`;
}
// The vendored icon font is subset by name, and Google's subsetting drops the
// ligatures - so an icon is addressed by codepoint, not by writing its name.
const ICON = {"attach_money": "", "bolt": "", "build_circle": "", "check_circle": "", "dashboard": "", "delete": "", "error": "", "public": "", "refresh": "", "rocket_launch": "", "schedule": "", "settings": "", "shield": "", "sports_esports": "", "stadia_controller": "", "storage": "", "terminal": ""};

function pill(parent, text, tone, icon) {
  const el = document.createElement('span');
  el.className = 'pill ' + (tone ? 'pill-' + tone : '');
  if (icon) {
    const i = document.createElement('span');
    i.className = 'material-symbols-outlined text-[14px]';
    i.textContent = ICON[icon] || '';
    el.append(i);
  }
  el.append(document.createTextNode(text));
  parent.append(el);
}

// Everything below reads fields from `cg status --json`. If a screen ever wants
// something that is not there, the fix is a field in cg - never a regex here.
function paintStatus(s) {
  paintSpec(s);
  // cg could not talk to AWS at all. Every number on every screen is then
  // unknown - which is not the same as zero, and must not be drawn as zero.
  const credErr = s.error && s.error.credentials;
  $('banner').hidden = !credErr;
  if (credErr) {
    $('banner-title').textContent = 'AWS rejected these credentials';
    $('banner-body').textContent = `${s.error.credentials} Your games are in S3; nothing here can see `
      + 'them until this is fixed. Settings - or cg check --fix - takes a new key.';
    $('arch-size').textContent = 'unknown';
    $('arch-objects').textContent = '—';
    $('arch-cost').textContent = '—';
    $('arch-chip').hidden = false;
    $('arch-chip').textContent = 'unknown - not empty';
    $('arch-chip').className = 'pill pill-bad';
  }
  $('chip-region').textContent = `${s.region} · ${s.host}`;

  // The mockup's three stages. cg reports one state; the stage is which of the
  // three that state falls into, and nothing is ever shown as "Ready" while a
  // build is still running.
  const st = s.box ? s.box.state : null;
  const stage = !st ? 'No box'
    : (st === 'pending' || jobsFor('init')) ? 'Building'
    : st === 'running' ? 'Ready' : st;
  const stages = $('d-stages');
  stages.textContent = '';
  for (const name of ['No box', 'Building', 'Ready']) {
    const el = document.createElement('span');
    el.className = 'px-space-sm py-0.5 rounded ' + (name === stage
      ? 'bg-primary/15 text-primary' : 'text-outline');
    el.textContent = name;
    stages.append(el);
  }

  // The machine, and whether anything is streaming: the two things the mockup
  // puts beside the title.
  const spec = s.spec || {};
  $('d-machine').textContent = spec.gpu
    ? `${spec.gpu} · ${Math.round((spec.gpu_memory_mib || 0) / 1024)} GB VRAM · ${spec.vcpus} vCPU · `
      + `${Math.round((spec.memory_mib || 0) / 1024)} GB RAM`
    : s.instance_type;

  $('box-state').textContent = s.box ? s.box.state : 'No box';
  $('box-state').className = 'font-headline-xl text-headline-xl mb-space-lg '
    + (s.box ? 'text-primary' : 'text-outline');
  $('dot-conn').className = 'w-2 h-2 rounded-full ' + (s.box ? 'bg-primary animate-pulse' : 'bg-outline');
  $('chip-conn').textContent = s.box ? 'box running' : 'no box';
  $('box-type').textContent = s.box ? s.box.type : s.instance_type;
  $('box-region').textContent = s.region;
  const spot = s.config && s.config.spot;
  $('box-buy').textContent = spot === '0' ? 'on demand' : spot === '1' ? 'spot' : 'spot when it can';
  $('box-chip').hidden = !s.box;
  if (s.box) {
    $('box-chip').textContent = s.box.state === 'running' ? 'billing' : s.box.state;
    $('box-chip').className = 'pill ' + (s.box.state === 'running' ? 'pill-bad' : '');
  }
  $('box-uptime').textContent = s.box ? uptime(s.box.launched) : 'not running';
  $('box-node').textContent = s.tailnet.node
    ? `${s.tailnet.node} · ${s.tailnet.online ? 'online' : 'offline'}` : 'no node';

  if (credErr) {
    // already said above: unknown, and the banner explains why
  } else if (s.archive && s.archive.error) {
    $('arch-size').textContent = 'unknown';
    $('arch-objects').textContent = '—';
    $('arch-cost').textContent = '—';
    $('arch-chip').hidden = false;
    $('arch-chip').textContent = 'cannot read S3 - this is not "empty"';
    $('arch-chip').className = 'pill pill-bad';
  } else if (s.archive && s.archive.bucket) {
    $('arch-bucket').textContent = `s3://${s.archive.bucket}`;
    $('arch-size').textContent = s.archive.bytes ? GB(s.archive.bytes) : 'empty';
    $('arch-objects').textContent = s.archive.objects ?? '—';
    $('arch-cost').textContent = s.archive.usd_month != null ? `$${s.archive.usd_month}` : '—';
    $('arch-chip').hidden = !s.archive.decision;
    $('arch-expiry').textContent = s.archive.decision || '';
    // Expiry off reads as reassurance, not a warning.
    $('arch-expiry').className = 'font-code-sm text-code-sm '
      + (s.archive.expiry_days === 0 ? 'text-primary' : 'text-tertiary');
  }

  statusBudget = s.budget || null;
  paintGuardStrip();

  const local = $('local-pills');
  local.textContent = '';
  for (const [name, ok] of [['tailscale', s.local.tailscale], ['moonlight', s.local.moonlight],
                            ['ssh key', s.local.ssh_key], ['auth key', s.local.auth_key]]) {
    pill(local, name, ok ? 'ok' : 'bad', ok ? 'check_circle' : 'error');
  }
  pill(local, `plan ${s.account.plan}`, s.account.plan === 'PAID' ? 'ok' : 'bad', 'cloud');
  pill(local, `credits $${s.account.credits}`, null, 'attach_money');
  $('age-status').textContent = new Date().toLocaleTimeString();

  // What the app may do with the box that exists. A stream can be running that
  // this window never started - closing the app does not end it - so Play asks
  // cg rather than remembering, and refuses to start a second Moonlight.
  sessionNow = s.session || null;
  const running = !!(s.box && s.box.state === 'running');
  $('d-open').hidden = !running;
  $('d-destroy').hidden = !s.box;
  $('d-build').hidden = !!s.box;
  paintSession();
  $('d-note').textContent = sessionNow
    ? 'A stream is already open from this laptop. cg refuses a second one.'
    : s.box
      ? 'Destroy mirrors your games to S3 first, and refuses if that fails.'
      : 'A build takes 10-20 minutes and starts billing.';
}

// Play, on both screens, says what it would do - and says no when a stream is
// already up, which is what cg itself does.
function paintSession() {
  const live = !!sessionNow;
  for (const id of ['d-open', 'b-open']) {
    const b = $(id);
    if (!b) continue;
    const label = b.lastChild;
    if (label && label.nodeType === 3) label.textContent = live ? 'Streaming' : 'Play';
    b.title = live
      ? `a stream is already running from this laptop (pid ${sessionNow.pid})`
      : 'opens Moonlight and streams the box';
  }
  const chip = $('d-session');
  if (chip) {
    chip.textContent = live ? `streaming (pid ${sessionNow.pid})` : 'session idle';
    chip.className = 'pill ' + (live ? 'pill-ok' : '');
  }
  const note = $('b-session');
  if (note) {
    note.hidden = !live;
    note.textContent = live
      ? `A stream is already open from this laptop (pid ${sessionNow.pid}`
        + `${sessionNow.age_s ? ', ' + uptime(new Date(Date.now() - sessionNow.age_s * 1000).toISOString()) : ''}).`
        + ' Find that Moonlight window - cg refuses a second one.'
      : '';
  }
}

const INR = n => '₹' + Math.round(n).toLocaleString('en-IN');
const money = n => (n == null ? '—' : '$' + Number(n).toFixed(2));

function cell(row, text, cls) {
  const td = document.createElement('td');
  td.className = 'py-space-xs px-space-md ' + (cls || '');
  td.textContent = text;
  row.append(td);
  return td;
}

// Rendered from `cg cost --json`: the same single Cost Explorer call the CLI makes.
function setting(key, fallback) {
  const r = config.find(x => x.key === key);
  return (r && (r.effective ?? r.value)) || fallback;
}

function paintSpend(d) {
  // The dashboard shows the last paid fetch and says how old it is. It never
  // fetches on its own: Cost Explorer bills a cent a call.
  costNow = d;
  const m = d.month || {};
  const rate = d.rates || {};
  const inr = rate.inr_per_usd || m.inr_per_usd || 0;
  const days = m.days || [];
  $('d-spend').textContent = m.total_inr != null ? INR(m.total_inr) : '—';
  $('d-spend-sub').textContent = m.total_usd != null
    ? `${money(m.total_usd)} · fetched ${new Date().toLocaleTimeString()}` : 'not fetched yet';
  if (rate.ce_call_usd) $('d-cost-price').textContent = money(rate.ce_call_usd);

  const box = d.resources && d.resources.instance;
  $('d-burn').textContent = box
    ? `${box.id} is ${box.state} - billing by the hour`
    : 'no box - nothing is billing by the hour';
  $('d-burn').className = 'font-code-sm text-code-sm ' + (box ? 'text-tertiary' : 'text-primary');
  $('d-burn-icon').textContent = box ? ICON.error : ICON.check_circle;
  $('d-burn-icon').className = 'material-symbols-outlined text-[16px] mt-0.5 '
    + (box ? 'text-tertiary' : 'text-primary');

  // A bar per billed day, at the same scale, so a heavy day is obvious.
  const spark = $('d-spark');
  spark.textContent = '';
  const max = days.reduce((n, x) => Math.max(n, x.total), 0) || 1;
  for (const day of days.slice(-14)) {
    const bar = document.createElement('div');
    bar.className = 'flex-1 bg-primary/60 rounded-t min-w-[3px]';
    bar.style.height = Math.max(2, (day.total / max) * 100) + '%';
    bar.title = `${day.date}: ${INR(day.total * inr)}`;
    spark.append(bar);
  }
  const now = new Date();
  const inMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
  $('d-projected').textContent = m.total_usd != null
    ? `projected ${INR((m.total_usd / now.getDate()) * inMonth * inr)} this month`
    : 'projected —';
}

function paintCost(d) {
  paintSpend(d);
  const m = d.month || {};
  // Every rate on this screen comes from cg. The app knows no prices: if a
  // number is missing here, the fix is a field in `cg cost --json`.
  const rate = d.rates || {};
  const inr = rate.inr_per_usd || m.inr_per_usd;
  const now = new Date();
  const first = new Date(now.getFullYear(), now.getMonth(), 1);
  const last = new Date(now.getFullYear(), now.getMonth() + 1, 0);
  const fmt = dt => dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  $('c-cycle').textContent = `billing cycle ${fmt(first)} - ${fmt(last)}`;
  $('c-age').textContent = `fetched ${now.toLocaleTimeString()} - one Cost Explorer call, `
    + `${money(rate.ce_call_usd)}`;
  $('c-rate').textContent = `₹${inr} to the dollar`;

  $('c-month').textContent = m.total_inr != null ? INR(m.total_inr) : '—';
  const boxHours = m.hours ? m.hours.on_demand + m.hours.spot : 0;
  $('c-month-usd').textContent = m.total_usd != null
    ? `${money(m.total_usd)} · ${boxHours.toFixed(1)} box hours` : '—';

  // The month projected at today's pace, against the budget cg set up. The
  // budget only emails; saying so is the honest part.
  const cap = d.resources && d.resources.budget_usd;
  const day = now.getDate(), days = last.getDate();
  const projected = m.total_usd != null ? (m.total_usd / day) * days : null;
  $('c-cap-wrap').hidden = !cap;
  $('c-cap-chip').hidden = !cap;
  if (cap && projected != null) {
    const pct = Math.min(100, (projected / cap) * 100);
    $('c-cap-bar').style.width = pct + '%';
    $('c-cap-bar').className = 'h-full ' + (projected > cap ? 'bg-error' : 'bg-primary');
    $('c-cap-chip').textContent = projected > cap ? 'over the budget' : 'under the budget';
    $('c-cap-chip').className = 'pill ' + (projected > cap ? 'pill-bad' : 'pill-ok');
    $('c-cap-note').textContent =
      `projected ${INR(projected * inr)} of the ${INR(cap * inr)} budget, which emails you and stops nothing`;
  } else if (cap) {
    $('c-cap-note').textContent = `budget ${INR(cap * inr)} a month - nothing fetched to compare it with yet`;
  } else {
    $('c-cap-note').textContent = 'no budget set - nothing will warn you';
  }

  $('c-credits').textContent = money(d.credits_usd);
  $('c-credits-note').textContent = d.credits_usd != null && projected
    ? `about ${(d.credits_usd / projected).toFixed(1)} months at this month's pace`
    : '';

  const today = (m.days || []).at(-1);
  $('c-today').textContent = today ? INR(today.total * inr) : '—';
  $('c-today-note').textContent = today ? `${today.date} · ${money(today.total)}` : 'nothing billed yet';
  $('c-today-chip').hidden = !today;
  if (today) {
    $('c-today-chip').textContent = `${(today.hours || 0).toFixed(1)}h box`;
    $('c-today-chip').className = 'pill ' + (today.hours ? 'pill-ok' : '');
  }
  const standby = d.standby || {};
  $('c-today-base').textContent = standby.usd_day
    ? `baseline ${INR(standby.usd_day * inr)} a day with no box at all` : '';

  const rows = $('c-rows');
  rows.textContent = '';
  for (const dayRow of m.days || []) {
    const tr = document.createElement('tr');
    tr.className = 'border-b border-surface-variant/40';
    cell(tr, dayRow.date, 'pr-space-md text-on-surface-variant');
    for (const k of ['hours', 'compute', 's3', 'disk', 'egress', 'api', 'other']) {
      const v = dayRow[k];
      cell(tr, !v ? '–' : (k === 'hours' ? v.toFixed(1) : v.toFixed(2)), 'text-right');
    }
    cell(tr, money(dayRow.total), 'text-right px-space-md text-outline');
    cell(tr, INR(dayRow.total * inr), 'text-right pl-space-md text-primary');
    rows.append(tr);
  }
  const foot = $('c-foot');
  foot.textContent = '';
  if (m.total_usd != null) {
    const tr = document.createElement('tr');
    cell(tr, `MONTH TO DATE (${(m.days || []).length}d)`, 'pr-space-md whitespace-nowrap');
    cell(tr, boxHours ? boxHours.toFixed(1) : '–', 'text-right');
    for (let i = 0; i < 6; i++) cell(tr, '', '');
    cell(tr, money(m.total_usd), 'text-right px-space-md text-outline');
    cell(tr, INR(m.total_inr), 'text-right pl-space-md text-primary font-medium');
    foot.append(tr);
  }

  // What bills when nothing is running: the archive, and whatever cg left behind.
  const arch = d.archive || {};
  $('c-arch-card').hidden = !arch.bucket;
  if (arch.bucket) {
    $('c-arch-size').textContent = arch.bytes ? GB(arch.bytes) : 'empty';
    $('c-arch-rate').textContent = standby.archive_usd_month
      ? `${INR((standby.archive_usd_month / 30) * inr)} / day` : 'nothing yet';
    $('c-arch-note').textContent = arch.usd_month
      ? `S3 standard at ${money(rate.s3_gb_month)} per GB-month · ${money(arch.usd_month)} a month`
      : 'nothing archived yet';
    $('c-arch-decision').textContent = arch.decision || '';
  }

  const bills = $('c-bills');
  bills.textContent = '';
  const line = (label, value, tone) => {
    const div = document.createElement('div');
    div.className = 'row border-b border-surface-variant/40';
    const l = document.createElement('span'); l.className = 'font-code-sm text-code-sm text-outline'; l.textContent = label;
    const v = document.createElement('span'); v.className = 'font-code-sm text-code-sm ' + (tone || ''); v.textContent = value;
    div.append(l, v); bills.append(div);
  };
  const r = d.resources || {};
  if (r.instance) line('box', `${r.instance.id} · ${r.instance.state} · billing by the hour`, 'text-tertiary');
  if (r.volumes_gb) line('volumes', `${r.volumes_gb} GB · ${INR(standby.volumes_usd_month * inr)} / mo`, 'text-tertiary');
  if (r.snapshots_gb) line('snapshots', `${r.snapshots_gb} GB · ${INR(standby.snapshots_usd_month * inr)} / mo`, 'text-tertiary');
  if (r.images) line('saved images', String(r.images), 'text-tertiary');
  line('elastic IPs', 'none held - cg releases them with the box', 'text-primary');
  line('watchdog lambda + logs', 'inside the free tier', 'text-primary');

  $('c-standby').hidden = !!r.instance;
  $('c-standby').textContent = 'standby';
  $('c-standby-note').textContent = r.instance
    ? 'a box is up, so the hourly rate above is on top of all this'
    : `standby burn ${INR(standby.usd_month * inr)} a month (${money(standby.usd_month)}) with no box at all`;

  const e = m.egress || {};
  // Bitrate decides how fast the free 100 GB goes; it is a setting, not a guess.
  const kbps = Number(setting('GAME_BITRATE_KBPS', 20000));
  const gbPerHour = (kbps * 3600) / 8 / 1e6;
  $('c-egress-burn').textContent = `${gbPerHour.toFixed(1)} GB an hour at ${(kbps / 1000).toFixed(0)} Mbps`;
  $('c-egress-rate').textContent = `${money(rate.egress_gb)} / GB`;
  // The one price written into the markup is what pressing Refresh costs, so a
  // first-time reader is warned before the first call. Once cg has answered, it
  // is cg's number like everything else.
  if (rate.ce_call_usd) $('refresh-cost').textContent = money(rate.ce_call_usd);
  if (e.gb_used != null) {
    $('c-egress').textContent = `${e.gb_used} / ${e.gb_free} GB`;
    const pct = Math.min(100, (e.gb_used / e.gb_free) * 100);
    $('c-egress-pct').hidden = false;
    $('c-egress-pct').textContent = `${pct.toFixed(0)}% used`;
    $('c-egress-pct').className = 'pill ' + (pct > 80 ? 'pill-bad' : 'pill-ok');
    $('c-egress-bar').style.width = pct + '%';
    $('c-egress-bar').className = 'h-full ' + (pct > 80 ? 'bg-tertiary' : 'bg-primary');
    $('c-egress-note').textContent = e.gb_left > 0
      ? `about ${(e.gb_left / gbPerHour).toFixed(1)} hours of streaming left before egress costs anything`
      : `the free allowance is used - streaming now costs about `
        + `${INR(gbPerHour * rate.egress_gb * inr)} an hour`;
  }
}
function paintLibrary(d) {
  paintPicker(d);
  paintArchiveCard(d);
  // cg says which it is; the app must never turn "I could not look" into
  // "there is nothing there".
  $('lib-error').hidden = !d.error;
  if (d.error) {
    $('lib-error').textContent = `cannot read the archive: ${d.error}`;
    $('lib-total').textContent = 'unknown';
    $('lib-count').textContent = 'the archive could not be read';
    $('lib-cost').textContent = '—';
    $('lib-rows').textContent = '';
    $('lib-foot').textContent = '';
    $('lib-fit-num').textContent = '—';
    $('lib-fit').textContent = 'unknown until the archive can be read';
    $('lib-fit-chip').hidden = true;
    $('lib-bar').style.width = '0%';
    return;
  }
  const gb = (d.total_bytes || 0) / 1073741824;
  const cap = d.selectable_gb || 209;
  const games = d.games || [];
  $('lib-bucket').textContent = d.bucket ? `s3://${d.bucket}` : 'no bucket yet';
  $('lib-total').textContent = `${gb.toFixed(1)} GB`;
  $('lib-count').textContent = games.length
    ? `${games.length} game${games.length > 1 ? 's' : ''} in the archive`
    : 'the archive is empty';
  $('lib-cost').textContent = `${money(d.usd_month ?? 0)}/mo`;
  $('lib-rate').textContent = d.usd_per_gb_month
    ? `S3 standard, ${money(d.usd_per_gb_month)} per GB-month` : 'S3 standard';
  // A box is up: what is here is the last push, not what is on the box now.
  $('lib-note').textContent = boxNow
    ? 'A box is running - this is the last push. The next one runs before the box is destroyed.'
    : 'Written by the push that runs before every destroy.';

  const rows = $('lib-rows');
  rows.textContent = '';
  if (!games.length) {
    const tr = document.createElement('tr');
    cell(tr, 'the archive is empty', 'py-space-sm text-outline').colSpan = 5;
    rows.append(tr);
  }
  for (const g of games) {
    const tr = document.createElement('tr');
    tr.className = 'border-b border-surface-variant/40';
    const name = cell(tr, '', 'py-space-sm pr-space-md');
    const n = document.createElement('div'); n.textContent = g.name || g.installdir || g.appid;
    const id = document.createElement('div'); id.className = 'text-outline'; id.textContent = `appid ${g.appid}`;
    name.append(n, id);
    cell(tr, GB(g.bytes), 'text-right px-space-md text-on-surface-variant');

    // Share of the archive, so the one worth deleting is obvious at a glance.
    const share = cell(tr, '', 'px-space-md w-32');
    const track = document.createElement('div');
    track.className = 'h-1.5 rounded-full bg-surface-container overflow-hidden';
    const fill = document.createElement('div');
    fill.className = 'h-full bg-secondary';
    fill.style.width = (d.total_bytes ? (g.bytes / d.total_bytes) * 100 : 0) + '%';
    track.append(fill); share.append(track);

    cell(tr, `${money(g.usd_month)}/mo`, 'text-right px-space-md text-tertiary');
    const last = cell(tr, '', 'text-right pl-space-md');
    const when = document.createElement('span');
    when.className = 'text-outline';
    when.textContent = daysAgo(g.pushed);
    const forget = document.createElement('button');
    forget.className = 'btn btn-danger ml-space-sm';
    forget.textContent = 'Forget';
    forget.onclick = () => forgetGame(g);
    last.append(when, forget);
    rows.append(tr);
  }
  const foot = $('lib-foot');
  foot.textContent = '';
  if (games.length) {
    const tr = document.createElement('tr');
    cell(tr, `TOTAL (${games.length})`, 'py-space-sm pr-space-md');
    cell(tr, GB(d.total_bytes), 'text-right px-space-md');
    cell(tr, '', 'px-space-md');
    cell(tr, `${money(d.usd_month ?? 0)}/mo`, 'text-right px-space-md text-tertiary');
    cell(tr, '', '');
    foot.append(tr);
  }

  $('lib-orphan-box').hidden = !d.orphan_bytes;
  if (d.orphan_bytes) {
    $('lib-orphans').textContent =
      `plus ${(d.orphan_bytes / 1073741824).toFixed(1)} GB orphaned by an unfinished push, `
      + `costing ${money(d.orphan_usd_month)} a month and unusable. Nothing indexed is touched.`;
  }

  const over = gb > cap;
  // The number is the true ratio - 138% says something 100% would hide - while
  // the bar stops at full.
  $('lib-fit-num').textContent = `${Math.round((gb / cap) * 100)}%`;
  $('lib-bar').style.width = Math.min(100, (gb / cap) * 100) + '%';
  $('lib-bar').className = 'h-full ' + (over ? 'bg-tertiary' : 'bg-secondary');
  $('lib-fit-chip').hidden = false;
  $('lib-fit-chip').textContent = over ? 'pick some' : 'all of it fits';
  $('lib-fit-chip').className = 'pill ' + (over ? '' : 'pill-ok');
  $('lib-fit').textContent = over
    ? `${gb.toFixed(1)} GB archived - more than the ${cap} GB a box offers, so a build asks which to restore`
    : `${gb.toFixed(1)} GB of the ${cap} GB a box offers after its reserve`;
}

const ago = s => s == null ? '' : s < 90 ? `${s}s ago` : s < 5400 ? `${Math.round(s / 60)}m ago`
  : s < 172800 ? `${Math.round(s / 3600)}h ago` : `${Math.round(s / 86400)}d ago`;

// Rendered from `cg watcher --json`: one card per layer, in the order they fire.
// The guard strip on the dashboard: one card per layer, in the order they fire,
// said the way cg says it. Nothing here is invented - a layer the app does not
// hear about is a layer it does not draw.
// The dashboard's archive card lists what is actually in there, biggest first.
// One game, deleted from the archive for good. cg does the asking - it prints
// what it costs to re-download and demands the word FORGET - so the app's own
// dialog only has to be honest about which game is going.
async function forgetGame(g) {
  const ok = await askConfirm({
    title: `Forget ${g.name || g.appid}?`,
    body: `${GB(g.bytes)} is deleted from the archive permanently. No undo, no versioning.\n\n`
        + 'Playing it again means downloading it from Steam onto a new box. '
        + 'cg will ask you to type FORGET.',
    yes: 'Forget', danger: true,
  });
  if (ok) await startRun(['library', 'forget', String(g.appid)]);
}

function paintArchiveCard(d) {
  const wrap = $('arch-games');
  if (!wrap) return;
  wrap.textContent = '';
  $('arch-cost-line').textContent = d.error ? '' : (d.usd_month ? `${money(d.usd_month)}/mo` : '');
  for (const g of (d.games || []).slice(0, 3)) {
    const row = document.createElement('div');
    row.className = 'row font-code-sm text-code-sm';
    const n = document.createElement('span');
    n.className = 'truncate';
    n.textContent = g.name || g.appid;
    const sz = document.createElement('span');
    sz.className = 'text-outline shrink-0';
    sz.textContent = GB(g.bytes);
    row.append(n, sz);
    wrap.append(row);
  }
  const more = (d.games || []).length - 3;
  if (more > 0) {
    const el = document.createElement('span');
    el.className = 'font-code-sm text-code-sm text-outline';
    el.textContent = `and ${more} more`;
    wrap.append(el);
  }
}

// Layer 1 is not armed or unarmed - `cg open` either runs or it does not - so
// it is not counted. Counting it as unarmed read as a missing guard.
const guardCount = guards => [
  guards.filter(g => g.armed === true).length,
  guards.filter(g => g.armed !== null && g.armed !== undefined).length,
];

function paintGuardStrip() {
  const pills = $('pills');
  pills.textContent = '';
  const guards = (watcher && watcher.guards) || [];
  for (const g of guards) {
    const card = document.createElement('div');
    card.className = 'p-space-md rounded bg-surface-container';
    const top = document.createElement('div');
    top.className = 'flex items-center justify-between gap-space-sm';
    const name = document.createElement('span');
    name.className = 'font-code-md text-code-md';
    name.textContent = g.name;
    const tone = g.armed === true ? 'pill-ok' : g.armed === false ? 'pill-bad' : '';
    const chip = document.createElement('span');
    chip.className = 'pill ' + tone;
    chip.textContent = g.state || (g.armed ? 'armed' : 'unknown');
    top.append(name, chip);
    const sub = document.createElement('p');
    sub.className = 'font-code-sm text-code-sm text-outline mt-0.5';
    sub.textContent = g.reaction || '';
    card.append(top, sub);
    pills.append(card);
  }
  // The budget belongs beside them even though it stops nothing.
  const b = statusBudget || {};
  const card = document.createElement('div');
  card.className = 'p-space-md rounded bg-surface-container';
  const top = document.createElement('div');
  top.className = 'flex items-center justify-between gap-space-sm';
  const name = document.createElement('span');
  name.className = 'font-code-md text-code-md';
  name.textContent = 'monthly budget';
  const chip = document.createElement('span');
  chip.className = 'pill ' + (b.limit != null ? 'pill-ok' : 'pill-bad');
  chip.textContent = b.limit != null ? `$${b.limit}` : 'none';
  top.append(name, chip);
  const sub = document.createElement('p');
  sub.className = 'font-code-sm text-code-sm text-outline mt-0.5';
  sub.textContent = b.limit != null
    ? `${b.alerts || 0} alert address${b.alerts === 1 ? '' : 'es'} - it emails, it stops nothing`
    : 'nothing will warn you';
  card.append(top, sub);
  pills.append(card);

  const [armed, armable] = guardCount(guards);
  $('d-armed').hidden = !guards.length;
  $('d-armed').textContent = `${armed} of ${armable} armed`;
  $('d-armed').className = 'pill ' + (armed === armable ? 'pill-ok' : 'pill-bad');
}

function paintGuards(d) {
  watcher = d;
  paintGuardStrip();
  const wrap = $('guard-cards');
  wrap.textContent = '';
  for (const g of d.guards || []) {
    const card = document.createElement('div');
    card.className = 'p-space-lg rounded-lg bg-surface-container-low';
    // A guard that lives on the box is not "not armed" when there is no box.
    const tone = g.armed === true ? 'pill-ok' : g.armed === false ? 'pill-bad' : '';
    const state = (g.state || (g.armed ? 'armed' : 'unknown')).toUpperCase();
    card.innerHTML = `
      <div class="flex items-start justify-between gap-space-md">
        <div>
          <div class="flex items-center gap-space-sm">
            <span class="material-symbols-outlined text-[18px] text-outline" data-icon="shield">&#xe9e0;</span>
            <span class="font-headline-md text-headline-md"></span>
            <span class="pill">tier ${g.layer}</span>
          </div>
          <p class="font-code-sm text-code-sm text-on-surface-variant mt-space-xs"></p>
        </div>
        <div class="flex items-center gap-space-sm shrink-0">
          <span class="font-code-sm text-code-sm text-outline reaction-top"></span>
          <span class="pill ${tone}">${state}</span>
        </div>
      </div>
      <dl class="grid grid-cols-1 md:grid-cols-3 gap-space-sm mt-space-md">
        <div class="p-space-md rounded bg-surface-container">
          <dt class="font-label-caps text-label-caps uppercase tracking-wider text-outline">catches</dt>
          <dd class="font-code-sm text-code-sm mt-0.5 catches"></dd></div>
        <div class="p-space-md rounded bg-surface-container">
          <dt class="font-label-caps text-label-caps uppercase tracking-wider text-outline">reacts</dt>
          <dd class="font-code-sm text-code-sm mt-0.5 reaction"></dd></div>
        <div class="p-space-md rounded bg-surface-container">
          <dt class="font-label-caps text-label-caps uppercase tracking-wider text-outline">dies with</dt>
          <dd class="font-code-sm text-code-sm mt-0.5 dies"></dd></div>
      </dl>
      <p class="font-code-sm text-code-sm text-outline mt-space-md last"></p>`;
    card.querySelector('.font-headline-md').textContent = g.name;
    card.querySelector('p.font-code-sm').textContent = g.note || '';
    card.querySelector('.catches').textContent = g.catches;
    card.querySelector('.reaction').textContent = g.reaction;
    card.querySelector('.reaction-top').textContent = g.reaction || '';
    card.querySelector('.dies').textContent = g.dies_with;
    card.querySelector('.last').textContent = g.last_decision
      ? `last audit ${ago(g.last_decision_age_s)}: ${g.last_decision}` : '';
    wrap.append(card);
  }

  const [armed, armable] = guardCount(d.guards || []);
  $('g-armed').textContent = `${armed} of ${armable} armed`;
  $('g-armed').className = 'pill ' + (armed === armable ? 'pill-ok' : 'pill-bad');
  $('g-policy').textContent = d.instance_state === 'running'
    ? 'a box is running - these are what end it'
    : 'no box is running - there is nothing for them to stop';

  const b = d.budget || {};
  $('g-budget').textContent = b.usd != null ? `$${b.usd} a month` : 'missing';
  $('g-budget-chip').hidden = false;
  $('g-budget-chip').textContent = b.usd != null ? 'set' : 'none';
  $('g-budget-chip').className = 'pill ' + (b.usd != null ? 'pill-ok' : 'pill-bad');
  $('g-budget-note').textContent = b.usd == null
    ? 'no budget exists - nothing will warn you'
    : `${b.alerts} alert address${b.alerts === 1 ? '' : 'es'}. It emails you; it does not stop anything.`;
  const sd = d.shutdown_action || {};
  $('g-shutdown').textContent = sd.value || (d.instance_state === 'none' ? 'no box' : 'unknown');
  $('g-shutdown-note').textContent = sd.expected
    ? (sd.ok ? `correct for this box (${sd.expected})` : `WRONG - must be ${sd.expected}`)
    : 'decided at launch; a spot box must terminate';

  // The knobs behind the guards, read from the settings registry and edited
  // through cg like every other setting.
  const knobs = $('g-knobs');
  knobs.textContent = '';
  const WANT = ['GAME_WATCHDOG_IDLE_MIN', 'GAME_WATCHDOG_STUCK_MIN', 'GAME_ARCHIVE_EXPIRY_DAYS',
                'GAME_BUDGET_INR', 'GAME_NTFY_URL', 'EMAIL_ALERTS'];
  for (const key of WANT) {
    const r = config.find(x => x.key === key);
    if (!r) continue;
    const row = document.createElement('div');
    row.className = 'row border-b border-surface-variant/40 items-start';
    const left = document.createElement('div');
    const n = document.createElement('p');
    n.className = 'font-code-md text-code-md';
    n.textContent = LABEL[r.key] || r.key;
    const note = document.createElement('p');
    note.className = 'font-code-sm text-code-sm text-outline mt-0.5';
    note.textContent = r.note;
    left.append(n, note);
    const right = document.createElement('div');
    right.className = 'flex items-center gap-space-sm shrink-0';
    const val = document.createElement('span');
    val.className = 'font-code-md text-code-md text-on-surface-variant';
    val.textContent = settingValue(r);
    const edit = document.createElement('button');
    edit.className = 'btn';
    edit.textContent = r.secret && r.is_set ? 'Replace' : 'Edit';
    edit.onclick = () => editSetting(r, row);
    right.append(val, edit);
    row.append(left, right);
    knobs.append(row);
  }

  // Its last decision, in its own words, with the archive line beside it.
  const log = $('g-log');
  log.textContent = '';
  const lines = [];
  for (const g of d.guards || []) {
    if (g.last_decision) lines.push([`${g.name} · ${ago(g.last_decision_age_s)}`, g.last_decision]);
  }
  if (d.archive) lines.push(['archive', d.archive]);
  if (!lines.length) {
    const el = document.createElement('span');
    el.className = 'text-outline';
    el.textContent = 'nothing recorded yet - the cloud watchdog writes a line every hour';
    log.append(el);
  }
  for (const [who, what] of lines) {
    const row = document.createElement('div');
    row.className = 'flex gap-space-sm';
    const a = document.createElement('span');
    a.className = 'text-outline shrink-0';
    a.textContent = who;
    const b2 = document.createElement('span');
    b2.className = 'text-on-surface-variant';
    b2.textContent = what;
    row.append(a, b2);
    log.append(row);
  }

  if (d.archive) $('age-watcher').textContent = new Date().toLocaleTimeString();
}

// --- Settings ----------------------------------------------------------------
// Every row comes from `cg config --json`, and every change goes back through
// `cg config set`, which validates it and writes .env. The app never touches
// the file, and never sees a secret: it can replace one, not read it.
const LABEL = {
  GAME_DISK_GB: 'root disk (GB)', GAME_ARCHIVE_EXPIRY_DAYS: 'archive expiry (days)',
  GAME_INSTANCE_TYPE: 'instance type', GAME_REGION: 'region', GAME_SPOT: 'purchase model',
  GAME_BUDGET_INR: 'monthly budget (₹)', GAME_WATCHDOG_IDLE_MIN: 'cloud watchdog idle (min)',
  GAME_WATCHDOG_STUCK_MIN: 'stuck shutdown forced after (min)',
  GAME_NTFY_URL: 'phone notifications', TAILSCALE_API_KEY: 'Tailscale API token',
  EMAIL_ALERTS: 'billing alerts to', GAME_RES: 'stream resolution',
  GAME_FPS: 'stream fps', GAME_BITRATE_KBPS: 'stream bitrate (kbps)',
};

// "1" means nothing to a person: a choice shows what it chose.
const CHOICE_LABEL = {
  GAME_SPOT: { '1': 'spot', '0': 'on demand', auto: 'spot when the quota allows' },
};
const choiceLabel = (key, v) => (CHOICE_LABEL[key] || {})[v] || v;

function settingValue(r) {
  if (r.secret) return r.is_set ? 'set' : 'not set';
  if (r.value != null) return choiceLabel(r.key, r.value);
  if (r.default != null) return `${choiceLabel(r.key, r.default)} (default)`;
  return 'not set';
}

// Settings, grouped the way the rig is actually thought about: what the box is,
// what stops it costing money, how the stream looks, and who gets told. The
// order and the groups are the app's; every row, rule and value is cg's.
const SETTING_GROUPS = [
  ['The box', 'Applies at the next build. A disk cannot be shrunk later.',
   ['GAME_INSTANCE_TYPE', 'GAME_REGION', 'GAME_SPOT', 'GAME_DISK_GB']],
  ['The guards', 'What the watchdogs wait for, and what the archive costs you to keep.',
   ['GAME_WATCHDOG_IDLE_MIN', 'GAME_WATCHDOG_STUCK_MIN', 'GAME_ARCHIVE_EXPIRY_DAYS', 'GAME_BUDGET_INR']],
  ['The stream', 'Passed to Moonlight as flags, so your saved settings stay untouched.',
   ['GAME_RES', 'GAME_FPS', 'GAME_BITRATE_KBPS']],
  ['Being told', 'Where it reaches you, and the token that keeps the tailnet tidy.',
   ['GAME_NTFY_URL', 'EMAIL_ALERTS', 'TAILSCALE_API_KEY']],
];

function paintConfig(rows) {
  config = rows;
  const wrap = $('s-groups');
  wrap.textContent = '';
  const set = rows.filter(r => r.is_set).length;
  $('s-count').textContent = `${set} of ${rows.length} set`;
  $('s-age').textContent = new Date().toLocaleTimeString();

  const seen = new Set();
  const groups = SETTING_GROUPS.map(([title, note, keys]) => [title, note, keys]);
  // Anything cg grows that this file has not heard of still appears, rather
  // than vanishing because the app did not know where to put it.
  const known = new Set(groups.flatMap(g => g[2]));
  const rest = rows.filter(r => !known.has(r.key)).map(r => r.key);
  if (rest.length) groups.push(['Everything else', 'New settings cg knows about.', rest]);

  for (const [title, note, keys] of groups) {
    const present = keys.map(k => rows.find(r => r.key === k)).filter(Boolean);
    if (!present.length) continue;
    const card = document.createElement('div');
    card.className = 'p-space-lg rounded-lg bg-surface-container-low';
    const head = document.createElement('div');
    head.className = 'pb-space-md';
    const h = document.createElement('span');
    h.className = 'font-label-caps text-label-caps uppercase tracking-wider text-outline';
    h.textContent = title;
    const p = document.createElement('p');
    p.className = 'font-code-sm text-code-sm text-outline mt-0.5';
    p.textContent = note;
    head.append(h, p);
    card.append(head);
    for (const r of present) { seen.add(r.key); card.append(settingRow(r)); }
    wrap.append(card);
  }
}

// The three settings the chooser table owns. They are one decision, so they
// have one control - see chooseMachine.
const CHOSEN_IN_TABLE = new Set(['GAME_REGION', 'GAME_INSTANCE_TYPE', 'GAME_SPOT']);

// One row: what it is, what it is for, what it says now, and how to change it.
function settingRow(r) {
  const row = document.createElement('div');
  row.className = 'row border-b border-surface-variant/40 items-start';

  const left = document.createElement('div');
  left.className = 'min-w-0';
  const name = document.createElement('p');
  name.className = 'font-code-md text-code-md';
  name.textContent = LABEL[r.key] || r.key;
  const note = document.createElement('p');
  note.className = 'font-code-sm text-code-sm text-outline mt-0.5';
  note.textContent = r.note;
  left.append(name, note);

  const right = document.createElement('div');
  right.className = 'flex items-center gap-space-sm shrink-0';
  const val = document.createElement('span');
  val.className = 'font-code-md text-code-md '
    + (r.is_set ? 'text-on-surface-variant' : 'text-outline');
  val.textContent = settingValue(r);

  // Region, machine and purchase model are chosen in the table above, together.
  // Editing them one at a time is what made this confusing: three controls for
  // one decision, and two of the three combinations they can produce cannot
  // launch. The value is still shown here - it is still a setting - but there
  // is exactly one place to change it.
  // ...but only while the table can actually offer something. With no scan and
  // a failing `cg machines` - no credentials, no aws binary - the table is
  // empty, and locking the only other way to set a region would leave no way at
  // all. Then the plain editor comes back.
  if (CHOSEN_IN_TABLE.has(r.key) && !chooserDead()) {
    const where = document.createElement('span');
    where.className = 'font-code-sm text-code-sm text-outline';
    where.textContent = 'set in Machine, above';
    right.append(val, where);
    row.append(left, right);
    return row;
  }

  const edit = document.createElement('button');
  edit.className = 'btn';
  edit.textContent = r.secret && r.is_set ? 'Replace' : 'Edit';
  edit.onclick = () => editSetting(r, row);

  if (r.secret && r.is_set) {
    // Secrets are withheld everywhere else. Showing one is a deliberate act,
    // so it takes a click, asks cg for it, and hides again.
    const eye = document.createElement('button');
    eye.className = 'btn';
    eye.title = 'show the value';
    const glyph = document.createElement('span');
    glyph.className = 'material-symbols-outlined text-[16px]';
    glyph.textContent = ICON.visibility;
    eye.append(glyph);
    let shown = false;
    eye.onclick = async () => {
      if (shown) {
        val.textContent = settingValue(r);
        glyph.textContent = ICON.visibility;
        shown = false;
        return;
      }
      const out = await runCg(['config', 'get', r.key], { capture: true });
      val.textContent = (out || '').trim() || '(empty)';
      glyph.textContent = ICON.visibility_off;   // click again to hide it
      shown = true;
    };
    right.append(val, eye, edit);
  } else {
    right.append(val, edit);
  }
  row.append(left, right);
  return row;
}

function editSetting(r, row) {
  const right = row.lastElementChild;
  right.textContent = '';
  row.classList.add('editing');
  let input;
  if (r.kind === 'choice') {
    input = document.createElement('select');
    for (const opt of (r.rule || '').split(',')) {
      const o = document.createElement('option');
      o.value = opt; o.textContent = choiceLabel(r.key, opt);
      input.append(o);
    }
    input.value = r.value || r.default || 'auto';
  } else {
    input = document.createElement('input');
    input.type = r.secret ? 'password' : (r.kind === 'number' ? 'number' : 'text');
    if (r.kind === 'number' && r.rule) input.min = r.rule;
    input.value = r.secret ? '' : (r.value || '');
    input.placeholder = r.secret
      ? (r.is_set ? 'type a new value, or leave empty to clear' : 'empty means go without')
      : (r.default || '');
  }
  input.className = 'bg-surface border border-surface-variant rounded px-space-sm py-0.5 '
                  + 'font-code-md text-code-md text-on-surface min-w-0 '
                  + 'w-64';
  const save = document.createElement('button');
  save.className = 'btn btn-primary'; save.textContent = 'Save';
  const cancel = document.createElement('button');
  cancel.className = 'btn'; cancel.textContent = 'Cancel';
  cancel.onclick = () => refresh();
  save.onclick = async () => {
    const value = input.value.trim();
    if (r.secret && !value && r.is_set && !(await askConfirm({
          title: `Clear ${LABEL[r.key] || r.key}?`,
          body: 'It will be remembered as "go without", and cg check --fix will not ask again.',
          yes: 'Clear', danger: true,
        }))) return;
    save.disabled = true;
    await runCg(['config', 'set', r.key, value], { collect: 's-check' });
    $('s-check').hidden = false;
    // refresh() re-reads config, machines AND regions for this screen, so a new
    // region repaints the Build picker too - different regions rent different
    // machines, and the type in force may not exist in the one just chosen.
    await refresh();
  };
  right.append(input, save, cancel);
  input.focus();
}

// --- Build -------------------------------------------------------------------
// The picker mirrors cg's own arithmetic so the button can be refused early;
// the box enforces it again at boot, which is where it must be enforced.
let archive = { games: [], selectable_gb: 209 };
let boxNow = null;   // the box `cg status` last reported, or null
let sessionNow = null; // a `cg open` streaming from this laptop, per cg status
let config = [];     // the settings registry, as `cg config --json` last gave it
let watcher = null;  // `cg watcher --json`, for the guard strip and the Guards screen
let statusBudget = null;
let costNow = null;  // the last paid cost fetch, if one was made in this window
const activity = [];  // what cg has done in this window, newest first
const picked = new Set();

function daysAgo(iso) {
  if (!iso) return 'never';
  const days = Math.floor((Date.now() - new Date(iso)) / 86400000);
  if (Number.isNaN(days)) return 'never';
  return days === 0 ? 'today' : days === 1 ? 'yesterday' : `${days}d ago`;
}

function paintPicker(d) {
  archive = d;
  const failed = !!d.error;
  $('b-bucket').textContent = d.bucket ? `s3://${d.bucket}` : 'no bucket yet';
  const body = $('b-games');
  body.textContent = '';
  if (!(d.games || []).length) {
    const tr = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 4;
    td.className = 'py-space-md ' + (failed ? 'text-error' : 'text-outline');
    td.textContent = failed
      ? `The archive could not be read: ${d.error}`
      : 'The archive is empty - a build starts with nothing to restore.';
    tr.append(td); body.append(tr);
  }
  for (const g of d.games || []) {
    const tr = document.createElement('tr');
    tr.className = 'border-b border-surface-variant/40 hover:bg-surface-container cursor-pointer';
    const cell = (cls) => { const td = document.createElement('td'); td.className = cls; tr.append(td); return td; };

    const box = document.createElement('input');
    box.type = 'checkbox'; box.className = 'accent-primary align-middle'; box.dataset.appid = g.appid;
    box.checked = picked.has(g.appid);
    box.onchange = () => { box.checked ? picked.add(g.appid) : picked.delete(g.appid); paintFit(); };
    cell('py-space-sm pr-space-sm').append(box);

    const name = cell('py-space-sm pr-space-md');
    const n = document.createElement('div');
    n.textContent = g.name || g.installdir || g.appid;
    const id = document.createElement('div');
    id.className = 'text-outline';
    id.textContent = `appid ${g.appid}`;
    name.append(n, id);

    cell('py-space-sm px-space-md text-right text-on-surface-variant').textContent = GB(g.bytes);
    cell('py-space-sm pl-space-md text-right text-outline').textContent = daysAgo(g.pushed);

    tr.onclick = e => { if (e.target !== box) { box.checked = !box.checked; box.onchange(); } };
    body.append(tr);
  }
  paintFit();
}

function selectedGb() {
  return (archive.games || []).filter(g => picked.has(g.appid))
    .reduce((n, g) => n + g.bytes, 0) / 1073741824;
}

function paintFit() {
  const gb = selectedGb(), cap = archive.selectable_gb || 209;
  const over = gb > cap;
  $('b-fit').textContent = picked.size
    ? `${gb.toFixed(1)} GB of ${cap} GB on the box's NVMe`
    : 'nothing selected - the box builds empty';
  $('b-fit').className = 'font-code-sm text-code-sm ' + (over ? 'text-error' : 'text-on-surface-variant');
  const pct = Math.min(100, (gb / cap) * 100);
  $('b-fit-pct').textContent = over ? `over by ${(gb - cap).toFixed(1)} GB` : `${Math.round(pct)}%`;
  $('b-fit-pct').className = 'font-code-sm text-code-sm ' + (over ? 'text-error' : 'text-primary');
  $('b-buffer').textContent = over
    ? 'it will not fit - deselect something'
    : `${(cap - gb).toFixed(1)} GB buffer remaining`;
  $('b-bar').style.width = pct + '%';
  $('b-bar').className = 'h-full ' + (over ? 'bg-error' : 'bg-primary');
  // A box is already running: there is nothing to build, and cg would refuse.
  // The screen says so and offers what you can actually do with it.
  const up = !!boxNow;
  $('b-build').hidden = up;
  $('b-open').hidden = !(boxNow && boxNow.state === 'running');
  $('b-destroy').hidden = !up;
  $('b-build').disabled = over || jobs.size > 0;
  for (const box of $('b-games').querySelectorAll('input[type=checkbox]')) box.disabled = up;
  // Nothing here applies while a box is up: what it holds was chosen at build.
  $('b-alloc').hidden = up;
  $('b-hint').textContent = up
    ? 'A box is already running. What it holds was chosen when it was built; destroy it to change that.'
    : 'Pulled from S3 while the box builds. Nothing is selected by default.';
}

// The machine strip: the type you asked for, and what AWS says that type is.
// Every number here comes from `cg status --json`; nothing is hardcoded.
// The instance-type picker. Everything shown - the types, their GPUs, their
// prices - is `cg machines --json`; nothing about any machine is written down
// in this file. Choosing one writes GAME_INSTANCE_TYPE through `cg config set`,
// so .env stays the single source of truth and the next build agrees with the
// picker without being told.
// The machine chooser: ONE table, rendered into both the Build and the Settings
// screen, replacing three separate dropdowns for region, instance type and
// purchase model. Those were not three decisions - the whole question is which
// COMBINATION to run, and a dropdown per axis hid exactly the comparison that
// matters. Picking a price picks all three.
//
// Rows come from `cg sweep`, which is free but takes about 90 seconds, so the
// app reads the remembered scan (`cg sweep --cached`, instant) and rescans only
// when asked. With no scan yet there is still a table: the current region's
// machines, from `cg machines`, with a line saying what a scan would add.
let sweepNow = null;
let sweepAnswered = false;
function paintSweep(d) { sweepNow = d; sweepAnswered = true; paintChooser(); }

// The settings rows defer to the table - but they are painted by whichever read
// lands first, and `cg config` usually beats `cg machines` and `cg sweep`. So
// they default to deferring, and only get their own editor back once BOTH
// answers are in AND neither produced a row, which means AWS is unreadable and
// the table can offer nothing.
function chooserDead() {
  return sweepAnswered && machinesAnswered && chooserRows().rows.length === 0;
}

// ONE mount. The table was on Build too, and two copies of a control that
// writes the same three settings is the original confusion in a new shape.
// Build states what will be built and sends you here to change it.
const MOUNTS = [
  { table: 's-chooser', note: 's-type-note', age: 's-sweep-age',
    legend: 's-chooser-legend', name: 'mach-s' },
];

// What is in force, read from cg's own answer rather than remembered here.
// GAME_SPOT 'auto' means spot wherever the quota allows, so it reads as spot -
// the same rule the old picker used.
function cfgVal(key) {
  const r = (config || []).find(x => x.key === key);
  return r ? (r.effective || r.value || r.default || null) : null;
}
function currentPick() {
  return {
    region: cfgVal('GAME_REGION') || (machinesNow && machinesNow.region) || null,
    type: cfgVal('GAME_INSTANCE_TYPE') || (machinesNow && machinesNow.configured) || null,
    spot: (cfgVal('GAME_SPOT') || 'auto') !== '0',
  };
}

function shortCity(city) {
  if (!city) return '';
  const m = /\(([^)]+)\)/.exec(city);
  return m ? m[1] : city;
}

// One flat list of (region, type) rows, whether the data came from a sweep or
// from the current region alone. Everything downstream reads only this shape,
// so the two sources cannot drift apart.
function chooserRows() {
  if (sweepNow && sweepNow.regions && sweepNow.regions.length) {
    const out = [];
    for (const r of sweepNow.regions) {
      for (const m of r.machines) {
        out.push({
          region: r.region, city: shortCity(r.city), rtt: r.rtt_ms, enabled: r.enabled,
          type: m.type, gpu: m.gpu, vram: m.vram_gib, score: m.score,
          spot: m.inr_hour_spot, spotMax: m.inr_hour_spot_max, od: m.inr_hour_ondemand,
          fitsSpot: m.fits_spot, fitsOd: m.fits_ondemand,
        });
      }
    }
    return { rows: out, swept: true };
  }
  // No scan yet. The current region is still worth showing, and comes from a
  // read the app already does.
  if (machinesNow && !machinesNow.error && machinesNow.machines) {
    return {
      rows: machinesNow.machines
        .filter(m => m.fits_spot || m.fits_ondemand)
        .map(m => ({
          region: machinesNow.region, city: '', rtt: null, enabled: true,
          type: m.type, gpu: m.gpu, vram: m.vram_gib, score: null,
          spot: m.inr_hour_spot, spotMax: m.usd_hour_spot_max != null
            ? Math.round(m.usd_hour_spot_max * (machinesNow.inr_per_usd || 88)) : null,
          od: m.inr_hour_ondemand,
          fitsSpot: m.fits_spot, fitsOd: m.fits_ondemand,
        })),
      swept: false,
    };
  }
  return { rows: [], swept: false };
}

function cell(tr, text, cls) {
  const td = tr.insertCell();
  td.textContent = text;
  if (cls) td.className = cls;
  return td;
}

// A price cell IS the control. Disabled for a reason the cell itself states,
// because "why can I not pick this" was the other half of the confusion.
function priceCell(tr, mount, row, spot, inr, cur) {
  const td = tr.insertCell();
  td.className = 'num';
  const fits = spot ? row.fitsSpot : row.fitsOd;
  let why = null;
  if (inr == null) why = spot ? 'no spot market' : 'no price';
  else if (!row.enabled) why = 'needs opt-in';
  else if (fits === false) why = 'no quota';

  const label = document.createElement('label');
  const usable = !why && !boxNow;
  label.className = 'pick ' + (usable ? '' : 'off');
  const radio = document.createElement('input');
  radio.type = 'radio';
  radio.name = mount.name;
  radio.value = `${row.region}|${row.type}|${spot ? '1' : '0'}`;
  radio.disabled = !usable;
  radio.checked = row.region === cur.region && row.type === cur.type && spot === cur.spot;
  if (radio.checked) label.classList.add('on');
  radio.onchange = () => { if (radio.checked) chooseMachine(row, spot); };
  label.append(radio);

  // The cheapest zone, and nothing pins the zone: show the spread when the
  // zones disagree, because the cheap number alone is a promise cg cannot keep.
  const range = spot && inr != null && row.spotMax != null && row.spotMax > inr
    ? `${inr}-${row.spotMax}` : (inr == null ? null : String(inr));
  const amount = document.createElement('span');
  amount.className = 'amount';
  amount.textContent = range == null ? '-' : range;
  label.append(amount);

  // Why, as its own short tag rather than appended to the number: it keeps the
  // prices readable down the column, and the full sentence is in the legend.
  if (why) {
    const tag = document.createElement('span');
    tag.className = 'reason';
    tag.textContent = why;
    label.append(tag);
    label.title = PICK_WHY[why] || why;
  }
  td.append(label);
  return { td, usable, why };
}

// Said once, under the table, instead of a sentence in every cell.
const PICK_WHY = {
  'no quota': 'Your G-instance quota in this region does not cover 4 vCPU for this '
            + 'purchase model. Ask AWS for it in Service Quotas - it is free and takes a day or two.',
  'needs opt-in': 'This region is not enabled on your account. Enabling it is an '
                + 'account-level change, so this app will not do it for you.',
  'no spot market': 'AWS publishes no spot price for this machine here, so there is '
                  + 'nothing to bid on. On demand may still work.',
  'no price': 'The Pricing API returned nothing for this machine here.',
};

let lastDead = null;
let repainting = false;
function paintChooser() {
  const { rows, swept } = chooserRows();
  const cur = currentPick();

  // The settings rows were painted before this had data, so their choice of
  // editor-or-pointer may now be wrong. Repaint them once, when the verdict
  // actually changes, and never from inside their own paint.
  const dead = chooserDead();
  if (!repainting && dead !== lastDead && config.length && $('s-groups').children.length) {
    lastDead = dead;
    repainting = true;
    try { paintConfig(config); } finally { repainting = false; }
  } else {
    lastDead = dead;
  }

  for (const mount of MOUNTS) {
    const table = $(mount.table);
    if (!table) continue;
    table.textContent = '';
    const reasons = new Set();
    if (!rows.length) {
      const td = table.insertRow().insertCell();
      td.colSpan = 8;
      td.className = 'why';
      td.textContent = !machinesAnswered ? 'reading what this region rents…'
        : machinesNow && machinesNow.error ? machinesNow.error
        : 'no machine here fits your quota - Scan all regions to compare every region';
    } else {
      const head = table.createTHead().insertRow();
      // The price headers do NOT get text-right: the cells under them lead with
      // a radio at the cell's left edge, so a right-aligned header sat over
      // nothing. capacity is the only genuinely right-aligned column.
      for (const [label, cls] of [['region', ''], ['city', ''], ['latency', ''],
                                  ['machine', ''], ['gpu', ''], ['capacity', 'text-right'],
                                  ['spot INR/hr', ''], ['on demand INR/hr', '']]) {
        const th = document.createElement('th');
        th.textContent = label; th.className = cls;
        head.append(th);
      }
      const body = table.createTBody();
      let lastRegion = null;
      for (const row of rows) {
        const tr = body.insertRow();
        const first = row.region !== lastRegion;
        if (first && lastRegion !== null) tr.classList.add('group');
        if (row.region === cur.region) tr.classList.add('here');

        cell(tr, first ? row.region : '', 'region');
        cell(tr, first ? row.city : '', 'city');
        cell(tr, first && row.rtt != null ? `${Math.round(row.rtt)} ms` : '', 'ms');
        cell(tr, row.type, '');
        cell(tr, row.gpu ? (row.vram ? `${row.gpu} ${row.vram} GB` : row.gpu) : '-', 'city');

        const sc = tr.insertCell();
        sc.className = 'num';
        if (row.score == null) { sc.textContent = swept ? '-' : ''; sc.classList.add('why'); }
        else {
          const s = document.createElement('span');
          s.className = 'score ' + (row.score >= 7 ? 'good' : row.score <= 2 ? 'bad' : '');
          s.textContent = `${row.score}/10`;
          sc.append(s);
        }
        const a = priceCell(tr, mount, row, true, row.spot, cur);
        const b = priceCell(tr, mount, row, false, row.od, cur);
        // A row with nothing pickable should recede, not look broken.
        if (!a.usable && !b.usable) tr.classList.add('dim');
        for (const r of [a.why, b.why]) if (r) reasons.add(r);
        lastRegion = row.region;
      }
    }

    // What the table cannot show on its own: how old it is, and what is missing.
    const parts = [];
    if (boxNow) parts.push('a box is running - destroy it before changing the machine');
    else if (!swept && rows.length) parts.push('showing this region only - Scan all regions '
      + 'compares every region AWS has, measures latency and reads spot capacity (free)');
    if (swept) {
      parts.push("capacity is AWS's spot placement score: 1 means a launch will almost "
        + 'certainly be refused, whatever the price says');
      // Two numbers in a spot cell are the cheapest and dearest zone, and the
      // zone is not pinned, so the bill can be either.
      if (rows.some(r => r.spotMax != null && r.spot != null && r.spotMax > r.spot))
        parts.push('a spot range is the cheapest and dearest zone - nothing pins the zone, '
                 + 'so either is possible');
      const far = (sweepNow.too_far || []).length;
      if (far) parts.push(`${far} regions are too far to stream and are not listed`);
    }
    $(mount.note).textContent = parts.join(' · ');

    // The legend. Only the reasons actually on screen, in plain words, so a
    // greyed-out half of a column reads as deliberate rather than broken.
    const legend = $(mount.legend);
    if (legend) {
      legend.textContent = '';
      if (reasons.size) {
        const intro = document.createElement('div');
        intro.textContent = 'A price you cannot pick would be refused at launch:';
        legend.append(intro);
        for (const r of ['no quota', 'needs opt-in', 'no spot market', 'no price']) {
          if (!reasons.has(r)) continue;
          const line = document.createElement('div');
          const b = document.createElement('b');
          b.textContent = r;
          line.append(b, document.createTextNode(' - ' + PICK_WHY[r]));
          legend.append(line);
        }
      }
    }
    const ageEl = $(mount.age);
    if (ageEl) ageEl.textContent = sweepNow && sweepNow.cached && sweepNow.age_seconds != null
      ? `scanned ${ago(sweepNow.age_seconds)}` : '';
  }
  paintBuildPick(rows, cur);
}

// Build shows the one line that matters: what is about to be built, and what it
// costs an hour. Everything it says comes from the same rows the table uses, so
// the two can never disagree.
function paintBuildPick(rows, cur) {
  const el = $('b-pick');
  if (!el) return;
  const hit = rows.find(r => r.region === cur.region && r.type === cur.type);
  const price = hit && (cur.spot ? hit.spot : hit.od);
  const bits = [cur.region, cur.type, cur.spot ? 'spot' : 'on demand'].filter(Boolean);
  if (hit && hit.gpu) bits.push(hit.vram ? `${hit.gpu} ${hit.vram} GB` : hit.gpu);
  if (price != null) bits.push(`INR ${price}/hr`);
  el.textContent = bits.length ? bits.join(' · ') : '—';

  // The warnings belong here too: the only place that shows the choice should
  // also say when the choice cannot launch.
  const warn = [];
  if (boxNow) warn.push('a box is running - it keeps the machine it started on');
  else if (hit && cur.spot && hit.score != null && hit.score <= 2)
    warn.push(`AWS scores spare ${cur.type} capacity here ${hit.score}/10 - a spot launch will `
            + 'very likely be refused');
  else if (hit && cur.spot && hit.fitsSpot === false)
    warn.push('your spot quota here is 0, so this cannot launch on spot');
  else if (!hit && rows.length)
    warn.push('this machine is not offered in this region - change the setup before building');
  $('b-type-note').textContent = warn.join(' · ');
}

let machinesNow = null;
// Just the store now. `cg machines` is still read - it is the only answer for
// the region in force, and the table falls back to it before any sweep - but
// the single <select> it used to fill is gone, replaced by the chooser table.
let machinesAnswered = false;
function paintMachines(d) { machinesNow = d; machinesAnswered = true; paintChooser(); }

// Numbered steps, the way cg reports them: the one running is marked, the ones
// before it carry how long they took. No timer - each event repaints.
let buildStarted = 0;
// How long a run is expected to take, in minutes, so the bar means something.
// Only `init` has a published estimate - the others finish when they finish, and
// a bar invented for them would be a number nobody measured.
const RUN_EXPECT = { init: 20 };
let buildSteps = 0;

// A step is a heading in the transcript, not a row in a second list. Keeping
// both meant two boxes that each grew, which is what stretched the page; the
// log scrolls on its own and loses nothing.
function buildStep(text) {
  const log = $('b-log');
  if (log.dataset.fresh !== 'no') { log.textContent = ''; log.dataset.fresh = 'no'; buildStarted = Date.now(); }
  buildSteps += 1;
  const head = document.createElement('div');
  head.className = 'step flex items-baseline gap-space-sm pt-space-sm first:pt-0';
  const n = document.createElement('span');
  n.className = 'text-outline shrink-0';
  n.textContent = String(buildSteps).padStart(2, '0');
  const label = document.createElement('span');
  label.className = 'text-on-surface';
  label.textContent = text;
  const meta = document.createElement('span');
  meta.className = 'meta ml-auto pl-space-sm text-outline shrink-0';
  head.append(n, label, meta);
  log.append(head);
  $('b-prog-step').textContent = text;
  paintProgress();
  if ($('b-follow').checked) log.scrollTop = log.scrollHeight;
}

// cg times every step; the finished ones carry how long they took, which is the
// only honest answer to "how much longer" on a box that varies.
function buildStepEnd(event) {
  const heads = $('b-log').querySelectorAll('.step');
  const last = heads[heads.length - 1];
  if (!last) return;
  const meta = last.querySelector('.meta');
  const ok = !event.rc;
  meta.textContent = event.secs != null ? `${Math.round(event.secs)}s` : (ok ? 'ok' : `exit ${event.rc}`);
  if (!ok) meta.classList.add('text-error');
  paintProgress();
}

// The bar is TIME against the expected window, not steps completed: cg does not
// announce how many steps a run has, and a fraction invented from the steps seen
// so far would move backwards the moment another one arrived. It stops short of
// full until the run actually ends, so it never claims to be finished.
function paintProgress() {
  const strip = $('b-strip');
  strip.hidden = false;
  const mins = buildStarted ? (Date.now() - buildStarted) / 60000 : 0;
  const expect = RUN_EXPECT[runKind];
  const bar = $('b-prog');
  if (expect) {
    bar.style.width = `${Math.min(95, (mins / expect) * 100).toFixed(1)}%`;
    bar.classList.remove('animate-pulse');
  } else {
    // No estimate: show that something is happening rather than a made-up share.
    bar.style.width = '100%';
    bar.classList.add('animate-pulse');
  }
  const foot = (RUN_FOOT[runKind] || RUN_FOOT.init)[1];
  $('b-strip-meta').textContent =
    [buildSteps ? `step ${String(buildSteps).padStart(2, '0')}` : null,
     buildStarted ? `${Math.floor(mins)}m${foot ? ' ' + foot : ''}` : null].filter(Boolean).join(' · ');
}

function buildProgressDone(rc) {
  if (buildFailures.length) return;   // the strip is showing why it stopped
  const bar = $('b-prog');
  bar.classList.remove('animate-pulse');
  bar.style.width = '100%';
  bar.className = bar.className.replace('bg-primary', rc === 0 ? 'bg-primary' : 'bg-error');
  $('b-prog-step').textContent = rc === 0 ? 'done' : 'stopped';
}

function buildStatus(text, tone) {
  $('b-status').textContent = text;
  $('b-status').className = 'font-code-sm text-code-sm ' + tone;
}

function paintElapsed() {
  if (!buildStarted) return;
  const mins = Math.floor((Date.now() - buildStarted) / 60000);
  const scale = (RUN_FOOT[runKind] || RUN_FOOT.init)[1];
  $('b-elapsed').textContent = `${mins}m elapsed${scale ? ' ' + scale : ''}`;
  paintProgress();
}

// Every line cg marked as a failure, plus whatever `error` event ended the run.
// Kept out of the log on purpose: the log holds 200 lines and auto-scrolls, so by
// the time a run ends the line that said why is usually gone.
let buildFailures = [];
// cg marks only the HEADLINE of a failure report as `fail`; the AWS message and
// the remedy underneath it are ordinary continuation lines. A relayed script
// exits straight after printing one, so once a failure starts, everything until
// the next step belongs to it - which is how the panel gets the whole report
// rather than just its title.
let buildFailing = false;
function buildFail(text) {
  if (!text) return;
  const line = text.replace(/\s+$/, '');
  if (!line && !buildFailures.length) return;
  if (buildFailures[buildFailures.length - 1] === line) return;
  buildFailures.push(line);
  // The title names the phase, not the failure: a fixed "launch failed" above
  // cg's own "launch failed: InsufficientInstanceCapacity" read as the same
  // thing said twice.
  // The strip's own heading carries the state, rather than a second heading
  // under it: "Provisioning" above "Provisioning stopped" was the same words
  // twice, and cg's first line says what failed anyway.
  const title = $('b-strip-title');
  title.textContent = `${RUN_TITLE[runKind] || RUN_TITLE.init} stopped`;
  title.classList.add('text-error');
  title.classList.remove('text-outline');
  $('b-error').textContent = buildFailures.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  $('b-error').classList.remove('hidden');
  // The failure takes the bar's place. A bar frozen at 35% beside the reason it
  // froze is two things saying the same moment, and the useful one is smaller.
  $('b-strip').hidden = false;
  $('b-bar-track').hidden = true;
  $('b-prog-step').hidden = true;
}

function buildFailClear() {
  buildFailures = [];
  buildFailing = false;
  $('b-error').textContent = '';
  $('b-error').classList.add('hidden');
  $('b-bar-track').hidden = false;
  $('b-prog-step').hidden = false;
  $('b-strip-title').classList.remove('text-error');
  $('b-strip-title').classList.add('text-outline');
}

function buildLine(event) {
  const log = $('b-log');
  const row = document.createElement('div');
  row.className = event.kind === 'fail' ? 'text-error'
                : event.kind === 'ok' ? 'text-primary' : 'text-on-surface-variant';
  row.textContent = event.text || '';
  log.append(row);
  // The strip carries the live line, so the one place to look while a step runs
  // is the same place that says which step it is.
  if (event.text && event.kind !== 'fail') $('b-prog-step').textContent = event.text;
  while (log.children.length > 200) log.firstChild.remove();
  if ($('b-follow').checked) log.scrollTop = log.scrollHeight;
  paintElapsed();
}

window.cg.onEvent(({ id, event }) => {
  const job = jobs.get(id);
  if (!job) return;
  logLine(event);
  if (isWrite(job.cmd)) {
    if (event.t === 'step') buildStep(event.text);
    if (event.t === 'step_end') buildStepEnd(event);
    if (event.t === 'line' || (event.t === 'raw' && event.stream === 'stdout')) buildLine(event);
    if (event.kind === 'fail') { buildFailing = true; buildFail(event.text); }
    else if (buildFailing && event.t === 'line') buildFail(event.text);
    if (event.t === 'step') buildFailing = false;
    if (event.t === 'error') buildFail(event.text);
    if (event.t === 'exit') {
      buildStatus(event.rc === 0 ? 'done' : `stopped (exit ${event.rc})`,
                  event.rc === 0 ? 'text-primary' : 'text-error');
      buildProgressDone(event.rc);
      // A nonzero exit with nothing marked is still a failure, and saying so
      // beats a bare status label the eye slides over.
      if (event.rc !== 0 && !buildFailures.length)
        buildFail(`cg ${job.cmd.join(' ')} exited ${event.rc} without saying why - the log above is all there is.`);
    }
  }
  if (event.t === 'ask') ask(id, event);
  // JSON comes back on stdout as the command's own data; reports arrive as events.
  if (event.t === 'raw' && event.stream === 'stdout' && (job.json || job.capture)) job.out.push(event.text);
  if (event.t === 'report' && job.panel) $(job.panel).textContent = event.text;
  if (event.t === 'error' && event.text) job.err = event.text;
  if (job.collect && (event.t === 'line' || event.t === 'step' || event.t === 'error')) {
    const box = $(job.collect);
    if (box.textContent === 'running…') box.textContent = '';
    box.textContent += (event.t === 'step' ? '\n' + event.text : '  ' + (event.text || '')) + '\n';
  }
  if (event.t === 'exit') {
    // Why the reason is kept rather than painted here: updateHeader() runs a few
    // lines below and rewrites job-line, so anything written now is wiped in the
    // same tick. A failing painter was therefore completely silent - the screen
    // stayed empty and the only clue was that nothing ever appeared.
    let failure = null;
    if (job.json && event.rc === 0) {
      try {
        const data = JSON.parse(job.out.join('\n'));
        const paint = { cost: paintCost, library: paintLibrary, guards: paintGuards,
                        config: paintConfig, status: paintStatus, machines: paintMachines,
                        sweep: paintSweep }[job.json];
        if (!paint) throw new Error(`no painter for ${job.json}`);
        paint(data);
      } catch (err) {
        failure = `could not show cg ${job.cmd[0]}: ${err && err.message ? err.message : err}`;
      }
    }
    if (job.age) $(job.age).textContent = new Date().toLocaleTimeString();
    jobs.delete(id);
    updateHeader();
    // A FAILED read used to be silent: note() and the follow-up refresh are
    // behind isWrite, so a read that could not run at all left the screen empty
    // and the header busy with nothing anywhere saying why - which is exactly
    // what a packaged app pointed at the wrong directory looked like. This runs
    // AFTER updateHeader because updateHeader rewrites the same line.
    if (job.json && (event.rc !== 0 || failure)) {
      $('job-line').textContent = failure ? failure
        : job.err ? `cg ${job.cmd[0]} could not run: ${job.err}`
        : `cg ${job.cmd[0]} failed (exit ${event.rc})`;
      $('job-line').className = JOB_LINE_ERR;
    }
    // A build, a destroy or a session changes what every free screen shows -
    // the box, the archive, the guards - so read them again once it is over.
    if (isWrite(job.cmd)) {
      note(`cg ${job.cmd.join(' ')} ${event.rc === 0 ? 'finished' : `failed (exit ${event.rc})`}`,
           event.rc === 0 ? 'text-primary' : 'text-error');
      refreshAll();
    }
    if (job.resolve) job.resolve(job.capture ? job.out.join('\n') : undefined);
  }
});

function runCg(args, { panel, age, json, env, collect, capture } = {}) {
  return new Promise(async resolve => {
    const res = await window.cg.run(args, env);
    if (!res.ok) {
      $('job-line').textContent = `busy: cg ${res.args.join(' ')} must finish first`;
      return resolve();
    }
    jobs.set(res.id, { cmd: args, view, panel, age, json, collect, capture, out: [], resolve });
    if (isWrite(args)) note(`cg ${args.join(' ')} started`, 'text-primary');
    updateHeader();
    if (panel) $(panel).textContent = 'running…';
  });
}

// Refresh means "this screen", and the reads behind it are independent, so
// they run together rather than one after another.
const NEEDS = {
  dashboard: [[['status', '--json'], 'status'], [['watcher', '--json'], 'guards']],
  // machines too: the instance-type row is a picker, and its options are
  // whatever this region rents - see editSetting.
  settings:  [[['config', '--json'], 'config'], [['machines', '--json'], 'machines'],
              [['sweep', '--cached', '--json'], 'sweep']],
  // Build reads status too: if a box is already up there is nothing to build,
  // and its own Refresh must be able to find that out.
  build:     [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status'],
              [['machines', '--json'], 'machines'], [['sweep', '--cached', '--json'], 'sweep']],
  library:   [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status']],
  guards:    [[['watcher', '--json'], 'guards']],
};
const loaded = new Set();

async function refresh() {
  // Cost is not in NEEDS, so opening the tab fetches nothing: it bills.
  if (view === 'cost') return runCg(['cost', '--json'], { json: 'cost' });
  const need = NEEDS[view];
  if (!need) return;               // logs need nothing
  loaded.add(view);
  await Promise.all(need.map(([args, json]) => runCg(args, { json })));
}

// On open, every free read goes at once and each screen paints when its own
// answer lands - they share nothing. cg cost is not among them: it is $0.01 a
// call, so it waits for its button.
const ALL_READS = [
  [['status', '--json'], 'status'],
  [['config', '--json'], 'config'],
  [['watcher', '--json'], 'guards'],
  [['library', 'list', '--json'], 'library'],
  [['machines', '--json'], 'machines'],
  // The REMEMBERED scan, never a fresh one: a scan takes 90 seconds and an
  // opening window must not wait on it. Rescanning is a button.
  [['sweep', '--cached', '--json'], 'sweep'],
];
function refreshAll() {
  for (const v of Object.keys(NEEDS)) loaded.add(v);
  return Promise.all(ALL_READS.map(([args, json]) => runCg(args, { json })));
}

$('refresh').onclick = refresh;
$('check').onclick = () => { $('s-check').hidden = false; $('s-check').textContent = 'running…';
                             runCg(['check'], { collect: 's-check' }); };
// What Stop costs depends on what is running, so say it before doing it.
const STOP_WARNING = {
  init: 'The box may already exist and be billing. If it is, destroy it from the Dashboard - '
      + 'otherwise the cloud watchdog ends it once it has been idle for 30 minutes.',
  destroy: 'The games are being mirrored to S3 right now. Stopping can lose everything installed '
         + 'since the last push, and the box may be left running.',
  open: 'This only ends the streaming session on this laptop. The box keeps running.',
};
function goView(v) {
  const link = document.querySelector(`.nav-item[data-view="${v}"]`);
  if (link && view !== v) link.click();
}
$('goto').onclick = () => {
  const target = $('goto').dataset.view;
  if (target) goView(target);
};
$('cancel').onclick = async () => {
  const mine = jobsHere();
  if (!mine.length) return;
  const names = mine.map(j => 'cg ' + j.cmd.join(' ')).join(', ');
  const ok = await askConfirm({
    title: `Stop ${names}?`,
    body: mine.map(j => STOP_WARNING[j.cmd[0]]).find(Boolean)
       || 'These only read; stopping them changes nothing.',
    yes: 'Stop', danger: true,
  });
  if (!ok) return;
  for (const [id, j] of jobs) if (j.view === view) window.cg.cancel(id);
};
$('d-build').onclick = () => goView('build');
$('d-library').onclick = () => goView('library');
for (const b of document.querySelectorAll('[data-filter]')) {
  b.onclick = () => applyLogFilter(b.dataset.filter);
}
$('log-clear').onclick = () => {
  $('log').textContent = '';
  logCount = 0;
  $('log-count').textContent = '0';
};
$('log-copy').onclick = async () => {
  const text = [...$('log').children].filter(r => !r.hidden)
    .map(r => [...r.children].map(c => c.textContent).join('  ')).join('\n');
  try {
    await navigator.clipboard.writeText(text);
    $('log-count').textContent = 'copied';
  } catch { $('log-count').textContent = 'could not copy'; }
};
// Reading CloudWatch logs is free; it is manual only because it is rarely the
// thing you want, not because it costs anything.
$('log-cloud').onclick = async () => {
  $('log-cloud-out').textContent = 'fetching…';
  const out = await runCg(['watchdog', 'logs'], { capture: true });
  $('log-cloud-out').textContent = (out || '').trim()
    || 'nothing in the last three hours - it writes a line when it decides something';
};
// Both of these delete things in S3 for good. The app asks once, then cg asks
// for the word typed out - CLEAN, FORGET - which the ask dialog renders.
$('lib-clean').onclick = async () => {
  const ok = await askConfirm({
    title: 'Delete the orphaned objects?',
    body: 'These belong to no archived game - a push that never finished. They cannot be '
        + 'restored: with no manifest, Steam cannot see them.\n\n'
        + 'Nothing that is indexed is touched. cg will ask you to type CLEAN.',
    yes: 'Clean', danger: true,
  });
  if (ok) await startRun(['library', 'clean']);
};
// Changing the machine is a `config set` - .env is where cg keeps it, and the
// next build reads it from there. Re-read afterwards rather than assuming the
// write landed: the note and the chip both describe the new choice.
// Picking a price in the chooser sets THREE settings, because it is one
// decision. Region last on purpose: it is the one that invalidates the other
// two - a type that exists in Mumbai may not exist where you came from - so the
// type and model are already correct by the time the region moves to match.
async function chooseMachine(row, spot) {
  const cur = currentPick();
  if (row.region === cur.region && row.type === cur.type && spot === cur.spot) return;
  const price = spot ? row.spot : row.od;
  const moving = row.region !== cur.region;
  const body =
    (row.gpu ? `${row.gpu}${row.vram ? `, ${row.vram} GB VRAM` : ''}. ` : '')
    + (price != null ? `About INR ${price} an hour. ` : '')
    + (spot ? 'Spot is far cheaper, and a region with no spare capacity will refuse to launch it.'
            : 'On demand costs the full rate and launches even when spot has none left.')
    + (row.score != null && row.score <= 2
        ? `\n\nAWS scores spare ${row.type} capacity here ${row.score}/10, so a spot launch will `
          + 'very likely be refused however cheap it looks.' : '')
    + (moving
        ? `\n\nThis MOVES the rig to ${row.region}. Your game library is in S3 in `
          + `${cur.region || 'the old region'} and does not follow: the next build creates a new `
          + 'bucket and reinstalls from Steam. Nothing is deleted or moved by this change, and '
          + 'the old archive keeps costing storage until you delete it.'
        : '')
    + '\n\nThis applies to the next build; a box that is already running is untouched.';
  const ok = await askConfirm({
    title: moving ? `Move to ${row.region} on ${row.type}?`
                  : `Build on ${row.type}, ${spot ? 'spot' : 'on demand'}?`,
    body, yes: moving ? 'Move' : 'Use it', danger: moving,
  });
  if (!ok) { paintChooser(); return; }            // put the old choice back
  // Type and model first, then the region. A half-applied change is possible
  // whatever the order, so the order is chosen to leave the least wrong state:
  // the wrong type in the right region is a refused launch with a clear reason,
  // while the right type in the wrong region silently builds the wrong box.
  await runCg(['config', 'set', 'GAME_INSTANCE_TYPE', row.type]);
  await runCg(['config', 'set', 'GAME_SPOT', spot ? '1' : '0']);
  if (moving) await runCg(['config', 'set', 'GAME_REGION', row.region]);
  // machines is per-region, so a move makes the old answer wrong.
  await Promise.all([runCg(['config', '--json'], { json: 'config' }),
                     runCg(['machines', '--json'], { json: 'machines' }),
                     runCg(['status', '--json'], { json: 'status' })]);
}

// Scanning every region is free but takes about 90 seconds, so it is a button
// and never something a screen does on its own.
async function scanRegions(btn) {
  const was = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'scanning all regions…';
  await runCg(['sweep', '--json'], { json: 'sweep' });
  btn.disabled = false;
  btn.textContent = was;
}
const sweepBtn = $('s-sweep');
if (sweepBtn) sweepBtn.onclick = () => scanRegions(sweepBtn);

// Build's "Change setup". Settings is a long screen and the table is at the
// top of it, so arriving there is not enough - the first instance-type picker
// went unnoticed for exactly this reason. Scroll to it and flash it.
$('b-setup').onclick = () => {
  goView('settings');
  const card = $('s-machine-card');
  if (!card) return;
  card.scrollIntoView({ block: 'center', behavior: 'smooth' });
  // Restarting a running animation needs the class off, a reflow, then on.
  card.classList.remove('flash-attn');
  void card.offsetWidth;
  // The animation says when it is finished, so nothing here runs on a timer.
  card.addEventListener('animationend', () => card.classList.remove('flash-attn'),
                        { once: true });
  card.classList.add('flash-attn');
};

$('d-guards').onclick = () => goView('guards');
$('g-settings').onclick = () => goView('settings');
// The only button on the dashboard that spends money, and it says so.
$('d-cost').onclick = () => runCg(['cost', '--json'], { json: 'cost' });
// A build, a destroy and a session all report the same way - steps, lines, an
// exit - so they all run in the Build screen's panel, and starting one goes
// there. Watching a destroy in a panel that says nothing was the complaint.
const RUN_TITLE = { init: 'Provisioning', destroy: 'Destroying', open: 'Session',
                    library: 'Changing the archive' };
// The footer says what the money is doing, which is not the same for all three.
const RUN_FOOT = {
  init: ['the box bills from the moment it launches', 'of 10-20'],
  destroy: ['the games are pushed to S3 first; billing stops when the box is gone', ''],
  open: ['the box bills while this streams', ''],
  library: ['deleting from S3 stops its storage charge', ''],
};
let runKind = 'init';
function startRun(args) {
  runKind = args[0];
  goView('build');
  $('b-log').dataset.fresh = 'yes';
  $('b-log').textContent = '';
  buildSteps = 0;
  buildStarted = Date.now();
  $('b-prog').className = 'h-full bg-primary rounded-full';
  $('b-prog').style.width = '0%';
  $('b-prog-step').textContent = 'starting…';
  $('b-strip').hidden = false;
  buildFailClear();
  $('b-log-title').textContent = 'cg ' + args.join(' ');
  $('b-strip-title').textContent = RUN_TITLE[args[0]] || 'Running';
  $('b-burn').textContent = (RUN_FOOT[args[0]] || RUN_FOOT.init)[0];
  buildStatus('running', 'text-primary');
  buildStarted = Date.now();
  paintElapsed();
  return runCg(args);
}

const play = () => {
  if (sessionNow) return refresh();   // already streaming: re-check, start nothing
  return startRun(['open']);
};
$('d-open').onclick = play;
$('b-open').onclick = play;
$('b-destroy').onclick = () => $('d-destroy').onclick();
$('d-destroy').onclick = async () => {
  const ok = await askConfirm({
    title: 'Destroy the box?',
    body: (sessionNow ? 'The stream open from this laptop is closed first - cg asks before it does.\n\n' : '')
        + 'Your games are mirrored to S3 first, and the destroy refuses if that fails.\n\n'
        + 'The box and its disk go. Rebuilding takes 10 to 20 minutes.',
    yes: 'Destroy', danger: true,
  });
  if (ok) await startRun(['destroy']);
};
$('b-build').onclick = async () => {
  const apps = picked.size ? [...picked].join(',') : 'none';
  const gb = selectedGb();
  const ok = await askConfirm({
    title: 'Build the box?',
    body: `${picked.size ? `${picked.size} game(s), ${gb.toFixed(1)} GB` : 'Nothing'} will be restored `
        + 'from S3 while it builds.\n\nThis starts billing by the hour, and takes 10 to 20 '
        + 'minutes. The Cost tab shows the rate you are actually paying.',
    yes: 'Build box',
  });
  if (!ok) return;
  goView('build');
  $('b-log').dataset.fresh = 'yes';
  $('b-log').textContent = '';
  buildSteps = 0;
  buildStarted = Date.now();
  $('b-prog').className = 'h-full bg-primary rounded-full';
  $('b-prog').style.width = '0%';
  $('b-prog-step').textContent = 'starting…';
  $('b-strip').hidden = false;
  buildFailClear();
  $('b-log-title').textContent = 'cg init';
  $('b-strip-title').textContent = RUN_TITLE.init;
  $('b-burn').textContent = RUN_FOOT.init[0];
  runKind = 'init';
  buildStatus('running', 'text-primary');
  buildStarted = Date.now();
  await runCg(['init'], { env: { GAME_APPS: apps } });
};

for (const link of document.querySelectorAll('.nav-item')) {
  link.onclick = e => {
    e.preventDefault();
    document.querySelectorAll('.nav-item').forEach(n => n.classList.toggle('on', n === link));
    $('view-title').textContent = link.textContent.trim();
    view = link.dataset.view;
    for (const sec of document.querySelectorAll('main section[data-view]'))
      sec.hidden = sec.dataset.view !== view;
    updateHeader();
    // Reads run in parallel, so an open tab loads even while others are in flight.
    if (NEEDS[view] && !loaded.has(view)) refresh();
  };
}
refreshAll();
