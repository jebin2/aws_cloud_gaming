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
// A command is more than its first word. `cg library list` reads an index;
// `cg library push` spends ten minutes uploading your games - and this table
// used to be keyed on `library` alone, TWICE, so the second one won and a
// mirror to S3 was called a refresh: "running: cg refresh" in the header and
// "Stop refresh" on the button that would abandon it.
//
// Longest match first, and flags are not part of the name.
const byCommand = (table, cmd) => {
  const words = cmd.filter(a => !a.startsWith('-'));
  for (let n = Math.min(3, words.length); n > 0; n--) {
    const hit = table[words.slice(0, n).join(' ')];
    if (hit !== undefined) return hit;
  }
  return undefined;
};

// The header groups runs rather than listing them: `cg status` and `cg watcher`
// are two commands and one refresh to whoever clicked it.
const RUN_NAME = {
  init: 'build', destroy: 'destroy', open: 'session', check: 'check',
  status: 'refresh', watcher: 'refresh', 'library list': 'refresh',
  cost: 'cost fetch',
  'library push': 'archive change', 'library pull': 'archive change',
  'library clean': 'archive change', 'library forget': 'archive change',
  'library account': 'account change',
};
const runName = cmd => byCommand(RUN_NAME, cmd) || cmd[0];

// What each command IS, in a person's words. One table, because these words are
// said in three places - the opening popup, the dashboard's activity list, and
// the refusal when something else holds the lock - and three tables of the same
// facts is how `library` came to mean two things.
//
//   name  what it is called, as a NOUN, so it can be the subject of a sentence:
//         "the build is still running", "the mirror to S3 finished".
const CG_WORDS = {
  deps: { name: 'the tool check' },
  creds: { name: 'the key check' },
  'creds tailscale': { name: 'the Tailscale check' },
  config: { name: 'the settings read' },
  status: { name: 'the box check' },
  watcher: { name: 'the guard check' },
  'library list': { name: 'the archive read' },
  machines: { name: 'the machine list' },
  sweep: { name: 'the region scan' },
  cost:              { name: 'the bill fetch' },
  check:             { name: 'the laptop check' },
  // Everything cg says runs alone - see `cg --contract`, and the test that
  // holds this list to it. These are the ones whose name ends up on a Stop
  // button, so none of them may read as something cheap.
  init:                      { name: 'the build' },
  destroy:                   { name: 'the destroy' },
  open:                      { name: 'the stream' },
  'library push':            { name: 'the mirror to S3' },
  'library pull':            { name: 'the fetch from S3' },
  'library forget':          { name: 'forgetting a game' },
  'library clean':           { name: 'the delete from S3' },
  'library account':         { name: 'the Steam account change' },
  'creds set':               { name: 'saving the AWS key' },
  // Longer than 'creds set', which is the AWS key: without this, saving a
  // Tailscale token was announced as saving an AWS one.
  'creds set tailscale':     { name: 'saving the Tailscale token' },
  'creds tailscale signin':  { name: 'the Tailscale sign-in' },
  'creds tailscale authkey': { name: 'saving the box auth key' },
  'deps install':            { name: 'installing the tools' },
};
const cgWords = cmd => byCommand(CG_WORDS, cmd) || {};
// Falls back to the command itself: a name nobody wrote down is better said in
// cg's words than guessed at.
const cgName = cmd => cgWords(cmd).name || `cg ${cmd.filter(a => !a.startsWith('-')).join(' ')}`;
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

// A read that failed, keyed by the read, so a later success for the same read
// clears it. The screens show their own unknowns; this is what the pipeline and
// the banner read to say WHY something is unknown.
const readFailures = new Map();

function updateHeader() {
  const mine = jobsHere();
  const busy = writing();
  // The dashboard's refresh is two commands - status and the watcher - but one
  // action to you, so count what they are called, not how many there are.
  const hereNames = [...new Set(mine.map(j => j.group || runName(j.cmd)))];
  $('cancel').hidden = !mine.length;
  if (mine.length) $('cancel-label').textContent =
    hereNames.length === 1 ? `Stop ${hereNames[0]}` : `Stop ${hereNames.length} runs`;

  // Point at a run only when it is worth watching: a build or a destroy takes
  // minutes and has its own screen. A refresh finishes in seconds and paints
  // itself, so sending you to another tab for it is noise.
  const elsewhere = [...jobs.values()].find(j => watchable(j.cmd) && j.view !== view);
  $('goto').hidden = !elsewhere;
  if (elsewhere) {
    // Named in full here, not grouped: this points at one run, and what it is
    // decides whether you want to go and watch it.
    $('goto-label').textContent = `${cgName(elsewhere.cmd)} is running - show it`;
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

  // A build starting or finishing is the dashboard's news too.
  paintDash();
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
function askConfirm({ title, body, yes = 'Continue', no = 'Cancel', danger = false }) {
  return new Promise(resolve => {
    $('confirm-title').textContent = title;
    $('confirm-body').textContent = body;
    $('confirm-no').textContent = no;
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
// When a game was saved to the archive, as a date: "10 Oct".
const savedOn = iso => iso ? new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) : '—';
// What the configured machine costs an hour, bought the configured way, plus
// its public address - what Build starts billing. cg's numbers throughout.
function buildRate() {
  const s = statusNow;
  if (!s) return null;
  const type = s.box ? s.box.type : s.instance_type;
  const spot = s.box ? s.box.lifecycle === 'spot' : (s.config || {}).spot !== '0';
  const h = hourlyInr(type, spot);
  const r = s.rates || {};
  return h == null ? null : h + (r.ipv4_hour && r.inr_per_usd ? r.ipv4_hour * r.inr_per_usd : 0);
}
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
function paintPing(d) { pingNow = d; paintDash(); }
function askPing(s) {
  const online = !!(s.box && s.box.state === 'running' && s.tailnet && s.tailnet.online);
  if (!online) { pingNow = null; return; }
  if (pingBusy || Date.now() - pingAt < 60000) return;
  pingBusy = true;
  pingAt = Date.now();
  runCg(['ping', '--json'], { json: 'ping', group: 'refresh' }).then(() => { pingBusy = false; });
}

function paintStatus(s) {
  paintSpec(s);
  statusNow = s;
  askPing(s);
  paintBanner();
  statusBudget = s.budget || null;
  // What the app may do with the box that exists. A stream can be running that
  // this window never started - closing the app does not end it - so Play asks
  // cg rather than remembering, and refuses to start a second Moonlight.
  sessionNow = s.session || null;
  paintSession();
  paintDash();
}

// ── The dashboard ───────────────────────────────────────────────────────────
//
// Three questions, in order: can I play right now, what is it costing, and are
// my games and my money safe. Drawn whole from what cg has already said -
// status, the machines, the archive, the guards - and redrawn when any of them
// lands. Money is in rupees only; every price is cg's (status carries the
// table), and the rate for a machine is `cg machines`'s.

// Rupees, with paise only where they matter.
const rs = n => n == null || !isFinite(n) ? '—'
  : '₹' + (n < 10 ? n.toFixed(2) : Math.round(n).toLocaleString('en-IN'));
// An hourly figure keeps its paise when it has any: ₹20 + ₹0.44 has to read as
// ₹20.44, or the total does not add up to the lines above it.
const rsh = n => n != null && isFinite(n) && n < 100 && Math.round(n * 100) % 100 ? '₹' + n.toFixed(2) : rs(n);
// NaN, not 0, when cg sent no price table (an older cg): every figure then reads
// "—", which is true, instead of ₹0, which is not.
const inrRate = () => (statusNow && statusNow.rates && statusNow.rates.inr_per_usd) || NaN;

// What a machine of this type costs an hour, bought this way, in rupees.
function hourlyInr(type, spot) {
  const m = machinesNow && (machinesNow.machines || []).find(x => x.type === type);
  if (!m) return null;
  return spot ? m.inr_hour_spot : m.inr_hour_ondemand;
}

// Everything billing right now, each with its cost. Built from status's own
// counts and cg's price table; nothing here is a guess at a resource cg did not
// report. Hourly items bill while they exist; monthly ones are storage.
function billingItems(s) {
  const r = s.rates || {}, inr = r.inr_per_usd || NaN, res = s.res || {}, items = [];
  const box = s.box && !['terminated', 'shutting-down'].includes(s.box.state) ? s.box : null;
  if (box) {
    const spot = box.lifecycle === 'spot';
    items.push({ name: `Machine · ${box.type}, ${spot ? 'spot' : 'on demand'}`,
                 hour: box.state === 'running' || box.state === 'pending'
                   ? hourlyInr(box.type, spot) : null,
                 note: box.state === 'stopped' ? 'stopped - not billed by the hour' : null });
    if (box.public_ip) items.push({ name: 'Public IP address', hour: r.ipv4_hour * inr });
  }
  if (res.volumes_gb > 0) {
    items.push({ name: `${box ? 'Machine disk' : 'Disk left behind'} · ${res.volumes_gb} GB`,
                 month: res.volumes_gb * r.ebs_gb_month * inr,
                 warn: !box, note: box ? null : 'no machine is using it' });
  }
  const a = s.archive || {};
  if (a.bytes > 0) items.push({ name: `Game archive · ${GB(a.bytes)}`, month: (a.usd_month || 0) * inr });
  if (res.snapshots > 0) {
    items.push({ name: `Snapshots · ${res.snapshots}${res.snapshots_gb ? `, ${res.snapshots_gb} GB` : ''}`,
                 month: (res.snapshots_gb || 0) * r.snapshot_gb_month * inr, upTo: true,
                 warn: true, note: 'cg does not make these' });
  }
  if (res.elastic_ips > 0) {
    items.push({ name: `Elastic IP address${res.elastic_ips === 1 ? '' : 'es'} · ${res.elastic_ips}`,
                 hour: res.elastic_ips * r.ipv4_hour * inr, warn: !box,
                 note: box ? null : 'reserved with no machine' });
  }
  return items;
}

function machineLine(s) {
  const spec = s.spec || {}, cfg = s.config || {};
  const type = s.box ? s.box.type : s.instance_type;
  const buy = s.box ? (s.box.lifecycle === 'spot' ? 'spot' : 'on demand')
    : cfg.spot === '0' ? 'on demand' : cfg.spot === '1' ? 'spot' : 'spot when available';
  return [type, spec.gpu ? `NVIDIA ${spec.gpu}` : null, placeName(s.region), buy]
    .filter(Boolean).join(' · ');
}

function paintDash() {
  const s = statusNow;
  if (!s || !$('d-main')) return;
  const inr = inrRate();
  const credErr = s.error && s.error.credentials;
  const box = s.box && !['terminated'].includes(s.box.state) ? s.box : null;
  const building = jobsFor('init');
  const running = !!(box && box.state === 'running');
  const spot = box ? box.lifecycle === 'spot' : (s.config || {}).spot !== '0';
  const hour = hourlyInr(box ? box.type : s.instance_type, spot);
  const upHours = box && box.launched ? (Date.now() - new Date(box.launched)) / 3600000 : 0;
  const idleGuard = ((watcher && watcher.guards) || []).find(g => g.layer === 2);
  const idleAfter = idleGuard && idleGuard.reaction ? idleGuard.reaction.replace(/ idle$/, '') : '15 min';

  // ── the machine ──
  const tag = $('d-tag');
  let title, sub, note = '';
  if (credErr) {
    title = 'Status unknown';
    sub = 'AWS could not be reached, so nothing below is known. The banner says why.';
  } else if (building) {
    title = 'Building your machine';
    sub = box && box.launched ? `Started ${uptime(box.launched)} ago · usually 10–20 minutes`
                              : 'Usually 10–20 minutes';
  } else if (running && sessionNow) {
    title = 'Playing';
    sub = `Up ${uptime(box.launched)} · ${rs(hour != null ? hour * upHours : null)} so far · ${rs(hour)}/hour`;
    note = 'Closing Moonlight asks whether to keep the machine or delete it.';
  } else if (running) {
    title = 'Ready to play';
    sub = `Up ${uptime(box.launched)} · ${rs(hour != null ? hour * upHours : null)} so far · ${rs(hour)}/hour`;
    note = `Stops by itself after ${idleAfter} with nobody playing.`;
  } else if (box) {
    title = `Machine ${box.state}`;
    sub = box.state === 'pending' ? 'Starting.' : box.state === 'stopping' || box.state === 'shutting-down'
      ? 'Shutting down.' : 'Not running.';
  } else {
    title = 'No machine running';
    sub = '';
  }
  $('d-title').textContent = title;
  $('d-sub').textContent = sub;
  $('d-sub').hidden = !sub;
  tag.hidden = !(running || building);
  tag.textContent = building ? 'building' : sessionNow ? 'streaming' : 'running';
  tag.className = 'pill shrink-0 pill-ok';
  $('d-machine').textContent = machineLine(s);
  $('d-rate').textContent = box || building ? ''
    : `${rs(hour)}/hour while it runs · ready in 10–20 minutes`;
  $('d-rate').hidden = !$('d-rate').textContent;
  $('d-prog').hidden = !building;
  $('d-build').hidden = !!box || building || !!credErr;
  $('d-open').hidden = !running || building;
  $('d-watch').hidden = !building;
  $('d-destroy').hidden = !box || building;
  $('d-change').hidden = !!box || building;
  $('d-note').textContent = note;
  $('d-note').hidden = !note;

  // ── billing now ──
  const list = $('d-bill');
  list.textContent = '';
  const totals = $('d-bill-total');
  totals.textContent = '';
  const items = credErr ? null : billingItems(s);
  if (!items) {
    list.append(Object.assign(document.createElement('p'),
      { className: 'font-body-sm text-body-sm text-outline', textContent: 'Unknown - AWS could not be reached.' }));
  } else if (!items.length) {
    list.append(Object.assign(document.createElement('p'),
      { className: 'font-body-sm text-body-sm text-on-surface-variant', textContent: 'No billing items.' }));
  }
  for (const it of items || []) {
    const row = document.createElement('div');
    row.className = 'flex items-baseline justify-between gap-space-md';
    const left = document.createElement('div');
    left.className = 'min-w-0';
    const name = document.createElement('p');
    name.className = 'font-body-md text-body-md ' + (it.warn ? 'text-tertiary' : 'text-on-surface');
    name.textContent = it.name;
    left.append(name);
    if (it.note) {
      left.append(Object.assign(document.createElement('p'),
        { className: 'font-code-sm text-code-sm text-outline', textContent: it.note }));
    }
    const cost = document.createElement('span');
    cost.className = 'font-code-md text-code-md shrink-0 ' + (it.warn ? 'text-tertiary' : 'text-on-surface-variant');
    cost.textContent = it.hour != null ? `${rsh(it.hour)}/hour`
      : it.month != null ? `${it.upTo ? 'up to ' : ''}${rs(it.month)}/month` : '—';
    row.append(left, cost);
    list.append(row);
  }
  const perHour = (items || []).reduce((n, i) => n + (i.hour || 0), 0);
  const perMonth = (items || []).reduce((n, i) => n + (i.month || 0), 0);
  for (const [label, v] of [['While running', perHour ? `${rsh(perHour)}/hour` : null],
                            ['Storage', perMonth ? `${rs(perMonth)}/month` : null]]) {
    if (!v) continue;
    const row = document.createElement('div');
    row.className = 'flex justify-between font-code-sm text-code-sm';
    row.append(Object.assign(document.createElement('span'), { className: 'text-outline', textContent: label }),
               Object.assign(document.createElement('span'), { className: 'text-on-surface', textContent: v }));
    totals.append(row);
  }
  totals.hidden = !totals.childElementCount;

  // ── this month ──
  const b = s.budget || {};
  const exact = costNow && costNow.month && costNow.month.total_inr != null ? costNow.month.total_inr : null;
  const spent = exact != null ? exact : b.spent != null ? b.spent * inr : null;
  const limit = b.limit != null ? b.limit * inr : null;
  $('d-month').textContent = spent == null ? '—' : limit ? `${rs(spent)} of ${rs(limit)}` : rs(spent);
  $('d-month-bar').style.width = spent != null && limit ? `${Math.min(100, (spent / limit) * 100)}%` : '0%';
  $('d-month-bar').className = 'h-full ' + (spent != null && limit && spent >= limit * 0.8 ? 'bg-tertiary' : 'bg-primary');
  // cg projects the month from an exact fetch; the window renders that number
  // and works out none of its own.
  const m = (costNow && costNow.month) || {};
  const proj = exact != null && m.projected_inr != null ? ` · on track for ${rs(m.projected_inr)}` : '';
  $('d-month-sub').textContent = (limit == null ? 'No monthly budget is set.'
    : spent == null ? `Budget ${rs(limit)}`
    : `${Math.round((spent / limit) * 100)}% of the monthly budget`) + proj;
  $('d-month-src').textContent = exact != null
    ? `Exact, from Cost Explorer at ${costNowAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`
    : b.spent != null ? 'From AWS Budgets - updates a few times a day' : '';
  const call = (s.rates || {}).ce_call_usd;
  $('d-cost-price').textContent = call && isFinite(inr) ? rs(call * inr) : '';

  // ── your games ──
  const a = s.archive || {};
  const n = (archive.games || []).length;
  if (credErr || a.error) {
    $('d-games').textContent = 'Unknown';
    $('d-games-sub').textContent = a.error ? 'The archive could not be read. This is not the same as empty.'
      : 'AWS could not be reached.';
    $('d-games-keep').textContent = '';
  } else {
    $('d-games').textContent = !a.bytes ? 'No games saved yet'
      : `${n || '—'} game${n === 1 ? '' : 's'} · ${GB(a.bytes)}`;
    $('d-games-sub').textContent = a.bytes
      ? `Saved in ${placeName(s.region)} · ${rs((a.usd_month || 0) * inr)} a month to keep` : '';
    const days = a.expiry_days;
    $('d-games-keep').textContent = !a.bytes ? ''
      : days ? `Deleted after ${days} days with no machine.` : 'Kept until you delete them.';
    $('d-games-keep').className = 'font-code-sm text-code-sm mt-space-sm '
      + (days ? 'text-tertiary' : 'text-primary');
  }

  // ── tailscale ──
  const ts = $('d-ts');
  ts.textContent = '';
  const tn = s.tailnet || {};
  const tsLines = [];
  // This laptop. null is "not read yet", not "signed out".
  const me = tskeyNow ? tskeyNow.signed_in : null;
  tsLines.push([me === true ? true : me === false ? false : null,
    me === true ? `This laptop is signed in${tskeyNow.node ? ` as ${tskeyNow.node}` : ''}`
      : me === false ? 'This laptop is not signed in' : 'Checking this laptop']);
  // The machine, only if there is one.
  if (!box) {
    tsLines.push([undefined, 'No machine on the network']);
  } else if (tn.node) {
    tsLines.push([!!tn.online, `Machine ${tn.node} is ${tn.online ? 'online' : 'offline'}`]);
  } else {
    tsLines.push([null, building ? 'Machine has not joined yet' : 'Machine is not on the network']);
  }
  // The path, while the machine is online.
  if (box && tn.online) {
    const ms = pingNow && pingNow.median_ms != null ? ` · ${pingNow.median_ms} ms` : '';
    tsLines.push(!pingNow ? [null, 'Checking the connection']
      : pingNow.path === 'direct' ? [true, `Direct connection${ms}`]
      : pingNow.path === 'DERP' ? ['warn', `Relayed through Tailscale${ms} - slower for streaming`]
      : [null, 'The connection could not be measured']);
  }
  for (const [ok, text] of tsLines) {
    const row = document.createElement('div');
    row.className = 'flex items-baseline gap-space-sm';
    row.append(Object.assign(document.createElement('span'), {
      className: 'font-code-md text-code-md w-4 shrink-0 '
        + (ok === true ? 'text-primary' : ok === false ? 'text-error' : ok === 'warn' ? 'text-tertiary' : 'text-outline'),
      textContent: ok === true ? '✓' : ok === false ? '✗' : ok === 'warn' ? '!' : ok === undefined ? '·' : '…' }),
      Object.assign(document.createElement('span'), {
      className: 'font-body-md text-body-md ' + (ok === false ? 'text-error' : ok === undefined ? 'text-outline' : 'text-on-surface'),
      textContent: text }));
    ts.append(row);
  }
  $('d-ts-signin').hidden = me !== false;

  // ── protection ──
  const prot = $('d-protect');
  prot.textContent = '';
  const guards = (watcher && watcher.guards) || [];
  const g2 = guards.find(g => g.layer === 2), g3 = guards.find(g => g.layer === 3);
  const lines = [
    // Installed with every build: with no machine there is nothing for it to
    // watch, which is not the same as it being off.
    [g2 ? (g2.armed === false ? false : true) : null,
     `An idle machine stops after ${idleAfter}`],
    [g3 ? g3.armed : null,
     g3 && g3.armed ? 'Cloud watchdog: stops a forgotten machine' : 'Cloud watchdog is off'],
    [b.limit != null ? true : (statusNow ? false : null),
     b.limit != null ? `Budget alert at ${rs(limit)} - emails ${b.alerts || 0} address${b.alerts === 1 ? '' : 'es'}`
                     : 'No budget alert is set'],
  ];
  for (const [ok, text] of lines) {
    const row = document.createElement('div');
    row.className = 'flex items-baseline gap-space-sm';
    row.append(Object.assign(document.createElement('span'), {
      className: 'font-code-md text-code-md w-4 shrink-0 '
        + (ok === true ? 'text-primary' : ok === false ? 'text-error' : 'text-outline'),
      textContent: ok === true ? '✓' : ok === false ? '✗' : '…' }),
      Object.assign(document.createElement('span'), {
      className: 'font-body-md text-body-md ' + (ok === false ? 'text-error' : 'text-on-surface'),
      textContent: text }));
    prot.append(row);
  }
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
  costNowAt = new Date();
  paintDash();
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

function paintArchiveCard() { paintDash(); }

// Layer 1 is not armed or unarmed - `cg open` either runs or it does not - so
// it is not counted. Counting it as unarmed read as a missing guard.
const guardCount = guards => [
  guards.filter(g => g.armed === true).length,
  guards.filter(g => g.armed !== null && g.armed !== undefined).length,
];

function paintGuardStrip() { paintDash(); }

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
  paintOnboardSoon();
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
  paintOnboardSoon();
  tskeyNow = ts;
  paintKeys();
  paintDash();
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
  runSurface = { link: 'rundlg-link', log: 'rundlg-log', status: runDlgStatus };
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
// Where the words of the run in flight go. Two surfaces now: the dialog, for a
// run you asked for from a card, and the first-run pipeline's pane. The link
// has to appear on whichever one is in front of you.
let runSurface = { link: 'rundlg-link', log: 'rundlg-log', status: runDlgStatus };
function watchForSignInLink(text) {
  const m = SIGNIN_RE.exec(text || '');
  if (!m) return;
  const link = $(runSurface.link);
  link.hidden = false;
  link.onclick = () => window.cg.openSignIn(m[0]);
  // What is being waited for, in words: the command is not stuck, it is
  // waiting for a browser - and that distinction is the whole dialog.
  runSurface.status('waiting for you to finish in the browser');
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
// `args` is either the command, or a function of the typed value for a command
// that takes it as an argument rather than answering a question - `cg config
// set` is the second kind. `after` is for those: cg does not list them as
// running alone, so the window does not count them as writes and nothing
// re-reads by itself.
// `secret` is what the field is for, not how long it is: a key is bulleted
// because it is a credential sitting on screen, an email address is typed
// wrong constantly and must be readable. The field was hard-coded to a
// password because for a while every caller was a key.
// `log` is a step's log in the first-run pipeline, when it was opened from
// there: what cg said while checking lands under the step, folded.
function openOneField({ title, note, label, placeholder, args, askId, save = 'Save',
                        working = 'Checking…', strip, after, secret = true, log }) {
  // Wired straight to onclick in places, which hands over an event, not a log.
  if (typeof log !== 'string') log = undefined;
  $('onefield-title').textContent = title;
  $('onefield-note').textContent = note;
  $('onefield-label').textContent = label;
  $('onefield-input').type = secret ? 'password' : 'text';
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
    const argv = typeof args === 'function' ? args(value) : args;
    if (askId) oneFieldPending = { askId, value };
    $('onefield-err').hidden = true;
    $('onefield-go').disabled = true;
    $('onefield-go').textContent = working;
    const { rc, err } = await runCg(argv, { wantRc: true, collect: log });
    oneFieldPending = null;
    if (rc === 0) {
      $('onefield').close();
      if (after) await after();
      return;
    }
    // cg's own words, minus the lines that only say where to make one - you
    // are holding one.
    oneFieldFail((err || `cg ${argv.join(' ')} exited ${rc}`).split('\n')
      .filter(l => l.trim() && !(strip && l.includes(strip)))
      .join('\n').trim() || `cg ${argv.join(' ')} exited ${rc}`, save);
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
function setAuthKey(log) {
  openOneField({
    title: 'A key for your games machine',
    note: 'In Tailscale: Settings \u2192 Keys \u2192 Generate auth key. Turn Reusable on and '
        + 'Ephemeral off - the machine goes offline every time it is stopped, and an ephemeral '
        + 'key would forget it.',
    label: 'auth key', placeholder: 'tskey-auth-…', log,
    args: ['creds', 'tailscale', 'authkey'], askId: ASK.tsAuthKey,
    save: 'Save key', working: 'Checking with Tailscale…',
    strip: 'A pre-auth key for the box',
  });
}

// Where the billing alert goes, asked where it is needed. It is one line of
// text and cg validates it, so it is the same dialog as the keys - and the
// alternative was sending someone to Settings to find the row and edit it in
// place, which is the detour the key stage used to make.
//
// Not a secret, and not an ask either: `cg config set` takes the value as an
// argument, validates it against the registry rule and writes .env.
function openAlertEmail(log) {
  openOneField({
    title: 'Where should bill alerts go?',
    note: 'Amazon emails this address if the month passes your budget - it is also what tells '
        + 'you a machine is still running when you thought it was not. Several? Separate them '
        + 'with commas.',
    label: 'email', placeholder: 'you@example.com', secret: false, log,
    args: v => ['config', 'set', 'EMAIL_ALERTS', v],
    save: 'Save address', working: 'Saving\u2026',
    // `cg config set` is not a command cg says runs alone, so no re-read
    // follows it on its own: the stage would stay exactly as it was.
    after: () => runCg(['config', '--json'], { json: 'config' }),
  });
}

// The AWS key, as one form: both halves, one Save, the answer checked with AWS
// before anything is written, and the failure shown HERE rather than in a log
// pane behind the dialog.
let awsKeyPending = null;
let awsKeyLog = null;     // a pipeline step's log, when it was opened from there
function awsKeyAnswer(askId) {
  if (!awsKeyPending) return null;
  if (askId === ASK.awsId) return awsKeyPending.id;
  if (askId === ASK.awsSecret) return awsKeyPending.secret;
  return null;
}
function openAwsKey(log) {
  awsKeyLog = typeof log === 'string' ? log : null;
  $('awskey-id').value = '';
  $('awskey-secret').value = '';
  $('awskey-err').hidden = true;
  $('awskey-err').textContent = '';
  $('awskey-go').disabled = false;
  $('awskey-go').textContent = 'Connect';
  $('awskey').showModal();
  $('awskey-id').focus();
}
function awsKeyFail(text) {
  const box = $('awskey-err');
  box.hidden = false;
  box.textContent = text;
  $('awskey-go').disabled = false;
  $('awskey-go').textContent = 'Connect';
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
  $('awskey-go').textContent = 'Checking with Amazon\u2026';
  const { rc, err } = await runCg(['creds', 'set'], { wantRc: true, collect: awsKeyLog });
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
  paintOnboardSoon();
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
let boxSeenAt = 0;   // when it was read
let boxNow = null;   // the box `cg status` last reported, or null
let sessionNow = null; // a `cg open` streaming from this laptop, per cg status
let config = [];     // the settings registry, as `cg config --json` last gave it
let watcher = null;  // `cg watcher --json`, for the guard strip and the Guards screen
let statusBudget = null;
let costNow = null;  // the last paid cost fetch, if one was made in this window
let costNowAt = null;
let statusNow = null; // `cg status --json`, as last read
// `cg ping --json` - direct or relayed, and the latency - asked only while the
// machine is online, and at most once a minute: it is a local tailscale ping,
// free, but it takes a few seconds and means nothing with no machine.
let pingNow = null, pingAt = 0, pingBusy = false;
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
  const body = $('b-games');
  body.textContent = '';
  if (!(d.games || []).length) {
    const tr = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 4;
    td.className = 'py-space-md ' + (failed ? 'text-error' : 'text-outline');
    td.textContent = failed
      ? `The archive could not be read: ${d.error}`
      : 'No games are saved yet. The machine starts empty, and Steam installs games as usual.';
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

    cell('py-space-sm pr-space-md text-on-surface').textContent = g.name || g.installdir || g.appid;
    cell('py-space-sm px-space-md text-right text-on-surface-variant').textContent = GB(g.bytes);
    cell('py-space-sm pl-space-md text-right text-outline').textContent = savedOn(g.pushed);

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
  $('b-fit').textContent = 'Space on the machine';
  $('b-fit').className = 'font-code-sm text-code-sm text-outline';
  const pct = cap != null ? Math.min(100, (gb / cap) * 100) : 0;
  $('b-fit-pct').textContent = over ? `Too big by ${(gb - cap).toFixed(1)} GB - untick a game`
    : cap != null ? `${gb.toFixed(1)} of ${cap} GB`
    : picked.size ? `${gb.toFixed(1)} GB - the machine's space is not known yet` : '';
  $('b-fit-pct').className = 'font-code-sm text-code-sm ' + (over ? 'text-error' : 'text-on-surface-variant');
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
    ? 'A machine is already running. Its games were chosen when it was built.'
    : 'Downloaded from your archive while the machine starts.';
  // What pressing Build does to the bill, said beside the button.
  const rate = buildRate();
  $('b-chip').textContent = up
    ? `The machine is running${rate != null ? ` · ${rsh(rate)}/hour` : ''}.`
    : `Billing starts when the machine launches${rate != null ? ` · ${rsh(rate)}/hour` : ''}`
      + ` · ready in about 10–20 min${picked.size ? ', plus the game download' : ''}`;
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
function paintSweep(d) { sweepNow = d; sweepAnswered = true; paintChooser(); paintOnboardSoon(); paintDash(); }

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
  const price = (hit && (cur.spot ? hit.spot : hit.od)) ?? hourlyInr(cur.type, cur.spot);
  // The machine, once: what it is on one line, where and at what price on the next.
  const spec = (statusNow && statusNow.spec) || {};
  el.textContent = [cur.type,
    hit && hit.gpu ? `NVIDIA ${hit.gpu}${hit.vram ? `, ${hit.vram} GB` : ''}` : spec.gpu ? `NVIDIA ${spec.gpu}` : null,
    spec.vcpus ? `${spec.vcpus} CPUs` : null,
    spec.memory_mib ? `${Math.round(spec.memory_mib / 1024)} GB RAM` : null].filter(Boolean).join(' · ') || '—';
  $('b-pick-where').textContent = [cur.region ? placeName(cur.region) : null,
    cur.spot ? 'spot' : 'on demand', price != null ? `₹${price}/hour` : null].filter(Boolean).join(' · ');

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
function paintMachines(d) { machinesNow = d; machinesAnswered = true; paintChooser(); paintOnboardSoon(); paintDash(); paintFit(); }

function paintSpec(s) {
  const spec = s.spec || {};
  boxNow = s.box || null;
  boxSeenAt = Date.now();
  // The reads land in whatever order they finish, and whether a pick is allowed
  // at all depends on this one - so repaint the chooser once a box is known, or
  // a table that arrived first would stay selectable beside a running box.
  paintChooser();
  paintFit();
  paintRun();
}

// Numbered steps, the way cg reports them: the one running is marked, the ones
// before it carry how long they took. No timer - each event repaints.
let buildStarted = 0;
// How long a run is expected to take, in minutes, so the bar means something.
// Only `init` has a published estimate - the others finish when they finish, and
// a bar invented for them would be a number nobody measured.
const RUN_EXPECT = { init: 20 };
let buildSteps = 0;

// ── A run, as steps ─────────────────────────────────────────────────────────
//
// cg reports about twelve steps for a build, in its own words, and the box adds
// a dozen more of its own ("installing nvidia driver", "configuring headless X").
// Someone building a games machine needs eight, in plain words - so each step
// cg announces is placed in one of these, and only ever moves the run forwards.
// A step cg announces that matches none of them belongs to the one in progress,
// and shows as its current line. A delete or a session has no such list: each
// of cg's steps is its own row.
const BUILD_STEPS = [
  { doing: 'Checking your setup', done: 'Checked your setup', match: /cloud watchdog|preflight/i },
  { doing: 'Setting the budget alert', done: 'Budget alert set', match: /budget/i },
  { doing: 'Renting the machine', done: 'Machine rented', bills: true,
    match: /provisioning|launching|confirming what shutdown|starting the existing|reusing the existing/i },
  { doing: 'Connecting to Tailscale', done: 'Connected to Tailscale',
    match: /join the tailnet|on the tailnet|key expiry/i },
  { doing: 'Installing the software', done: 'Software installed', parts: true,
    match: /building the box|^installing|^installed |^configuring|^setting up|^disabling|nvidia/i },
  { doing: 'Downloading your games', done: 'Games downloaded', games: true, match: /finishing up|restor/i },
  { doing: 'Pairing Moonlight', done: 'Moonlight paired', match: /on-host watchdog|sunshine account|pairing/i },
  { doing: 'Starting Steam', done: 'Steam started', match: /waiting for steam/i },
];
// A session, as steps. `cg open` announces none - it prints lines, and under
// the app its waits print only once they are over ("waiting for sunshine ok") -
// so each step is closed by the line that says it is done.
const OPEN_STEPS = [
  { doing: 'Starting the machine', done: 'Machine on',
    end: /instance already running|^running after|waiting for tailscale|^\s*pong|\bvia\b/i },
  { doing: 'Connecting over Tailscale', done: 'Connected over Tailscale',
    end: /waiting for tailscale ok|tailscale is up|^\s*pong|\bvia\b/i },
  { doing: 'Waiting for Sunshine', done: 'Sunshine answered', end: /waiting for sunshine ok|sunshine is up|^disk:/i },
  { doing: 'Playing', done: 'Played', end: /session ended/i, stream: true,
    note: 'Close Moonlight to stop. You are then asked whether to keep the machine or delete it.' },
];
// What the machine installs, in the order it does it, each matched to the
// progress line the box prints when it starts that piece (lib/bootstrap.d).
// Shown as chips inside "Installing the software", ticked as the box moves on:
// the step installs far more than a driver, and said so in three words.
const BUILD_PARTS = [
  ['Base system', /^installing base packages/i],
  ['Game disk', /^setting up local nvme/i],
  ['Idle watchdog', /^installing the idle watchdog/i],
  ['Tailscale', /^installing tailscale/i],
  ['Game library', /^installing the s3 game library/i],
  ['Desktop', /^installing desktop/i],
  ['NVIDIA driver', /nvidia driver|nvidia-driver|nvidia drm/i],
  ['Display', /^configuring headless x/i],
  ['Autologin', /^configuring autologin/i],
  ['Steam', /^installing steam/i],
  ['Firefox', /^installing firefox/i],
  ['Audio', /^installing audio/i],
  ['Sunshine', /^installing sunshine/i],
];
// Each part: not started, started (the latest one to start is in progress), or
// done - because a later one has started, or the whole step has finished.
function partStates(lines, stepDone) {
  const firstAt = BUILD_PARTS.map(([, re]) => lines.findIndex(l => re.test(l)));
  const started = firstAt.map(i => i >= 0);
  const latest = firstAt.reduce((best, i, k) => (i > (best < 0 ? -1 : firstAt[best]) ? k : best), -1);
  return BUILD_PARTS.map(([name], k) => [name,
    stepDone ? 'done' : !started[k] ? 'waiting' : k === latest ? 'running' : 'done']);
}

// The run on screen: which kind, when it began, its steps and their lines, and
// how it ended. null while the Build screen is choosing what to build.
let run = null;
let builtOpen = false;
// The build that made the machine, and its full log: a session or a refused
// delete replaces the run, and afterwards the machine is still that build -
// "How it was built" and its log come back with it.
let lastBuild = null, lastBuildLog = '';   // whether "How it was built" is unfolded
const runRow = text => ({ name: text, start: Date.now(), end: null, lines: [], failed: false });
function runBegin(kind, opts = {}) {
  run = { kind, start: Date.now(), billFrom: null, state: 'running', idx: -1, steps: [],
          games: opts.games || 0, gamesGb: opts.gamesGb || 0, apps: opts.apps || 'none',
          rate: kind === 'init' ? buildRate() : null };
  if (kind === 'init') run.steps = BUILD_STEPS.map(() => null);
  if (kind === 'open') {
    run.steps = OPEN_STEPS.map(() => null);
    run.steps[0] = runRow('');
    run.idx = 0;
    // The machine has been billing since it launched, not since Play.
    const box = liveBox();
    run.billFrom = box && box.launched ? new Date(box.launched).getTime() : null;
    run.rate = buildRate();
  }
}
// A session's line: move past every step it says is over.
function openLine(text) {
  const last = OPEN_STEPS.reduce((k, d, i) => (d.end.test(text) ? i : k), -1);
  if (last < run.idx) return;
  const now = Date.now();
  for (let i = 0; i <= last; i++) {
    if (!run.steps[i]) run.steps[i] = { ...runRow(''), start: now };
    if (!run.steps[i].end) run.steps[i].end = now;
  }
  if (last === OPEN_STEPS.length - 1) { run.streamEnded = true; return; }
  run.steps[last + 1] = runRow('');
  run.idx = last + 1;
}
// A step cg announced: move to the step it belongs to, closing the ones before.
function runStep(text) {
  if (!run) return;
  const now = Date.now();
  // The stream has ended and "delete" was the answer: cg open hands over to
  // cg destroy in the same process, so the run becomes the delete.
  if (run.kind === 'open' && run.streamEnded) runBegin('destroy');
  if (run.kind === 'open') { runLine(text); return; }
  if (run.kind !== 'init') {
    if (run.idx >= 0) run.steps[run.idx].end = now;
    run.steps.push(runRow(text));
    run.idx = run.steps.length - 1;
    return;
  }
  const at = BUILD_STEPS.findIndex((d, i) => i >= Math.max(run.idx, 0) && d.match.test(text));
  if (at > run.idx) {
    for (let i = 0; i < at; i++) {
      if (!run.steps[i]) run.steps[i] = { ...runRow(''), start: now };
      if (!run.steps[i].end) run.steps[i].end = now;
    }
    run.steps[at] = runRow('');
    run.idx = at;
    // A step that was passed did not fail; whatever it said that sounded like
    // failure is not the headline of a later one.
    if (buildFailures.length) buildFailClear();
    // Billing starts with a machine that exists: when the renting step has
    // finished, counted from when it began. A rental that fails bills nothing.
    const rent = BUILD_STEPS.findIndex(d => d.bills);
    if (!run.billFrom && at > rent && run.steps[rent]) run.billFrom = run.steps[rent].start;
  }
  if (run.idx >= 0) run.steps[run.idx].lines.push(text);
}
function runLine(text) {
  if (!run || run.idx < 0 || !text) return;
  // The box reports its own progress as lines, not steps. Its last one, the
  // reboot that waits for the game download, is a step of its own here.
  if (run.kind === 'init' && /^finishing up/i.test(text)
      && run.idx < BUILD_STEPS.findIndex(d => d.games)) { runStep(text); return; }
  if (run.kind === 'open' && !run.streamEnded) openLine(text);
  const lines = run.steps[run.idx].lines;
  lines.push(text);
  if (lines.length > 400) lines.splice(0, lines.length - 400);
}
function runEnd(rc) {
  if (!run) return;
  const now = Date.now();
  run.state = rc === 0 ? 'done' : 'failed';
  run.ended = now;
  run.rc = rc;
  if (rc === 0) {
    run.steps = run.steps.map(x => x ? { ...x, end: x.end || now } : { ...runRow(''), start: now, end: now });
  } else if (run.idx >= 0) {
    run.steps[run.idx].failed = true;
    run.steps[run.idx].end = now;
  }
}

const mins = ms => { const m = Math.max(0, Math.round(ms / 60000)); return m < 1 ? 'under a minute' : `${m} min`; };
const took = (a, b) => { const s = Math.round((b - a) / 1000); return s < 60 ? `${s} s` : `${Math.round(s / 60)} min`; };

const RUN_HEAD = {
  init: { running: 'Building your machine', done: 'Ready to play', failed: 'The build stopped' },
  destroy: { running: 'Deleting the machine', done: 'Machine deleted', failed: 'The delete stopped' },
  open: { running: 'Starting the stream', done: 'Stream ended', failed: 'The stream stopped' },
  library: { running: 'Changing the archive', done: 'Archive changed', failed: 'The change stopped' },
};

// Which card the Build screen shows is decided by the machine, never by where
// you have been: the plan only when there is no machine, a run while one goes,
// and otherwise the machine itself. It used to be whatever `run` held, and
// "Back to dashboard" cleared that - so leaving and coming back swapped a
// finished build for the plan of a machine that already existed.
const liveBox = () => boxNow && boxNow.state !== 'terminated' ? boxNow : null;

// A finished run that the machine has moved past gives way to it.
function settleRun() {
  settleRunOnly();
  // Back to the machine: if this window built it, it is that build again.
  if (!run && lastBuild && liveBox()) {
    run = lastBuild;
    $('b-log').innerHTML = lastBuildLog;
    $('b-log-title').textContent = 'cg init';
  }
}
function settleRunOnly() {
  // A session you stopped is not a failure: it ends where any session does.
  if (run && run.kind === 'open' && run.rc === 130) { run = null; return; }
  if (!run || run.state !== 'done') return;
  if (run.kind === 'destroy') {
    lastBuild = null;
    // cg said the machine is gone; the status read that confirms it is still
    // on its way, and the plan should not wait for it.
    run = null;
    boxNow = null;
    paintFit();
  } else if (run.kind !== 'init') {
    run = null;                               // a stream ended: back to the machine
  } else if (!liveBox() && boxSeenAt > (run.ended || Infinity)) {
    // Built, and gone since (idle, reclaimed) - by a read taken after the
    // build ended, not one from before the machine existed.
    run = null;
    lastBuild = null;
  }
}

// The machine, when no run is in memory - the app was reopened, or a stream
// has ended. A machine that exists is shown as one, never as a plan.
function machineCard() {
  const box = liveBox();
  if (!box) return null;
  const t = box.launched ? new Date(box.launched).getTime() : null;
  return { kind: 'machine', state: 'done', start: t || Date.now(), billFrom: t, steps: [], idx: -1,
           rate: buildRate(), games: 0, gamesGb: 0, apps: 'none' };
}

// What a machine is doing, as the heading of its card.
function machineTitle() {
  const box = liveBox();
  if (sessionNow) return 'Playing';
  if (!box || box.state === 'running') return 'Ready to play';
  if (box.state === 'pending') return 'Starting up';
  return `Machine ${box.state}`;
}

function paintBuildMode() {
  settleRun();
  const card = !!(run || liveBox());
  $('b-plan').hidden = card;
  $('b-strip').hidden = !card;
}

// Cancel a build: stop cg, then delete whatever it rented. The delete runs
// even when no machine has been seen yet - the launch may have gone through
// before the status caught up, and a delete with nothing to delete is quick
// and free. --no-push: a half-built machine holds nothing worth saving.
async function cancelBuild() {
  const ok = await askConfirm({
    title: 'Cancel the build?',
    body: 'The machine is deleted and billing stops. Your saved games are not touched.',
    yes: 'Cancel the build', no: 'Keep building', danger: true,
  });
  if (!ok || !run || run.kind !== 'init' || run.state !== 'running') return;
  run.cancelling = true;
  paintRun();
  for (const [id, j] of jobs) if (j.cmd[0] === 'init') window.cg.cancel(id);
}

function paintRun() {
  paintBuildMode();
  const r = run || machineCard();
  if (!r) return;
  const head = RUN_HEAD[r.kind] || { running: 'Running', done: 'Done', failed: 'Stopped' };
  const machine = r.state === 'done' && (r.kind === 'init' || r.kind === 'machine');
  const now = r.state === 'running' ? Date.now() : (r.steps.reduce((t, x) => Math.max(t, x && x.end || 0), 0) || Date.now());
  const title = $('b-strip-title');
  title.textContent = r.cancelling ? 'Cancelling the build' : machine ? machineTitle()
    : r.kind === 'open' && r.state === 'running' && OPEN_STEPS[r.idx] && OPEN_STEPS[r.idx].stream
      ? (r.streamEnded ? 'Stream ended' : 'Playing') : head[r.state];
  title.className = 'font-headline-md text-headline-md ' + (r.state === 'failed' ? 'text-error' : '');
  // The bill, in the heading, from the moment the machine is rented.
  const so = r.billFrom && r.rate != null ? r.rate * ((machine ? Date.now() : now) - r.billFrom) / 3600000 : null;
  $('b-strip-meta').textContent = [
    r.state === 'running' ? mins(now - r.start) : r.kind === 'machine' ? `up ${mins(now - r.start)}`
      : r.state === 'done' && r.kind === 'init' ? `built in ${mins(now - r.start)}` : null,
    so != null ? `${rs(so)} so far` : r.kind === 'init' && r.state === 'failed' ? 'Nothing was billed' : null,
    r.billFrom && r.rate != null ? `${rsh(r.rate)}/hour` : null,
  ].filter(Boolean).join(' · ');
  const s = statusNow || {};
  $('b-run-sum').textContent = r.kind === 'init' || r.kind === 'machine' || r.kind === 'open'
    ? [r.kind !== 'init' && liveBox() ? liveBox().type : s.instance_type, s.region ? placeName(s.region) : null,
       (r.kind !== 'init' && liveBox() ? liveBox().lifecycle !== 'spot' : (s.config || {}).spot === '0') ? 'on demand' : 'spot',
       r.kind !== 'init' ? null
         : r.games ? `${r.games} game${r.games === 1 ? '' : 's'}, ${r.gamesGb.toFixed(1)} GB` : 'no games']
        .filter(Boolean).join(' · ')
    : '';
  $('b-run-sum').hidden = !$('b-run-sum').textContent;
  // Time against the usual length, and only while it runs.
  const expect = RUN_EXPECT[r.kind];
  $('b-bar-track').hidden = !(r.state === 'running' && expect);
  if (expect) $('b-prog').style.width = `${Math.min(95, ((now - r.start) / 60000 / expect) * 100).toFixed(1)}%`;

  const wrap = $('b-steps');
  // The failure panel is drawn into the failed step; park it before the rows go.
  const fail = $('b-fail');
  $('b-strip').insertBefore(fail, $('b-run-acts'));
  // A machine found already running has no run behind it, so no log either.
  $('b-logbox').hidden = r.kind === 'machine';
  if (r.state === 'running' || machine || r.cancelling) fail.classList.add('hidden');
  else if (buildFailures.length) fail.classList.remove('hidden');
  wrap.textContent = '';
  const defs = r.kind === 'init' ? BUILD_STEPS : r.kind === 'open' ? OPEN_STEPS : null;
  const rows = defs
    ? defs.map((d, i) => ({ def: d, st: r.steps[i] }))
    : r.steps.map(st => ({ def: null, st }));
  rows.forEach(({ def, st }, i) => {
    const state = !st ? (r.state === 'running' ? 'locked' : 'skipped')
      : st.failed ? 'failed' : st.end ? 'done' : 'running';
    const row = document.createElement('div');
    row.className = 'flex gap-space-md items-stretch';
    row.dataset.step = def ? String(i) : st.name;
    row.dataset.state = state;
    const rail = document.createElement('div');
    rail.className = 'flex flex-col items-center shrink-0 w-5';
    const [mark, cls] = { done: ['✓', 'text-primary'], running: ['●', 'text-tertiary animate-pulse'],
                          failed: ['✗', 'text-error'], locked: ['○', 'text-outline-variant'],
                          skipped: ['○', 'text-outline-variant'] }[state];
    rail.append(Object.assign(document.createElement('span'),
      { className: 'font-code-md text-code-md leading-6 ' + cls, textContent: mark }));
    if (i < rows.length - 1) {
      rail.append(Object.assign(document.createElement('div'), {
        className: 'w-px flex-1 min-h-[12px] my-1 ' + (state === 'done' ? 'bg-primary/70' : 'bg-surface-variant') }));
    }
    const body = document.createElement('div');
    body.className = 'min-w-0 flex-1 ' + (state === 'running' || state === 'failed' ? 'pb-space-lg' : 'pb-space-sm');
    const top = document.createElement('div');
    top.className = 'flex items-baseline justify-between gap-space-sm';
    let name = def ? (state === 'done' ? def.done : def.doing) : st.name;
    if (def && def.games) {
      name = !r.games ? (state === 'done' ? 'Restarted into the desktop' : 'Restarting into the desktop')
        : state === 'done' ? name : `${name} · ${r.gamesGb.toFixed(1)} GB`;
    }
    if (def && def.bills && state === 'done' && r.billFrom) {
      name += ` · billing from ${new Date(r.billFrom).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    }
    top.append(Object.assign(document.createElement('span'), {
      className: 'leading-6 font-body-md text-body-md ' + (state === 'done' ? 'text-on-surface-variant'
        : state === 'locked' || state === 'skipped' ? 'text-outline'
        : state === 'failed' ? 'text-error font-medium' : 'text-on-surface font-medium'),
      textContent: name }));
    const meta = state === 'done' && st.start && st.end ? took(st.start, st.end)
      : state === 'running' ? took(st.start, Date.now()) : state === 'failed' ? 'failed' : '';
    if (meta) top.append(Object.assign(document.createElement('span'), {
      className: 'font-code-sm text-code-sm shrink-0 ' + (state === 'failed' ? 'text-error' : 'text-outline'),
      textContent: meta }));
    body.append(top);
    if (def && def.note && state === 'running') {
      body.append(Object.assign(document.createElement('p'), {
        className: 'font-code-sm text-code-sm text-outline mt-0.5', textContent: def.note }));
    }
    if (def && def.parts && st && (state === 'running' || state === 'failed')) {
      const chips = document.createElement('div');
      chips.className = 'flex flex-wrap gap-space-xs mt-space-sm';
      chips.id = 'b-parts';
      for (const [part, ps] of partStates(st.lines, false)) {
        chips.append(Object.assign(document.createElement('span'), {
          className: 'pill ' + (ps === 'done' ? 'pill-ok' : ps === 'running' ? 'pill-warn' : ''),
          textContent: ({ done: '\u2713 ', running: '\u25cf ', waiting: '\u2026 ' })[ps] + part }));
        chips.lastChild.dataset.part = part;
        chips.lastChild.dataset.state = ps;
      }
      body.append(chips);
    }
    // Playing is not a wait: no progress sweep, and no echo of cg's last line.
    if (state === 'running' && !(def && def.stream)) {
      const last = [...st.lines].reverse().find(Boolean);
      if (last) body.append(Object.assign(document.createElement('p'),
        { className: 'font-code-sm text-code-sm text-on-surface-variant truncate mt-0.5', textContent: last }));
      const sweep = document.createElement('div');
      sweep.className = 'onb-progress mt-space-xs';
      sweep.append(document.createElement('i'));
      body.append(sweep);
    }
    if (state === 'failed') body.append(fail);
    // A failed step shows cg's words once, in the failure above - not again here.
    if (st && st.lines.length && state !== 'locked' && state !== 'failed') {
      // This step's own lines, folded - opened by itself when it failed.
      const det = document.createElement('details');
      det.className = 'mt-space-xs';
      det.open = st.open != null ? st.open : state === 'failed';
      det.ontoggle = () => { st.open = det.open; };
      det.append(Object.assign(document.createElement('summary'), {
        className: 'font-code-sm text-code-sm text-outline cursor-pointer',
        textContent: `Details · ${st.lines.length} line${st.lines.length === 1 ? '' : 's'}` }));
      const pre = document.createElement('pre');
      pre.className = 'font-code-sm text-code-sm text-on-surface-variant whitespace-pre-wrap break-words '
        + 'max-h-[32vh] overflow-auto mt-space-xs p-space-sm rounded bg-surface-container-lowest '
        + 'border border-surface-variant';
      pre.textContent = st.lines.join('\n');
      det.append(pre);
      body.append(det);
      if (det.open) pre.scrollTop = pre.scrollHeight;
    }
    row.append(rail, body);
    wrap.append(row);
  });
  // A finished build is the machine now; how it was built folds away under it.
  if (r.kind === 'init' && r.state === 'done') {
    const det = document.createElement('details');
    det.open = builtOpen;
    det.ontoggle = () => { builtOpen = det.open; };
    det.append(Object.assign(document.createElement('summary'), {
      className: 'font-code-sm text-code-sm text-outline cursor-pointer mb-space-sm',
      textContent: `How it was built · ${mins(now - r.start)}` }), ...wrap.children);
    wrap.append(det);
  }

  // What to do now, by how it ended.
  const acts = $('b-run-acts');
  acts.textContent = '';
  const btn = (label, go, primary) => {
    const b = document.createElement('button');
    b.className = 'btn' + (primary ? ' btn-primary' : '');
    b.textContent = label;
    b.onclick = go;
    acts.append(b);
  };
  if (r.state === 'running' && r.kind === 'init') {
    btn(r.cancelling ? 'Cancelling…' : 'Cancel', cancelBuild);
    acts.lastChild.disabled = !!r.cancelling;
  } else if (machine) {
    const box = liveBox();
    // Just built, the status may not have read the machine yet: it is there.
    if (!sessionNow && (box ? box.state === 'running' : r.kind === 'init')) btn('▶ Play', play, true);
    btn('Delete machine', () => $('d-destroy').onclick());
    acts.lastChild.classList.add('btn-danger');
  } else if (r.state === 'failed' && r.kind === 'init') {
    btn('Try again', () => retryBuild(), true);
    btn('Close', () => { run = null; paintRun(); });
  } else if (r.state !== 'running') {
    btn('Done', () => { run = null; paintRun(); });
  }
}

// The durations and the bill move with cg's own lines - a build reports at
// least every ten seconds - so nothing here runs on a timer.

// The live line and step heading for runs, now that the strip has no line of
// its own: kept as functions because the event handler calls them.
function buildStep(text) {
  const log = $('b-log');
  if (log.dataset.fresh !== 'no') { log.textContent = ''; log.dataset.fresh = 'no'; buildStarted = Date.now(); }
  buildSteps += 1;
  const head = document.createElement('div');
  head.className = 'step flex items-baseline gap-space-sm pt-space-sm first:pt-0';
  const label = document.createElement('span');
  label.className = 'text-on-surface';
  label.textContent = text;
  const meta = document.createElement('span');
  meta.className = 'meta ml-auto pl-space-sm text-outline shrink-0';
  head.append(label, meta);
  log.append(head);
  $('b-prog-step').textContent = text;
  runStep(text);
  paintRun();
  if ($('b-follow').checked) log.scrollTop = log.scrollHeight;
}

// cg times every step; the transcript keeps how long each took.
function buildStepEnd(event) {
  const heads = $('b-log').querySelectorAll('.step');
  const last = heads[heads.length - 1];
  if (!last) return;
  const meta = last.querySelector('.meta');
  const ok = !event.rc;
  meta.textContent = event.secs != null ? `${Math.round(event.secs)}s` : (ok ? 'ok' : `exit ${event.rc}`);
  if (!ok) meta.classList.add('text-error');
}

function paintProgress() { paintRun(); }
function buildProgressDone(rc) {
  const cancelled = run && run.kind === 'init' && run.cancelling;
  runEnd(rc);
  if (run && run.kind === 'init' && run.state === 'done') { lastBuild = run; lastBuildLog = $('b-log').innerHTML; }
  paintRun();
  // After the exit has been handled, so the init job is gone when the delete starts.
  if (cancelled) Promise.resolve().then(() => startRun(['destroy', '--no-push']));
}
function paintElapsed() { paintRun(); }

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
  // Spot ran out. Full price, another location and another machine were all
  // offered here, and three ways out of one failure was more confusing than
  // helpful: the machine picker shows price and place together, so it is the
  // one choice. Try again sits beside it, for capacity that comes back.
  InsufficientInstanceCapacity: () => [['Pick another machine', () => goSetting($('s-machine-card'))]],
  SpotMaxPriceTooLow: (spot) => FAIL_ACTS.InsufficientInstanceCapacity(spot),
  // Try again is already beside the step; nothing more to offer.
  MaxSpotInstanceCountExceeded: () => [],
  VcpuLimitExceeded: () => [['Ask AWS for GPU quota', () => openQuota()]],
  InstanceLimitExceeded: () => [['Ask AWS for GPU quota', () => openQuota()]],
  'InvalidKeyPair.NotFound': () => [
    ['Run the preflight fix', () => runCg(['check', '--fix'])],
  ],
  OptInRequired: () => [['Open Dependencies', () => goView('deps')]],
  AuthFailure: () => [['Connect Amazon again', () => openAwsKey()]],
  UnauthorizedOperation: () => [['Connect Amazon again', () => openAwsKey()]],
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
  // Noted, not believed: a step is failed only when the run ends in failure.
  // cg reads "cannot" in a line as a failure, and the box's own healthy
  // progress said "NvFBC cannot capture" - the driver step went red while the
  // build carried on installing Steam.
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
  $('b-bar-track').hidden = true;
  paintRun();
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
  runLine(event.text);
  paintRun();
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
      buildProgressDone(event.rc);
      // A nonzero exit with nothing marked is still a failure, and saying so
      // beats a bare status label the eye slides over.
      if (event.rc !== 0 && !buildFailures.length && !(run && run.cancelling)
          && !(job.cmd[0] === 'open' && event.rc === 130))
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
  if (job.collect === runSurface.log && event.text) watchForSignInLink(event.text);
  if (job.collect && (event.t === 'line' || event.t === 'step' || event.t === 'error'
                      || event.t === 'raw')) {
    const box = $(job.collect);
    if (box.textContent === 'running…' || box.dataset.fresh === 'yes') {
      box.textContent = '';
      delete box.dataset.fresh;
    }
    // Measured BEFORE the line is added, because appending to a box that is
    // already scrolled to the bottom moves the bottom away from you.
    //
    // Only if that is where you already were: an install prints for minutes,
    // and yanking the view back down while someone is reading up the log is
    // worse than not following at all. The build's transcript has a checkbox
    // for the same decision - this is the small version of it.
    const following = box.scrollHeight - box.scrollTop - box.clientHeight < 24;
    box.textContent += (event.t === 'step' ? '\n' + event.text : '  ' + (event.text || '')) + '\n';
    if (following) box.scrollTop = box.scrollHeight;
    if (box.id.startsWith('onb-log-')) onbLogGrew(box, event.text);
  }
  if (event.t === 'exit') {
    // Why the reason is KEPT rather than printed somewhere here: it used to be
    // written to a line in the header that updateHeader() rewrites a few lines
    // below, in the same tick - so a failing painter was completely silent, the
    // screen stayed empty, and the only clue was that nothing ever appeared.
    // Now it is held in readFailures and the screens read it from there.
    let failure = null, painted = null;
    if (job.json && job.out.length) {
      try {
        const data = JSON.parse(job.out.join('\n'));
        painted = data;
        const paint = { cost: paintCost, library: paintLibrary, guards: paintGuards,
                        config: paintConfig, status: paintStatus, machines: paintMachines,
                        sweep: paintSweep, creds: paintCreds, deps: paintDeps,
                        tskey: paintTskey, ping: paintPing }[job.json];
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
    // Not every painter repaints the pipeline, and the opening list is a line
    // per read: it ticks as each one lands, not all at once at the end.
    if (job.json && readingBehindGate) paintOnboardSoon();
    // The read that judges a step that has just been done: it has answered, so
    // the step shows what it says - ticked, or back to what is still missing.
    if (onbVerifying && job.json && onbPending.has(job.json)) {
      onbPending.delete(job.json);
      if (!onbPending.size) onbVerified();
    }
    // A gate read that has just cleared the last blocking stage - see gateShut.
    if (gateShut && GATE_READS.some(([, j]) => j === job.json)) gateMayOpen();
    // A build, a destroy or a session changes what every free screen shows -
    // the box, the archive, the guards - so read them again once it is over.
    if (job.write) {
      note(`${cgName(job.cmd)} ${event.rc === 0 ? 'finished' : `stopped (exit ${event.rc})`}`,
           event.rc === 0 ? 'text-primary' : 'text-error');
      afterWrite(job);
    }
    if (job.resolve) job.resolve(job.wantRc ? { rc: event.rc, err: job.collected || '' }
                                 : job.capture ? job.out.join('\n') : undefined);
  }
});

// `group` names a run by what started it rather than by what it is: one click on
// Refresh is several reads, and naming them each made the Build screen offer to
// "Stop 2 runs" for a click that was one.
function runCg(args, { panel, age, json, env, collect, capture, wantRc, onStart, group } = {}) {
  return new Promise(async resolve => {
    const res = await window.cg.run(args, env);
    if (!res.ok) {
      const why = `${cgName(res.args)} is still running - this has to wait for it`;
      if (collect) $(collect).textContent = why + '\n';
      if (panel) $(panel).textContent = why;
      return resolve(wantRc ? { rc: null, err: why } : undefined);
    }
    jobs.set(res.id, { cmd: args, view, panel, age, json, collect, capture, wantRc, group,
                      // cg's verdict, not a second guess at it.
                      write: !!res.write,
                      out: [], collected: '', resolve });
    if (onStart) onStart(res.id);
    if (res.write) note(`${cgName(args)} started`, 'text-primary');
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

// What a screen reads when it refreshes. Cost is not in NEEDS, so opening that
// tab fetches nothing: it bills, and only its Refresh asks.
const readsFor = v => (v === 'cost' ? [[['cost', '--json'], 'cost']] : NEEDS[v]);
async function refresh(each, need = readsFor(view)) {
  if (!need) return;               // logs need nothing
  if (view !== 'cost') loaded.add(view);
  await Promise.all(need.map(([args, json]) =>
    runCg(args, view === 'cost' ? { json } : { json, group: 'refresh' }).then(() => each && each(json))));
}

// Each read, in the words the page uses for what it shows.
const READ_NAME = {
  status: 'Your machine and the bill', guards: 'Protection', library: 'Your saved games',
  machines: 'Machines and prices', sweep: 'Locations', config: 'Settings',
  creds: 'Amazon key', tskey: 'Tailscale', deps: 'Tools on this laptop', cost: 'Exact cost this month',
};
// The top Refresh, as a popup: what is being read, each ticking as it lands,
// closed once the page has been redrawn. A read that failed keeps it open with
// the reason, because a popup that vanished would say it all worked.
async function refreshShown(reads = readsFor(view), read = each => refresh(each, reads)) {
  if (!reads) return;
  const dlg = $('refdlg');
  const state = new Map(reads.map(([, json]) => [json, 'reading']));
  $('refdlg-title').textContent = `Refreshing ${$('view-title').textContent.trim()}`;
  const price = $('d-cost-price').textContent;
  $('refdlg-sub').textContent = view === 'cost'
    ? `One Cost Explorer call${price ? `, ${price}` : ''}.`
    : 'Reading the latest from AWS and this laptop. This costs nothing.';
  $('refdlg-menu').hidden = true;
  const paint = () => {
    const list = $('refdlg-list');
    list.textContent = '';
    for (const [json, st] of state) {
      const row = document.createElement('div');
      row.className = 'flex items-start gap-space-sm font-body-md text-body-md';
      row.dataset.read = json;
      row.dataset.state = st;
      row.append(st === 'reading'
        ? Object.assign(document.createElement('span'), { className: 'spinner mt-0.5' })
        : Object.assign(document.createElement('span'), {
            className: 'w-4 text-center font-code-md text-code-md ' + (st === 'done' ? 'text-primary' : 'text-error'),
            textContent: st === 'done' ? '✓' : '✗' }));
      const text = document.createElement('div');
      text.className = 'min-w-0';
      text.append(Object.assign(document.createElement('div'), { textContent: READ_NAME[json] || json }));
      if (st === 'failed') text.append(Object.assign(document.createElement('div'), {
        className: 'font-code-sm text-code-sm text-on-surface-variant break-words',
        textContent: readFailures.get(json) || 'could not be read' }));
      row.append(text);
      list.append(row);
    }
  };
  paint();
  if (!dlg.open) dlg.showModal();
  await read(json => { state.set(json, readFailures.has(json) ? 'failed' : 'done'); paint(); });
  // A read the gate held back was never asked: it is not news either way.
  for (const [json, st] of state) if (st === 'reading') state.delete(json);
  paint();
  if ([...state.values()].every(s => s === 'done')) { dlg.close(); return; }
  $('refdlg-sub').textContent = 'Some of it could not be read. The page shows what was.';
  $('refdlg-menu').hidden = false;
  $('refdlg-close').focus();
}
// A build, a delete, a session or an archive change alters what the page shows,
// so the page you are on is read again with the popup up - "Stream ended"
// visibly becoming "Ready to play" - and every other screen quietly behind it.
// Not a settings save: those happen a field at a time.
const SHOWN_AFTER = new Set(['init', 'destroy', 'open', 'library']);
// One round of reads, all of them, with the popup up until the last has landed -
// not the page's reads under the popup and then the rest after it had gone.
function afterWrite(job) {
  // A cancelled build goes straight on to its delete; the read waits for that.
  if (!SHOWN_AFTER.has(job.cmd[0]) || (run && run.cancelling)) return refreshAll();
  return refreshShown([...GATE_READS, ...ALL_READS], each => refreshAll(each));
}
$('refdlg-close').onclick = e => { e.preventDefault(); $('refdlg').close(); };
// Esc does not close it: it closes itself when the page is redrawn, and a
// failure is closed with its button. Both, because Chromium honours a
// prevented cancel only once per user activation - a second Esc would close it
// anyway - while a prevented keydown never becomes a close request at all.
$('refdlg').oncancel = e => e.preventDefault();
$('refdlg').addEventListener('keydown', e => { if (e.key === 'Escape') e.preventDefault(); });

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
// What is wrong with the key, which is cg's answer and not a guess from an
// error string: a laptop with no network was told "AWS rejected this access
// key", which is a lie about a call that never arrived, and sent people to
// replace a key that was fine. See creds_json in lib/laptop.sh.
//
// An older cg sends no reason at all, and a rejection is what this said before
// and what nearly all of them are, so that is where it falls back to.
function keyProblem() {
  switch (credsNow && credsNow.reason) {
    case 'unreachable':
      return { title: 'This laptop could not reach AWS',
               body: 'Nothing was rejected - the call never arrived. The key may be fine.',
               label: 'Try again', go: retryReads };
    case 'no-key':
      return { title: 'There is no AWS access key on this laptop',
               body: 'Everything below is unknown, not empty.',
               label: 'Add your key', go: () => goSetting($('s-creds-card')) };
    default:
      return { title: 'AWS rejected this access key',
               body: 'Everything below is unknown, not empty.',
               label: 'Add your key', go: () => goSetting($('s-creds-card')) };
  }
}

// The done line for the region stage, which names the place rather than the
// setting: "ap-south-2" means nothing to someone who has not read .env.
function whereDone() {
  if (!machinesNow) return 'Location';
  const city = ((sweepNow && sweepNow.regions) || [])
    .find(r => r.region === machinesNow.region);
  return city && city.city ? `Runs in ${shortCity(city.city)}` : `Runs in ${machinesNow.region}`;
}

// Whether a region is written in .env - chosen - as against cg's default.
const regionChosen = () => {
  const r = (config || []).find(x => x.key === 'GAME_REGION');
  return !!(r && r.is_set);
};

function prereqs() {
  const missing = depsNow ? (depsNow.tools || []).filter(x => !x.present).map(x => x.label) : [];
  const email = (config || []).find(r => r.key === 'EMAIL_ALERTS');
  return [
    // Installed is not enough for the AWS CLI: it also has to run, which only
    // cg creds can say. Both answers decide this one step - the pipeline used
    // to show the second as a row of its own, also called Tools, that came and
    // went as the two answers landed a second apart.
    { key: 'tools', reads: 'deps', name: 'The tools this rig needs are installed',
      ok: depsNow ? !missing.length && !cliBroken() : null,
      problem: { blocking: true,
                 title: `${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} not installed`,
                 body: 'Nothing here can run without them.',
                 label: 'Open Dependencies', go: () => goView('deps') } },
    { key: 'cli', reads: 'creds', name: 'The AWS CLI is installed',
      // Shown only when the tools stage is happy: when it is not, this is the
      // same missing package and the same button, one row further down.
      sameAs: 'tools',
      ok: credsNow ? !!credsNow.cli : null,
      problem: { blocking: true, title: 'The AWS CLI is not installed',
                 body: 'Everything below is unknown, not empty.',
                 label: 'Open Dependencies', go: () => goView('deps') } },
    // Judged only once there is a CLI to ask with: "AWS rejected this key" is a
    // lie about a laptop that could not ask AWS anything.
    { key: 'key', reads: 'creds', name: 'Amazon accepts this access key',
      ok: !credsNow ? null : credsNow.cli ? credsNow.valid === true : null,
      problem: { blocking: true, ...keyProblem() } },
    { key: 'tailnet', reads: 'tskey', name: 'This laptop is signed in to Tailscale',
      // Only a clear yes. cg says null when it cannot tell - Tailscale is not
      // installed - and "not false" read that as signed in: an empty laptop
      // showed this step ticked before it had Tailscale at all.
      ok: tskeyNow ? tskeyNow.signed_in === true : null,
      problem: { blocking: true, title: 'This laptop is not signed in to Tailscale',
                 body: 'The box has no public SSH port, so nothing here can reach it.',
                 label: 'Sign in', go: signInTailscale } },
    { key: 'authkey', reads: 'tskey', name: 'The box has a key to join your tailnet with',
      ok: tskeyNow ? !!(tskeyNow.auth_key_stored || tskeyNow.can_mint) : null,
      problem: { blocking: true, title: 'The box has no Tailscale auth key',
                 body: 'A build cannot join it to your tailnet without one.',
                 label: 'Paste a key', go: setAuthKey } },
    { key: 'email', reads: 'config', name: 'Billing alerts have somewhere to go',
      ok: email ? !!email.is_set : null,
      problem: { blocking: true, title: 'No address for billing alerts',
                 body: 'A build sets a budget alarm and needs somewhere to send it.',
                 label: 'Add an address', go: () => goSetting(settingEl('EMAIL_ALERTS')) } },
    { key: 'where', reads: 'machines', name: whereDone(),
      // Not "did you click a button": whether the region .env names can rent
      // the machine it names. A laptop pointed at a region with no GPU quota
      // looks completely set up and cannot build - which is exactly how an
      // enabled-but-empty Malaysia read as a broken app.
      //
      // And not cg's default either: a region nobody chose is not a choice.
      // On a fresh laptop .env names no region, cg falls back to ap-south-2,
      // that happens to rent the machine - and the stage ticked itself, so the
      // pipeline finished and handed over without ever showing the list. The
      // popup IS this stage; it is skipped only once a region has been
      // written to .env, by it or by Settings.
      //
      // Still judged only once `cg machines` has answered, never before: it is
      // one of the reads behind the gate, and a stage that could shut the gate
      // on the reads it needs would wait for ever.
      ok: !machinesNow ? null
        : regionChosen()
          && !machinesNow.error && (machinesNow.machines || []).some(m => m.fits_spot || m.fits_ondemand),
      problem: regionChosen()
        ? { blocking: true,
            title: machinesNow ? `${machinesNow.region} cannot rent this machine` : 'Nowhere to run it yet',
            body: 'Either AWS gives you no GPU quota there, or none of its machines fit. '
                + 'Closer is smoother, and measuring every location is free.',
            label: 'Choose where', go: openWhereTo }
        : { blocking: true, title: 'Pick where it runs',
            body: 'Closer is smoother. This measures every Amazon location from here - free, '
                + 'about 90 seconds.',
            label: 'Choose where', go: openWhereTo } },
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

// Where it runs. A dialog, because changing it later is this same question
// asked again - and because it is a choice, which is what a dialog is for.
//
// Every number in it is cg's: the latency it measured, the rupee rates it
// converted, and whether AWS will actually let you launch there. The app adds
// nothing but the radio buttons.
let whereToPick = null;
function openWhereTo() {
  whereToPick = machinesNow ? machinesNow.region : null;
  paintWhereTo();
  if (!$('whereto').open) $('whereto').showModal();
  // Nothing measured yet: measure, since the dialog is useless without it and
  // the measuring is free.
  if (!sweepNow || !(sweepNow.regions || []).length) whereToMeasure();
}
// The dialog follows every scan, whoever started it.
const repaintWhereTo = () => { if ($('whereto').open) paintWhereTo(); };

function whereToRows() {
  const regions = (sweepNow && sweepNow.regions) || [];
  return regions.map(r => {
    const fits = (r.machines || []).filter(m => m.fits_spot || m.fits_ondemand);
    const best = fits.slice().sort((a, b) => (a.inr_hour_spot || 1e9) - (b.inr_hour_spot || 1e9))[0];
    return { region: r.region, city: shortCity(r.city), rtt: r.rtt_ms, enabled: r.enabled,
             spot: best ? best.inr_hour_spot : null, od: best ? best.inr_hour_ondemand : null,
             type: best ? best.type : null, usable: !!best };
  }).sort((a, b) => (a.rtt == null) - (b.rtt == null) || (a.rtt || 0) - (b.rtt || 0));
}

function paintWhereTo() {
  const table = $('whereto-table');
  table.textContent = '';
  const rows = whereToRows();
  const head = document.createElement('tr');
  for (const h of ['', 'place', 'delay', 'machine', 'spot', 'on demand']) {
    const th = document.createElement('th');
    th.textContent = h;
    head.append(th);
  }
  table.append(head);
  for (const r of rows) {
    const tr = document.createElement('tr');
    tr.dataset.region = r.region;
    tr.dataset.usable = r.usable ? 'yes' : 'no';
    if (!r.usable) tr.className = 'dim';
    const pick = document.createElement('td');
    const label = document.createElement('label');
    label.className = 'pick' + (r.usable ? (whereToPick === r.region ? ' on' : '') : ' off');
    const radio = document.createElement('input');
    radio.type = 'radio';
    radio.name = 'whereto';
    radio.value = r.region;
    radio.checked = whereToPick === r.region;
    radio.disabled = !r.usable;
    radio.onchange = () => { whereToPick = r.region; paintWhereTo(); };
    label.append(radio);
    pick.append(label);
    const city = document.createElement('td');
    city.className = 'city';
    city.textContent = r.city || r.region;
    const ms = document.createElement('td');
    ms.className = 'ms num';
    ms.textContent = r.rtt != null ? `${Math.round(r.rtt)} ms` : '—';
    const type = document.createElement('td');
    type.className = 'region';
    // Why it cannot be used, where the machine would go: an enabled region
    // with no GPU quota is the one that reads as a broken app.
    type.textContent = r.type || (r.enabled ? 'no GPU quota here yet' : 'not switched on yet');
    const spot = document.createElement('td');
    spot.className = 'num';
    spot.textContent = r.spot != null ? `\u20b9${r.spot}/hr` : '—';
    const od = document.createElement('td');
    od.className = 'num';
    od.textContent = r.od != null ? `\u20b9${r.od}/hr` : '—';
    tr.append(pick, city, ms, type, spot, od);
    table.append(tr);
  }
  const usable = rows.filter(r => r.usable).length;
  $('whereto-sub').textContent = rows.length
    ? `Measured from this laptop \u00b7 ${usable} of ${rows.length} can run your machine`
    : 'Nearer means lower latency.';
  $('whereto-note').textContent = rows.length && !usable
    ? 'None of them can yet. A region starts with no GPU quota and the request is free - '
      + 'Settings has it.'
    : '';
  $('whereto-use').disabled = !whereToPick || !rows.some(r => r.region === whereToPick && r.usable);
  // The button names the place, so what it does is never in doubt.
  $('whereto-use').textContent = whereToPick ? `Use ${placeName(whereToPick)}` : 'Use it';

  // Three ways for there to be nothing to list, and each says which it is:
  // still measuring, the measurement failed, or nothing answered.
  const failed = !sweeping && !rows.length && readFailures.has('sweep');
  // Measuring shows the spinner whether or not there is a table yet. Measuring
  // AGAIN used to change one grey line of text and nothing else, so pressing
  // the button looked like it had done nothing: the old table stays, faded and
  // out of reach, under a spinner, until the new numbers replace it.
  $('whereto-busy').hidden = !sweeping;
  $('whereto-busy-text').textContent = rows.length
    ? 'Measuring again from this laptop. About 90 seconds.'
    : 'Measuring every AWS location from this laptop. About 90 seconds, and free.';
  $('whereto-list').hidden = !rows.length;
  $('whereto-list').classList.toggle('stale', sweeping);
  $('whereto-err').hidden = sweeping || rows.length > 0;
  $('whereto-err').textContent = failed
    ? `The measurement did not finish: ${readFailures.get('sweep')}`
    : 'No AWS location answered from this laptop. Check the internet connection and try again.';
  if (sweeping) $('whereto-sub').textContent = 'Nearer means lower latency.';
  $('whereto-measure').hidden = sweeping;
  $('whereto-measure').textContent = rows.length ? 'Measure again' : 'Try again';
  $('whereto-use').hidden = !rows.length || sweeping;
}

// One measurement at a time: the app starts one by itself on a laptop that has
// never measured, and this used to start a second on top of it.
function whereToMeasure() {
  if (sweeping) return paintWhereTo();
  return scanRegions(null);
}
$('whereto-measure').onclick = e => { e.preventDefault(); whereToMeasure(); };
$('whereto-cancel').onclick = e => { e.preventDefault(); $('whereto').close(); };
$('whereto-use').onclick = async e => {
  e.preventDefault();
  const code = whereToPick;
  $('whereto').close();
  // cg owns the setting and its rules - the app does not write .env.
  const ok = await runInPipeline('where', ['config', 'set', 'GAME_REGION', code],
                                 `Saving ${placeName(code)}\u2026`);
  // `cg config set` is not a write by cg's contract, so nothing re-reads on its
  // own, and the stage sat on "Pick where it runs" after you had picked. The
  // setting, so the stage sees a region was chosen - and then everything behind
  // the gate, because all of it is per region: the machines it rents, the box,
  // the archive. Read before the choice, the dashboard would open on the old one.
  // Together, not one after the other: the setting lands first and ticks the
  // last step, and if the reads had not started by then the dashboard opened
  // on a box read for the old region, still loading.
  if (ok) await Promise.all([runCg(['config', '--json'], { json: 'config' }), readBehindGate()]);
};

// ── The first-run pipeline ────────────────────────────────────────────────────
//
// The dashboard, on a laptop that is not ready. Six stages in the order they
// have to be met, one of them active, the pane beside it carrying cg's own
// words. When the last one is met it collapses to a line and the dashboard
// cards take over.
//
// It replaces three attempts at this: a banner that named one problem at a
// time with no sense of how many there were, a modal popup over a window you
// could not use yet, and that popup moved into a corner so it would stop
// blocking. All three were ways of avoiding the fact that a new laptop has no
// screen of its own.
//
// What is on each stage comes from prereqs(), which the banner also reads, so
// the two cannot disagree. What cg is doing comes from cg.

// Which of three things the dashboard is doing:
//   setup      something is unmet, or not yet known - the pipeline is the screen
//   handover   all six are met, and the finished pipeline is held on screen for
//              a beat so you see it finish rather than having it vanish
//   dashboard  the cards
//
// It only ever moves forwards. A prerequisite that breaks later in the session
// is the banner's to report: dropping back into a setup flow out from under
// someone who is using the app would be worse than the problem.
let onbPhase = 'setup';
// How many sets of the reads behind the gate are in flight. The pipeline's
// stages are judged on the fast ones, so it used to finish and hand over while
// the box, the archive and the guards were still being read - and the first
// thing on the new dashboard was "Stop refresh" and three empty cards. The
// handover waits for this to reach zero instead: the dashboard arrives filled.
let readingBehindGate = 0;
let onbHandover = null;
let onbBeatDone = false;
const ONB_HANDOVER_MS = 900;

// The stage that is running something, and the job it started - so it can be
// stopped, which matters: a sign-in waits on a browser that may never answer.
let onbRunning = null;
let onbJob = null;
// A sentence about the last attempt at the active stage - why it failed - and
// whether the run in flight is now waiting on a browser rather than working.
let onbNote = '';
let onbTone = '';
let onbWaiting = false;
// The step whose command just succeeded, until the read that judges it comes
// back. Without it the step fell back to exactly what it showed before - red
// marks and "Install them" - for as long as the re-read took, which looked like
// the install had not happened.
let onbVerifying = null;
// Every read that has to answer before that step is judged again - for Tools,
// both the tool list and the AWS CLI check - and the tools that were missing
// when the install started, which show "…" until then rather than ✗ or ✓.
let onbPending = new Set();
let onbWasMissing = new Set();
const ONB_REREAD = { tools: ['deps', 'creds'], cli: ['deps', 'creds'], tailnet: ['tskey'],
                     where: ['config', 'machines'] };
const ONB_VERIFY = { tools: 'Installed. Checking\u2026', cli: 'Installed. Checking\u2026',
                     tailnet: 'Signed in. Checking\u2026', where: 'Saved. Checking\u2026' };

// Called by watchForSignInLink when the sign-in prints its link: the command
// is not stuck, it is waiting for you, and the stage says that instead.
function onbStatus() {
  onbWaiting = true;
  // Nothing is being worked on now, so no sweep and no "current line": the
  // step's own sentence says what is being waited for, and the link is there.
  if (onbRunning) {
    $('onb-live-' + onbRunning).hidden = true;
    $('onb-prog-' + onbRunning).hidden = true;
  }
  paintOnboard();
}

// ── Each step's own log ──────────────────────────────────────────────────────
//
// One log per step rather than one pane for all of them: when step three fails
// you want step three's output, not whatever ran last. Each is a small unit -
// the line cg is on now, a progress sweep, the sign-in link when there is one,
// and the full output folded behind "Details" - built once and kept in
// #onb-logs between paints, because the steps are redrawn every time a read
// lands and an install's half-written log must survive that.
const onbLogId = key => 'onb-log-' + key;
function onbUnit(key) {
  let u = document.getElementById('onb-unit-' + key);
  if (u) return u;
  u = document.createElement('div');
  u.id = 'onb-unit-' + key;
  u.className = 'mt-space-sm';
  u.dataset.open = 'no';

  const live = document.createElement('div');
  live.id = 'onb-live-' + key;
  live.className = 'font-code-sm text-code-sm text-on-surface-variant truncate';
  live.hidden = true;
  const prog = document.createElement('div');
  prog.id = 'onb-prog-' + key;
  prog.className = 'onb-progress mt-space-xs';
  prog.hidden = true;
  prog.append(document.createElement('i'));
  // A sign-in prints a link and then waits: it has to be reachable while the
  // command is still running, and the browser it opened may be behind this.
  const link = document.createElement('button');
  link.id = 'onb-link-' + key;
  link.className = 'btn mt-space-sm';
  link.textContent = 'Open the sign-in page again';
  link.hidden = true;

  const bar = document.createElement('div');
  bar.className = 'flex items-center gap-space-sm mt-space-xs';
  bar.id = 'onb-bar-' + key;
  bar.hidden = true;
  const tog = document.createElement('button');
  tog.id = 'onb-tog-' + key;
  tog.className = 'font-code-sm text-code-sm text-outline hover:text-on-surface';
  const copy = document.createElement('button');
  copy.className = 'font-code-sm text-code-sm text-outline hover:text-on-surface ml-auto';
  copy.textContent = 'Copy';
  copy.hidden = true;
  bar.append(tog, copy);

  const pre = document.createElement('pre');
  pre.id = onbLogId(key);
  pre.className = 'font-code-sm text-code-sm text-on-surface-variant whitespace-pre-wrap break-words '
    + 'overflow-auto max-h-[32vh] mt-space-xs p-space-sm rounded bg-surface-container-lowest '
    + 'border border-surface-variant';
  pre.hidden = true;
  pre.dataset.n = '0';

  tog.onclick = () => onbLogOpen(key, u.dataset.open !== 'yes');
  copy.onclick = async () => {
    try { await navigator.clipboard.writeText(pre.textContent); copy.textContent = 'Copied'; }
    catch { copy.textContent = 'Could not copy'; }
  };
  u.append(live, prog, link, bar, pre);
  $('onb-logs').append(u);
  onbLogCount(key);
  return u;
}
function onbLogCount(key) {
  const u = onbUnit(key), pre = $(onbLogId(key)), n = Number(pre.dataset.n || 0);
  $('onb-bar-' + key).hidden = n === 0;
  $('onb-tog-' + key).textContent = `${u.dataset.open === 'yes' ? '▾' : '▸'} Details · `
    + `${n} line${n === 1 ? '' : 's'}`;
}
function onbLogOpen(key, open) {
  const u = onbUnit(key), pre = $(onbLogId(key));
  u.dataset.open = open ? 'yes' : 'no';
  pre.hidden = !open;
  u.querySelector('#onb-bar-' + key + ' button:last-child').hidden = !open;
  // Opened at the end, which is where the news is.
  if (open) pre.scrollTop = pre.scrollHeight;
  onbLogCount(key);
}
// A fresh attempt at a step: its old output stays on screen until the new run
// says something, then is replaced - the collect handler's "fresh" rule.
function onbLogFresh(key) {
  onbUnit(key);
  const pre = $(onbLogId(key));
  pre.dataset.fresh = 'yes';
  pre.dataset.freshCount = 'yes';
  return onbLogId(key);
}
// Every line that reaches a step's log: count it, and show it as the line the
// step is on. Called from the shared collect handler.
function onbLogGrew(box, text) {
  const key = box.id.slice('onb-log-'.length);
  if (box.dataset.freshCount === 'yes') { box.dataset.n = '0'; delete box.dataset.freshCount; }
  box.dataset.n = String(Number(box.dataset.n || 0) + 1);
  const said = (text || '').trim();
  if (said) $('onb-live-' + key).textContent = said;
  onbLogCount(key);
}

// A stage's command, run inside the stage itself. Same shape as runInDialog;
// the difference is where the words go.
async function runInPipeline(key, args, status) {
  onbUnit(key);
  const pre = $(onbLogId(key));
  pre.dataset.fresh = 'yes';
  pre.dataset.freshCount = 'yes';
  runSurface = { link: 'onb-link-' + key, log: onbLogId(key), status: onbStatus };
  $('onb-link-' + key).hidden = true;
  $('onb-live-' + key).textContent = status || 'Starting…';
  $('onb-live-' + key).hidden = false;
  $('onb-prog-' + key).hidden = false;
  onbRunning = key;
  onbWaiting = false;
  onbNote = '';
  onbTone = '';
  paintOnboard();
  const { rc } = await runCg(args, { collect: onbLogId(key), wantRc: true,
                                     onStart: id => { onbJob = id; } });
  onbJob = null;
  onbRunning = null;
  onbWaiting = false;
  $('onb-link-' + key).hidden = true;
  $('onb-live-' + key).hidden = true;
  // Done, not yet judged: the sweep keeps going until the re-read lands.
  if (rc === 0) {
    onbVerifying = key;
    onbPending = new Set(ONB_REREAD[key] || []);
  }
  else $('onb-prog-' + key).hidden = true;
  if (rc !== 0) {
    onbNote = rc === null ? 'Something else is running - this waits for it to finish.'
      : rc === 130 ? 'Stopped.'
      : (ONB_FAIL[key] || 'That did not finish. The details below say why.');
    onbTone = 'bad';
    // The reason is in cg's words, and nobody should have to find the toggle
    // to read why the thing they just pressed did not work.
    if (rc !== 130) onbLogOpen(key, true);
  }
  // A write re-reads everything behind it, which repaints this - but only on
  // success does the stage move on, so say so either way.
  paintOnboard();
  return rc === 0;
}
const ONB_FAIL = {
  tools: 'The install did not finish. The details below say why.',
  cli: 'The AWS CLI did not install. The details below say why.',
  tailnet: 'Sign-in did not finish. The details below say why.',
  where: 'The location could not be saved. The details below say why.',
};

// Installing the tools runs here rather than opening something: it needs no
// answer from you beyond the password your OS asks for.
function onbInstall() {
  const missing = depsNow ? (depsNow.tools || []).filter(x => !x.present).map(x => x.tool) : [];
  onbWasMissing = new Set(missing);
  return runInPipeline('tools', ['deps', 'install', ...missing], 'Asking for your password…');
}
function onbInstallCli() {
  return runInPipeline('cli', ['deps', 'install', 'aws'], 'Asking for your password…');
}
function onbSignIn() {
  return runInPipeline('tailnet', ['creds', 'tailscale', 'signin'], 'Opening your browser…');
}

// What each step is called, in the words of someone who has never used AWS.
// The banner keeps prereqs()' own sentences, which are for someone mid-session
// who already knows what a key is; these are for the first run, and nothing in
// them names a command, a flag or an AWS service without saying what it is.
//
//   name  the step, short - what the dim list of steps still to come shows
//   done  what is now true, said once it is
//   body  why it matters, and what pressing the button will do
const missingTools = () => depsNow
  ? (depsNow.tools || []).filter(x => !x.present).map(x => x.label) : [];
// Short and plain: what is needed and what it is for, in one or two sentences.
// The Tools step has no sentence at all - it shows the tools themselves.
// The AWS CLI is installed - cg deps found it - but does not run: cg creds
// says there is no CLI. Shown on its own chip, not as a second Tools row.
function cliBroken() {
  if (!depsNow || !credsNow || credsNow.cli !== false) return false;
  const aws = (depsNow.tools || []).find(t => t.tool === 'aws');
  return !!(aws && aws.present);
}

// Every read behind a just-done step has answered: it shows what they say.
// Still unmet after an install that exited cleanly means something did not
// take, and that is said, with the log open - not the step silently going back
// to what it showed before.
function onbVerified() {
  const key = onbVerifying;
  onbVerifying = null;
  onbWasMissing = new Set();
  const prog = document.getElementById('onb-prog-' + key);
  if (prog) prog.hidden = true;
  const rung = prereqs().find(x => x.key === key);
  if (rung && rung.ok === false) {
    const still = key === 'tools' || key === 'cli'
      ? [...missingTools(), ...(cliBroken() ? ['AWS CLI v2 (installed, but it will not run)'] : [])]
      : [];
    onbNote = still.length ? `Still missing: ${still.join(', ')}. The details below say why.`
      : (ONB_FAIL[key] || 'That did not finish. The details below say why.');
    onbTone = 'bad';
    onbLogOpen(key, true);
  }
  paintOnboardSoon();
}

const ONB_COPY = {
  open: { name: 'Loading the app', done: () => 'App ready', body: () => '' },
  tools: { name: 'Tools', done: () => 'Tools installed', body: () => '' },
  cli: { name: 'Tools', done: () => 'Tools installed',
    body: () => 'The AWS CLI is not installed.' },
  key: { name: 'Amazon account', done: () => 'Amazon account connected',
    body: () => ({
      unreachable: 'AWS could not be reached from this laptop, so the key was not checked. '
                 + 'It may be fine.',
      'no-key': 'Add an AWS access key. The app uses it to start and stop your games machine.',
    }[credsNow && credsNow.reason]
      || 'AWS rejected the saved access key. Add a new one.') },
  tailnet: { name: 'Private connection', done: () => 'Private connection ready',
    body: () => 'Sign this laptop in to Tailscale. Your games machine is reachable only over '
              + 'your private Tailscale network.' },
  authkey: { name: 'Machine key', done: () => 'Machine key saved',
    body: () => 'Paste a Tailscale auth key. Each new games machine uses it to join your network.' },
  email: { name: 'Bill alerts',
    done: () => { const e = cfgVal('EMAIL_ALERTS'); return e ? `Alerts go to ${e}` : 'Bill alerts on'; },
    body: () => 'Set the address AWS emails when spending passes your budget.' },
  where: { name: 'Location', done: () => whereDone(),
    body: () => regionChosen() && machinesNow
      ? `${placeName(machinesNow.region)} has no GPU quota for your machine. Choose another location.`
      : 'Choose where your games machine runs. Nearer means lower latency.' },
};
// The city, when the scan knows it; the code otherwise.
function placeName(region) {
  const r = ((sweepNow && sweepNow.regions) || []).find(x => x.region === region);
  return r && r.city ? shortCity(r.city) : region;
}

// The one button a step offers, in the same words. Each opens its dialog right
// here or runs right here: nothing in the first run sends you to another screen.
const ONB_ACTION = {
  // Installed but will not run is not something installing fixes - cg deps
  // install skips a tool it can find - so that case offers a fresh look.
  tools:   () => [!missingTools().length && cliBroken()
                    ? { label: 'Check again', go: retryReads }
                    : { label: 'Install them', go: onbInstall }],
  cli:     () => [{ label: 'Install it', go: onbInstallCli }],
  tailnet: () => [{ label: 'Sign in to Tailscale', go: onbSignIn }],
  // A read that never reached AWS is not a request for a key, so it keeps the
  // rung's own Try again rather than opening the key form.
  key: r => r.problem.go === retryReads
    ? [{ label: 'Try again', go: retryReads }]
    : [{ label: credsNow && credsNow.reason === 'no-key' ? 'Connect Amazon' : 'Connect again',
         go: () => openAwsKey(onbLogFresh('key')) }],
  authkey: () => [{ label: 'Paste a key', go: () => setAuthKey(onbLogFresh('authkey')) }],
  email:   () => [{ label: 'Add your email', go: () => openAlertEmail(onbLogFresh('email')) }],
  where:   () => [{ label: 'Choose a location', go: openWhereTo }],
};
const onbActions = r =>
  (ONB_ACTION[r.key] || (x => [{ label: x.problem.label, go: x.problem.go }]))(r);

// What each step looked like at the last paint, so the motion runs on the
// paint where a step CHANGED and not on every repaint after it.
const onbSeen = {};

// The last step: loading the app. Every tab shows something cg has to read
// first - the box, the archive, the guards, the machines - and on real AWS that
// takes seconds. Without this step the dashboard opened on empty cards and
// "Stop refresh", and the other tabs were empty until visited.
//
// One chip per TAB, not per read: "Cost guards" and "Game archive" meant
// nothing on their own, and two of the five said what the Location step had
// already said. A tab is ticked when every read it shows has landed; which
// reads those are is NEEDS, the same table its own Refresh uses. Cost is not
// here: its read is a paid Cost Explorer call, made only when you press Fetch.
const OPENING = [
  ['dashboard', 'Dashboard'], ['build', 'Build'], ['library', 'Library'],
  ['guards', 'Guards'], ['settings', 'Settings'],
];
const readOut = json => [...jobs.values()].some(j => j.json === json);

const ONB_MARK = {
  done:     ['\u2713', 'text-primary'],
  checking: ['\u2026', 'text-outline animate-pulse'],
  active:  ['\u25c9', 'text-tertiary'],
  loading: ['\u25cf', 'text-primary animate-pulse'],
  verifying: ['\u25cf', 'text-primary animate-pulse'],
  running: ['\u25cf', 'text-tertiary animate-pulse'],
  failed:  ['\u2717', 'text-error'],
  locked:  ['\u25cb', 'text-outline-variant'],
  unknown: ['?', 'text-outline'],
};

// Repainting the pipeline from inside a painter, without assuming the order the
// reads come back in: every one of them changes a stage's verdict, and the
// stage that is active depends on all of them.
function paintOnboardSoon() {
  if (paintOnboardSoon.queued) return;
  paintOnboardSoon.queued = true;
  Promise.resolve().then(() => { paintOnboardSoon.queued = false; paintOnboard(); });
}

function paintOnboard() {
  const wrap = $('onb-steps');
  if (!wrap) return;

  // No engine. Not a stage you can be talked through - every command fails
  // identically without cg, and six broken reads is not what happened. One
  // thing did, and only the main process can see it.
  if (engineGone) {
    document.body.classList.add('setup');
    $('onb').hidden = false;
    $('onb-head').hidden = false;
    wrap.hidden = false;
    $('d-main').hidden = true;
    $('onb-title').textContent = 'This app cannot find cg';
    $('onb-count').textContent = '';
    $('onb-sub').textContent = 'cg is the engine; this window is a face on it. '
      + 'Nothing here can run until there is a cg to run.';
    wrap.textContent = '';
    for (const [state, text, note] of [
      ['failed', `Looked for it at ${engineGone.cg}`, ''],
      ['locked', 'Install it, or point CG_REPO at a checkout',
       'git clone https://github.com/jebin2/aws_cloud_gaming ~/cloud_gaming'],
    ]) {
      const row = document.createElement('div');
      row.className = 'flex gap-space-sm items-start';
      row.dataset.stage = state === 'failed' ? 'engine' : 'engine-fix';
      row.dataset.state = state;
      const [mark, cls] = ONB_MARK[state];
      const dot = document.createElement('span');
      dot.className = 'font-code-md text-code-md shrink-0 w-6 ' + cls;
      dot.textContent = mark;
      const body = document.createElement('div');
      body.className = 'min-w-0 pb-space-md';
      const title = document.createElement('div');
      title.className = 'font-body-md text-body-md '
        + (state === 'failed' ? 'text-error' : 'text-on-surface');
      title.textContent = text;
      body.append(title);
      if (note) {
        const n = document.createElement('div');
        n.className = 'font-code-sm text-code-sm text-outline mt-0.5 break-all';
        n.textContent = note;
        body.append(n);
      }
      if (state === 'locked') {
        const b = document.createElement('button');
        b.className = 'btn mt-space-sm';
        b.textContent = 'Try again';
        b.onclick = retryReads;
        body.append(b);
      }
      row.append(dot, body);
      wrap.append(row);
    }
    return;
  }

  // A rung that is the same fix as another is its own step only in the one case
  // the other cannot cover: the tools are all there and the AWS CLI alone is
  // not. Met, it is part of "Tools installed" - drawn as a second identical
  // line, it was, and the count read "of 7" on one laptop and "of 6" on the next.
  // A rung that is the same fix as another is never a row of its own: the AWS
  // CLI is judged inside Tools. Six steps, every time.
  const setup = prereqs().filter(r => !r.sameAs);
  // Setup is done when the six are; the dashboard step is done when, on top of
  // that, everything it shows has been read.
  const ready = setup.every(r => r.ok === true);
  const rungs = [...setup, { key: 'open', reads: null, name: 'Loading the app',
                             ok: ready && !readingBehindGate ? true : null }];
  const firstOpen = rungs.findIndex(r => r.ok !== true);
  const done = rungs.filter(r => r.ok === true).length;

  // Every open is the same flow: the six steps, each ticking as its check comes
  // back, stopping at the first that is not met. There was a "Checking your
  // rig" splash in front of them that stayed up until something was found
  // missing - so a laptop with five steps done sat on it for as long as the
  // slow reads behind Location took, instead of watching five ticks land.
  //
  // The handover has a beat first: six ticks replaced in 200ms reads as a
  // glitch rather than as "that is all done".
  if (ready && onbPhase === 'setup' && !readingBehindGate) {
    onbPhase = 'handover';
    onbHandover = setTimeout(() => {
      onbHandover = null;
      onbBeatDone = true;
      paintOnboard();
    }, ONB_HANDOVER_MS);
  }
  // The beat is a minimum, not a deadline: reads that started during it are
  // waited for too, or the dashboard opens on "Stop refresh".
  if (onbPhase === 'handover' && onbBeatDone && !readingBehindGate) {
    enterDashboard();
    return;
  }
  const showPipeline = onbPhase !== 'dashboard';
  document.body.classList.toggle('setup', showPipeline);
  $('onb').hidden = !showPipeline;
  $('d-main').hidden = showPipeline;
  if (!showPipeline) {
    return;
  }

  wrap.hidden = false;

  // The count is the only heading: the steps say the rest.
  $('onb-count').textContent = `${done} of ${rungs.length} done`;
  $('onb-head').hidden = true;

  // The log units are kept, not rebuilt: park them before the rows go.
  for (const u of [...wrap.querySelectorAll('[id^="onb-unit-"]')]) {
    const pre = u.querySelector('pre');
    u.dataset.scroll = String(pre.scrollTop);
    u.dataset.follow = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 24 ? 'yes' : 'no';
    $('onb-logs').append(u);
  }
  wrap.textContent = '';

  rungs.forEach((r, i) => {
    const copy = ONB_COPY[r.key] || { name: r.name, done: () => r.name, body: () => r.problem.body };
    const active = i === firstOpen;
    const blocked = rungs.slice(0, i).some(x => x.ok !== true);
    // A verdict of null has two causes that must not share a sentence: the read
    // behind it has not come back yet, or it came back broken.
    const waiting = r.ok === null && !readFailures.has(r.reads) && !blocked;
    const state = r.key === 'open' ? (r.ok ? 'done' : blocked ? 'locked' : 'loading')
      : onbVerifying === r.key ? 'verifying'
      : r.ok === true ? 'done'
      : r.ok === null ? (waiting ? 'checking' : 'unknown')
      : onbRunning === r.key ? 'running'
      : active ? (onbTone === 'bad' ? 'failed' : 'active')
      : 'locked';
    // When this step last changed, and from what. The steps are redrawn every
    // time a read lands, often mid-animation; a redrawn tick has to carry on
    // from where it was rather than start again, so each animation is given a
    // negative delay of however long ago the change happened. No timer: the
    // clock is only read, at paint.
    const now = performance.now();
    const seen = onbSeen[r.key];
    if (!seen || seen.state !== state) {
      onbSeen[r.key] = { state, from: seen ? seen.state : null, at: now };
    }
    const { from, at } = onbSeen[r.key];
    const since = now - at;
    const justDone = state === 'done' && from !== null && from !== 'done' && since < 600;
    const justOpened = state === 'active' && from !== null
                       && !['active', 'failed', 'running'].includes(from) && since < 900;
    const motion = (el, cls, delay) => {
      el.classList.add(cls);
      el.style.animationDelay = `${delay - since}ms`;
    };
    // Still to come, however it is judged: a name, dimmed, with nothing to press.
    const quiet = state === 'locked' || (state === 'unknown' && blocked);

    const row = document.createElement('div');
    row.className = 'flex gap-space-md items-stretch';
    row.dataset.stage = r.key;
    row.dataset.state = state;

    // The line down the left: what makes this a pipeline rather than a list,
    // and it goes green behind you.
    const rail = document.createElement('div');
    rail.className = 'flex flex-col items-center shrink-0 w-5';
    const [mark, cls] = quiet ? ONB_MARK.locked : ONB_MARK[state];
    const dot = document.createElement('span');
    dot.className = 'font-code-md text-code-md leading-6 ' + cls;
    if (justDone) motion(dot, 'onb-tick', 0);
    dot.textContent = mark;
    rail.append(dot);
    if (i < rungs.length - 1) {
      const line = document.createElement('div');
      line.className = 'w-px flex-1 min-h-[12px] my-1 '
        + (r.ok === true ? 'bg-primary/70' : 'bg-surface-variant');
      if (justDone) motion(line, 'onb-fill', 140);
      rail.append(line);
    }

    const body = document.createElement('div');
    body.className = 'min-w-0 flex-1 ' + (quiet || state === 'done' ? 'pb-space-sm' : 'pb-space-lg');
    const head = document.createElement('div');
    head.className = 'flex items-baseline justify-between gap-space-sm';
    const title = document.createElement('div');
    title.className = 'leading-6 ' + (state === 'done' ? 'font-body-md text-body-md text-on-surface-variant'
      : quiet ? 'font-body-md text-body-md text-outline'
      : state === 'failed' ? 'font-body-md text-body-md text-error font-medium'
      : 'font-body-md text-body-md text-on-surface font-medium');
    title.textContent = state === 'done' ? copy.done() : copy.name;
    head.append(title);
    const tag = { running: onbWaiting ? 'waiting for browser' : 'working', failed: 'failed',
                  verifying: 'checking\u2026', loading: 'loading\u2026',
                  checking: 'checking…' }[state];
    if (tag && !quiet) {
      const t = document.createElement('span');
      t.className = 'font-code-sm text-code-sm shrink-0 '
        + (state === 'failed' ? 'text-error' : state === 'checking' ? 'text-outline' : 'text-tertiary');
      t.textContent = tag;
      head.append(t);
    }
    body.append(head);

    const unit = document.getElementById('onb-unit-' + r.key);
    const hasLog = unit && Number($(onbLogId(r.key)).dataset.n || 0) > 0;
    const place = () => {
      if (!unit) return;
      body.append(unit);
      const pre = unit.querySelector('pre');
      pre.scrollTop = unit.dataset.follow === 'no' ? Number(unit.dataset.scroll || 0) : pre.scrollHeight;
    };

    if (state === 'loading') {
      const list = document.createElement('div');
      list.className = 'flex flex-wrap gap-space-xs mt-space-sm';
      list.id = 'onb-reads';
      for (const [tab, label] of OPENING) {
        const reads = (NEEDS[tab] || []).map(([, json]) => json);
        const st = reads.some(readOut) ? 'checking'
          : reads.some(j => readFailures.has(j)) ? 'failed' : 'done';
        const chip = document.createElement('span');
        chip.className = 'pill ' + (st === 'done' ? 'pill-ok' : st === 'failed' ? 'pill-bad' : '');
        chip.dataset.tab = tab;
        chip.dataset.state = st;
        chip.textContent = ({ done: '\u2713 ', failed: '\u2717 ', checking: '\u2026 ' })[st] + label;
        list.append(chip);
      }
      const sweep = document.createElement('div');
      sweep.className = 'onb-progress mt-space-sm';
      sweep.append(document.createElement('i'));
      body.append(list, sweep);
      row.append(rail, body); wrap.append(row); return;
    }
    if (quiet || state === 'checking') { row.append(rail, body); wrap.append(row); return; }
    if (state === 'done') {
      // What it did stays, folded: you can still look at what the install said.
      if (hasLog) place();
      row.append(rail, body); wrap.append(row); return;
    }
    if (state === 'unknown') {
      const why = document.createElement('div');
      why.className = 'font-body-sm text-body-sm text-on-surface-variant mt-0.5';
      why.textContent = 'This couldn’t be checked just now.';
      body.append(why);
      const b = document.createElement('button');
      b.className = 'btn mt-space-sm';
      b.textContent = 'Try again';
      b.onclick = retryReads;
      body.append(b);
      row.append(rail, body); wrap.append(row); return;
    }

    // The open step: why it matters, what is happening, and the one thing to do.
    const inner = document.createElement('div');
    if (justOpened) motion(inner, 'onb-open', 260);
    const said = state === 'verifying' ? ONB_VERIFY[r.key] || 'Done. Checking\u2026'
      : state === 'running' && onbWaiting
      ? 'Finish signing in in your browser. This continues by itself when you are done.'
      : copy.body();
    if (said) {
      const why = document.createElement('div');
      why.className = 'font-body-sm text-body-sm text-on-surface-variant mt-0.5';
      why.textContent = said;
      inner.append(why);
    }
    // The tools themselves, rather than a sentence about them: what is already
    // here in green, what is missing in red.
    if (r.key === 'tools' && depsNow) {
      const list = document.createElement('div');
      list.className = 'flex flex-wrap gap-space-xs mt-space-sm';
      list.id = 'onb-tools';
      for (const t of depsNow.tools || []) {
        const chip = document.createElement('span');
        const broken = t.tool === 'aws' && cliBroken();
        const recheck = state === 'verifying' && onbWasMissing.has(t.tool);
        const ok = t.present && !broken;
        chip.className = 'pill ' + (recheck ? '' : ok ? 'pill-ok' : 'pill-bad');
        chip.dataset.tool = t.tool;
        chip.dataset.present = recheck ? 'checking' : ok ? 'yes' : 'no';
        chip.textContent = (recheck ? '\u2026 ' : ok ? '\u2713 ' : '\u2717 ') + t.label
          + (broken && !recheck ? ' - installed, will not run' : '');
        list.append(chip);
      }
      inner.append(list);
    }
    if (onbNote && state === 'failed') {
      const note = document.createElement('div');
      note.className = 'font-body-sm text-body-sm text-error mt-space-sm';
      note.textContent = onbNote;
      inner.append(note);
    }
    body.append(inner);
    if (state === 'running' || state === 'verifying' || hasLog) place();

    const bar = document.createElement('div');
    bar.className = 'flex flex-wrap items-center gap-space-sm mt-space-md';
    if (state === 'verifying') {
      // Nothing to press while the answer is on its way.
    } else if (state === 'running') {
      // Stopping has to reach cg: a sign-in is waiting on a browser that may
      // never answer, and a package manager can be sitting on a lock.
      const stop = document.createElement('button');
      stop.className = 'btn';
      stop.textContent = onbWaiting ? 'Stop waiting' : 'Stop';
      stop.onclick = () => { if (onbJob !== null) window.cg.cancel(onbJob); };
      bar.append(stop);
    } else {
      for (const a of onbActions(r)) {
        const b = document.createElement('button');
        b.className = 'btn btn-primary';
        b.textContent = state === 'failed' && a.go !== retryReads ? 'Try again' : a.label;
        b.onclick = () => { onbNote = ''; onbTone = ''; a.go(); };
        bar.append(b);
        if (a.note) {
          const n = document.createElement('span');
          n.className = 'font-code-sm text-code-sm text-outline';
          n.textContent = a.note;
          bar.append(n);
        }
      }
    }
    if (bar.childElementCount) body.append(bar);
    row.append(rail, body);
    wrap.append(row);
  });
}

// Setup is over: the sidebar slides in, the header drops in, the cards come up.
// Only ever forwards - a prerequisite that breaks later is the banner's.
function enterDashboard() {
  if (onbPhase === 'dashboard') return;
  onbPhase = 'dashboard';
  document.body.classList.remove('setup');
  document.body.classList.add('arriving');
  paintOnboard();
  paintBanner();
}

function paintBanner() {
  const p = bannerProblem();
  paintOnboard();
  // Out of the way on the dashboard, where the pipeline is already saying this
  // in order and with the button for it - two copies of one problem is what the
  // banner plus the popup had become. It stays on every OTHER screen, because
  // it sits above all of them and the pipeline does not.
  $('banner').hidden = !p || (view === 'dashboard' && !$('onb').hidden);
  if (!p) return null;
  $('banner-title').textContent = p.title;
  $('banner-body').textContent = p.body;
  $('banner-fix').hidden = false;
  $('banner-fix-label').textContent = p.label;
  $('banner-fix').onclick = p.go;
  return p;
}

// What cg is doing, for the pipeline's log pane and for the refusal when
// something else holds the lock. The nine reads each have a sentence; see
// CG_WORDS.
//
// There used to be a popup here - three modes of it - which said the same
// things in front of the window instead of in it. The pipeline on the
// dashboard says them in place, so the popup and the header's
// "running: cg machines, cg refresh" are both gone.

// True when there is something to talk to. A main process too old to answer -
// or a test stub - says nothing, and is taken at its word: carry on, and let
// the reads report whatever they find.
let engineGone = null;
async function engineReady() {
  let e;
  try { e = await window.cg.engine(); } catch { return true; }
  if (!e || e.found) { engineGone = null; return true; }
  engineGone = e;
  paintOnboard();
  return false;
}

// The reads are free, and a laptop that could not reach AWS a minute ago may be
// able to now. Cancelling first, which is the part that matters: reads do not
// block each other, so starting a second set leaves the stuck ones exactly
// where they were - in `jobs`, where a job in flight is what disables Build,
// Play and Destroy.
async function retryReads() {
  for (const [id, job] of [...jobs]) if (!job.write) await window.cg.cancel(id);
  if (!(await engineReady())) return;
  return refreshAll();
}

// On open: ask what this laptop can do, and only then ask AWS anything.
//
// It used to fire all nine reads at once. On a laptop with no AWS CLI that is
// six reads that cannot work, a screen of unknowns, and the actual problem - a
// missing tool - somewhere in the middle of it.
//
// When the gate stays shut, it has to open again by itself once the last
// blocking stage is fixed - and not every fix is a write that comes back
// through here. The billing address is a `cg config set`, which cg does not
// list as running alone, so the window re-reads only the setting: the stage
// ticked, and "where it runs" sat on "checking…" for ever, waiting on a
// `cg machines` that nothing was ever going to ask for. So `gateShut` remembers
// that the reads behind the gate were skipped, and ANY gate read that lands
// with nothing blocking left - from a dialog, from Settings, from anywhere -
// asks them. Cleared at the start of this function, so the gate reads it
// makes itself never open it a second time underneath it.
let gateShut = false;
// each: told as each read lands, so a popup can tick them off.
async function refreshAll(each) {
  gateShut = false;
  await Promise.all(GATE_READS.map(([args, json]) =>
    runCg(args, { json, group: 'refresh' }).then(() => each && each(json))));
  paintBanner();
  // A prerequisite is missing. The reads that need AWS or a tailnet would
  // every one come back unknown, and the pipeline is already showing the one
  // thing to do about it.
  if (gateBlocked()) { gateShut = true; return; }
  return readBehindGate(each);
}
// Only a stage judged on a gate read can keep the gate shut. "Where it runs"
// is judged on `cg machines`, which is BEHIND the gate - letting it shut the
// gate would stop the very read that answers it, and leave the region popup
// with nothing to list.
const GATE_JSON = new Set(GATE_READS.map(([, json]) => json));
const gateBlocked = () => prereqs().some(r => r.ok === false && GATE_JSON.has(r.reads));
function gateMayOpen() {
  if (gateBlocked()) return;
  gateShut = false;
  readBehindGate();
}
async function readBehindGate(each) {
  for (const v of Object.keys(NEEDS)) loaded.add(v);
  readingBehindGate++;
  // In parallel, because they share nothing and each screen paints when its own
  // answer lands. cg cost is not among them: it bills.
  try {
    await Promise.all(ALL_READS.map(([args, json]) =>
      runCg(args, { json, group: 'refresh' }).then(() => each && each(json))));
  } finally { readingBehindGate--; }
  paintOnboard();
  firstScan();             // not awaited: a first scan takes 90 seconds
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

$('refresh').onclick = () => refreshShown();
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
$('d-watch').onclick = () => goView('build');
$('d-change').onclick = () => goSetting($('s-machine-card'));
$('d-ts-signin').onclick = signInTailscale;
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
  repaintWhereTo();
  try {
    await runCg(['sweep', '--json'], { json: 'sweep' });
  } finally {
    sweeping = false;
    if (btn) { btn.disabled = false; btn.textContent = was; }
    paintChooser();
    repaintWhereTo();
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
// A build, a delete and a session all report the same way - steps, lines, an
// exit - so they all run on the Build screen as steps, and starting one goes
// there. Watching a delete in a panel that says nothing was the complaint.
let runKind = 'init';
function startRun(args, opts = {}) {
  runKind = args[0];
  goView('build');
  $('b-log').dataset.fresh = 'yes';
  $('b-log').textContent = '';
  $('b-log-title').textContent = 'cg ' + args.join(' ');
  buildSteps = 0;
  buildStarted = Date.now();
  $('b-prog').className = 'h-full bg-primary rounded-full';
  $('b-prog').style.width = '0%';
  $('b-prog-step').textContent = 'starting…';
  buildFailClear();
  runBegin(args[0], opts);
  paintRun();
  return runCg(args, opts.env ? { env: opts.env } : {});
}

// A build, with the games ticked now. Try again uses the ones the failed build
// had, so a retry builds the same machine.
function buildWith(apps, games, gamesGb) {
  return startRun(['init'], { env: { GAME_APPS: apps }, apps, games, gamesGb });
}
function retryBuild() {
  const r = run || {};
  return buildWith(r.apps || 'none', r.games || 0, r.gamesGb || 0);
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
    title: 'Delete the machine?',
    body: (sessionNow ? 'The stream open from this laptop is closed first - cg asks before it does.\n\n' : '')
        + 'Your games are saved to the archive first, and nothing is deleted if that fails.\n\n'
        + 'The machine and its disk go. Building a new one takes 10 to 20 minutes.',
    yes: 'Delete machine', danger: true,
  });
  if (ok) await startRun(['destroy']);
};
$('b-build').onclick = async () => {
  const apps = picked.size ? [...picked].join(',') : 'none';
  const gb = selectedGb();
  const rate = buildRate();
  const ok = await askConfirm({
    title: 'Build the machine?',
    body: `${picked.size ? `${picked.size} game${picked.size === 1 ? '' : 's'}, ${gb.toFixed(1)} GB, will be`
                         : 'No games will be'} downloaded while it builds.\n\n`
        + `Billing starts when the machine launches${rate != null ? `, at ${rsh(rate)}/hour` : ''}. `
        + 'It is ready in about 10 to 20 minutes.',
    yes: 'Build',
  });
  if (!ok) return;
  await buildWith(apps, picked.size, gb);
};

for (const link of document.querySelectorAll('.nav-item')) {
  link.onclick = e => {
    e.preventDefault();
    document.querySelectorAll('.nav-item').forEach(n => n.classList.toggle('on', n === link));
    // The label only: the link's text also holds its icon's glyph, which came
    // out as an invisible character in "Refreshing <page>".
    $('view-title').textContent = link.querySelector('span:last-child').textContent.trim();
    view = link.dataset.view;
    for (const sec of document.querySelectorAll('main section[data-view]'))
      sec.hidden = sec.dataset.view !== view;
    updateHeader();
    paintBanner();          // the pipeline only covers for it on the dashboard
    // Reads run in parallel, so an open tab loads even while others are in flight.
    if (NEEDS[view] && !loaded.has(view)) refresh();
  };
}
// Drawn once before anything has been read, so the card has its rows and they
// say "reading…", rather than being blank until two reads land.
paintKeys();
checkAsks();
// Is there an engine? Then what does it say. In that order: without cg the
// reads cannot even be started, and nine spawn errors describe one problem
// badly.
// The steps are drawn at once, all of them still being checked, so the window
// never opens on a blank page while the first answers come back.
paintOnboard();
(async () => {
  if (await engineReady()) await refreshAll();
})();
