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
const LONG_LIBRARY = new Set(['push', 'pull', 'clean']);
const watchable = cmd => WATCHABLE.has(cmd[0]) || (cmd[0] === 'library' && LONG_LIBRARY.has(cmd[1]));
const jobsHere = () => [...jobs.values()].filter(j => j.view === view);

// A screen's button answers for that screen. The one real dependency is that a
// build or a destroy runs alone - cg refuses anything else while one is in
// flight - so those disable the rest. Reads never block each other.
//
// WHICH commands those are is not written down here any more. It used to be,
// in two places - this file and the main process - and the two disagreed three
// times, silently, because a command that is never started looks exactly like
// one that returned nothing. cg publishes the rule (cg --contract), the main
// process applies it, and the answer comes back with the job as job.write.
const writing = () => [...jobs.values()].some(j => j.write);
const runningHere = cmd => jobsHere().some(j => j.cmd[0] === cmd);
const jobsFor = cmd => [...jobs.values()].some(j => j.cmd[0] === cmd);

// job-line carries both the running list and a failure, so its colour has to be
// set back as well as its text - otherwise one failed read left every later
// "idle" painted as an error.
const JOB_LINE_OK  = 'font-code-sm text-code-sm text-on-surface-variant';
const JOB_LINE_ERR = 'font-code-sm text-code-sm text-error';

// Why these are kept rather than painted where they happen: job-line is shared
// with the running list, and updateHeader() rewrites it every time ANY job
// starts or ends. A failure written directly was erased by the next read.
// Keyed by the read, so a later success for the same read clears it.
const readFailures = new Map();

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

  if (jobs.size) {
    $('job-line').textContent = `running: ${names.map(n => 'cg ' + n).join(', ')}`;
    $('job-line').className = JOB_LINE_OK;
  } else if (readFailures.size) {
    $('job-line').textContent = [...readFailures.values()].join(' · ');
    $('job-line').className = JOB_LINE_ERR;
  } else {
    $('job-line').textContent = 'idle';
    $('job-line').className = JOB_LINE_OK;
  }
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
  const box = $('ask-choices');
  // cg states the answers it accepts. When it does, this is a CHOICE, and a
  // free-text field is the wrong control for one: the build sat on a dialog
  // reading "choice [1]:" with no sign of what the choices were, because the
  // options cg had printed went to the log pane behind the modal.
  const choices = (event.choices || '').split(',').map(c => c.trim()).filter(Boolean);
  box.textContent = '';
  box.hidden = choices.length === 0;
  input.hidden = choices.length > 0;
  if (choices.length) {
    // Radios, not a <select>: two or three options are worth showing at once,
    // and the default has to be visibly the default.
    for (const c of choices) {
      const row = document.createElement('label');
      row.className = 'row font-code-md text-code-md cursor-pointer';
      const r = document.createElement('input');
      r.type = 'radio'; r.name = 'ask-choice'; r.value = c;
      r.checked = c === (event.default || choices[0]);
      const txt = document.createElement('span');
      txt.textContent = ASK_CHOICE_LABEL[`${event.id}:${c}`] || c;
      row.append(r, txt);
      box.append(row);
    }
  } else {
    input.value = event.default || '';
    input.type = event.secret ? 'password' : 'text';
  }
  $('ask').showModal();
  if (choices.length) box.querySelector('input:checked')?.focus(); else input.focus();
  $('ask').onclose = () => {
    const picked = choices.length
      ? (box.querySelector('input:checked')?.value ?? event.default ?? '')
      : input.value;
    window.cg.answer(id, picked);
  };
}

// A bare "1" or "2" in a dialog says nothing. cg prints the meaning to the log,
// which is behind the modal, so the words are repeated here for the prompts
// where the answer is a number. Anything not listed falls back to the raw
// value, so a new prompt is terse rather than broken.
// Keyed <ask id>:<answer>. Distinct from CHOICE_LABEL further down, which maps
// a SETTING to labels for its values - same idea, different shape, and sharing
// one name for both silently shadowed the other.
// The ask ids this window knows by name: the ones it answers from a dialog it
// has already shown, and the one whose answers it spells out below. cg owns
// these ids; they are written here only to be matched, and checkAsks() holds
// the two lists against each other at startup so a rename in cg is loud.
const ASK = {
  awsId:      'aws-access-key-id',
  awsSecret:  'aws-secret-access-key',
  tsToken:    'tailscale-api-token',
  tsAuthKey:  'tailscale-auth-key',
  sessionEnd: 'session-end',
};
const ASK_CHOICE_LABEL = {
  [`${ASK.sessionEnd}:d`]: 'destroy the box (recommended - the games are mirrored to S3)',
  [`${ASK.sessionEnd}:n`]: 'leave it running (it keeps billing by the hour)',
};
// Any id the window pre-answers but cg no longer asks under is a modal waiting
// to appear in the middle of a build - which is exactly what this replaced.
async function checkAsks() {
  let asks;
  try { asks = await window.cg.asks(); } catch { return; }
  if (!Array.isArray(asks) || !asks.length) return;   // cg could not be asked
  const gone = Object.values(ASK).filter(id => !asks.includes(id));
  if (gone.length) {
    console.error('cg no longer asks under: ' + gone.join(', ')
                  + ' - a dialog here will not be used to answer it');
    note(`This app expects cg to ask for ${gone.join(', ')}, and it does not. `
         + 'The app and cg are different versions.', 'text-error');
  }
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
  paintBanner();
  if (credErr) {
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
  // Guarded, even though cg now always sends it: this line threw for every
  // machine whose node was absent and took the whole status paint down with it
  // - the box, the archive, the guards, all of it blank. One missing field
  // should cost one field. The fix for the field itself is in lib/setup.
  const tn = s.tailnet || {};
  $('box-node').textContent = tn.node
    ? `${tn.node} · ${tn.online ? 'online' : 'offline'}` : 'no node';

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
  // cg projects the month - it has the billed window and the day count. The
  // window renders that number; it does not work out one of its own.
  $('d-projected').textContent = m.projected_inr != null
    ? `projected ${INR(m.projected_inr)} this month`
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
  const projected = m.projected_usd ?? null;
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
  paintLogin(d.login);
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
  // How much a box offers is cg's number. When the read could not say,
  // the screen says it could not - a plausible-looking 209 GB is a wrong
  // answer that reads like a right one.
  const cap = d.selectable_gb || null;
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

  if (cap == null) {
    $('lib-fit-num').textContent = '—';
    $('lib-bar').style.width = '0%';
    $('lib-fit-chip').hidden = true;
    $('lib-fit').textContent =
      `${gb.toFixed(1)} GB archived - how much a box offers is not known yet`;
    return;
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

// The archived Steam login. Three states, and the third is the one that matters:
// null is "could not look", which must never be painted as "none archived" -
// that would invite someone to rebuild expecting a fresh login prompt and get
// a box signed in as an account they thought they had deleted.
// What the build will do about Steam. The machine is half of what a build
// decides; the other half is whether it comes up already signed in, and as
// whom - which lives in two places (the archive, and GAME_STEAM_LOGIN) and was
// visible on neither of the screens where a build is started.
let loginNow = null;
function paintBuildLogin() {
  const line = $('b-login'), note = $('b-login-note');
  if (!line) return;
  const choice = (config || []).find(r => r.key === 'GAME_STEAM_LOGIN');
  const fresh = choice && (choice.value || choice.default) === 'fresh';
  if (loginNow === null) {
    line.textContent = 'reading…';
    note.textContent = '';
    return;
  }
  if (fresh) {
    line.textContent = 'sign in on the box';
    note.textContent = loginNow.present
      ? 'the archived login is kept, and not used - Settings > Steam sign-in'
      : 'nothing is archived to restore - Settings > Steam sign-in';
    return;
  }
  if (!loginNow.present) {
    line.textContent = 'sign in on the box';
    note.textContent = 'no login is archived yet; one is saved when a box shuts down';
    return;
  }
  // Which account, when the archive says: a key that signs in as someone you
  // did not expect is the thing worth catching before a build, not after it.
  const who = (loginNow.accounts || []).find(a => a.most_recent) || (loginNow.accounts || [])[0];
  line.textContent = who ? `signed in as ${who.account || who.steamid}` : 'signed in from the archive';
  note.textContent = loginNow.accounts === null
    ? 'restored from the archive - the account names could not be read'
    : 'restored from the archive, so Steam does not ask';
}

function paintLogin(l) {
  loginNow = l === undefined ? null : l;
  paintBuildLogin();
  const head = $('lib-login-head'), sub = $('lib-login-sub');
  const accts = $('lib-login-accounts'), btn = $('lib-login-forget');
  if (!head) return;
  accts.textContent = '';
  if (!l) {
    head.textContent = 'Steam login';
    sub.textContent = 'could not read it - this says nothing about whether one is archived';
    btn.hidden = true;
    return;
  }
  if (!l.present) {
    head.textContent = 'No Steam login archived';
    sub.textContent = 'A new box will ask you to sign in. One is pushed automatically when a box shuts down.';
    btn.hidden = true;
    return;
  }
  head.textContent = 'Steam login archived';
  const kb = (l.bytes || 0) / 1024;
  // The cost is stated and then dismissed on purpose: it is the reason NOT to
  // treat Forget as a saving.
  sub.textContent = `${kb.toFixed(1)} KB${l.modified ? `, pushed ${daysAgo(l.modified)}` : ''}`
    + ' - a new box comes up already signed in. Deleting it saves nothing; it changes which account a new box uses.';
  const rows = l.accounts;
  if (rows === null || rows === undefined) {
    accts.textContent = 'the account names could not be read from the archive';
  } else {
    for (const r of rows) {
      const line = document.createElement('div');
      const who = r.account || r.persona || r.steamid || '?';
      line.textContent = r.most_recent
        ? `${who} - a new box signs in as this one`
        : who;
      if (r.most_recent) line.className = 'text-on-surface-variant';
      accts.append(line);
    }
    if (rows.length > 1) {
      const note = document.createElement('div');
      note.className = 'text-tertiary mt-space-xs';
      note.textContent = `${rows.length} accounts are archived together. The tarball restores whole, `
        + 'so a new box gets all of them. To keep one: sign in as it on the box, then push.';
      accts.append(note);
    }
  }
  btn.hidden = false;
  btn.onclick = () => forgetLogin(l);
}

async function forgetLogin(l) {
  const rows = l.accounts || [];
  const who = rows.length ? rows.map(r => r.account || r.steamid || '?').join(', ') : 'the archived account';
  const ok = await askConfirm({
    title: 'Forget the archived Steam login?',
    body: `This deletes the archived login for ${who}. No undo, no versioning.\n\n`
        + 'Your games are NOT affected - they are a separate archive. What you lose is '
        + 'the signed-in state: the next box will ask for your password and Steam Guard code.\n\n'
        + 'It is 22 KB, so this saves no money. Do it to change which account a new box '
        + 'uses. cg will ask you to type FORGET.',
    yes: 'Forget', danger: true,
  });
  if (ok) await startRun(['library', 'account', 'forget']);
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
    n.textContent = label(r);
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
// A setting's name is cg's to give: `cg config --json` carries `label` and
// `group`. This file kept its own table of both, so a setting cg grew appeared
// in the window as a raw GAME_SHOUTING_KEY until someone added it here too.
const label = r => r.label || r.key;

// --- Dependencies -----------------------------------------------------------
// The tools cg needs on this laptop. It exists because a new laptop reports
// UNKNOWN everywhere and the reason is six lines down in a preflight report:
// the AWS CLI is not installed, so nothing can be read, so every screen says
// nothing. This page says which tool, what it is for, and installs it.
let depsNow = null, credsNow = null, tskeyNow = null;
function paintDeps(d) {
  depsNow = d;
  paintKeys();
  paintBanner();
  const tools = d.tools || [];
  const missing = tools.filter(x => !x.present);
  const signedOut = d.tailscale_signed_in === false;

  const ready = $('d-ready');
  if (!missing.length && !signedOut) {
    ready.className = 'pill pill-ok';
    ready.textContent = 'everything cg needs is here';
  } else {
    ready.className = 'pill pill-bad';
    ready.textContent = missing.length
      ? `${missing.length} of ${tools.length} missing`
      : 'Tailscale is not signed in';
  }
  $('d-pm').textContent = d.package_manager
    ? `installs with ${d.package_manager}`
    : 'no supported package manager - these go in by hand';

  // Say whether an Install button can do anything BEFORE it is pressed.
  $('d-root').textContent = d.root === 'sudo'
    ? 'installing uses sudo in this terminal'
    : d.root === 'pkexec'
    ? 'installing asks for your password in a desktop dialog (polkit)'
    : `installing is not possible from here: ${d.root_blocked || 'no way to become root'}`;

  const canInstall = Boolean(d.package_manager && d.root);
  $('d-install-all').hidden = !missing.length || !canInstall;
  $('d-install-all-label').textContent = `Install ${missing.length} missing`;

  const table = $('d-rows');
  table.textContent = '';
  const head = table.insertRow();
  for (const h of ['TOOL', 'WHAT IT IS FOR', 'STATE', '']) {
    const th = document.createElement('th');
    th.textContent = h;
    head.append(th);
  }
  for (const x of tools) {
    const tr = table.insertRow();
    tr.className = 'group';
    tr.insertCell().textContent = x.label;
    const why = tr.insertCell();
    why.className = 'city whitespace-normal';
    why.textContent = x.why || '';
    const st = tr.insertCell();
    st.textContent = x.present ? 'installed' : 'missing';
    st.className = x.present ? 'city' : 'text-error';
    const act = tr.insertCell();
    if (!x.present) {
      if (canInstall) {
        const b = document.createElement('button');
        b.className = 'btn';
        b.textContent = 'Install';
        b.onclick = () => installDeps([x.tool]);
        act.append(b);
      } else {
        // Nothing can be pressed, so hand over the command instead.
        act.className = 'city whitespace-normal';
        act.textContent = x.manual || '';
      }
    }
  }
}

// The two things no package manager can install. Each row says where it stands
// and sends you to the one place it is set - the same rule as the machine
// chooser, which shows region and instance type here and lets you change them
// in exactly one place.
const signedAs = () =>
  (tskeyNow && tskeyNow.node) ? `signed in as ${tskeyNow.node}` : 'signed in';

function paintKeys() {
  const wrap = $('d-keys');
  if (!wrap) return;
  const c = credsNow;
  const rows = [
    { name: 'AWS access key',
      why: 'every call to AWS; without it nothing can be read',
      // null until the read lands: "not set" would be a guess, and a wrong one
      // on a laptop where the key is fine.
      state: !c ? ['reading…', 'wait']
        : !c.cli ? ['the AWS CLI is not installed', 'bad']
        : c.valid ? [`${c.key_id || 'a key'} works`, 'ok']
        : c.key_id ? [`${c.key_id} was rejected`, 'bad']
        : ['not set', 'bad'],
      to: () => goSetting($('s-creds-card')) },
    // One row per card in Settings, and no row without somewhere to go. The
    // sign-in used to have a row of its own here, saying "in a terminal: sudo
    // tailscale up" with no button - a dead end next to two rows that lead
    // somewhere, and the Tailscale card says the same thing with the token
    // beside it.
    { name: 'Tailscale',
      why: 'the private network the box joins; there is no public SSH port',
      // The sign-in comes first when it is missing: a token cannot help a
      // laptop that is not on the tailnet.
      state: !depsNow || !tskeyNow ? ['reading…', 'wait']
        : depsNow.tailscale_signed_in === false
          ? [depsNow.root ? 'not signed in - Settings has a Sign in button'
                          : 'not signed in - in a terminal:  sudo tailscale up', 'bad']
        : depsNow.tailscale_signed_in === null ? ['not installed', 'bad']
        // Signed in: then the token is what is left to say, and it is CHECKED,
        // not counted - .env cannot tell a good token from a refused one.
        : !tskeyNow.present
          ? [`${signedAs()} · no API token, cg goes without`, 'warn']
        : tskeyNow.valid
          ? [`${signedAs()} · API token works`, 'ok']
        : tskeyNow.valid === false
          ? [`${signedAs()} · API token rejected${tskeyNow.detail ? ' (' + tskeyNow.detail + ')' : ''}`, 'bad']
          : [`${signedAs()} · API token set, api.tailscale.com did not answer`, 'warn'],
      to: () => goSetting($('s-tskey-card')) },
  ];
  wrap.textContent = '';
  for (const r of rows) {
    const row = document.createElement('div');
    row.className = 'row border-b border-surface-variant/40 items-start';
    row.dataset.key = r.name;
    const left = document.createElement('div');
    left.className = 'min-w-0 flex-1';
    const n = document.createElement('p');
    n.className = 'font-code-md text-code-md';
    n.textContent = r.name;
    const why = document.createElement('p');
    why.className = 'font-code-sm text-code-sm text-outline mt-0.5';
    why.textContent = r.why;
    left.append(n, why);
    const right = document.createElement('div');
    right.className = 'flex items-center gap-space-sm shrink-0';
    const [text, tone] = r.state;
    const val = document.createElement('span');
    val.className = 'font-code-sm text-code-sm text-right max-w-[18rem] break-words '
      + (tone === 'ok' ? 'text-on-surface-variant' : tone === 'bad' ? 'text-error' : 'text-outline');
    val.textContent = text;
    right.append(val);
    if (r.to) {
      const b = document.createElement('button');
      b.className = 'btn';
      b.textContent = 'Set in Settings';
      b.onclick = r.to;
      right.append(b);
    }
    row.append(left, right);
    wrap.append(row);
  }
}

function installDeps(tools) {
  const what = tools.length === 1 ? tools[0] : 'what is missing';
  return runInDialog({
    title: `Installing ${what}`,
    args: ['deps', 'install', ...tools],
    starting: 'asking for your password first (the dialog can appear behind this window)',
    done: 'installed',
    fail: rc => `the install did not finish (exit ${rc})`,
  });
}
$('d-install-all').onclick = () => installDeps([]);

// The AWS access key: three states, and the third is why this card exists at
// all. No CLI is not a rejected key, and a rejected key is not an absent one -
// a new laptop hits the first and used to be told the second.
function paintCreds(c) {
  credsNow = c;
  paintKeys();
  paintBanner();
  const state = $('creds-state'), detail = $('creds-detail'), btn = $('creds-set');
  btn.hidden = false;
  if (!c.cli) {
    state.textContent = 'the AWS CLI is not installed';
    state.className = 'font-code-md text-code-md text-error mt-space-sm';
    detail.textContent = 'Nothing can be read from AWS until it is. The Dependencies page '
      + 'installs it; then this card can take a key.';
    btn.textContent = 'Open Dependencies';
    btn.onclick = () => goView('deps');
    return;
  }
  btn.textContent = 'Set access key';
  btn.onclick = setCreds;
  if (c.valid) {
    state.textContent = `${c.key_id || 'a key'} works`;
    state.className = 'font-code-md text-code-md text-on-surface mt-space-sm';
    // The account is the thing worth seeing on a new laptop: a key that works
    // for the WRONG account reads as "fine" everywhere else in the app.
    detail.textContent = [c.account && `account ${c.account}`, c.arn, c.source && `from ${c.source}`]
      .filter(Boolean).join('  \u00b7  ');
    return;
  }
  state.textContent = c.key_id ? `${c.key_id} was rejected` : 'no access key is configured';
  state.className = 'font-code-md text-code-md text-error mt-space-sm';
  detail.textContent = c.error || 'AWS would not accept it.';
}

// cg asks for the two halves of the key as events; the dialog answers them, and
// the secret one renders as a password field. Nothing is typed into the app's
// own storage - cg writes ~/.aws/credentials.
// The Tailscale card. Two facts, and they fail independently: this laptop can
// be signed in with no API token (normal, and cg says what it gives up), or
// hold a token while being signed out (nothing works, and no token helps).
function paintTskey(ts) {
  tskeyNow = ts;
  paintKeys();
  paintBanner();
  const state = $('tskey-state'), detail = $('tskey-detail'), btn = $('tskey-set');
  const canRootNow = Boolean(depsNow && depsNow.root);
  const signed = ts.signed_in === true ? `signed in${ts.node ? ' as ' + ts.node : ''}`
    : ts.signed_in === false
      ? (canRootNow ? 'not signed in' : 'not signed in - in a terminal:  sudo tailscale up')
    : 'Tailscale is not installed';
  const token =
      !ts.present      ? 'no API token - dead nodes are left in place, key expiry stays on'
    : ts.valid         ? 'API token works'
    : ts.valid === false ? `API token rejected${ts.detail ? ' (' + ts.detail + ')' : ''}`
    // Unreachable says nothing about the token, so it must not be drawn as a
    // bad one: the fix for a flat network is not a new token.
    : 'API token set, but api.tailscale.com did not answer';
  state.textContent = signed;
  state.className = 'font-code-md text-code-md mt-space-sm '
    + (ts.signed_in === true ? 'text-on-surface' : 'text-error');
  detail.textContent = token;
  // The box's own key. It is not the token and cannot be: `tailscale up` takes
  // a node registration key, and the token has no business in EC2 user-data.
  // With a token here, nobody has to paste one.
  $('tskey-auth').textContent =
      ts.auth_key_stored && ts.can_mint
        ? "the box's auth key is stored, and checked before each build"
    : ts.auth_key_stored ? "the box's auth key is stored in .env"
    : ts.can_mint        ? "the box's auth key is minted from this token at the next build"
    : 'no auth key for the box - the next build will ask for one';
  btn.textContent = ts.present ? 'Replace API token' : 'Set API token';
  btn.onclick = openTskey;
  // Pasting the box's key is for when the token cannot make one: no token, or
  // a tailnet whose ACLs will not issue an untagged key. With a working token
  // there is nothing to type, so there is no button.
  const authBtn = $('tskey-authkey');
  authBtn.hidden = ts.can_mint && !ts.auth_key_stored;
  authBtn.textContent = ts.auth_key_stored ? 'Replace auth key' : 'Set auth key';
  authBtn.onclick = setAuthKey;
  // Signing in is root's business - systemctl, then `tailscale up` - which in a
  // window means polkit. Where polkit cannot be reached the card says what to
  // type instead of offering a button that dies inside sudo.
  $('tskey-signin-go').hidden = ts.signed_in !== false || !canRootNow;
}

// `tailscale up` prints a login URL and then WAITS for someone to visit it, so
// the URL has to reach the person while the command is still running - the one
// place in this app where output during a run is the point, not a log.
// The sign-in, as a dialog, because it is a thing that happens rather than a
// state to read: polkit asks for a password, `tailscale up` prints a link and
// then WAITS for someone to visit it, and none of that is over until it is.
let runDlgJob = null, runDlgRetry = null;
function runDlgStatus(text, tone) {
  const el = $('rundlg-status');
  el.textContent = text;
  el.className = 'font-code-sm text-code-sm mt-0.5 mb-space-md '
    + (tone === 'bad' ? 'text-error' : tone === 'ok' ? 'text-on-surface' : 'text-outline');
}

// runInDialog({...}) - run a cg command in front of the person.
//   title    what is happening, in two or three words
//   args     the cg command
//   starting the first status line, before cg has said anything
//   done     the status when it succeeds (a string, or a function for one that
//            has to be read off the state the run just changed)
//   fail     the status when it does not, given the exit code
async function runInDialog({ title, args, starting, done, fail }) {
  const log = $('rundlg-log'), link = $('rundlg-link');
  runDlgRetry = () => runInDialog({ title, args, starting, done, fail });
  $('rundlg-title').textContent = title;
  link.hidden = true;
  $('rundlg-done').hidden = true;
  $('rundlg-done').textContent = 'Done';
  $('rundlg-retry').hidden = true;
  $('rundlg-cancel').hidden = false;
  log.textContent = '';
  // The first line cg sends replaces the placeholder rather than appending
  // under it - see the collect handler.
  log.dataset.fresh = 'yes';
  runDlgStatus(starting);
  if (!$('rundlg').open) $('rundlg').showModal();
  const { rc } = await runCg(args, { collect: 'rundlg-log', wantRc: true,
                                     onStart: id => { runDlgJob = id; } });
  runDlgJob = null;
  link.hidden = true;
  $('rundlg-cancel').hidden = true;
  if (rc === 0) {
    // Everything behind the dialog has already re-read: these are writes.
    runDlgStatus(typeof done === 'function' ? done() : done, 'ok');
    $('rundlg-done').hidden = false;
    $('rundlg-done').focus();
    return true;
  }
  runDlgStatus(rc === null ? 'could not start - something else is running'
                           : (typeof fail === 'function' ? fail(rc) : fail), 'bad');
  $('rundlg-retry').hidden = false;
  $('rundlg-done').hidden = false;
  $('rundlg-done').textContent = 'Close';
  return false;
}
$('rundlg-done').onclick = e => { e.preventDefault(); $('rundlg').close(); };
$('rundlg-retry').onclick = e => { e.preventDefault(); if (runDlgRetry) runDlgRetry(); };
// Cancelling has to reach cg: `tailscale up` is waiting on a browser that is
// never going to answer, and a package manager can be sitting on a lock.
// Closing a dialog does not tell either of them that.
$('rundlg-cancel').onclick = e => {
  e.preventDefault();
  if (runDlgJob !== null) window.cg.cancel(runDlgJob);
  runDlgJob = null;
  $('rundlg').close();
};
function signInTailscale() {
  return runInDialog({
    title: 'Signing in to Tailscale',
    args: ['creds', 'tailscale', 'signin'],
    starting: 'starting - a password dialog opens first (it can appear behind this window)',
    done: () => (tskeyNow && tskeyNow.node) ? `signed in as ${tskeyNow.node}` : 'signed in',
    fail: rc => `sign-in did not finish (exit ${rc})`,
  });
}
$('tskey-signin-go').onclick = signInTailscale;

// The link, lifted out of whatever cg relayed. Only this host, and the main
// process checks it again before anything opens.
const SIGNIN_RE = /https:\/\/login\.tailscale\.com\/[^\s]+/;
function watchForSignInLink(text) {
  const m = SIGNIN_RE.exec(text || '');
  if (!m) return;
  const link = $('rundlg-link');
  link.hidden = false;
  link.onclick = () => window.cg.openSignIn(m[0]);
  // What is being waited for, in words: the command is not stuck, it is
  // waiting for a browser - and that distinction is the whole dialog.
  runDlgStatus('waiting for you to finish in the browser');
}

// Same shape as the AWS form, for the same reasons: one field, one Save, the
// answer checked before it is believed, and the failure shown here.
// Asking AWS for quota, as four states of one dialog.
//
// The ask is mechanical and free; what gets it approved is the appeal on the
// case it opens, which is a letter to a person - so this drafts it and sending
// it is yours. The Support API could not post it anyway without a Business
// plan.
//
// AWS has five words for where a request stands and they mean quite different
// things. DENIED in particular is not the end: every quota this account holds
// was granted on appeal rather than on the first ask.
const QUOTA_STATE = {
  PENDING: ['filed, not yet routed',
            'AWS has it. The case appears within a minute or two - Refresh to look again.'],
  CASE_OPENED: ['case open',
            'A case exists. Usually this will get refused; reply to it with the appeal below '
          + 'and a human reviews it, which takes two to four days. This line does not change '
          + 'when you reply - the refusal and your appeal live on the case, and only AWS\u2019s '
          + 'decision moves the request.'],
  DENIED: ['refused - this is normal, and not the end',
            'Every quota this rig has was granted on appeal, not on the first ask. Reply on the '
          + 'case with the text below: it is the detailed use case they asked for.'],
  CASE_CLOSED: ['case closed',
            'Closed without the quota being raised. A closed case cannot be appealed - create a '
          + 'new request and appeal that one.'],
  APPROVED: ['granted',
            'It can take up to an hour to appear as the applied value. Refresh to check.'],
};
const QUOTA_LABEL = { ondemand: 'on demand', spot: 'spot' };
let quotaNow = null, quotaKind = '', quotaAppeal = '', quotaCase = null, quotaWhere = '';

const quotaCaseUrl = id => `https://console.aws.amazon.com/support/home#/case/?displayId=${id}`;

function quotaClear() {
  $('quota-state').textContent = '';
  $('quota-explain').textContent = '';
  $('quota-pre-label').hidden = true;
  $('quota-pre-label').textContent = '';
  $('quota-log').textContent = '';
  $('quota-case-row').hidden = true;
  $('quota-case-url').textContent = '';
  $('quota-copy').textContent = 'Copy the appeal';
  quotaAppeal = '';
  quotaCase = null;
}

// Reading, and saying so: the controls are dead while it reads, because a
// second Refresh on top of the first answers the first one's question.
function quotaBusy(on) {
  $('quota-where').disabled = on;
  $('quota-kind').disabled = on;
  $('quota-refresh').disabled = on;
  $('quota-go').disabled = on || $('quota-go').disabled;
  $('quota-refresh').textContent = on ? 'Reading\u2026' : 'Refresh';
}

function quotaSay(state, explain, tone) {
  $('quota-state').textContent = state;
  $('quota-state').className = 'font-code-md text-code-md mt-space-md '
    + (tone === 'bad' ? 'text-error' : tone === 'ok' ? 'text-on-surface' : 'text-on-surface-variant');
  $('quota-explain').textContent = explain || '';
}

// One read answers everything the dialog shows: the applied value, whether it
// covers a box, and where the last request stands.
const quotaCmd = (...rest) => (quotaWhere ? ['--region', quotaWhere, ...rest] : rest);

async function quotaRead() {
  const out = await runCg(quotaCmd('quota', '--json'), { capture: true });
  try { quotaNow = JSON.parse(out); } catch { quotaNow = null; }
  $('quota-region').textContent = quotaNow ? quotaNow.region : '';
  return quotaNow;
}

async function quotaRender() {
  const kind = quotaKind;
  $('quota-case-row').hidden = true;
  $('quota-pre-label').hidden = true;
  $('quota-log').textContent = '';
  $('quota-refresh').hidden = !kind;
  $('quota-refresh').disabled = false;
  $('quota-kind').disabled = false;
  $('quota-where').disabled = false;
  $('quota-go').hidden = false;
  $('quota-go').disabled = true;
  $('quota-go').textContent = 'Confirm \u00b7 create case';
  if (!kind) {
    quotaSay('', 'Pick one to see what it would ask for.');
    return;
  }
  const q = (quotaNow || {})[kind];
  if (!q) { quotaSay('could not read this quota', 'cg quota says more.', 'bad'); return; }
  const need = quotaNow.vcpus_needed, type = quotaNow.instance_type;

  // Nothing to ask for. Offering the button here gets a duplicate refused.
  if (q.enough) {
    quotaSay(`${q.value} vCPU already covers one ${type}`, 'Nothing to ask for.', 'ok');
    $('quota-go').hidden = true;
    return;
  }

  const r = q.request;
  if (r && r.status && r.status !== 'APPROVED') {
    const [head, why] = QUOTA_STATE[r.status] || [r.status.toLowerCase().replace(/_/g, ' '), ''];
    const when = (r.created || '').slice(0, 10);
    const moved = (r.last_updated || '').slice(0, 10);
    quotaSay(`\u25cf ${head}${when ? ' \u00b7 asked ' + when : ''}${r.desired ? ' \u00b7 ' + r.desired + ' vCPU' : ''}`
             + (moved && moved !== when ? ` \u00b7 AWS last moved it ${moved}` : ''),
             why, r.status === 'DENIED' || r.status === 'CASE_CLOSED' ? 'bad' : '');
    quotaCase = r.case_id || null;
    $('quota-case-row').hidden = false;
    $('quota-case').hidden = !quotaCase;
    $('quota-case-url').textContent = quotaCase ? quotaCaseUrl(quotaCase) : 'the case id has not appeared yet - Refresh';
    // A closed case cannot be appealed, so asking again is the only way on.
    $('quota-go').hidden = r.status !== 'CASE_CLOSED';
    $('quota-go').disabled = r.status !== 'CASE_CLOSED';
    if (r.status === 'CASE_CLOSED') $('quota-go').textContent = 'Confirm \u00b7 ask again';
    const appeal = await runCg(quotaCmd('quota', 'appeal', kind), { capture: true });
    quotaAppeal = (appeal || '').trim();
    $('quota-copy').hidden = !quotaAppeal;
    if (quotaAppeal) {
      $('quota-pre-label').hidden = false;
      $('quota-pre-label').textContent = 'Paste this as a reply on that case as an appeal when denied:';
      $('quota-log').textContent = quotaAppeal;
    }
    return;
  }

  // Nothing asked for yet: say exactly what the case would contain.
  quotaSay(`You have ${q.value === null ? 'an unknown number of' : q.value} vCPU. One ${type} needs ${need}.`, '');
  $('quota-pre-label').hidden = false;
  $('quota-pre-label').textContent = 'This creates a support case containing:';
  $('quota-log').textContent =
      `Service:    EC2 Instances\n`
    + `Region:     ${quotaNow.region}\n`
    + `Quota:      ${kind === 'spot' ? 'All G and VT Spot Instance Requests' : 'Running On-Demand G and VT instances'} (${q.code})\n`
    + `New value:  ${need}   (exactly one instance - never more)\n\n`
    + `Free. AWS usually refuses within minutes - that is step one, and the\n`
    + `appeal on the case it opens is what gets approved.`;
  $('quota-go').disabled = false;
}

function quotaWhereOptions(selected) {
  const sel = $('quota-where');
  const cfg = (config || []).find(r => r.key === 'GAME_REGION');
  const current = (cfg && (cfg.value || cfg.default)) || (machinesNow && machinesNow.region) || '';
  const seen = new Set();
  sel.textContent = '';
  const add = (code, label) => {
    if (!code || seen.has(code)) return;
    seen.add(code);
    const o = document.createElement('option');
    o.value = code;
    o.textContent = label || code;
    sel.append(o);
  };
  add(current, current ? `${current} (cg is set to this one)` : '');
  for (const r of (sweepNow && sweepNow.regions) || []) {
    if (r.enabled === false) continue;   // no quota to ask for until it is on
    add(r.region, `${r.region} - ${shortCity(r.city)}`);
  }
  sel.value = selected && seen.has(selected) ? selected : current;
  quotaWhere = sel.value;
}

async function openQuota(kind, where) {
  quotaKind = kind || '';
  quotaWhereOptions(where);
  // Cleared BEFORE the dialog is shown, not after the read comes back: what
  // was on it is an answer about the last thing you asked, and showing it for
  // half a second under a new question is worse than showing nothing.
  quotaClear();
  $('quota-kind').value = quotaKind;
  $('quota-title').textContent = 'Ask AWS for GPU quota';
  $('quota-go').hidden = false;
  $('quota-go').disabled = true;
  $('quota-refresh').hidden = true;
  quotaBusy(true);
  quotaSay('reading\u2026', '');
  if (!$('quota').open) $('quota').showModal();
  await quotaRead();
  quotaBusy(false);
  await quotaRender();
}

$('quota-where').onchange = async () => {
  quotaWhere = $('quota-where').value;
  quotaClear();
  quotaBusy(true);
  quotaSay('reading\u2026', '');
  await quotaRead();
  quotaBusy(false);
  await quotaRender();
};
$('quota-kind').onchange = async () => {
  quotaKind = $('quota-kind').value;
  quotaClear();
  quotaBusy(true);
  quotaSay('reading\u2026', '');
  await quotaRender();
  quotaBusy(false);
};
$('quota-refresh').onclick = async e => {
  e.preventDefault();
  if ($('quota-refresh').disabled) return;
  quotaClear();
  quotaBusy(true);
  quotaSay('reading\u2026', '');
  await quotaRead();
  await quotaRender();
  quotaBusy(false);
};
$('quota-cancel').onclick = e => { e.preventDefault(); $('quota').close(); };
$('quota-copy').onclick = async e => {
  e.preventDefault();
  try { await navigator.clipboard.writeText(quotaAppeal); $('quota-copy').textContent = 'Copied'; }
  catch { $('quota-copy').textContent = 'select it below and copy'; }
};
$('quota-case').onclick = e => {
  e.preventDefault();
  if (quotaCase) window.cg.openSignIn(quotaCaseUrl(quotaCase));
};
$('quota-go').onclick = async e => {
  e.preventDefault();
  if (!quotaKind) return;
  $('quota-go').disabled = true;
  $('quota-go').textContent = 'Creating\u2026';
  $('quota-kind').disabled = true;
  quotaSay('Creating the case\u2026', 'AWS answers in a few seconds.');
  $('quota-pre-label').hidden = true;
  const { rc, err } = await runCg(quotaCmd('quota', 'request', quotaKind), { wantRc: true });
  $('quota-kind').disabled = false;
  if (rc !== 0) {
    quotaSay('the request was not created', (err || '').trim().split('\n')[0]
      || `cg quota request exited ${rc}`, 'bad');
    $('quota-log').textContent = (err || '').trim();
    $('quota-go').disabled = false;
    $('quota-go').textContent = 'Confirm \u00b7 create case';
    return;
  }
  // Read it back rather than believing the submit: the case id lags the
  // request by up to a minute, and the status is AWS's to report.
  await quotaRead();
  await quotaRender();
  if (!quotaCase) {
    $('quota-case-row').hidden = false;
    $('quota-case-url').textContent = 'the case id has not appeared yet - Refresh in a moment';
  }
};

// Turning a region on: one API call, no case, no person - the opposite of a
// quota. What it needs instead is care, because it is account-wide and undoing
// it is slower than doing it.
const OPTIN_STATE = {
  ENABLING: ['enabling', 'AWS is working on it. A few minutes is normal - Refresh to look again.'],
  ENABLED: ['enabled', 'The region is usable. Rows for it are pickable now.'],
  ENABLED_BY_DEFAULT: ['enabled', 'This region never needed enabling.'],
  DISABLING: ['being disabled', 'AWS is turning it off. Wait for that to finish first.'],
};
let optinNow = null, optinPick = '';

function optinClear() {
  $('optin-state').textContent = '';
  $('optin-explain').textContent = '';
  $('optin-log').textContent = '';
}
function optinBusy(on) {
  $('optin-pick').disabled = on;
  $('optin-refresh').disabled = on;
  $('optin-refresh').textContent = on ? 'Reading\u2026' : 'Refresh';
  if (on) $('optin-go').disabled = true;
}
function optinSay(state, why, tone) {
  $('optin-state').textContent = state;
  $('optin-state').className = 'font-code-md text-code-md mt-space-md '
    + (tone === 'bad' ? 'text-error' : tone === 'ok' ? 'text-on-surface' : 'text-on-surface-variant');
  $('optin-explain').textContent = why || '';
}

async function optinRead() {
  const out = await runCg(['regions', 'optin', '--json'], { capture: true });
  try { optinNow = JSON.parse(out); } catch { optinNow = null; }
  return optinNow;
}

// The list is every disabled region, but the ones the sweep has measured come
// first and carry their numbers: "ap-southeast-5 - Malaysia, 48ms, 9/10" is a
// decision, where a bare region code is a guess.
//
// The regions already ON are listed too, in their own group. They were left out
// at first - there is nothing to enable - and that made the dialog unable to
// answer the question people actually bring to it: I enabled Malaysia, the
// table still will not let me pick it, did the enable work? Nothing to enable
// looked exactly like nothing happened. Selecting one now says it is on, and
// what is really in the way.
function optinOptions() {
  const sel = $('optin-pick');
  const seen = new Set();
  sel.textContent = '';
  const first = document.createElement('option');
  first.value = ''; first.textContent = 'pick one\u2026';
  sel.append(first);
  const measured = new Map();
  for (const r of (sweepNow && sweepNow.regions) || []) measured.set(r.region, r);
  const group = label => {
    const g = document.createElement('optgroup');
    g.label = label;
    sel.append(g);
    return g;
  };
  const add = (into, code, m) => {
    if (seen.has(code)) return;
    seen.add(code);
    const o = document.createElement('option');
    o.value = code;
    const best = m && (m.machines || [])[0];
    o.textContent = m
      ? `${code} - ${shortCity(m.city)}, ${Math.round(m.rtt_ms)}ms`
        + (best ? `, ${best.type} at ${best.score}/10` : '')
      : code;
    into.append(o);
  };
  const off = group('not enabled yet');
  for (const code of (optinNow && optinNow.disabled) || []) if (measured.has(code)) add(off, code, measured.get(code));
  for (const code of (optinNow && optinNow.disabled) || []) add(off, code, null);
  for (const code of (optinNow && optinNow.enabling) || []) add(off, code, measured.get(code));
  // Only the measured ones: every account has a dozen enabled by default, and
  // listing all of them would bury the one you came to check.
  const on = group('already enabled');
  for (const r of (optinNow && optinNow.regions) || [])
    if (ON_ALREADY.has(r.status) && measured.has(r.region)) add(on, r.region, measured.get(r.region));
  if (!off.children.length) off.remove();
  if (!on.children.length) on.remove();
}
const ON_ALREADY = new Set(['ENABLED', 'ENABLED_BY_DEFAULT']);

// Why an enabled region is still greyed in the table, said from the sweep. The
// quota is the usual answer: a region you have just enabled starts at 0 vCPU of
// G instances, and the opt-in does not carry any across from another region.
function optinBlocker(code) {
  const m = ((sweepNow && sweepNow.regions) || []).find(r => r.region === code);
  if (!m) return 'No scan of this region yet, so there is nothing to say about it.\n'
                + 'Scan the regions on Settings and it will carry its numbers.';
  const ms = (m.machines || []);
  const fits = ms.filter(x => x.fits_spot || x.fits_ondemand);
  if (fits.length) return `${code} is on, and ${fits.length} machine`
    + `${fits.length > 1 ? 's here are' : ' here is'} already pickable in the table.`;
  if (!ms.length) return `${code} is on, but AWS offers none of the machines this rig uses here.`;
  const q = m.quota || {};
  return `${code} is on. What stops it being picked is GPU quota, not the opt-in:\n`
    + `  on demand  ${q.ondemand_vcpu ?? '?'} vCPU\n`
    + `  spot       ${q.spot_vcpu ?? '?'} vCPU\n`
    + 'A region starts at 0 and the opt-in carries nothing across, so this needs\n'
    + 'its own request - "Ask AWS for GPU quota" on Settings, which is free.';
}

function optinRender() {
  const code = optinPick;
  $('optin-refresh').hidden = !code;
  $('optin-go').hidden = false;
  $('optin-go').disabled = true;
  $('optin-go').textContent = 'Confirm \u00b7 enable';
  if (!code) {
    optinSay('', 'Pick one to see what enabling it means.');
    return;
  }
  const row = ((optinNow && optinNow.regions) || []).find(r => r.region === code);
  const status = row && row.status;
  if (status && status !== 'DISABLED') {
    const [head, why] = OPTIN_STATE[status] || [status.toLowerCase(), ''];
    optinSay(`\u25cf ${head}`, why, ON_ALREADY.has(status) ? 'ok' : '');
    $('optin-go').hidden = status !== 'DISABLING';
    // On, and still not pickable: the opt-in is not what is in the way. Say
    // what is, because the next step is a different button.
    if (ON_ALREADY.has(status)) $('optin-log').textContent = optinBlocker(code);
    return;
  }
  const m = ((sweepNow && sweepNow.regions) || []).find(r => r.region === code);
  const best = m && (m.machines || [])[0];
  optinSay(`${code}${m ? ' \u00b7 ' + shortCity(m.city) : ''}`
    + (m ? ` \u00b7 ${Math.round(m.rtt_ms)}ms` : '')
    + (best ? ` \u00b7 ${best.type} at ${best.score}/10` : ''), '');
  $('optin-log').textContent =
      'This is an account-level change. Everything on this account can use the region\n'
    + 'afterwards. Nothing is created and nothing is billed by enabling it.\n\n'
    + 'It takes a few minutes. Turning it back off is slower, and AWS requires the\n'
    + 'region to be empty first - so this is not a switch to flip and forget.';
  $('optin-go').disabled = false;
}

async function openOptin(code) {
  optinPick = code || '';
  optinClear();
  $('optin-refresh').hidden = true;
  $('optin-go').hidden = false;
  $('optin-go').disabled = true;
  optinBusy(true);
  optinSay('reading\u2026', '');
  if (!$('optin').open) $('optin').showModal();
  await optinRead();
  optinOptions();
  $('optin-pick').value = optinPick;
  optinBusy(false);
  optinRender();
}

$('optin-pick').onchange = () => {
  optinPick = $('optin-pick').value;
  optinClear();
  optinRender();
};
$('optin-cancel').onclick = e => { e.preventDefault(); $('optin').close(); };
$('optin-refresh').onclick = async e => {
  e.preventDefault();
  if ($('optin-refresh').disabled) return;
  optinClear();
  optinBusy(true);
  optinSay('reading\u2026', '');
  await optinRead();
  optinBusy(false);
  optinRender();
};
$('optin-go').onclick = async e => {
  e.preventDefault();
  if (!optinPick) return;
  const code = optinPick;
  $('optin-go').disabled = true;
  $('optin-go').textContent = 'Enabling\u2026';
  optinBusy(true);
  optinSay(`Enabling ${code}\u2026`, 'AWS takes a few minutes. This watches until it is done.');
  $('optin-log').textContent = '';
  const { rc, err } = await runCg(['regions', 'enable', code], { wantRc: true });
  $('optin-log').textContent = (err || '').trim();
  optinBusy(false);
  if (rc !== 0) {
    optinSay('AWS refused', (err || '').trim().split('\n')[0] || `cg regions enable exited ${rc}`, 'bad');
    $('optin-go').disabled = false;
    $('optin-go').textContent = 'Confirm \u00b7 enable';
    return;
  }
  // Read it back: "asked" is not "usable", and the status is AWS's to report.
  await optinRead();
  optinRender();
};

// One secret, typed once and checked before it is kept: the Tailscale API
// token and the box's own auth key are the same dialog with different words.
// cg still asks its question - that is the protocol, and both commands work in
// a terminal unchanged - and this answers it from the field.
let oneFieldPending = null;
function oneFieldAnswer(askId) {
  return oneFieldPending && oneFieldPending.askId === askId ? oneFieldPending.value : null;
}
function oneFieldFail(text, go) {
  const box = $('onefield-err');
  box.hidden = false;
  box.textContent = text;
  $('onefield-go').disabled = false;
  $('onefield-go').textContent = go;
  oneFieldPending = null;
}
function openOneField({ title, note, label, placeholder, args, askId, save = 'Save',
                        working = 'Checking…', strip }) {
  $('onefield-title').textContent = title;
  $('onefield-note').textContent = note;
  $('onefield-label').textContent = label;
  $('onefield-input').value = '';
  $('onefield-input').placeholder = placeholder || '';
  $('onefield-err').hidden = true;
  $('onefield-err').textContent = '';
  $('onefield-go').disabled = false;
  $('onefield-go').textContent = save;
  $('onefield-go').onclick = async e => {
    e.preventDefault();
    const value = $('onefield-input').value.trim();
    if (!value) return oneFieldFail('Paste it first.', save);
    oneFieldPending = { askId, value };
    $('onefield-err').hidden = true;
    $('onefield-go').disabled = true;
    $('onefield-go').textContent = working;
    const { rc, err } = await runCg(args, { wantRc: true });
    oneFieldPending = null;
    if (rc === 0) { $('onefield').close(); return; }
    // cg's own words, minus the lines that only say where to make one - you
    // are holding one.
    oneFieldFail((err || `cg ${args.join(' ')} exited ${rc}`).split('\n')
      .filter(l => l.trim() && !(strip && l.includes(strip)))
      .join('\n').trim() || `cg ${args.join(' ')} exited ${rc}`, save);
  };
  $('onefield').showModal();
  $('onefield-input').focus();
}
$('onefield-cancel').onclick = e => {
  e.preventDefault();
  oneFieldPending = null;
  $('onefield').close();
};

function openTskey() {
  openOneField({
    title: 'Tailscale API token',
    note: 'An API access token from login.tailscale.com > Settings > Keys - not the auth key a box '
        + 'joins with. Optional: without one, dead nodes are left in place and key expiry stays on.',
    label: 'api token', placeholder: 'tskey-api-…',
    args: ['creds', 'set', 'tailscale'], askId: ASK.tsToken,
    save: 'Save token', working: 'Checking with Tailscale…',
    strip: 'Tailscale API token (NOT',
  });
}

// The box's own key, pasted. Only needed when the API token cannot make one -
// a tailnet whose ACLs want tags, or no token at all - so the button appears
// only then, and the dialog says what kind of key to make.
function setAuthKey() {
  openOneField({
    title: 'Tailscale auth key for the box',
    note: 'A pre-auth key from login.tailscale.com > Settings > Keys. Reusable on, ephemeral off - '
        + 'the box goes offline every time the watchdog stops it.',
    label: 'auth key', placeholder: 'tskey-auth-…',
    args: ['creds', 'tailscale', 'authkey'], askId: ASK.tsAuthKey,
    save: 'Save key', working: 'Checking with Tailscale…',
    strip: 'A pre-auth key for the box',
  });
}

// The AWS key, as one form: both halves, one Save, the answer checked with AWS
// before anything is written, and the failure shown HERE rather than in a log
// pane behind the dialog.
let awsKeyPending = null;
function awsKeyAnswer(askId) {
  if (!awsKeyPending) return null;
  if (askId === ASK.awsId) return awsKeyPending.id;
  if (askId === ASK.awsSecret) return awsKeyPending.secret;
  return null;
}
function openAwsKey() {
  $('awskey-id').value = '';
  $('awskey-secret').value = '';
  $('awskey-err').hidden = true;
  $('awskey-err').textContent = '';
  $('awskey-go').disabled = false;
  $('awskey-go').textContent = 'Save key';
  $('awskey').showModal();
  $('awskey-id').focus();
}
function awsKeyFail(text) {
  const box = $('awskey-err');
  box.hidden = false;
  box.textContent = text;
  $('awskey-go').disabled = false;
  $('awskey-go').textContent = 'Save key';
  awsKeyPending = null;
}
$('awskey-cancel').onclick = e => { e.preventDefault(); awsKeyPending = null; $('awskey').close(); };
$('awskey-go').onclick = async e => {
  e.preventDefault();
  const id = $('awskey-id').value.trim(), secret = $('awskey-secret').value.trim();
  if (!id || !secret) return awsKeyFail('Both halves are needed: the key id and its secret.');
  awsKeyPending = { id, secret };
  $('awskey-err').hidden = true;
  $('awskey-go').disabled = true;
  $('awskey-go').textContent = 'Checking with AWS…';
  const { rc, err } = await runCg(['creds', 'set'], { wantRc: true });
  awsKeyPending = null;
  if (rc === 0) {
    // cg has written it and every screen re-reads, because this counts as a
    // write - so the card behind this dialog is already right.
    $('awskey').close();
    return;
  }
  // cg's own words, minus the line that only tells you where to find a key -
  // you are holding one.
  awsKeyFail((err || `cg creds set exited ${rc}`).split('\n')
    .filter(l => l.trim() && !l.startsWith('AWS credentials: paste'))
    .join('\n').trim() || `cg creds set exited ${rc}`);
};

function setCreds() { openAwsKey(); }

// "1" means nothing to a person: a choice shows what it chose.
const CHOICE_LABEL = {
  GAME_SPOT: { '1': 'spot', '0': 'on demand', auto: 'spot when the quota allows' },
  GAME_STEAM_LOGIN: { use: 'use the archived login', fresh: 'sign in fresh on the box' },
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
// The cards, in order, and the sentence under each heading. WHICH settings land
// on which card is cg's answer - every row carries its own `group` - and this
// is the layout around them.
const GROUP_NOTE = {
  'The box': 'Applies at the next build. A disk cannot be shrunk later.',
  'The guards': 'What the watchdogs wait for, and what the archive costs you to keep.',
  'The stream': 'Passed to Moonlight as flags, so your saved settings stay untouched.',
  'Notifications': 'Where cg reaches you.',
};
const GROUP_ORDER = ['The box', 'The guards', 'The stream', 'Notifications'];

function paintConfig(rows) {
  config = rows;
  paintKeys();
  paintBuildLogin();
  const wrap = $('s-groups');
  wrap.textContent = '';
  const set = rows.filter(r => r.is_set).length;
  $('s-count').textContent = `${set} of ${rows.length} set`;
  $('s-age').textContent = new Date().toLocaleTimeString();

  const seen = new Set();
  // Built from what cg said. A setting with no group has a card of its own and
  // is deliberately absent from this list; one in a group this file has never
  // heard of still gets a card, because cg knowing about it is what matters.
  const byGroup = new Map();
  for (const r of rows) {
    if (!r.group) continue;
    if (!byGroup.has(r.group)) byGroup.set(r.group, []);
    byGroup.get(r.group).push(r.key);
  }
  const groups = [];
  for (const name of GROUP_ORDER) {
    if (byGroup.has(name)) groups.push([name, GROUP_NOTE[name] || '', byGroup.get(name)]);
  }
  for (const [name, keys] of byGroup) {
    if (!GROUP_ORDER.includes(name)) groups.push([name, GROUP_NOTE[name] || '', keys]);
  }

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
  row.dataset.key = r.key;          // so anything can send you to this one row

  const left = document.createElement('div');
  left.className = 'min-w-0 flex-1';
  const name = document.createElement('p');
  name.className = 'font-code-md text-code-md';
  name.textContent = label(r);
  const note = document.createElement('p');
  note.className = 'font-code-sm text-code-sm text-outline mt-0.5';
  note.textContent = r.note;
  left.append(name, note);

  const right = document.createElement('div');
  right.className = 'flex items-center gap-space-sm shrink-0';
  const val = document.createElement('span');
  val.className = 'font-code-md text-code-md text-right max-w-[13rem] break-words '
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
          title: `Clear ${label(r)}?`,
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
let archive = { games: [], selectable_gb: null };
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
  // The disk a box offers is cg's arithmetic, read with the archive. Until it
  // has been read the meter says so, and nothing is refused on a guess: the box
  // enforces the real limit at boot, which is where it must be enforced.
  const gb = selectedGb(), cap = archive.selectable_gb;
  const over = cap != null && gb > cap;
  $('b-fit').textContent = !picked.size
    ? 'nothing selected - the box builds empty'
    : cap != null ? `${gb.toFixed(1)} GB of ${cap} GB on the box's NVMe`
    : `${gb.toFixed(1)} GB selected - the box's free disk is not known yet`;
  $('b-fit').className = 'font-code-sm text-code-sm ' + (over ? 'text-error' : 'text-on-surface-variant');
  const pct = cap != null ? Math.min(100, (gb / cap) * 100) : 0;
  $('b-fit-pct').textContent = over ? `over by ${(gb - cap).toFixed(1)} GB`
    : cap != null ? `${Math.round(pct)}%` : '—';
  $('b-fit-pct').className = 'font-code-sm text-code-sm ' + (over ? 'text-error' : 'text-primary');
  $('b-buffer').textContent = cap == null ? ''
    : over ? 'it will not fit - deselect something'
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
// A scan in flight. The table shows one region until it lands, and saying why
// is the difference between "still working" and "the other regions are gone".
let sweeping = false;
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
// How many of this region's machines were left out because no quota can launch
// them. Only meaningful for the un-swept view, which is one region; a sweep
// shows every region and the question "how many are hidden" has no one answer.
function hiddenByQuota() {
  if (sweepNow && sweepNow.regions && sweepNow.regions.length) return 0;
  if (!machinesNow || machinesNow.error || !machinesNow.machines) return 0;
  return machinesNow.machines.filter(m => !m.fits_spot && !m.fits_ondemand).length;
}

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
          // No rate from cg, no rupee figure. The app holds no exchange rate.
          spot: m.inr_hour_spot,
          spotMax: m.usd_hour_spot_max != null && machinesNow.inr_per_usd
            ? Math.round(m.usd_hour_spot_max * machinesNow.inr_per_usd) : null,
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
  if (why === 'no quota' && Array.isArray(mount.shortOfQuota)
      && !mount.shortOfQuota.includes(row.region)) mount.shortOfQuota.push(row.region);

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
  'no quota': 'Your G-instance quota in this region does not cover this machine for '
            + 'this purchase model. Asking is free: the button below does it, and drafts '
            + 'the appeal that gets it approved.',
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
    // Collected as the cells are drawn, and reset each pass: priceCell is the
    // only place that knows a row is enabled and short, and the button under
    // the table is the only place that can do anything about it.
    const shortOfQuota = [];
    mount.shortOfQuota = shortOfQuota;
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
    else if (sweeping) parts.push('scanning all regions - about 90 seconds');
    else if (!swept && rows.length) parts.push('showing this region only - a scan compares '
      + 'every region AWS has, measures latency and reads spot capacity (free)');
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
      // Why the table is short. Rows that no quota can launch are left out -
      // picking one would only fail at launch - but a region offering sixteen
      // machines and showing two looks broken without a word about it.
      // And why it is one region. The scan is remembered per laptop, so a
      // window that has never run one shows the region .env names and nothing
      // else - which looks like the other regions have gone missing.
      // A scan in flight says so here as well as on its button: the button is
      // at the top of a long screen, and the question is asked at the table.
      if (sweeping && rows.length) {
        const line = document.createElement('div');
        line.textContent = 'scanning every region now - about 90 seconds. This is '
          + `${machinesNow ? machinesNow.region : 'one region'} until it lands.`;
        legend.append(line);
      } else if (!swept && rows.length) {
        const line = document.createElement('div');
        line.textContent = `This is ${machinesNow ? machinesNow.region : 'one region'} only. `
          + 'A scan compares every region cg can reach - about 90 seconds, and free.';
        legend.append(line);
        // The button, here, rather than the name of a button elsewhere: this
        // line is where the question gets asked, and the answer was two
        // scrolls away at the top of the screen.
        const b = document.createElement('button');
        b.className = 'btn mt-space-xs';
        b.textContent = 'Scan all regions';
        b.onclick = () => scanRegions($('s-sweep'));
        legend.append(b);
      }
      const hidden = hiddenByQuota();
      if (hidden) {
        const line = document.createElement('div');
        line.textContent = `${hidden} more GPU machine${hidden === 1 ? ' is' : 's are'} offered here, `
          + 'all bigger than your vCPU quota allows. Ask AWS for more, or pick another region.';
        legend.append(line);
      }
      if (reasons.size) {
        const intro = document.createElement('div');
        intro.textContent = 'A price you cannot pick would be refused at launch:';
        legend.append(intro);
        // The one reason with something to do about it from in here.
        if (reasons.has('no quota')) {
          const b = document.createElement('button');
          b.className = 'btn mt-space-xs';
          b.textContent = 'Ask AWS for GPU quota';
          // The regions in this table that are enabled and short of quota. One
          // of them is what the button is about; with several, the first is a
          // better guess than the configured region, which may not be in the
          // table at all.
          b.onclick = () => openQuota(null, shortOfQuota[0]);
          legend.append(b);
        }
        // The other reason with something to do about it - and unlike the
        // quota, this one finishes here.
        if (reasons.has('needs opt-in')) {
          const b = document.createElement('button');
          b.className = 'btn mt-space-xs ml-space-xs';
          b.textContent = 'Enable a region';
          b.onclick = () => openOptin();
          legend.append(b);
        }
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

function paintSpec(s) {
  const spec = s.spec || {};
  boxNow = s.box || null;
  const cells = [
    ['vCPU',  spec.vcpus ?? '—',                                       s.quota ? `quota ${s.quota.vcpus}` : ''],
    ['RAM',   spec.memory_mib ? `${Math.round(spec.memory_mib / 1024)} GB` : '—', ''],
    ['GPU',   spec.gpu || '—', spec.gpu_memory_mib ? `${Math.round(spec.gpu_memory_mib / 1024)} GB VRAM` : ''],
    ['PROTOCOL', 'Sunshine', 'Moonlight client'],
  ];
  const wrap = $('b-spec');
  wrap.textContent = '';
  for (const [label, value, meta] of cells) {
    const box = document.createElement('div');
    box.className = 'p-space-md rounded bg-surface-container';
    const l = document.createElement('div');
    l.className = 'font-code-sm text-code-sm text-outline uppercase tracking-wider';
    l.textContent = label;
    const v = document.createElement('div');
    v.className = 'font-code text-code text-on-surface mt-0.5';
    v.textContent = value;
    const m = document.createElement('div');
    m.className = 'font-code-sm text-code-sm text-outline';
    m.textContent = meta;
    box.append(l, v, m);
    wrap.append(box);
  }
  $('b-ready').textContent = s.box ? `${s.box.state} for ${uptime(s.box.launched)}` : 'ready to build';
  // The chip beside the button: what will be launched, and how it is paid for.
  const spot = s.config && s.config.spot;
  const pay = spot === '0' ? 'on demand' : spot === '1' ? 'spot' : 'spot when the quota allows';
  const disk = s.config && s.config.disk_gb ? ` · ${s.config.disk_gb} GB root` : '';
  $('b-chip').textContent = s.box
    ? `${s.box.id} · ${s.box.type} · ${s.region} · billing`
    : `${s.instance_type} · ${s.region} · ${pay}${disk}`;
  // The reads land in whatever order they finish, and whether a pick is allowed
  // at all depends on this one - so repaint the chooser once a box is known, or
  // a table that arrived first would stay selectable beside a running box.
  paintChooser();
  paintFit();
}

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
// What to DO about a failure, keyed by the AWS error code cg prints. The code
// is the stable part: the prose around it is written for a terminal, where the
// answer is a command to type, and in here a command to type is a worse button.
//
// Nothing is invented: every action here is one cg already offers somewhere
// else, reached from the moment it is relevant.
const FAIL_ACTS = {
  InsufficientInstanceCapacity: (spot) => spot ? [
    ['Build on demand instead', async () => {
      await runCg(['config', 'set', 'GAME_SPOT', '0']);
      goView('build');
    }],
    ['Scan all regions', () => { goView('settings'); const b = $('s-sweep'); if (b) b.click(); }],
    ['Pick another machine', () => goSetting($('s-machine-card'))],
  ] : [
    ['Pick another machine', () => goSetting($('s-machine-card'))],
    ['Scan all regions', () => { goView('settings'); const b = $('s-sweep'); if (b) b.click(); }],
  ],
  SpotMaxPriceTooLow: (spot) => FAIL_ACTS.InsufficientInstanceCapacity(spot),
  MaxSpotInstanceCountExceeded: () => [
    ['Try the build again', () => $('b-build').click()],
  ],
  VcpuLimitExceeded: () => [['Ask AWS for GPU quota', () => openQuota()]],
  InstanceLimitExceeded: () => [['Ask AWS for GPU quota', () => openQuota()]],
  'InvalidKeyPair.NotFound': () => [
    ['Run the preflight fix', () => runCg(['check', '--fix'])],
  ],
  OptInRequired: () => [['Open Dependencies', () => goView('deps')]],
  AuthFailure: () => [['Set AWS key', () => goSetting($('s-creds-card'))]],
  UnauthorizedOperation: () => [['Set AWS key', () => goSetting($('s-creds-card'))]],
};

// cg's own words, read back: the marked line is the headline, and the two
// lines under it are the facts worth keeping above the fold.
function failSummary(text) {
  const lines = text.split('\n');
  const head = (lines.find(l => l.trim() && !l.startsWith(' ')) || '').trim();
  const code = (/error code:\s*([A-Za-z0-9.]+)/.exec(text) || [])[1] || '';
  const said = (/AWS said:\s*(.+)/.exec(text) || [])[1] || '';
  const safe = /nothing was launched/.test(text);
  return { head, code, said, safe };
}

function buildFailActions(code) {
  const acts = $('b-fail-acts');
  acts.textContent = '';
  const spot = (() => {
    const r = (config || []).find(x => x.key === 'GAME_SPOT');
    const v = r && (r.value || r.default);
    return v !== '0';
  })();
  const make = FAIL_ACTS[code];
  if (!make) return;
  for (const [label, go] of make(spot)) {
    const b = document.createElement('button');
    b.className = 'btn';
    b.textContent = label;
    b.onclick = go;
    acts.append(b);
  }
}

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
  const whole = buildFailures.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  $('b-error').textContent = whole;
  // The headline above the fold, the detail behind a disclosure, and the two or
  // three things worth doing as buttons - because "cg config set GAME_SPOT 0"
  // is a command to type at someone who is looking at a window.
  const { head, code, said, safe } = failSummary(whole);
  $('b-fail-head').textContent = head || 'the build stopped';
  $('b-fail-why').textContent = [safe ? 'Nothing was launched, and nothing is billing.' : '',
                                 said ? `AWS said: ${said}` : '',
                                 code ? `(${code})` : ''].filter(Boolean).join('  ');
  buildFailActions(code);
  $('b-fail').classList.remove('hidden');
  // The failure takes the bar's place. A bar frozen at 35% beside the reason it
  // froze is two things saying the same moment, and the useful one is smaller.
  $('b-strip').hidden = false;
  $('b-bar-track').hidden = true;
  $('b-prog-step').hidden = true;
}

function buildFailClear() {
  buildFailures = [];
  buildFailing = false;
  $('b-fail').classList.add('hidden');
  $('b-fail-head').textContent = '';
  $('b-fail-why').textContent = '';
  $('b-fail-acts').textContent = '';
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
  if (job.write) {
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
  if (event.t === 'ask') {
    // The key dialog asked already: cg's two questions are answered from what
    // is in it, rather than putting two more modals on top of the one the
    // person is looking at.
    const pre = awsKeyAnswer(event.id) ?? oneFieldAnswer(event.id);
    if (pre !== null) window.cg.answer(id, pre);
    else ask(id, event);
  }
  // JSON comes back on stdout as the command's own data; reports arrive as events.
  if (event.t === 'raw' && event.stream === 'stdout' && (job.json || job.capture)) job.out.push(event.text);
  if (event.t === 'report' && job.panel) $(job.panel).textContent = event.text;
  if (event.t === 'error' && event.text) job.err = event.text;
  if (job.wantRc && (event.t === 'line' || event.t === 'error') && event.text)
    job.collected += event.text + '\n';
  if (job.collect === 'rundlg-log' && event.text) watchForSignInLink(event.text);
  if (job.collect && (event.t === 'line' || event.t === 'step' || event.t === 'error'
                      || event.t === 'raw')) {
    const box = $(job.collect);
    if (box.textContent === 'running…' || box.dataset.fresh === 'yes') {
      box.textContent = '';
      delete box.dataset.fresh;
    }
    box.textContent += (event.t === 'step' ? '\n' + event.text : '  ' + (event.text || '')) + '\n';
  }
  if (event.t === 'exit') {
    // Why the reason is kept rather than painted here: updateHeader() runs a few
    // lines below and rewrites job-line, so anything written now is wiped in the
    // same tick. A failing painter was therefore completely silent - the screen
    // stayed empty and the only clue was that nothing ever appeared.
    let failure = null, painted = null;
    if (job.json && job.out.length) {
      try {
        const data = JSON.parse(job.out.join('\n'));
        painted = data;
        const paint = { cost: paintCost, library: paintLibrary, guards: paintGuards,
                        config: paintConfig, status: paintStatus, machines: paintMachines,
                        sweep: paintSweep, creds: paintCreds, deps: paintDeps,
                        tskey: paintTskey }[job.json];
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
    // behind job.write, so a read that could not run at all left the screen empty
    // and the header busy with nothing anywhere saying why - which is exactly
    // what a packaged app pointed at the wrong directory looked like. This runs
    // AFTER updateHeader because updateHeader rewrites the same line.
    if (job.json) {
      if (event.rc !== 0 || failure) {
        readFailures.set(job.json, failure ? failure
          : job.err ? `cg ${job.cmd[0]} could not run: ${job.err}`
          // A read that answered WITH its reason has already said it on the
          // screen it belongs to; repeating "exit 1" in the header adds a
          // number and takes away the reason.
          : painted && painted.error ? `cg ${job.cmd[0]}: ${painted.error}`
          : `cg ${job.cmd[0]} failed (exit ${event.rc})`);
      } else {
        readFailures.delete(job.json);       // it worked this time
      }
      updateHeader();
    }
    // A build, a destroy or a session changes what every free screen shows -
    // the box, the archive, the guards - so read them again once it is over.
    if (job.write) {
      note(`cg ${job.cmd.join(' ')} ${event.rc === 0 ? 'finished' : `failed (exit ${event.rc})`}`,
           event.rc === 0 ? 'text-primary' : 'text-error');
      refreshAll();
    }
    if (job.resolve) job.resolve(job.wantRc ? { rc: event.rc, err: job.collected || '' }
                                 : job.capture ? job.out.join('\n') : undefined);
  }
});

function runCg(args, { panel, age, json, env, collect, capture, wantRc, onStart } = {}) {
  return new Promise(async resolve => {
    const res = await window.cg.run(args, env);
    if (!res.ok) {
      const why = `cg ${res.args.join(' ')} is still running - this has to wait for it`;
      $('job-line').textContent = `busy: cg ${res.args.join(' ')} must finish first`;
      if (collect) $(collect).textContent = why + '\n';
      if (panel) $(panel).textContent = why;
      return resolve(wantRc ? { rc: null, err: why } : undefined);
    }
    jobs.set(res.id, { cmd: args, view, panel, age, json, collect, capture, wantRc,
                      // cg's verdict, not a second guess at it.
                      write: !!res.write,
                      out: [], collected: '', resolve });
    if (onStart) onStart(res.id);
    if (res.write) note(`cg ${args.join(' ')} started`, 'text-primary');
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
              [['sweep', '--cached', '--json'], 'sweep'], [['creds', '--json'], 'creds'],
              [['creds', 'tailscale', '--json'], 'tskey']],
  // Build reads status too: if a box is already up there is nothing to build,
  // and its own Refresh must be able to find that out.
  build:     [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status'],
              [['machines', '--json'], 'machines'], [['sweep', '--cached', '--json'], 'sweep']],
  library:   [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status']],
  guards:    [[['watcher', '--json'], 'guards']],
  // creds and config too: the page shows the two keys, and neither is in
  // `cg deps` - they belong to AWS and to .env.
  deps:      [[['deps', '--json'], 'deps'], [['creds', '--json'], 'creds'],
              [['creds', 'tailscale', '--json'], 'tskey']],
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
// Asked FIRST, and alone, because they decide whether anything else is worth
// asking. Six `command -v` checks, a file read, and two free calls - nothing
// here needs AWS to work, which is the point: these are the reads that still
// answer on a laptop where nothing else can.
const GATE_READS = [
  [['deps', '--json'], 'deps'],
  [['creds', '--json'], 'creds'],
  [['creds', 'tailscale', '--json'], 'tskey'],
  // Reads .env and nothing else, and carries the alert address a build needs.
  [['config', '--json'], 'config'],
];
// The rest. Every one of them needs AWS, a tailnet, or both, so on a laptop
// that is not ready yet they would all come back unknown and the screen would
// fill with question marks instead of the one thing to do about it.
const ALL_READS = [
  [['status', '--json'], 'status'],
  [['watcher', '--json'], 'guards'],
  [['library', 'list', '--json'], 'library'],
  [['machines', '--json'], 'machines'],
  // The REMEMBERED scan, never a fresh one: a scan takes 90 seconds and an
  // opening window must not wait on it. Rescanning is a button.
  [['sweep', '--cached', '--json'], 'sweep'],
];

// What a box needs before it can be built, in the order it has to be met, each
// with the one button that meets it.
//
// This used to be a ladder of `if`s that returned the first problem and nothing
// else, because the banner only ever shows one. That is right for a problem
// that turns up mid-session and wrong on a fresh laptop, where it means finding
// out about four jobs one at a time, each after finishing the last. So the list
// is a list, with a verdict for every rung: the banner takes the first unmet
// one, the opening popup shows the whole thing.
//
// `ok` is three-valued. true met, false not met, and null NOT KNOWN - the read
// behind it has not come back, or came back broken, or the rung above it has to
// be dealt with before this one can be judged at all. A rung whose read failed
// must never read as met.
//
// One sentence each. The old banner ran to three - cg's own sentence, then "Your
// games are in S3; nothing here can see them until this is fixed", then where
// the button was - which is a paragraph to say "the key does not work".
function prereqs() {
  const missing = depsNow ? (depsNow.tools || []).filter(x => !x.present).map(x => x.label) : [];
  const email = (config || []).find(r => r.key === 'EMAIL_ALERTS');
  return [
    { key: 'tools', name: 'The tools this rig needs are installed',
      ok: depsNow ? !missing.length : null,
      problem: { blocking: true,
                 title: `${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} not installed`,
                 body: 'Nothing here can run without them.',
                 label: 'Open Dependencies', go: () => goView('deps') } },
    { key: 'cli', name: 'The AWS CLI is installed',
      ok: credsNow ? !!credsNow.cli : null,
      problem: { blocking: true, title: 'The AWS CLI is not installed',
                 body: 'Everything below is unknown, not empty.',
                 label: 'Open Dependencies', go: () => goView('deps') } },
    // Judged only once there is a CLI to ask with: "AWS rejected this key" is a
    // lie about a laptop that could not ask AWS anything.
    { key: 'key', name: 'Amazon accepts this access key',
      ok: !credsNow ? null : credsNow.cli ? credsNow.valid === true : null,
      problem: { blocking: true, title: 'AWS rejected this access key',
                 body: 'Everything below is unknown, not empty.',
                 label: 'Set AWS key', go: () => goSetting($('s-creds-card')) } },
    { key: 'tailnet', name: 'This laptop is signed in to Tailscale',
      ok: tskeyNow ? tskeyNow.signed_in !== false : null,
      problem: { blocking: true, title: 'This laptop is not signed in to Tailscale',
                 body: 'The box has no public SSH port, so nothing here can reach it.',
                 label: 'Sign in', go: signInTailscale } },
    { key: 'authkey', name: 'The box has a key to join your tailnet with',
      ok: tskeyNow ? !!(tskeyNow.auth_key_stored || tskeyNow.can_mint) : null,
      problem: { blocking: true, title: 'The box has no Tailscale auth key',
                 body: 'A build cannot join it to your tailnet without one.',
                 label: 'Set auth key', go: setAuthKey } },
    { key: 'email', name: 'Billing alerts have somewhere to go',
      ok: email ? !!email.is_set : null,
      problem: { blocking: true, title: 'No address for billing alerts',
                 body: 'A build sets a budget alarm and needs somewhere to send it.',
                 label: 'Set an address', go: () => goSetting(settingEl('EMAIL_ALERTS')) } },
  ];
}

function bannerProblem() {
  const unmet = prereqs().find(r => r.ok === false);
  if (unmet) return unmet.problem;
  // Not blocking: the token is optional, and everything else works without it.
  // It is not a rung either - nothing waits for it - so it never joins the
  // ladder, only the banner.
  if (tskeyNow && tskeyNow.present && tskeyNow.valid === false) {
    return { blocking: false, title: 'Tailscale rejected this API token',
             body: 'Dead nodes will not be pruned and key expiry stays on.',
             label: 'Set API token', go: () => goSetting($('s-tskey-card')) };
  }
  return null;
}

function paintBanner() {
  const p = bannerProblem();
  $('banner').hidden = !p;
  if (!p) return null;
  $('banner-title').textContent = p.title;
  $('banner-body').textContent = p.body;
  $('banner-fix').hidden = false;
  $('banner-fix-label').textContent = p.label;
  $('banner-fix').onclick = p.go;
  return p;
}

// The opening popup: what the window is doing, while it does it.
//
// The only thing that used to say so was the header's job-line, which reads
// "running: cg machines, cg refresh". That is cg's own vocabulary - correct,
// and no help at all to someone who did not write cg. Worse, it looks the same
// whether the window is loading or stuck.
//
// It is driven by a list of steps and nothing else, so the long runs that
// currently speak only through job-line can be handed the same dialog later.
//
// Three rules:
//   - never a flash. A warm laptop answers every one of these reads in well
//     under half a second, and a modal that appears and disappears again is
//     worse than no modal, so nothing is SHOWN until this long has passed with
//     work still outstanding. The common case is that it never appears.
//   - never a trap. The window behind it is already usable; Skip closes it and
//     keeps it closed.
//   - no Done to click. Whoever opened it closes it.
const STAGE_SHOW_AFTER_MS = 400;
// A marker, not an icon: the icon font is subsetted, and a glyph it does not
// carry renders as a blank box - see the codepoint check in tests/app.sh.
const STAGE_MARK = {
  doing: ['\u2026', 'text-primary animate-pulse'],
  done:  ['\u2713', 'text-primary'],
  fail:  ['\u2717', 'text-error'],
  wait:  ['\u00b7', 'text-outline-variant'],
  // The ladder's two: something that needs you, and something that could not be
  // judged - which is not the same as something that is fine.
  todo:    ['\u2192', 'text-tertiary'],
  unknown: ['?', 'text-outline'],
};
// One line per read, in a person's words. Keyed by the name the read is already
// filed under, so a read cg grows cannot quietly arrive here without one.
const READ_STEP = {
  deps:     'Checking the tools this laptop needs',
  creds:    'Asking Amazon whether your key works',
  tskey:    'Checking the private link to the box',
  config:   'Reading your settings',
  status:   'Looking for a box that is already running',
  guards:   'Checking the guards that end the bill',
  library:  'Reading your game archive',
  machines: 'Finding what this region rents',
  sweep:    'Looking up the last region scan',
};
const stepsFor = reads => reads.map(([, json]) => ({ key: json, label: READ_STEP[json] || json }));

let stageSteps = [];
let stageTimer = null;
let stageSkipped = false;        // said once, honoured for the rest of the window

// `now` is for a popup with nothing to wait for: the ladder is drawn from reads
// that have already come back, so delaying it would only be a blank screen.
// A popup that is already up is refilled in place rather than reopened - which
// is how the opening progress becomes the ladder, if it got that far.
function stageOpen(title, sub, steps, { now = false, skip = 'Skip' } = {}) {
  $('stage-title').textContent = title;
  $('stage-sub').textContent = sub;
  $('stage-skip').textContent = skip;
  stageSteps = [];
  stageAdd(steps);
  if ($('stage').open) return;
  if (now) return $('stage').showModal();
  if (stageTimer !== null) return;
  stageTimer = setTimeout(() => {
    stageTimer = null;
    // Everything landed inside the delay: there is nothing left to report, and
    // opening now would be the flash this delay exists to prevent.
    if (stageSteps.some(s => s.state === 'doing')) $('stage').showModal();
  }, STAGE_SHOW_AFTER_MS);
}

// Mode two: not what the window is doing, but what needs YOU - all of it, at
// once, with the button for each. Shown instead of the progress list when the
// gate reads say a box cannot be built yet.
//
// It does not try to tick itself off as you work. Every button here leads to
// another screen or another dialog, so each one closes this; the banner is
// what guides the rest, and it is already right for one problem at a time.
const COUNT_WORD = ['Nothing', 'One thing', 'Two things', 'Three things',
                    'Four things', 'Five things', 'Six things'];
function stageLadder() {
  const rungs = prereqs();
  const unmet = rungs.filter(r => r.ok === false);
  if (!unmet.length) return false;
  const steps = rungs.map((r, i) => {
    if (r.ok === true) return { key: r.key, label: r.name, state: 'done' };
    if (r.ok === null) return { key: r.key, label: r.name, state: 'unknown',
      note: rungs.slice(0, i).some(x => x.ok === false)
        ? 'not checked yet - the one above it comes first'
        : 'cg could not check this one' };
    return { key: r.key, label: r.problem.title, state: 'todo', note: r.problem.body,
             action: { label: r.problem.label, go: r.problem.go } };
  });
  stageOpen(`${COUNT_WORD[unmet.length] || `${unmet.length} things`} to do before this can build a box`,
            'Each one is a sign-in or a setting, and the window behind this works while you do '
            + 'them. None of it costs anything.',
            steps, { now: true, skip: "I'll do it later" });
  return true;
}

// More steps for a popup that is already up: the reads come in two batches, and
// the second batch is only worth listing once the first says it is worth asking.
function stageAdd(steps) {
  for (const s of steps)
    if (!stageSteps.some(x => x.key === s.key)) stageSteps.push({ ...s, state: s.state || 'doing' });
  paintStage();
}

function stageStep(key, state) {
  const s = stageSteps.find(x => x.key === key);
  if (!s) return;
  s.state = state;
  paintStage();
}

// Closing is the owner's call, not the last step's: between the two batches
// every step is done and more are coming, which a popup that closed itself on
// an empty list would read as "finished".
function stageClose() {
  if (stageTimer !== null) { clearTimeout(stageTimer); stageTimer = null; }
  if ($('stage').open) $('stage').close();
}

function paintStage() {
  const wrap = $('stage-steps');
  if (!wrap) return;
  wrap.textContent = '';
  for (const s of stageSteps) {
    const [mark, cls] = STAGE_MARK[s.state] || STAGE_MARK.wait;
    const row = document.createElement('div');
    // items-start, because a ladder rung is a line, a reason and a button, and
    // its marker belongs beside the first of the three.
    row.className = 'flex gap-space-sm items-start';
    row.dataset.step = s.key;
    row.dataset.state = s.state;
    const m = document.createElement('span');
    m.className = 'w-6 shrink-0 ' + cls;
    m.textContent = mark;
    const body = document.createElement('div');
    body.className = 'min-w-0';
    const label = document.createElement('div');
    label.className = s.state === 'fail' ? 'text-error'
      : s.state === 'todo' ? 'text-on-surface' : 'text-on-surface-variant';
    label.textContent = s.label;
    body.append(label);
    if (s.note) {
      const note = document.createElement('div');
      note.className = 'text-outline';
      note.textContent = s.note;
      body.append(note);
    }
    if (s.action) {
      const btn = document.createElement('button');
      btn.className = 'btn mt-space-xs';
      btn.textContent = s.action.label;
      // Closed first: every one of these goes to a screen or a dialog, and a
      // modal still up in front of it is the thing people click Cancel on.
      btn.onclick = () => { stageClose(); s.action.go(); };
      body.append(btn);
    }
    row.append(m, body);
    wrap.append(row);
  }
}

$('stage-skip').onclick = () => { stageSkipped = true; stageClose(); };

// A read, and the popup's line for it. Whether it worked is read back from
// readFailures rather than judged again here: that map is what every other
// screen in this window already believes about the same read.
function readStep(args, json, narrate) {
  const p = runCg(args, { json });
  return narrate ? p.then(() => stageStep(json, readFailures.has(json) ? 'fail' : 'done')) : p;
}

// On open: ask what this laptop can do, and only then ask AWS anything.
//
// It used to fire all nine reads at once. On a laptop with no AWS CLI that is
// six reads that cannot work, a screen of unknowns, and the actual problem - a
// missing tool - somewhere in the middle of it.
//
// `narrate` is the window opening, which is the one time nobody has asked for
// anything yet and a popup is welcome. The same function runs after a build or
// a destroy, where a modal over the screen you are reading would be rude.
async function refreshAll({ narrate = false } = {}) {
  if (narrate && !stageSkipped) stageOpen('Getting your rig ready',
    'Checking what this laptop has and what is already in your Amazon account. '
    + 'None of it costs anything.', stepsFor(GATE_READS));
  await Promise.all(GATE_READS.map(([args, json]) => readStep(args, json, narrate)));
  const problem = paintBanner();
  // A rejected API token is a banner, not a stop: everything else still works.
  //
  // Something needs you. On the window opening, that is the ladder: the whole
  // list, in order, with the button for each. Any other time - the refresh
  // after a build, say - the banner has it, and a modal over the screen you
  // are reading would only be in the way.
  if (problem && problem.blocking) {
    if (!narrate || !stageLadder()) stageClose();
    return;
  }
  for (const v of Object.keys(NEEDS)) loaded.add(v);
  // In parallel, because they share nothing and each screen paints when its own
  // answer lands. cg cost is not among them: it bills.
  if (narrate) stageAdd(stepsFor(ALL_READS));
  await Promise.all(ALL_READS.map(([args, json]) => readStep(args, json, narrate)));
  stageClose();
  return firstScan();
}

// A laptop that has never scanned shows one region - the one .env names - and
// that reads as "where did the other regions go". The scan that fills the table
// is free, so it is started once, by itself, after the first set of reads. It
// is NOT awaited by anything: the window is usable throughout, and the table
// says what it is waiting for.
//
// Once only, and never when a scan is already remembered, however old: a
// remembered scan is what the button is for.
let scanOffered = false;
async function firstScan() {
  if (scanOffered || sweeping) return;
  if (sweepNow && (sweepNow.regions || []).length) return;
  // Something is running: a scan can wait, and cg would refuse to start one
  // underneath a build anyway.
  if (jobs.size) return;
  scanOffered = true;
  return scanRegions($('s-sweep'));
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
// Settings is a long screen, and arriving on it is not the same as finding the
// thing you came for: the first instance-type picker went unnoticed entirely
// because it was below the fold. So anything that sends you to a setting
// scrolls to it and flashes it, and that is the ONLY way a key is set - one
// place per thing, the same rule the machine chooser follows.
function goSetting(el) {
  goView('settings');
  if (!el) return;
  el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  // Restarting a running animation needs the class off, a reflow, then on.
  el.classList.remove('flash-attn');
  void el.offsetWidth;
  // The animation says when it is finished, so nothing here runs on a timer.
  el.addEventListener('animationend', () => el.classList.remove('flash-attn'), { once: true });
  el.classList.add('flash-attn');
}
// A settings row, by the key cg calls it.
const settingEl = key => document.querySelector(`#s-groups .row[data-key="${key}"]`);

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

// Scanning every region takes about 90 seconds, so nothing waits on it: the
// window opens on the remembered scan and this runs in the background, either
// from the button or - once, on a laptop that has never scanned - by itself.
// Every call it makes is free.
async function scanRegions(btn) {
  const was = btn && btn.textContent;
  if (btn) { btn.disabled = true; btn.textContent = 'scanning all regions…'; }
  sweeping = true;
  paintChooser();                 // the table says what it is waiting for
  try {
    await runCg(['sweep', '--json'], { json: 'sweep' });
  } finally {
    sweeping = false;
    if (btn) { btn.disabled = false; btn.textContent = was; }
    paintChooser();
  }
}
const sweepBtn = $('s-sweep');
if (sweepBtn) sweepBtn.onclick = () => scanRegions(sweepBtn);

// Build's "Change setup". Settings is a long screen and the table is at the
// top of it, so arriving there is not enough - the first instance-type picker
// went unnoticed for exactly this reason. Scroll to it and flash it.
$('b-setup').onclick = () => goSetting($('s-machine-card'));

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
// Drawn once before anything has been read, so the card has its rows and they
// say "reading…", rather than being blank until two reads land.
paintKeys();
checkAsks();
refreshAll({ narrate: true });
