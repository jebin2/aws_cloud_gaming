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
  init: 'the build', destroy: 'deleting', open: 'the session', check: 'the check',
  status: 'the refresh', watcher: 'the refresh', 'library list': 'the refresh',
  cost: 'loading the bill', 'host list': 'the refresh', 'host status': 'the refresh',
  'library push': 'the games change', 'library pull': 'the games change',
  'library clean': 'the games change', 'library forget': 'the games change',
  'library move': 'the games change', 'library reset': 'the games change',
  'library keep-for': 'the games change', 'library account': 'the login change',
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
  creds: { name: 'the AWS key check' },
  'creds tailscale': { name: 'the Tailscale check' },
  config: { name: 'reading your settings' },
  status: { name: 'the machine check' },
  watcher: { name: 'the auto-stop check' },
  'library list': { name: 'reading your saved games' },
  'library elsewhere': { name: 'looking for games in other locations' },
  machines: { name: 'reading machine prices' },
  sweep: { name: 'checking all locations' },
  cost:              { name: 'loading the bill' },
  check:             { name: 'the laptop check' },
  'watchdog logs':   { name: 'loading the auto-stop history' },
  'config set':      { name: 'saving a setting' },
  // Everything cg says runs alone - see `cg --contract`, and the test that
  // holds this list to it. These are the ones whose name ends up on a Stop
  // button, so none of them may read as something cheap.
  init:                      { name: 'the build' },
  destroy:                   { name: 'deleting the machine' },
  open:                      { name: 'the game session' },
  'library push':            { name: 'saving your games' },
  'library pull':            { name: 'downloading your games' },
  'library forget':          { name: 'deleting a game' },
  'library clean':           { name: 'cleaning up leftover files' },
  'library move':            { name: 'moving a game' },
  'library reset':           { name: 'keeping a game' },
  'library keep-for':        { name: 'changing how long games are kept' },
  'library account':         { name: 'changing the Steam login' },
  'creds set':               { name: 'saving your AWS key' },
  // Longer than 'creds set', which is the AWS key: without this, saving a
  // Tailscale token was announced as saving an AWS one.
  'creds set tailscale':     { name: 'saving the Tailscale token' },
  'creds tailscale signin':  { name: 'signing in to Tailscale' },
  'creds tailscale authkey': { name: 'saving the auth key' },
  'deps install':            { name: 'installing tools' },
  'host list':               { name: 'reading your machines' },
  'host status':             { name: 'checking your machine' },
  'host add':                { name: 'adding a machine' },
  'host remove':             { name: 'removing a machine' },
  'host setup':              { name: 'setting up your machine' },
  'host open':               { name: 'the game session on your machine' },
};
const cgWords = cmd => byCommand(CG_WORDS, cmd) || {};
// Falls back to the command itself: a name nobody wrote down is better said in
// cg's words than guessed at.
const cgName = cmd => cgWords(cmd).name || 'a background task';
// The same, to start a sentence with.
const CgName = cmd => { const s = cgName(cmd); return s.charAt(0).toUpperCase() + s.slice(1); };
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
// Setting up or streaming from a machine of yours: minutes to hours, and
// nothing to do with AWS, so they are not reads to cancel or wait out. They
// have their own Stop, on the machine's card.
const hostRun = j => j.cmd[0] === 'host' && (j.cmd[1] === 'setup' || j.cmd[1] === 'open');
// Woken each time a job ends - see readsSettled.
const jobEnded = [];
// Until the reads in flight have landed. A step's own command runs alone (cg
// --contract), so it is refused while anything else runs - and a step's button
// is offered the moment its own read lands, with the rest still landing: the
// Tailscale sign-in after an install was refused that way, every time, by the
// reads the install had set off. Waits on the jobs ending, never on a timer.
// A machine of yours setting up or streaming is not waited for: it can take
// hours, and the refusal then says so.
async function readsSettled() {
  while ([...jobs.values()].some(j => !hostRun(j))) await new Promise(r => jobEnded.push(r));
}

// A read that failed, keyed by the read, so a later success for the same read
// clears it. The screens show their own unknowns; this is what the pipeline
// reads to say WHY something is unknown.
const readFailures = new Map();

function updateHeader() {
  const mine = jobsHere();
  const busy = writing();
  // The dashboard's refresh is two commands - status and the watcher - but one
  // action to you, so count what they are called, not how many there are.
  // Stop is for what changes something - a build, a delete, a session, an
  // install. A read finishes in seconds and says so where it was asked (the
  // Refresh popup, a Fetch button); a Stop appearing for it was noise.
  const stoppable = mine.filter(j => j.write);
  const hereNames = [...new Set(stoppable.map(j => j.group || runName(j.cmd)))];
  $('cancel').hidden = !stoppable.length;
  if (stoppable.length) $('cancel-label').textContent =
    hereNames.length === 1 ? `Stop ${hereNames[0]}` : `Stop ${hereNames.length} runs`;

  // Point at a run only when it is worth watching: a build or a destroy takes
  // minutes and has its own screen. A refresh finishes in seconds and paints
  // itself, so sending you to another tab for it is noise.
  const elsewhere = [...jobs.values()].find(j => watchable(j.cmd) && j.view !== view);
  $('goto').hidden = !elsewhere;
  if (elsewhere) {
    // Named in full here, not grouped: this points at one run, and what it is
    // decides whether you want to go and watch it.
    $('goto-label').textContent = `${CgName(elsewhere.cmd)} is running · show it`;
    $('goto').dataset.view = elsewhere.view;
  }

  // Cost has a Refresh like every screen, but it carries its price: one Cost
  // Explorer call, $0.01. It is never fetched automatically - only this click.
  $('refresh').hidden = (!NEEDS[view] && view !== 'cost') || mine.some(j => !hostRun(j));
  $('refresh').disabled = busy;                    // only a build or destroy blocks a read
  $('refresh-cost').hidden = view !== 'cost' || !$('refresh-cost').textContent;
  if ($('refresh-age')) $('refresh-age').hidden = view !== 'cost' || !costNowAt;
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
    el.textContent = 'Nothing yet';
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
  if (event.t === 'error' || event.kind === 'fail') return 'problems';
  if (event.t === 'step' || event.t === 'step_end') return 'steps';
  return 'other';
}

// What a row is, in a word.
const LOG_WORD = { step: 'Step', error: 'Problem', fail: 'Problem', warn: 'Note', ask: 'Question',
                   ok: 'Done', wait: 'Waiting', raw: 'Data' };
function logShown(row) {
  return logFilter === 'all' || row.dataset.group === logFilter;
}
function logLine(event) {
  const kind = event.kind || event.t;
  const row = document.createElement('div');
  row.dataset.group = logKind(event);
  row.className = 'log-row';
  row.hidden = !logShown(row);
  row.innerHTML = '<time></time><span class="k"></span><span class="t"></span>';
  row.querySelector('time').textContent = (event.at || '').slice(11, 19)
    || new Date().toLocaleTimeString();
  row.querySelector('.k').textContent = event.t === 'exit' ? (event.rc === 0 ? 'Done' : 'Stopped')
    : LOG_WORD[event.t === 'line' ? event.kind : event.t] || '';
  row.querySelector('.k').className = 'k ' + (event.t === 'exit' ? (event.rc === 0 ? 'ok' : 'fail') : kind);
  row.querySelector('.t').textContent =
    event.text || event.prompt || (event.t === 'exit' ? (event.rc === 0 ? 'Finished' : 'Did not finish') : '');
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
  for (const row of $('log').children) row.hidden = !logShown(row);
  for (const b of document.querySelectorAll('[data-filter]')) {
    b.classList.toggle('btn-primary', b.dataset.filter === which);
  }
}

// The app's own confirmation. window.confirm draws a native alert box that
// belongs to no design and says the app's name in its title bar.
// word: what cannot be undone asks for a word typed out; Yes waits for it.
function askConfirm({ title, body, yes = 'Continue', no = 'Cancel', danger = false, word = null }) {
  return new Promise(resolve => {
    $('confirm-title').textContent = title;
    $('confirm-body').textContent = body;
    // No Cancel when there is nothing to decline - a dialog that only informs.
    $('confirm-no').hidden = no === null;
    $('confirm-no').textContent = no || '';
    const btn = $('confirm-yes');
    btn.textContent = yes;
    btn.className = 'btn ' + (danger ? 'btn-danger' : 'btn-primary');
    const input = $('confirm-word');
    $('confirm-word-row').hidden = !word;
    input.value = '';
    btn.disabled = !!word;
    if (word) {
      $('confirm-word-label').textContent = `Type ${word} to confirm`;
      input.oninput = () => { btn.disabled = input.value.trim() !== word; };
      // Enter would submit the form's first button, which is Cancel.
      input.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); if (!btn.disabled) btn.click(); } };
    }
    const dlg = $('confirm');
    dlg.onclose = () => resolve(dlg.returnValue === 'yes');
    dlg.showModal();
    if (word) input.focus();
  });
}

function ask(id, event) {
  // A question the app knows is asked in its own words; cg's prompt is written
  // for a terminal ("[d] destroy  [n] leave it running:").
  $('ask-prompt').textContent = ASK_QUESTION[event.id] || event.prompt || event.id;
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
  hostSudo:   'host-sudo',
  hostSshPw:  'host-ssh-password',
};
const ASK_QUESTION = {
  [ASK.sessionEnd]: 'Session ended. What should happen to the machine?',
  [ASK.hostSudo]: 'Sudo password for this machine. Used once for setup. Not stored.',
  [ASK.hostSshPw]: 'SSH password. Used once to install a key. Not stored.',
};
const ASK_CHOICE_LABEL = {
  [`${ASK.sessionEnd}:d`]: 'Delete it (recommended; games are saved first)',
  [`${ASK.sessionEnd}:n`]: 'Keep it running (billed hourly)',
};
// Any id the window pre-answers but cg no longer asks under is a modal waiting
// to appear in the middle of a build - which is exactly what this replaced.
async function checkAsks() {
  let asks;
  try { asks = await window.cg.asks(); } catch { return; }
  if (!Array.isArray(asks) || !asks.length) return;   // cg could not be asked
  const gone = Object.values(ASK).filter(id => !asks.includes(id));
  if (gone.length) {
    console.error('This app and its scripts are different versions. The scripts no longer ask: ' + gone.join(', ')
                  + ' - the app cannot answer it.');
    note(`Version mismatch: the scripts no longer ask for ${gone.join(', ')}. `
         + 'Update the app and the scripts together.', 'text-error');
  }
}

const GB = bytes => (bytes / 1073741824).toFixed(1) + ' GB';
// When a game was saved to the archive, as a date: "10 Oct".
const savedOn = iso => iso ? new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) : '—';
// What Build starts billing: the machine card's price, so the two never differ.
function buildRate() {
  return statusNow ? machineFacts().price : null;
}
// A machine's hourly price as billed: the machine, its public address and its
// disk, which all bill by the hour while it exists. Every rate is AWS's, read by
// cg; the rupee rate has GST in it. A GB-month is the hours of this month, as
// cg says them.
function perHour(h, diskGb) {
  const r = (statusNow && statusNow.rates) || {};
  if (h == null || !r.inr_per_usd) return h ?? null;
  const gb = diskGb ?? ((statusNow && statusNow.config) || {}).disk_gb;
  return h + (r.ipv4_hour ? r.ipv4_hour * r.inr_per_usd : 0)
           + (gb && r.ebs_gb_month && r.month_hours ? gb * r.ebs_gb_month / r.month_hours * r.inr_per_usd : 0);
}
// Dollars to rupees at cg's rate today. A saved scan carries the rupees of
// the day it ran; the dollars are AWS's, so they are converted again.
function inrNow(usd, given) {
  const k = statusNow && statusNow.rates && statusNow.rates.inr_per_usd;
  return usd != null && k ? usd * k : given ?? null;
}
// One price, or the spread when the zones disagree.
const hourText = (lo, hi) => lo == null ? null
  : hi != null && Math.round(hi * 100) > Math.round(lo * 100) ? `${rsh(lo)}–${rsh(hi)}` : rsh(lo);
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
  statusAt = new Date().toISOString();
  const wasUp = statusNow && statusNow.box && statusNow.box.state === 'running';
  const isUp = s.box && ['running', 'pending'].includes(s.box.state);
  const checkedAt = lastCost() && lastCost().at;
  if (checkedAt && isUp && !billChangesSince(checkedAt).some(c => c.what === 'a machine was running')) {
    noteBillChange('a machine was running');
  }
  // Ended outside the app - auto-stop, or the console - with no delete here.
  const justDeleted = billChanges().some(c => c.what === 'you deleted the machine'
                                         && Date.now() - Date.parse(c.at) < 15 * 60000);
  if (wasUp && !isUp && !jobsFor('destroy') && !justDeleted) noteBillChange('the machine stopped');
  paintSpec(s);
  statusNow = s;
  resumeBuild(s);
  askPing(s);
  paintOnboardSoon();
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

// What a machine of this type costs an hour, bought this way, in rupees: in
// the cheapest zone, or with `dearest`, the dearest - spot only.
function hourlyInr(type, spot, dearest) {
  const m = machinesNow && (machinesNow.machines || []).find(x => x.type === type);
  if (!m) return null;
  if (spot && dearest) return inrNow(m.usd_hour_spot_max, m.inr_hour_spot_max);
  return spot ? inrNow(m.usd_hour_spot, m.inr_hour_spot) : inrNow(m.usd_hour_ondemand, m.inr_hour_ondemand);
}

// The machine card, drawn the same on Home and the Machine page: what is
// running if something is, otherwise what Build would start. Each page puts its
// own buttons under it.
// A GPU as every screen says it: "NVIDIA T4, 16 GB".
const gpuName = (gpu, vram) => `NVIDIA ${gpu}${vram ? `, ${vram} GB` : ''}`;
// How far a place is, in a word, with the measurement beside it.
const distance = ms => `${ms <= 30 ? 'Close' : ms <= 60 ? 'OK' : 'Far'} (${Math.round(ms)} ms)`;

function machineFacts() {
  const s = statusNow || {};
  const box = s.box && s.box.state !== 'terminated' ? s.box : null;
  const cur = currentPick();
  const region = box ? s.region || cur.region : cur.region;
  const type = box ? box.type : cur.type || s.instance_type;
  const spot = box ? box.lifecycle === 'spot' : cur.spot;
  const rows = chooserRows().rows;
  const hit = rows.find(r => r.region === region && r.type === type);
  const spec = s.spec || {};
  const gpu = hit && hit.gpu ? hit.gpu : spec.gpu;
  const vram = hit && hit.vram;
  // Nothing pins the zone, and spot prices differ by zone. A machine that runs
  // is priced in its own zone; one not built yet is the spread across zones.
  const disk = box ? box.disk_gb : (s.config || {}).disk_gb;
  let lo = null, hi = null;
  if (box && spot && box.az && machinesNow && machinesNow.region === region) {
    const m = (machinesNow.machines || []).find(x => x.type === type);
    const usd = m && m.spot_usd_by_az && m.spot_usd_by_az[box.az];
    if (usd != null) lo = hi = inrNow(usd);
  }
  if (lo == null) {
    lo = (hit && (spot ? hit.spot : hit.od)) ?? hourlyInr(type, spot);
    hi = spot ? (hit ? hit.spotMax : hourlyInr(type, true, true)) ?? lo : lo;
  }
  const price = perHour(lo, disk), priceMax = perHour(hi, disk);
  const priceText = hourText(price, priceMax);
  // Room for games, in the same number the Build page's meter uses: cg's
  // figure for this machine type, less the space kept free. Before that is
  // read, the type's disk as AWS sizes it.
  const lib = libNow || {};
  const store = hit ? hit.store
    : ((machinesNow && (machinesNow.machines || []).find(m => m.type === type)) || {}).store_gb;
  const room = lib.disk_type === type && lib.selectable_gb != null ? `${lib.selectable_gb} GB for games`
    : store != null ? `${store} GB disk` : null;
  return { s, box, cur, rows, hit, region, type, spot, price, priceMax, priceText, room,
           what: [type, gpu ? gpuName(gpu, vram) : null, room].filter(Boolean).join(' · ') || '—',
           where: [region ? placeName(region) : null,
                   box || cfgVal('GAME_SPOT') === '1' ? (spot ? 'Spot' : 'On-demand')
                     : cfgVal('GAME_SPOT') === '0' ? 'On-demand' : 'Spot, else on-demand',
                   priceText ? `${priceText}/hour` : null].filter(Boolean).join(' · ') };
}

function renderMachineCard(card) {
  if (!card || !statusNow) return;
  const f = machineFacts();
  const { s, box, cur, hit, rows, price } = f;
  const credErr = s.error && s.error.credentials;
  const building = jobsFor('init') || unfinished(box);
  const running = !!(box && box.state === 'running');
  const upHours = box && box.launched ? (Date.now() - new Date(box.launched)) / 3600000 : 0;
  const idleGuard = ((watcher && watcher.guards) || []).find(g => g.layer === 2);
  const idleAfter = idleGuard && idleGuard.idle_min != null ? `${idleGuard.idle_min} min` : null;
  let title, sub = '', note = '';
  if (credErr) {
    title = 'Status unknown';
    sub = 'AWS is unreachable.';
  } else if (building) {
    title = 'Building';
    // How long the last build took, as cg measured it; no number until one has.
    const took = (s.build || {}).last_min;
    const last = took != null ? `last build took ${took} min` : '';
    sub = box && box.launched ? [`Started ${uptime(box.launched)} ago`, last].filter(Boolean).join(' · ')
                              : (last ? last[0].toUpperCase() + last.slice(1) : 'Starting');
  } else if (running) {
    title = sessionNow ? 'Playing' : 'Ready to play';
    sub = `Up ${uptime(box.launched)} · ${rs(price != null ? price * upHours : null)} so far`;
    note = sessionNow ? 'Closing Moonlight prompts to keep or delete the machine.'
                      : idleAfter ? `Auto-stops after ${idleAfter} idle.`
                                  : 'Auto-stops when idle.';
  } else if (box) {
    title = `Machine ${box.state}`;
    sub = box.state === 'pending' ? 'Starting.' : box.state === 'stopping' || box.state === 'shutting-down'
      ? 'Shutting down.' : 'Not running.';
  } else {
    title = 'No machine running';
  }
  // What stands in the way of the choice, said where the choice is shown.
  const warn = [];
  if (box && (cur.type !== f.type || cur.region !== f.region))
    warn.push('Changes apply to the next build.');
  else if (!box && hit && cur.spot && hit.score != null && hit.score <= 2)
    warn.push(`Low spot capacity for ${cur.type} here (${hit.score}/10). A spot launch will likely fail.`);
  else if (!box && hit && cur.spot && hit.fitsSpot === false)
    warn.push('Spot quota here is 0.');
  else if (!box && !hit && rows.length)
    warn.push('This machine type is not offered in this region.');
  if (sessionNow && !running)
    warn.push('A session is already open in Moonlight. Only one can run at a time.');

  card.textContent = '';
  const top = el('div', 'flex items-start justify-between gap-space-md');
  const head = el('div', 'min-w-0');
  const t = el('p', 'font-headline-lg text-headline-lg', title); t.dataset.f = 'title';
  head.append(t);
  if (sub) { const p = el('p', 'font-body-md text-body-md text-on-surface-variant mt-space-xs', sub); p.dataset.f = 'sub'; head.append(p); }
  top.append(head);
  if (running || building) {
    const tag = el('span', 'pill shrink-0 pill-ok', building ? 'building' : sessionNow ? 'streaming' : 'running');
    tag.dataset.f = 'tag';
    top.append(tag);
  }
  const mid = el('div', 'flex flex-wrap items-end justify-between gap-space-md mt-space-lg');
  const lines = el('div', 'min-w-0');
  const what = el('p', 'font-code-md text-code-md', f.what); what.dataset.f = 'what';
  const where = el('p', 'font-code-sm text-code-sm text-outline mt-0.5', f.where); where.dataset.f = 'where';
  lines.append(what, where);
  mid.append(lines);
  if (!box && !building) {
    const ch = el('button', 'btn shrink-0', 'Change machine');
    ch.dataset.f = 'change';
    ch.onclick = () => openMachines();
    mid.append(ch);
  }
  card.append(top, mid);
  if (warn.length) { const w = el('p', 'font-code-sm text-code-sm text-tertiary mt-space-sm', warn.join(' · ')); w.dataset.f = 'warn'; card.append(w); }
  if (note) { const n = el('p', 'font-code-sm text-code-sm text-outline mt-space-sm', note); n.dataset.f = 'note'; card.append(n); }
  return f;
}

// The whole card, buttons too, built once per page from one recipe, so the
// two cannot be laid out differently. Ids keep the page's prefix: d- on Home,
// b- on the Machine page. What Build does differs (Home sends you to pick
// games), what the card looks like does not.
function mountMachineCard(box, p) {
  const body = el('div'); body.id = `${p}-machine-card`;
  const busy = el('div', 'onb-progress mt-space-md'); busy.id = `${p}-busy`; busy.hidden = true;
  busy.append(el('i'));
  const row = el('div', 'flex flex-wrap items-center gap-space-sm mt-space-lg');
  const btn = (id, cls, icon, glyph, label) => {
    const b = el('button', cls); b.id = `${p}-${id}`;
    if (icon) {
      const i = el('span', 'material-symbols-outlined text-[16px]', glyph);
      i.dataset.icon = icon;
      b.append(i);
    }
    b.append(document.createTextNode(label));
    row.append(b);
    return b;
  };
  btn('fix', 'btn btn-primary', null, null, 'Finish setting up').hidden = true;
  btn('build', 'btn btn-primary', 'rocket_launch', '\ueb9b', 'Build machine');
  btn('open', 'btn btn-primary', 'stadia_controller', '\uf135', 'Play').hidden = true;
  btn('watch', 'btn', null, null, 'Watch the build').hidden = true;
  btn('destroy', 'btn btn-danger', 'delete', '\ue92e', 'Delete machine').hidden = true;
  box.append(body, busy, row);
}

function paintMachineCards() {
  // AWS added but something it needs is missing - a key AWS rejects, a tool
  // gone: the card says what, with the button that reopens its steps. Never
  // over a machine that is there or being built: that one is shown as itself,
  // whatever the next build would need.
  const there = statusNow && statusNow.box && statusNow.box.state !== 'terminated';
  const stuck = awsAdded() && !there && !jobsFor('init') ? prereqs('aws').find(r => r.ok === false) : null;
  for (const p of ['d', 'b']) {
    if (!$(`${p}-build`)) continue;
    $(`${p}-fix`).hidden = !stuck;
    if (stuck) {
      const card = $(`${p}-machine-card`);
      card.textContent = '';
      const t = el('p', 'font-headline-lg text-headline-lg', 'AWS needs you'); t.dataset.f = 'title';
      card.append(t, el('p', 'font-body-md text-body-md text-on-surface-variant mt-space-xs', stuck.problem.title));
      for (const b of ['build', 'open', 'watch', 'destroy']) $(`${p}-${b}`).hidden = true;
      $(`${p}-busy`).hidden = true;
      continue;
    }
    const { box, s } = renderMachineCard($(`${p}-machine-card`)) || {};
    if (!s) {
      const card = $(`${p}-machine-card`);
      if (card.dataset.state !== 'loading') {
        card.textContent = '';
        card.dataset.state = 'loading';
        card.append(el('p', 'font-body-sm text-body-sm font-medium text-on-surface-variant', 'AWS'),
                    el('span', 'skel mt-space-xs h-9 w-48'), el('span', 'skel mt-space-sm h-4 w-72'));
      }
      for (const b of ['build', 'open', 'watch', 'destroy']) $(`${p}-${b}`).hidden = true;
      $(`${p}-busy`).hidden = false;
      continue;
    }
    const card = $(`${p}-machine-card`);
    if (card.dataset.state === 'loading') { delete card.dataset.state; card.classList.add('card-in'); }
    const building = jobsFor('init') || unfinished(box);
    const running = !!(box && box.state === 'running');
    $(`${p}-busy`).hidden = !building;
    $(`${p}-build`).hidden = !!box || building || !!(s.error && s.error.credentials);
    $(`${p}-open`).hidden = !running || building;
    $(`${p}-watch`).hidden = !building || p === 'b';
    $(`${p}-destroy`).hidden = !box || building;
  }
}

function paintDash() {
  // ── the machine: the Machine page's own card ──
  paintMachineCards();
  const s = awsAdded() ? statusNow : null;
  if (!s) return paintNetwork(null);
  const inr = inrRate();
  const credErr = s.error && s.error.credentials;
  const box = s.box && !['terminated'].includes(s.box.state) ? s.box : null;
  const building = jobsFor('init') || unfinished(box);
  const running = !!(box && box.state === 'running');
  const idleGuard = ((watcher && watcher.guards) || []).find(g => g.layer === 2);
  const idleAfter = idleGuard && idleGuard.idle_min != null ? `${idleGuard.idle_min} min` : null;

  // ── recurring cost and this month: the Spending page's own cards ──
  renderRecurring($('d-recurring-card'), { hint: 'Exact cost reads the bill.' });
  // The same card on Spending, redrawn with it: its play line reads the
  // machine's status, which changes without a Refresh.
  if (costNow) renderRecurring($('c-recurring-card'));
  renderMonth($('d-month-card'), { hint: 'Use Exact cost to load it.' });
  const b = s.budget || {};
  const limit = b.limit == null ? null
    : isFinite(Number(setting('GAME_BUDGET_INR', NaN))) ? Number(setting('GAME_BUDGET_INR', NaN))
    // AWS keeps the budget in dollars with the tax inside it, so it turns back
    // into rupees at the plain exchange rate, not the one with GST added.
    : b.limit * ((s.rates && s.rates.fx_inr_per_usd) || NaN);
  const checked = lastCost();
  showChecked($('d-month-src'), checked ? checked.at : null, true);
  showChecked($('d-bill-src'), checked ? checked.at : null, true);
  const call = (s.rates || {}).ce_call_usd;
  $('d-cost-price').textContent = call && isFinite(inr) ? rs(call * inr) : '';
  // The Cost page's Refresh is the same call, so it carries the same price.
  $('refresh-cost').textContent = $('d-cost-price').textContent;

  // ── your games ──
  // Names, wherever they are kept; size, place and dates are on the Games page.
  const gl = $('d-games');
  gl.textContent = '';
  const a = s.archive || {};
  const say = (text, cls) => gl.append(Object.assign(document.createElement('p'),
    { className: cls || 'text-on-surface', textContent: text }));
  if (credErr || a.error || (libNow && libNow.error)) {
    say('Could not read saved games.', 'text-outline');
  } else if (!libNow) {
    say('Reading…', 'text-outline');
  } else {
    const names = [...(libNow.games || []), ...elsewherePlaces().flatMap(p => p.games || [])]
      .map(g => g.name || g.installdir).filter(Boolean);
    if (!names.length) say('No saved games', 'text-on-surface-variant');
    for (const n of names.slice(0, 5)) say(n);
    if (names.length > 5) say(`and ${names.length - 5} more`, 'text-outline');
  }

  paintNetwork(s);


  // ── protection ──
  const prot = $('d-protect');
  prot.textContent = '';
  const guards = (watcher && watcher.guards) || [];
  const g2 = guards.find(g => g.layer === 2), g3 = guards.find(g => g.layer === 3);
  const lines = [
    // Installed with every build: with no machine there is nothing for it to
    // watch, which is not the same as it being off.
    [g2 ? (g2.armed === false ? false : true) : null,
     idleAfter ? `Auto-stop after ${idleAfter} idle` : 'Auto-stop when idle'],
    [g3 ? g3.armed : null,
     g3 && g3.armed ? 'AWS auto-stop: on' : 'AWS auto-stop: off'],
    [b.limit != null ? true : (statusNow ? false : null),
     b.limit != null ? `Budget alert at ${rs(limit)} · ${b.alerts ? `emails ${b.alerts} address${b.alerts === 1 ? '' : 'es'}` : 'no email set'}`
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

// The private network: this laptop, the AWS machine when there is one, and
// each machine of yours. Own machines only, there is no AWS status at all.
function paintNetwork(s) {
  const box = s && s.box && !['terminated'].includes(s.box.state) ? s.box : null;
  const building = !!s && (jobsFor('init') || unfinished(box));
  // "Your machine" is the AWS one only while it is the only one.
  const it = (hostsNow || []).length ? 'AWS machine' : 'Machine';
  const ts = $('d-ts');
  ts.textContent = '';
  const tn = (s && s.tailnet) || {};
  const tsLines = [];
  // This laptop. null is "not read yet", not "signed out".
  const me = tskeyNow ? tskeyNow.signed_in : null;
  tsLines.push([me === true ? true : me === false ? false : null,
    me === true ? `This device: signed in${tskeyNow.node ? ` as ${tskeyNow.node}` : ''}`
      : me === false ? 'This device: not signed in' : 'Checking this device']);
  // The machine, only if there is one.
  if (!s) {
    // No AWS machine on this laptop: nothing to say about one.
  } else if (!box) {
    tsLines.push([undefined, building ? `${it}: connecting…` : `${it}: joins on build`]);
  } else if (tn.node && tn.online) {
    tsLines.push([true, `${it}: connected`]);
  } else if (tn.node) {
    tsLines.push([false, `${it}: not connected`]);
  } else {
    tsLines.push(building ? [null, `${it}: connecting…`] : [false, `${it}: not connected`]);
  }
  // The path, while the machine is online.
  if (box && tn.online) {
    const ms = pingNow && pingNow.median_ms != null ? ` · ${pingNow.median_ms} ms` : '';
    tsLines.push(!pingNow ? [null, 'Checking the connection']
      : pingNow.path === 'direct' ? [true, `Direct connection${ms}`]
      : pingNow.path === 'DERP' ? ['warn', `Relayed${ms} · higher latency`]
      : [null, 'Connection not measured']);
  }
  for (const h of hostsNow || []) {
    const hs = hostStatus.get(h.name);
    tsLines.push(!hs ? [null, `Checking ${h.name}`]
      : hs.online ? [true, `${h.name}: connected`]
      : [hs.set_up ? false : undefined, hs.set_up ? `${h.name}: not connected` : `${h.name}: joins on setup`]);
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
      ? `a session is already open`
      : 'Opens Moonlight and connects to your machine';
  }
  paintMachineCards();
  paintHostCards();
}


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

// The last bill check: this window's, else the one remembered on this laptop
// from the same month. Last month's total is not this month's.
// The last bill on this laptop, drawn again at start until a new check -
// with when it was checked, so it is never read as current.
function restoreBill() {
  if (costNow) return;
  try {
    const kept = JSON.parse(localStorage.getItem('cg.lastCost') || 'null');
    if (!kept || !kept.bill) return;
    const at = new Date(kept.at), now = new Date();
    if (at.getFullYear() !== now.getFullYear() || at.getMonth() !== now.getMonth()) return;
    costNow = kept.bill;
    costNowAt = at;
    paintCostPage();
    paintDash();
  } catch { /* nothing remembered */ }
}
function lastCost() {
  const m = costNow && costNow.month;
  if (m && m.total_inr != null) return { total_inr: m.total_inr, projected_inr: m.projected_inr ?? null, at: costNowAt.toISOString() };
  try {
    const kept = JSON.parse(localStorage.getItem('cg.lastCost') || 'null');
    const at = kept && new Date(kept.at), now = new Date();
    if (at && at.getFullYear() === now.getFullYear() && at.getMonth() === now.getMonth()) return kept;
  } catch { /* nothing remembered */ }
  return null;
}
// "Checked today 14:15", on any element, red and blinking once it is more
// than a day old. Every "Checked" in the app goes through this.
function showChecked(el, iso, bill = false) {
  if (!el) return;
  el.textContent = iso ? `Checked ${whenChecked(iso)}` : '';
  const old = !!iso && Date.now() - Date.parse(iso) > 86400000;
  // A bill label is also out of date once something since has changed it.
  const since = bill && iso ? billChangesSince(iso) : [];
  el.classList.toggle('out-of-date', old || since.length > 0);
  el.title = !iso ? ''
    : since.length ? `Checked ${whenChecked(iso)}. Since then: `
        + since.map(c => `${c.what} (${whenChecked(c.at)})`).join(', ')
        + '. Refresh for the new total. The AWS bill lags about a day.'
    : old ? `Checked ${whenChecked(iso)}. Over a day old.`
    : '';
}

// What changed the bill after it was checked: actions here that cost or save
// money, and a machine seen running. Kept on this laptop with the bill, and
// cleared by the next check.
const BILL_CHANGE = {
  init: 'you built a machine', destroy: 'you deleted the machine', open: 'you played',
  'library move': 'you moved a game', 'library forget': 'you deleted a game',
  'library clean': 'you cleaned up leftover files',
};
function billChanges() {
  try { return JSON.parse(localStorage.getItem('cg.billChanges') || '[]'); } catch { return []; }
}
// At or after: the list is cleared when a check is made, so anything in it
// came after that check - even within the same millisecond.
const billChangesSince = iso => billChanges().filter(c => Date.parse(c.at) >= Date.parse(iso));
function noteBillChange(what) {
  if (!lastCost()) return;              // nothing checked yet: nothing to go out of date
  const list = billChanges();
  list.push({ what, at: new Date().toISOString() });
  try { localStorage.setItem('cg.billChanges', JSON.stringify(list.slice(-20))); } catch { /* this window only */ }
  paintDash();
  paintRefreshAge();
}
const whenChecked = iso => {
  const d = new Date(iso), hm = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return d.toDateString() === new Date().toDateString() ? `today ${hm}`
    : `${d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })} ${hm}`;
};

function paintSpend(d) {
  // The dashboard shows the last paid fetch and says how old it is. It never
  // fetches on its own: Cost Explorer bills a cent a call.
  costNow = d;
  costNowAt = new Date();
  // Kept on this laptop, so Home is not empty again after a restart; it is
  // shown with when it was checked, never as if it were live.
  const m = d.month || {};
  try { localStorage.removeItem('cg.billChanges'); } catch { /* nothing kept */ }
  if (m.total_inr != null) {
    try {
      localStorage.setItem('cg.lastCost', JSON.stringify({
        total_inr: m.total_inr, projected_inr: m.projected_inr ?? null, at: costNowAt.toISOString(), bill: d }));
    } catch { /* storage unavailable: this window still has it */ }
  }
  paintDash();
}

// Spending's Refresh says what it costs and how old the bill on screen is.
function paintRefreshAge() {
  const el = $('refresh-age');
  showChecked(el, costNowAt ? costNowAt.toISOString() : null, true);
  el.hidden = view !== 'cost' || !costNowAt;
}

function paintCost(d) {
  paintSpend(d);
  paintCostPage();
}
// Redrawn from the last paid answer when a free one lands - the games found in
// other places explain storage the bill charges for - so it never asks again.
// The two cards Home and Spending share, drawn from the last bill check and
// nothing else - so a build changes neither until the bill is checked again,
// and the two pages can never disagree. `hint` is what an unchecked card says.
const el = (tag, cls, text) => Object.assign(document.createElement(tag), { className: cls || '', textContent: text || '' });
function billParts() {
  const d = costNow;
  if (!d) return null;
  const m = d.month || {}, rate = d.rates || {};
  const inr = rate.inr_per_usd || m.inr_per_usd;
  const r = usd => (usd == null || !isFinite(usd) || !inr ? '—' : rs(usd * inr));
  return { d, m, rate, inr, r };
}
function renderMonth(box, { hint } = {}) {
  if (!box) return;
  box.textContent = '';
  const p = billParts();
  const total = el('p', 'font-headline-xl text-headline-xl mt-space-sm');
  total.dataset.f = 'total';
  const sub = el('p', 'font-code-sm text-code-sm text-on-surface-variant mt-space-xs');
  sub.dataset.f = 'sub';
  box.append(total, sub);
  if (!p) { total.textContent = '—'; sub.textContent = hint || ''; return; }
  const { d, m, inr, r } = p;
  const hours = m.hours ? m.hours.on_demand + m.hours.spot : 0;
  const projected = m.projected_usd ?? null;
  const now = new Date();
  const monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0);
  total.textContent = m.total_usd != null ? r(m.total_usd) : '—';
  sub.textContent = m.total_usd == null ? 'No response from AWS.'
    : `so far${(d.rates || {}).tax_pct ? `, with ${d.rates.tax_pct}% GST` : ''} · ${hours.toFixed(1)} h runtime`
      + (projected != null ? ` · projected ${r(projected)} by ${monthEnd.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })}` : '');
  // Your number, in rupees, as you set it. AWS keeps it in dollars, converted
  // when it was made; turned back at today's rate it read Rs 5,412 for 5,000.
  const budget = Number(setting('GAME_BUDGET_INR', NaN));
  const inAws = (d.resources || {}).budget_usd != null;
  if (inAws && isFinite(budget) && projected != null && inr) {
    const over = projected * inr > budget;
    const wrap = el('div', 'h-1.5 rounded-full bg-surface-container mt-space-md overflow-hidden');
    const bar = el('div', 'h-full ' + (over ? 'bg-error' : 'bg-primary'));
    bar.style.width = Math.min(100, (projected * inr / budget) * 100) + '%';
    bar.dataset.f = 'bar';
    wrap.append(bar);
    const chip = el('span', 'pill ml-space-xs ' + (over ? 'pill-bad' : 'pill-ok'), over ? 'over budget' : 'under budget');
    chip.dataset.f = 'chip';
    box.append(wrap);
    sub.append(' ', chip);
  }
  const note = el('p', 'font-code-sm text-code-sm mt-space-sm ' + (inAws ? 'text-outline' : 'text-error'),
    !inAws ? 'No budget alert set in AWS.'
      : isFinite(budget) ? `Budget ${rs(budget)}/month. Alert by email only; nothing is stopped.` : '');
  note.dataset.f = 'note';
  box.append(note);
}
function renderRecurring(box, { hint } = {}) {
  if (!box) return;
  box.textContent = '';
  const p = billParts();
  const head = el('p', 'font-headline-md text-headline-md mt-space-sm');
  head.dataset.f = 'total';
  const sub = el('p', 'font-code-sm text-code-sm text-on-surface-variant mt-0.5', 'Billed monthly, whether or not you play.');
  sub.dataset.f = 'sub';
  box.append(head, sub);
  if (!p) { head.textContent = '—'; sub.textContent = hint || ''; return; }
  const { d, inr, r } = p;
  const standby = d.standby || {}, res = d.resources || {}, arch = d.archive || {};
  // Games cg found in other places bill like any others. What the bill says
  // beyond those is not guessed at here: the bill runs days behind, so a game
  // just deleted read as "storage this app cannot find" for three days.
  const away = elsewherePlaces().filter(x => x.usd_month);
  const awayUsd = away.reduce((a, x) => a + x.usd_month, 0);
  head.textContent = standby.usd_month != null ? `${r(standby.usd_month + awayUsd)} a month` : '—';
  const list = el('div', 'flex flex-col mt-space-sm');
  list.dataset.f = 'rows';
  const line = (label, value, go) => {
    const row = el('div', 'row border-b border-surface-variant/40 last:border-b-0');
    const a = el(go ? 'button' : 'span', 'font-code-sm text-code-sm ' + (go ? 'text-primary hover:underline text-left' : 'text-outline'),
                 go ? `${label} →` : label);
    if (go) a.onclick = go;
    row.append(a, el('span', 'font-code-sm text-code-sm', value));
    list.append(row);
  };
  // One row for saved games, wherever they are; the Games page has them one by one.
  // With none saved there is nothing to charge and nothing to open, so no row.
  const savedBytes = (arch.bytes || 0) + away.reduce((a, x) => a + (x.bytes || 0), 0);
  const savedUsd = (standby.archive_usd_month || 0) + awayUsd;
  if (savedBytes) line('Saved games', `${r(savedUsd)} a month`, () => goView('library'));
  // The machine as the bill saw it: by the hour while it ran, its disk by the
  // month while stopped. Otherwise only a disk a deleted machine left behind.
  if (res.instance) {
    const st = res.instance.state;
    const hr = boxNow ? machineFacts().price : null;
    line(`Machine (${st})`, st === 'running' ? (hr != null ? `${rsh(hr)} an hour` : 'by the hour')
                                             : `${r(standby.volumes_usd_month)} a month`, () => goView('build'));
  } else if (res.volumes_gb) {
    line('Orphaned disk', `${res.volumes_gb} GB · ${r(standby.volumes_usd_month)} a month`);
  }
  if (res.snapshots_gb) line('Snapshots', `${res.snapshots_gb} GB · ${r(standby.snapshots_usd_month)} a month`);
  if (!list.children.length) {
    const none = el('p', 'font-code-sm text-code-sm text-outline', 'Nothing stored.');
    none.dataset.f = 'none';
    list.append(none);
  }
  box.append(list);
  // What playing adds on top: the machine, by the hour.
  const play = machineFacts().priceText;
  if (play != null) {
    const pl = el('p', 'font-code-sm text-code-sm text-on-surface-variant mt-space-sm',
      res.instance && res.instance.state === 'running'
        ? `Running now: +${play}/hour.`
        : `Playing adds ${play}/hour.`);
    pl.dataset.f = 'play';
    box.append(pl);
  }
}

function paintCostPage() {
  const d = costNow;
  if (!d) return;
  const m = d.month || {};
  // Every rate on this screen comes from cg, and one rupee rate converts all
  // of it - cg's own, so the rows add up to the total under them.
  const rate = d.rates || {};
  const inr = rate.inr_per_usd || m.inr_per_usd;
  const r = usd => (usd == null || !isFinite(usd) || !inr ? '—' : rs(usd * inr));
  const short = dt => dt.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  const day = iso => short(new Date(iso + 'T00:00:00'));
  const now = new Date();
  const monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0);

  const hours = m.hours ? m.hours.on_demand + m.hours.spot : 0;
  const projected = m.projected_usd ?? null;
  renderMonth($('c-month-card'), { hint: 'Refresh to load this month\'s bill.' });

  // ── credits ──
  const credits = d.credits_usd;
  $('c-credits').textContent = credits != null ? `${r(credits)} left` : '—';
  $('c-credits-note').textContent = credits == null ? 'Not reported by AWS.'
    : 'Applied before your card is charged'
      + (projected ? ` · about ${Math.round(credits / projected)} months at this rate.` : '.');

  // ── day by day: what you played, the machine, storage, and the rest ──
  $('c-days-note').textContent = 'Days with no charges are omitted. The AWS bill lags about a day.'
    + (inr ? ` ₹${inr} to the dollar.` : '');
  paintRefreshAge();
  const parts = x => ({ machine: x.compute || 0, storage: (x.s3 || 0) + (x.disk || 0),
                        other: (x.egress || 0) + (x.api || 0) + (x.other || 0) });
  const money0 = v => (v ? r(v) : '–');
  const rows = $('c-rows');
  rows.textContent = '';
  const sum = { machine: 0, storage: 0, other: 0 };
  for (const dayRow of m.days || []) {
    const p = parts(dayRow);
    for (const k in sum) sum[k] += p[k];
    const tr = document.createElement('tr');
    tr.className = 'border-b border-surface-variant/40';
    cell(tr, day(dayRow.date), 'pr-space-md text-on-surface-variant whitespace-nowrap');
    cell(tr, dayRow.hours ? `${dayRow.hours.toFixed(1)} h` : '–', 'text-right');
    for (const k of ['machine', 'storage', 'other']) cell(tr, money0(p[k]), 'text-right');
    cell(tr, r(dayRow.total), 'text-right pl-space-md text-primary');
    rows.append(tr);
  }
  const foot = $('c-foot');
  foot.textContent = '';
  if (m.total_usd != null) {
    const tr = document.createElement('tr');
    cell(tr, 'Month so far', 'pr-space-md whitespace-nowrap');
    cell(tr, hours ? `${hours.toFixed(1)} h` : '–', 'text-right');
    for (const k of ['machine', 'storage', 'other']) cell(tr, money0(sum[k]), 'text-right');
    cell(tr, r(m.total_usd), 'text-right pl-space-md text-primary font-medium');
    foot.append(tr);
  }

  renderRecurring($('c-recurring-card'));

  // ── free streaming ──
  const e = m.egress || {};
  // Bitrate decides how fast the free 100 GB goes; it is a setting, not a guess.
  const kbps = Number(setting('GAME_BITRATE_KBPS', 20000));
  const gbPerHour = (kbps * 3600) / 8 / 1e6;
  if (e.gb_used != null) {
    $('c-egress').textContent = `${e.gb_used.toFixed(1)} of ${e.gb_free} GB used this month`;
    $('c-egress-src').textContent = 'From the AWS bill.';
    const pct = Math.min(100, (e.gb_used / e.gb_free) * 100);
    $('c-egress-pct').hidden = false;
    $('c-egress-pct').textContent = `${pct.toFixed(0)}% used`;
    $('c-egress-pct').className = 'pill ' + (pct > 80 ? 'pill-bad' : 'pill-ok');
    $('c-egress-bar').style.width = pct + '%';
    $('c-egress-bar').className = 'h-full ' + (pct > 80 ? 'bg-tertiary' : 'bg-primary');
    // The used figure is measured; the hours are the worst case - what the
    // quality setting would use flat out - so they are said as "at least".
    const fps = setting('GAME_FPS', '60'), res = setting('GAME_RES', null);
    const quality = `${(kbps / 1000).toFixed(0)} Mbps, ${fps} fps, ${res || 'native resolution'}`;
    $('c-egress-note').textContent = e.gb_left > 0
      ? `At ${quality} (~${gbPerHour.toFixed(0)} GB/hour): at least ${Math.floor(e.gb_left / gbPerHour)} free hours left, then ${r(rate.egress_gb)}/GB.`
      : `Free ${e.gb_free} GB used. Streaming costs ${r(rate.egress_gb)}/GB, up to ${r(gbPerHour * rate.egress_gb)}/hour at ${quality}.`;
  }
}
// Games cg saved in a region the machine is no longer built in. They bill like
// any others; they are rows of the one Games table, with their place beside them.
let elsewhereNow = null;
function paintElsewhere(d) {
  elsewhereNow = d;
  paintLibraryPage();
  paintDash();
  if (costNow) paintCostPage();
}
// The places worth a line: anything holding something, or that could not be read.
const elsewherePlaces = () => ((elsewhereNow && elsewhereNow.places) || []).filter(p => p.bytes || p.error);

function paintLibrary(d) {
  libNow = d;                 // first: Home lists these names as it redraws
  paintPicker(d);
  paintArchiveCard(d);
  // cg says which it is; the app must never turn "I could not look" into
  // "there is nothing there".
  paintLogin(d.login);
  paintLibraryPage();
}
let libNow = null;   // the last `cg library list`, for repainting when status lands

// The Library page: in rupees, in the words the rest of the app uses, and with
// where the games are kept and for how long - which come from `cg status`, so
// this repaints when either answer lands.
function paintLibraryPage() {
  paintLoginTable();        // its other places arrive with the games' read
  const d = libNow;
  if (!d || !$('lib-rows')) return;
  const e = elsewhereNow || {};
  // cg's own rate and place ride in these answers, so this never waits for
  // another read - it did, and drew "another place" and "— a month".
  const inr = d.inr_per_usd || e.inr_per_usd || inrRate();
  const r = usd => (usd == null || !isFinite(inr) ? '—' : rs(usd * inr));
  const here = d.region || e.region || (statusNow && statusNow.region) || null;
  const rows = $('lib-rows'), foot = $('lib-foot');
  rows.textContent = ''; foot.textContent = '';
  $('lib-error').hidden = !d.error;
  if (d.error) {
    $('lib-error').textContent = `Could not read saved games: ${d.error}`;
    $('lib-keep').textContent = '';
    $('lib-keepfor-row').hidden = true;
    $('lib-orphan-box').hidden = true;
    return;
  }
  // Every game, wherever it is kept: the machine's place first, then the rest.
  const games = (d.games || []).map(g => ({ ...g, region: here, bucket: null }));
  for (const p of e.places || []) {
    if (p.error) continue;
    for (const g of p.games || []) games.push({ ...g, region: p.region, bucket: p.bucket });
  }
  games.sort((a, b) => (a.bucket ? 1 : 0) - (b.bucket ? 1 : 0) || (b.bytes || 0) - (a.bytes || 0));

  const days = d.expiry_days ?? e.expiry_days;
  const seen = d.last_seen || e.last_seen || null;
  const marks = d.marks_read !== false;
  if (!games.length) {
    const tr = document.createElement('tr');
    cell(tr, 'No saved games. Games are saved when a machine is deleted.', 'py-space-sm text-outline').colSpan = 6;
    rows.append(tr);
  }
  for (const g of games) {
    const tr = document.createElement('tr');
    tr.className = 'border-b border-surface-variant/40';
    cell(tr, g.name || g.installdir || g.appid, 'py-space-sm pr-space-md text-on-surface');
    cell(tr, g.region ? placeName(g.region) : '—', 'px-space-md text-on-surface-variant');
    cell(tr, GB(g.bytes), 'text-right px-space-md text-on-surface-variant whitespace-nowrap');
    cell(tr, r(g.usd_month), 'text-right px-space-md text-on-surface-variant');
    cell(tr, deleteOn(g, days, seen, marks), 'text-right px-space-md text-on-surface-variant whitespace-nowrap');
    const act = cell(tr, '', 'text-right pl-space-md whitespace-nowrap');
    act.className += ' space-x-space-xs';
    // A game found only by its folder has no id, and cg acts on ids.
    if (g.appid) {
      const btn = (label, fn) => {
        const b = document.createElement('button');
        b.className = 'btn'; b.textContent = label; b.onclick = fn;
        act.append(b);
      };
      if (days) btn('Keep', () => resetGame(g));
      if (g.bucket) btn('Move', () => moveGame(g, here, inr));
      btn('Delete', () => forgetGame(g));
    }
    rows.append(tr);
  }
  for (const p of e.places || []) {
    if (!p.error) continue;
    const tr = document.createElement('tr');
    cell(tr, `Could not read saved games in ${p.region ? placeName(p.region) : 'another region'}: ${p.error}`,
         'py-space-sm text-error').colSpan = 6;
    rows.append(tr);
  }
  if (games.length) {
    const tr = document.createElement('tr');
    const usd = games.reduce((a, g) => a + (g.usd_month || 0), 0);
    cell(tr, 'Total', 'py-space-sm pr-space-md text-outline');
    cell(tr, '', '');
    cell(tr, GB(games.reduce((a, g) => a + (g.bytes || 0), 0)), 'text-right px-space-md whitespace-nowrap');
    cell(tr, `${r(usd)} a month`, 'text-right px-space-md whitespace-nowrap');
    cell(tr, '', ''); cell(tr, '', '');
    foot.append(tr);
  }

  // How long: one setting, chosen here and applied at once (cg library keep-for).
  const sel = $('lib-keepfor');
  $('lib-keepfor-row').hidden = days == null;
  if (days != null) {
    const opts = [7, 14, 30, 60, 0];
    if (!opts.includes(days)) opts.splice(-1, 0, days);
    sel.textContent = '';
    for (const n of opts) {
      sel.append(Object.assign(document.createElement('option'),
        { value: String(n), textContent: n ? `${n} days` : 'Forever' }));
    }
    sel.value = String(days);
  }
  $('lib-keep').textContent = !games.length ? ''
    : !days ? 'Kept until deleted.'
    : `Deleted ${days} days after last played. Keep resets the timer.`;

  $('lib-orphan-box').hidden = !d.orphan_bytes;
  if (d.orphan_bytes) {
    $('lib-orphans').textContent =
      `${(d.orphan_bytes / 1073741824).toFixed(1)} GB of files from an incomplete save`
      + ` · ${r(d.orphan_usd_month)}/month, unused.`;
  }
}

// When the cloud watchdog deletes a game: N days after the later of the last
// machine and the game's own Reset. A machine that exists keeps everything.
function deleteOn(g, days, seen, marks) {
  if (days === 0) return 'never';
  if (days == null || !marks) return '—';
  if (boxNow) return 'Kept while running';
  if (!seen) return '—';
  const from = Math.max(Date.parse(seen), g.kept ? Date.parse(g.kept) : 0);
  const when = new Date(from + days * 86400000);
  return when <= new Date() ? 'today'
    : when.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

// --from names the place for a game kept outside the machine's own; cg checks
// it is one of this rig's before it touches anything.
const fromArgs = g => (g.bucket ? ['--from', g.bucket] : []);

async function resetGame(g) {
  const name = g.name || g.appid;
  await libraryRun(['library', 'reset', String(g.appid), ...fromArgs(g)], `Resetting timer for ${name}`);
}

async function moveGame(g, here, inr) {
  const name = g.name || g.appid;
  const to = here ? placeName(here) : 'the machine region';
  // Billed where the bytes leave, at that place's own price; inside one
  // location a copy has no transfer charge at all.
  const place = elsewherePlaces().find(p => p.bucket === g.bucket) || {};
  const same = here && g.region === here;
  const rate = place.xregion_usd_gb;
  const cost = !same && rate && isFinite(inr) ? rs((g.bytes / 1073741824) * rate * inr) : null;
  const ok = await askConfirm({
    title: `Move ${name} to ${to}?`,
    body: `${GB(g.bytes)} is copied from ${placeName(g.region)} to ${to}, verified, then removed from ${placeName(g.region)}.\n\n`
        + (same ? 'Same region: no transfer charge. '
           : cost ? `One-time transfer: about ${cost}. ` : '')
        + 'Storage cost is unchanged.',
    yes: 'Move',
  });
  if (ok) await libraryRun(['library', 'move', String(g.appid), ...fromArgs(g)], `Moving ${name} to ${to}`, 'move-game', 'MOVE');
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
  const name = g.name || g.appid;
  const ok = await askConfirm({
    title: `Delete ${name}?`,
    body: `Permanently deletes the ${GB(g.bytes)} saved copy.\n\n`
        + 'Steam will re-download it next time.',
    yes: 'Delete', danger: true, word: 'DELETE',
  });
  // cg asks for FORGET; the word typed here is the app's own, and the answer
  // handed to cg is cg's.
  if (ok) await libraryRun(['library', 'forget', String(g.appid), ...fromArgs(g)], `Deleting ${name}`, 'forget-game', 'FORGET');
}

// The word typed in the app's own dialog, handed to cg when it asks for it.
let typedPending = null;
const typedAnswer = askId => (typedPending && typedPending.askId === askId ? typedPending.word : null);

// A change to the saved games, run where you asked for it. The popup says what
// is happening; when cg is done the same popup reads everything again and
// closes (afterWrite), and you are still on Library. Only a refusal keeps it
// open, with cg's reason.
async function libraryRun(args, doing, askId, word) {
  typedPending = askId ? { askId, word } : null;
  const dlg = $('refdlg');
  $('refdlg-title').textContent = doing;
  $('refdlg-sub').textContent = '';
  $('refdlg-menu').hidden = true;
  // Under the title, what cg is doing - its own steps as they arrive, each
  // ticked when the next begins. It used to repeat the title, word for word.
  const list = $('refdlg-list');
  list.textContent = '';
  let current = null;
  const step = text => {
    if (current) current.firstChild.replaceWith(Object.assign(document.createElement('span'),
      { className: 'w-4 text-center font-code-md text-code-md text-primary', textContent: '✓' }));
    current = document.createElement('div');
    current.className = 'flex items-start gap-space-sm font-body-md text-body-md';
    current.dataset.step = text;
    current.append(Object.assign(document.createElement('span'), { className: 'spinner mt-0.5' }),
                   Object.assign(document.createElement('div'), { textContent: text }));
    list.append(current);
  };
  step('Working…');
  let first = true;
  const onStep = text => {
    const plain = text.replace(/\b(?:af|ap|ca|eu|il|me|mx|sa|us)-[a-z]+-\d\b/g, code => placeName(code));
    const said = plain.charAt(0).toUpperCase() + plain.slice(1);
    // The placeholder gives way to cg's first real step rather than being ticked.
    if (first) { first = false; list.textContent = ''; current = null; }
    step(said);
  };
  if (!dlg.open) dlg.showModal();
  const { rc, err } = await runCg(args, { wantRc: true, onStep });
  typedPending = null;
  if (rc === 0) return;
  const why = (err || '').trim().split('\n').filter(Boolean).slice(-2).join(' ')
    || `cg ${args.join(' ')} stopped (exit ${rc})`;
  $('refdlg-title').textContent = `${doing} - not done`;
  $('refdlg-sub').textContent = 'Nothing was changed.';
  list.textContent = '';
  const bad = document.createElement('div');
  bad.className = 'flex items-start gap-space-sm font-body-md text-body-md';
  bad.dataset.state = 'failed';
  bad.append(Object.assign(document.createElement('span'), { className: 'w-4 text-center text-error', textContent: '✗' }),
             Object.assign(document.createElement('div'), { className: 'font-code-sm text-code-sm text-on-surface-variant break-words', textContent: why }));
  list.append(bad);
  $('refdlg-menu').hidden = false;
  if (!dlg.open) dlg.showModal();
  $('refdlg-close').focus();
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
    line.textContent = 'Reading…';
    note.textContent = '';
    return;
  }
  // The choice is only worth offering when there is a saved login to use.
  const sel = $('b-login-choice');
  sel.hidden = !loginNow.present;
  if (loginNow.present) {
    const acct = ((loginNow.accounts || []).find(a => a.most_recent) || (loginNow.accounts || [])[0]);
    const name = acct ? (acct.account || acct.steamid) : 'the saved account';
    sel.textContent = '';
    sel.append(Object.assign(document.createElement('option'), { value: 'use', textContent: `Sign in as ${name}` }),
               Object.assign(document.createElement('option'), { value: 'fresh', textContent: 'Ask me to sign in' }));
    sel.value = fresh ? 'fresh' : 'use';
  }
  if (fresh) {
    line.textContent = 'You sign in on the machine';
    note.textContent = loginNow.present
      ? 'Saved login kept, not used.'
      : 'No saved login.';
    return;
  }
  if (!loginNow.present) {
    line.textContent = 'You sign in on the machine';
    note.textContent = 'No saved login. Saved when a machine shuts down.';
    return;
  }
  // Which account, when the archive says: a key that signs in as someone you
  // did not expect is the thing worth catching before a build, not after it.
  const who = (loginNow.accounts || []).find(a => a.most_recent) || (loginNow.accounts || [])[0];
  line.textContent = who ? `Signs in as ${who.account || who.steamid}` : 'Signs in with your saved login';
  note.textContent = loginNow.accounts === null
    ? 'Uses the saved login (account name unavailable).'
    : 'Steam starts signed in.';
}

function paintLogin(l) {
  loginNow = l === undefined ? null : l;
  paintBuildLogin();
  paintLoginTable();
}

// One row per saved login: the one beside the machine, which a new machine
// signs in as, and any copy a region move left beside games elsewhere.
function paintLoginTable() {
  const rows = $('lib-login-rows'), note = $('lib-login-note');
  if (!rows) return;
  rows.textContent = '';
  note.textContent = '';
  const l = loginNow;
  const here = (libNow && libNow.region) || (elsewhereNow && elsewhereNow.region)
    || (statusNow && statusNow.region) || null;
  const saved = iso => {
    if (!iso) return '—';
    const d = new Date(iso);
    return d.toDateString() === new Date().toDateString() ? 'today'
      : d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  };
  const who = a => (a === null || a === undefined ? 'Name unknown'
    : a.map(r => r.account || r.persona || r.steamid || '?').join(', '));
  const line = (detail, place, status, bucket) => {
    const tr = document.createElement('tr');
    tr.className = 'border-b border-surface-variant/40';
    cell(tr, who(detail.accounts), 'py-space-sm pr-space-md text-on-surface');
    cell(tr, place ? placeName(place) : '—', 'px-space-md text-on-surface-variant');
    cell(tr, `${((detail.bytes || 0) / 1024).toFixed(1)} KB`, 'text-right px-space-md text-on-surface-variant whitespace-nowrap');
    cell(tr, saved(detail.modified), 'text-right px-space-md text-on-surface-variant whitespace-nowrap');
    cell(tr, status, 'px-space-md ' + (bucket ? 'text-outline' : 'text-primary'));
    const act = cell(tr, '', 'text-right pl-space-md');
    const b = document.createElement('button');
    // The one in use is red: forgetting it is what changes the next machine.
    b.className = bucket ? 'btn' : 'btn btn-danger';
    b.textContent = 'Remove';
    b.onclick = () => forgetLogin(detail, bucket, place);
    act.append(b);
    rows.append(tr);
  };
  const say = (text, cls) => {
    const tr = document.createElement('tr');
    cell(tr, text, 'py-space-sm ' + (cls || 'text-outline')).colSpan = 6;
    rows.append(tr);
  };
  if (!l) say('Could not read the saved login.', 'text-error');
  else if (!l.present) say('No saved Steam login. You sign in once on the next machine.');
  else line(l, here, 'In use', null);
  for (const p of (elsewhereNow && elsewhereNow.places) || []) {
    if (p.error || !p.login_detail || !p.login_detail.present) continue;
    line(p.login_detail, p.region, 'Old copy', p.bucket);
  }
  if (l && l.present) {
    const accts = l.accounts || [];
    const next = accts.find(r => r.most_recent) || accts[0];
    note.textContent = (next ? `A new machine signs in as ${next.account || next.persona || next.steamid}. ` : '')
      + 'Removing it does not reduce cost.'
      + (accts.length > 1 ? ` ${accts.length} accounts are saved together and come back together; to keep `
        + 'only one, sign in as it on the machine and it is saved when the machine shuts down.' : '');
  }
}

async function forgetLogin(l, bucket, place) {
  const rows = l.accounts || [];
  const who = rows.length ? rows.map(r => r.account || r.steamid || '?').join(', ') : 'the saved account';
  const where = place ? placeName(place) : '';
  const ok = await askConfirm(bucket ? {
    title: `Remove the old Steam login in ${where}?`,
    body: `An unused copy for ${who}. This cannot be undone.\n\n`
        + 'The active login and your games are not affected.',
    yes: 'Remove', word: 'REMOVE',
  } : {
    title: 'Remove the saved Steam login?',
    body: `Deletes the saved login for ${who}. This cannot be undone.\n\n`
        + 'Games are not affected. The next machine asks for your password and Steam Guard code.',
    yes: 'Remove', danger: true, word: 'REMOVE',
  });
  if (ok) await libraryRun(['library', 'account', 'forget', ...(bucket ? ['--from', bucket] : [])],
                          bucket ? `Removing the old Steam login in ${where}` : 'Removing the Steam login',
                          'forget-login', 'FORGET');
}

function paintArchiveCard() { paintDash(); }

function paintGuardStrip() { paintDash(); }

// The three nets in plain words. The minutes are cg's, read from the settings
// the watchdogs run with; the wording around them is the page's.
const NET_NAME = { 1: 'When you quit', 2: 'On the machine', 3: 'In AWS' };
function netWords(g, d) {
  if (g.layer === 1) return ['Closing Moonlight ends the session.', 'Runs on this device.'];
  if (g.layer === 2) {
    const sd = d.shutdown_action || {};
    const end = sd.expected
      ? ` Then ${sd.value === 'terminate' ? 'deleted' : 'stopped'}.` : '';
    // Every number is cg's (cg watcher), none is a fallback written here.
    return [`Shuts down after ${g.idle_min != null ? `${g.idle_min} min` : 'a period'} with no connection.${end}`,
            'Runs on the machine.'];
  }
  return [`${g.every_min != null ? `Every ${g.every_min} min: ` : ''}ends the machine after ${g.idle_min ?? '?'} min without a stream, or a shutdown stuck for `
          + `${g.stuck_min ?? '?'} min.`,
          'Runs in AWS, independent of this device and the machine.'];
}
function netState(g) {
  if (g.layer === 1) return ['Always on', 'pill-ok'];
  if (g.armed === true) return ['On', 'pill-ok'];
  if (g.armed === false) return ['Off', 'pill-bad'];
  // Layer 2 with no machine to live on is waiting, not failing.
  return [g.state === 'no box' ? 'Idle' : 'Unreachable', ''];
}

function paintGuards(d) {
  watcher = d;
  paintGuardStrip();
  const guards = d.guards || [];
  const by = n => guards.find(g => g.layer === n) || {};
  const running = d.instance_state === 'running';
  const gone = ['none', 'terminated', '', undefined, null].includes(d.instance_state);
  const on = guards.filter(g => g.layer === 1 || g.armed === true).length;

  $('g-head').textContent = running
    ? `Machine running · ${on === guards.length ? `all ${on}` : `${on} of ${guards.length}`} safeguards on`
    : gone ? 'No machine running' : `Machine ${d.instance_state}`;
  const cloud = by(3);
  $('g-sub').textContent = cloud.last_decision
    ? `Last check ${ago(cloud.last_decision_age_s)}: ${/nothing to do/.test(cloud.last_decision) ? 'idle.' : cloud.last_decision}`
    : cloud.armed ? 'Runs every 5 minutes. No activity in the last hour.' : '';

  // What is wrong, in red, on top - not three cards down.
  const warn = [];
  if (cloud.armed === false) warn.push(`AWS auto-stop is ${cloud.state || 'off'}.`);
  if (running && by(2).armed === false) warn.push("The machine's own check is off - only AWS will stop it.");
  const sd = d.shutdown_action || {};
  if (sd.expected && !sd.ok) warn.push(`Shutdown behavior is ${sd.value === 'terminate' ? 'delete' : 'stop'}; expected ${sd.expected === 'terminate' ? 'delete' : 'stop'}.`);
  if ((d.budget || {}).usd == null) warn.push('No budget alert set in AWS.');
  $('g-warn').textContent = '';
  for (const w of warn) {
    const el = document.createElement('span');
    el.textContent = w;
    $('g-warn').append(el);
  }
  $('g-warn').hidden = !warn.length;

  const nets = $('g-nets');
  nets.textContent = '';
  for (const g of guards) {
    const [what, needs] = netWords(g, d);
    const [state, tone] = netState(g);
    const row = document.createElement('div');
    row.className = 'flex items-start gap-space-md py-space-sm border-b border-surface-variant/40 last:border-b-0';
    row.innerHTML = `
      <span class="font-code-md text-code-md text-outline w-4 shrink-0"></span>
      <span class="font-code-md text-code-md w-40 shrink-0"></span>
      <div class="flex-1 min-w-0">
        <p class="font-code-sm text-code-sm"></p>
        <p class="font-code-sm text-code-sm text-outline mt-0.5"></p>
      </div>
      <span class="pill shrink-0 ${tone}"></span>`;
    const [n, name, , pill] = row.children;
    n.textContent = g.layer;
    name.textContent = NET_NAME[g.layer] || g.name;
    row.querySelector('p').textContent = what;
    row.querySelectorAll('p')[1].textContent = needs;
    pill.textContent = state;
    nets.append(row);
  }

  // The settings behind them, read from the settings registry and edited
  // through cg like every other setting.
  const knobs = $('g-knobs');
  knobs.textContent = '';
  const WANT = ['GAME_BUDGET_INR', 'EMAIL_ALERTS', 'GAME_WATCHDOG_IDLE_MIN',
                'GAME_WATCHDOG_STUCK_MIN', 'GAME_NTFY_URL'];
  for (const key of WANT) {
    const r = config.find(x => x.key === key);
    if (!r) continue;
    const row = document.createElement('div');
    // Wraps rather than squeezes, as settingRow's do.
    row.className = 'row flex-wrap border-b border-surface-variant/40 last:border-b-0 items-start';
    row.dataset.key = key;          // so anything can send you to this one row
    const left = document.createElement('div');
    left.className = 'min-w-[12rem] flex-1';
    const n = document.createElement('p');
    n.className = 'font-code-md text-code-md';
    n.textContent = PLAIN[key] || label(r);
    const note = document.createElement('p');
    note.className = 'font-code-sm text-code-sm text-outline mt-0.5';
    note.textContent = PLAIN_NOTE[key] || r.note;
    left.append(n, note);
    const right = document.createElement('div');
    right.className = 'flex items-center gap-space-sm min-w-0 max-w-full ml-auto';
    const val = document.createElement('span');
    val.className = 'font-code-md text-code-md text-on-surface-variant text-right min-w-0 [overflow-wrap:anywhere]';
    const v = r.value != null ? r.value : r.default;
    val.textContent = key === 'GAME_BUDGET_INR' && v != null ? `${rs(Number(v))} a month`
      : /_MIN$/.test(key) && v != null ? `${v} min${r.value == null ? ' (default)' : ''}`
      // No topic means your phone hears nothing, which is "off", not "not set".
      : key === 'GAME_NTFY_URL' && !r.is_set ? 'off'
      : settingValue(r);
    const edit = document.createElement('button');
    edit.className = 'btn';
    edit.textContent = r.secret && r.is_set ? 'Replace' : 'Edit';
    edit.onclick = () => editSetting(r, row);
    right.append(val, edit);
    row.append(left, right);
    knobs.append(row);
  }
}

// --- Settings ----------------------------------------------------------------
// Every row comes from `cg config --json`, and every change goes back through
// `cg config set`, which validates it and writes .env. The app never touches
// the file, and never sees a secret: it can replace one, not read it.
// A setting's name is cg's to give: `cg config --json` carries `label` and
// `group`. This file kept its own table of both, so a setting cg grew appeared
// in the window as a raw GAME_SHOUTING_KEY until someone added it here too.
const label = r => r.label || r.key;

// --- Tools on this laptop ---------------------------------------------------
// What cg needs here. There is no page for it: setup lists what is missing and
// installs it in place, and anything that goes missing later is offered as an
// Install button where it is noticed. A page of green ticks was all that was
// left of it once setup could do its job.
let depsNow = null, credsNow = null, tskeyNow = null;
function paintDeps(d) {
  paintOnboardSoon();
  depsNow = d;
  paintOnboardSoon();
}

// The button for tools that are missing: Install, when this laptop can install
// at all - and otherwise the command to run by hand, because an Install button
// that cannot install anything is worse than none.
function toolAction(tools) {
  const all = (depsNow && depsNow.tools) || [];
  const rows = tools.map(t => all.find(x => x.tool === t) || { tool: t, label: t === 'aws' ? 'the AWS CLI' : t });
  const names = rows.map(x => x.label || x.tool).join(', ');
  // Not read yet: offer it, and cg says so if it cannot.
  if (!depsNow || (depsNow.package_manager && depsNow.root)) {
    return { label: `Install ${names}`, go: () => installDeps(tools) };
  }
  return { label: `How to install ${names}`, go: () => askConfirm({
    title: `Install ${names} by hand`,
    body: (depsNow && !depsNow.package_manager ? 'No supported package manager found. '
           : `Install permission denied${depsNow && depsNow.root_blocked ? ` (${depsNow.root_blocked})` : ''}. `)
      + 'Run the following, then Refresh:\n\n' + rows.map(x => x.manual || x.plan || x.tool).join('\n'),
    yes: 'OK', no: null,
  }) };
}

function installDeps(tools) {
  const what = tools.length === 1 ? tools[0] : 'what is missing';
  return runInDialog({
    title: `Installing ${what}`,
    args: ['deps', 'install', ...tools],
    starting: 'Waiting for your password. The prompt may open behind this window.',
    done: 'Installed',
    fail: rc => 'Install failed.',
  });
}

// The AWS access key: three states, and the third is why this card exists at
// all. No CLI is not a rejected key, and a rejected key is not an absent one -
// a new laptop hits the first and used to be told the second.
function paintCreds(c) {
  credsNow = c;
  paintOnboardSoon();
  const state = $('creds-state'), detail = $('creds-detail'), btn = $('creds-set');
  btn.hidden = false;
  if (!c.cli) {
    state.textContent = 'The AWS CLI is not installed';
    state.className = 'font-code-md text-code-md text-error mt-space-sm';
    detail.textContent = 'Install it, then add your key.';
    const act = toolAction(['aws']);
    btn.textContent = act.label;
    btn.onclick = act.go;
    return;
  }
  btn.textContent = c.key_id ? 'Update access key' : 'Add access key';
  btn.onclick = setCreds;
  if (c.valid) {
    state.textContent = `Key ${c.key_id || ''} is working`.replace('  ', ' ');
    state.className = 'font-code-md text-code-md text-on-surface mt-space-sm';
    // The account is the thing worth seeing on a new laptop: a key that works
    // for the WRONG account reads as "fine" everywhere else in the app.
    detail.textContent = [c.account && `AWS account ${c.account}`]
      .filter(Boolean).join('  \u00b7  ');
    return;
  }
  state.textContent = c.key_id ? `Key ${c.key_id} was rejected` : 'No key added';
  state.className = 'font-code-md text-code-md text-error mt-space-sm';
  detail.textContent = c.error || 'Rejected by AWS.';
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
  paintDash();
  paintOnboardSoon();
  const state = $('tskey-state'), detail = $('tskey-detail'), btn = $('tskey-set');
  const canRootNow = Boolean(depsNow && depsNow.root);
  const signed = ts.signed_in === true ? `Signed in${ts.node ? ' as ' + ts.node : ''}`
    : ts.signed_in === false
      ? (canRootNow ? 'Not signed in' : 'Not signed in. Run: sudo tailscale up')
    : 'Tailscale is not installed';
  const token =
      !ts.present      ? 'No access token (optional)'
    : ts.valid         ? 'Access token is working'
    : ts.valid === false ? 'Access token was rejected'
    // Unreachable says nothing about the token, so it must not be drawn as a
    // bad one: the fix for a flat network is not a new token.
    : 'Access token saved; Tailscale did not respond';
  state.textContent = signed;
  state.className = 'font-code-md text-code-md mt-space-sm '
    + (ts.signed_in === true ? 'text-on-surface' : 'text-error');
  detail.textContent = token;
  // The box's own key. It is not the token and cannot be: `tailscale up` takes
  // a node registration key, and the token has no business in EC2 user-data.
  // With a token here, nobody has to paste one.
  $('tskey-auth').textContent =
      ts.auth_key_stored && ts.can_mint
        ? 'Auth key saved'
    : ts.auth_key_stored ? 'Auth key saved'
    : ts.can_mint        ? 'An auth key is generated from the access token at the next build'
    : 'No auth key. The next build asks for one.';
  btn.textContent = ts.present ? 'Update access token' : 'Add access token';
  btn.onclick = openTskey;
  // Pasting the box's key is for when the token cannot make one: no token, or
  // a tailnet whose ACLs will not issue an untagged key. With a working token
  // there is nothing to type, so there is no button.
  const authBtn = $('tskey-authkey');
  authBtn.hidden = ts.can_mint && !ts.auth_key_stored;
  authBtn.textContent = ts.auth_key_stored ? 'Update auth key' : 'Add auth key';
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
let runDlgJob = null, runDlgRetry = null, runDlgRc = null;
let runDlgConfirm = null;   // the confirm step's answer, while it is asking
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
//   confirm  optional { body, yes, danger }: the same dialog asks first, and the
//            run happens in it - no confirm box that closes onto nothing
//   close    on success, close after a beat (given cg's output: false keeps it
//            open, for a result worth reading)
//   stoppable false for a run that is over in seconds and must not be left
//            half done: no Cancel while it runs
//   after    on success, what has to happen before it is shown as done -
//            re-reading what the change touched - given cg's output; the
//            dialog keeps loading until it has
// Resolves true on success; `false` when it failed or was not confirmed.
async function runInDialog({ title, args, starting, done, fail, confirm, close, stoppable = true, after }) {
  const log = $('rundlg-log'), link = $('rundlg-link'), go = $('rundlg-go');
  $('rundlg-title').textContent = title;
  link.hidden = true;
  go.hidden = true;
  $('rundlg-busy').hidden = true;
  if (confirm) {
    log.textContent = '';
    $('rundlg-status').textContent = confirm.body;
    $('rundlg-status').className = 'dlg-sub whitespace-pre-line mb-space-md';
    $('rundlg-done').hidden = true;
    $('rundlg-retry').hidden = true;
    $('rundlg-cancel').hidden = false;
    $('rundlg-cancel').textContent = 'Cancel';
    go.hidden = false;
    go.textContent = confirm.yes || 'Continue';
    go.className = 'btn ' + (confirm.danger ? 'btn-danger' : 'btn-primary');
    if (!$('rundlg').open) $('rundlg').showModal();
    go.focus();
    const yes = await new Promise(resolve => {
      runDlgConfirm = resolve;
      go.onclick = e => { e.preventDefault(); resolve(true); };
    });
    runDlgConfirm = null;
    go.hidden = true;
    if (!yes) return false;
  }
  runSurface = { link: 'rundlg-link', log: 'rundlg-log', status: runDlgStatus };
  runDlgRetry = () => runInDialog({ title, args, starting, done, fail, close, stoppable, after });
  $('rundlg-done').hidden = true;
  $('rundlg-done').textContent = 'Done';
  $('rundlg-retry').hidden = true;
  $('rundlg-cancel').hidden = !stoppable;
  log.textContent = '';
  // The first line cg sends replaces the placeholder rather than appending
  // under it - see the collect handler.
  log.dataset.fresh = 'yes';
  runDlgStatus(starting);
  $('rundlg-busy').hidden = false;
  if (!$('rundlg').open) $('rundlg').showModal();
  const { rc, err } = await runCg(args, { collect: 'rundlg-log', wantRc: true,
                                          onStart: id => { runDlgJob = id; } });
  runDlgJob = null;
  runDlgRc = rc;
  link.hidden = true;
  $('rundlg-cancel').hidden = true;
  if (rc === 0 && after) {
    // Still loading: done is said once what it changed has been read again.
    runDlgStatus('Updating…');
    try { await after(err || ''); } catch { /* the screens say what they could not read */ }
  }
  $('rundlg-busy').hidden = true;
  if (rc === 0) {
    // Everything behind the dialog has already re-read: these are writes.
    runDlgStatus(typeof done === 'function' ? done(err || '') : done, 'ok');
    $('rundlg-done').hidden = false;
    $('rundlg-done').focus();
    if (close && close(err || '')) afterBeat(() => { if ($('rundlg').open) $('rundlg').close(); });
    return true;
  }
  runDlgStatus(rc === null ? 'Another task is running.'
                           : (typeof fail === 'function' ? fail(rc) : fail), 'bad');
  $('rundlg-retry').hidden = false;
  $('rundlg-done').hidden = false;
  $('rundlg-done').textContent = 'Close';
  return false;
}
$('rundlg-done').onclick = e => { e.preventDefault(); $('rundlg').close(); };
// Closed while it is still asking: a no.
$('rundlg').addEventListener('close', () => { if (runDlgConfirm) runDlgConfirm(false); });
$('rundlg-retry').onclick = e => { e.preventDefault(); if (runDlgRetry) runDlgRetry(); };
// Cancelling has to reach cg: `tailscale up` is waiting on a browser that is
// never going to answer, and a package manager can be sitting on a lock.
// Closing a dialog does not tell either of them that.
$('rundlg-cancel').onclick = e => {
  e.preventDefault();
  if (runDlgConfirm) runDlgConfirm(false);
  if (runDlgJob !== null) window.cg.cancel(runDlgJob);
  runDlgJob = null;
  $('rundlg').close();
};
function signInTailscale() {
  return runInDialog({
    title: 'Signing in to Tailscale',
    args: ['creds', 'tailscale', 'signin'],
    starting: 'Starting. A password prompt may open behind this window.',
    done: () => (tskeyNow && tskeyNow.node) ? `signed in as ${tskeyNow.node}` : 'signed in',
    fail: rc => 'Sign-in failed.',
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
  runSurface.status('Complete sign-in in your browser.');
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
  PENDING: ['Sent',
            'Submitted. It appears within a few minutes.'],
  CASE_OPENED: ['Being reviewed',
            'First requests are usually denied. Reply with the text below to get a manual review (2-4 days).'],
  DENIED: ['Denied',
            'Reply to the case with the text below to request a review.'],
  CASE_CLOSED: ['Closed',
            'Closed without an increase. Submit a new request.'],
  APPROVED: ['granted',
            'May take up to an hour to appear.'],
};
const QUOTA_LABEL = { ondemand: 'standard', spot: 'spot' };
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
  $('quota-copy').textContent = 'Copy reply';
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
  $('quota-go').textContent = 'Submit request';
  if (!kind) {
    quotaSay('', 'Select a quota.');
    return;
  }
  const q = (quotaNow || {})[kind];
  if (!q) { quotaSay('Could not read this quota', '', 'bad'); return; }
  const need = quotaNow.vcpus_needed, type = quotaNow.instance_type;

  // Nothing to ask for. Offering the button here gets a duplicate refused.
  if (q.enough) {
    quotaSay(`Current quota covers one ${type}`, 'No increase needed.', 'ok');
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
    $('quota-case-url').textContent = quotaCase ? quotaCaseUrl(quotaCase) : 'Not available yet. Refresh shortly.';
    // A closed case cannot be appealed, so asking again is the only way on.
    $('quota-go').hidden = r.status !== 'CASE_CLOSED';
    $('quota-go').disabled = r.status !== 'CASE_CLOSED';
    if (r.status === 'CASE_CLOSED') $('quota-go').textContent = 'Resubmit';
    const appeal = await runCg(quotaCmd('quota', 'appeal', kind), { capture: true });
    quotaAppeal = (appeal || '').trim();
    $('quota-copy').hidden = !quotaAppeal;
    if (quotaAppeal) {
      $('quota-pre-label').hidden = false;
      $('quota-pre-label').textContent = 'If denied, reply with:';
      $('quota-log').textContent = quotaAppeal;
    }
    return;
  }

  // Nothing asked for yet: say exactly what the case would contain.
  quotaSay(`Quota: ${q.value === null ? 'unknown' : q.value} vCPU. One ${type} needs ${need}.`, '');
  $('quota-pre-label').hidden = false;
  $('quota-pre-label').textContent = 'Request:';
  $('quota-log').textContent =
      `Service:    EC2 Instances\n`
    + `Region:     ${quotaNow.region}\n`
    + `Quota:      ${kind === 'spot' ? 'Spot GPU instances' : 'On-demand GPU instances'}\n`
    + `New value:  ${need} vCPU (one instance)\n\n`
    + `No charge. First requests are usually denied; reply to the case for a review.`;
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
  add(current, current ? `${current} (current)` : '');
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
  $('quota-title').textContent = 'Ask AWS for a higher GPU limit';
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
  catch { $('quota-copy').textContent = 'Select it below and copy'; }
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
  quotaSay('Submitting\u2026', '');
  $('quota-pre-label').hidden = true;
  const { rc, err } = await runCg(quotaCmd('quota', 'request', quotaKind), { wantRc: true });
  $('quota-kind').disabled = false;
  if (rc !== 0) {
    quotaSay('Request not submitted', (err || '').trim().split('\n')[0]
      || '', 'bad');
    $('quota-log').textContent = (err || '').trim();
    $('quota-go').disabled = false;
    $('quota-go').textContent = 'Submit request';
    return;
  }
  // Read it back rather than believing the submit: the case id lags the
  // request by up to a minute, and the status is AWS's to report.
  await quotaRead();
  await quotaRender();
  if (!quotaCase) {
    $('quota-case-row').hidden = false;
    $('quota-case-url').textContent = 'Not available yet. Refresh shortly.';
  }
};

// Turning a region on: one API call, no case, no person - the opposite of a
// quota. What it needs instead is care, because it is account-wide and undoing
// it is slower than doing it.
const OPTIN_STATE = {
  ENABLING: ['enabling', 'In progress. Usually a few minutes.'],
  ENABLED: ['enabled', 'Enabled. Ready to use.'],
  ENABLED_BY_DEFAULT: ['enabled', 'Already enabled.'],
  DISABLING: ['being disabled', 'Being disabled. Wait for it to finish.'],
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
  first.value = ''; first.textContent = 'Pick one\u2026';
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
  const off = group('Not enabled');
  for (const code of (optinNow && optinNow.disabled) || []) if (measured.has(code)) add(off, code, measured.get(code));
  for (const code of (optinNow && optinNow.disabled) || []) add(off, code, null);
  for (const code of (optinNow && optinNow.enabling) || []) add(off, code, measured.get(code));
  // Only the measured ones: every account has a dozen enabled by default, and
  // listing all of them would bury the one you came to check.
  const on = group('Enabled');
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
  if (!m) return 'Not measured yet. Check all regions under Machine type.';
  const ms = (m.machines || []);
  const fits = ms.filter(x => x.fits_spot || x.fits_ondemand);
  if (fits.length) return `${code} is enabled; ${fits.length} machine type`
    + `${fits.length > 1 ? 's are' : ' is'} available.`;
  if (!ms.length) return `${code} is enabled but offers no supported machine types.`;
  const q = m.quota || {};
  return `${code} is enabled, but its GPU quota is too low:\n`
    + `  on demand  ${q.ondemand_vcpu ?? '?'} vCPU\n`
    + `  spot       ${q.spot_vcpu ?? '?'} vCPU\n`
    + 'New regions start at 0. Request an increase under Machine type.';
}

function optinRender() {
  const code = optinPick;
  $('optin-refresh').hidden = !code;
  $('optin-go').hidden = false;
  $('optin-go').disabled = true;
  $('optin-go').textContent = 'Confirm \u00b7 enable';
  if (!code) {
    optinSay('', 'Select a region.');
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
      'Applies to the whole AWS account. No charge.\n'
    + '\n'
    + 'Takes a few minutes. Disabling is slow; treat it as permanent.';
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
  optinSay(`Enabling ${code}\u2026`, 'Takes a few minutes.');
  $('optin-log').textContent = '';
  const { rc, err } = await runCg(['regions', 'enable', code], { wantRc: true });
  $('optin-log').textContent = (err || '').trim();
  optinBusy(false);
  if (rc !== 0) {
    optinSay('Rejected by AWS', (err || '').trim().split('\n')[0] || '', 'bad');
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
    if (!value) return oneFieldFail('Required.', save);
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
    title: 'Tailscale access token',
    note: 'Optional. login.tailscale.com → Settings → Keys → Generate access token. '
        + 'Used to remove stale devices.',
    label: 'Access token', placeholder: 'tskey-api-…',
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
    title: 'Tailscale auth key',
    note: 'login.tailscale.com \u2192 Settings \u2192 Keys \u2192 Generate auth key. '
        + 'Reusable on, Ephemeral off.'
        + '',
    label: 'Auth key', placeholder: 'tskey-auth-…', log,
    args: ['creds', 'tailscale', 'authkey'], askId: ASK.tsAuthKey,
    save: 'Save key', working: 'Checking with Tailscale…',
    strip: 'Machine key',
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
    title: 'Budget alert email',
    note: 'Notified when spending passes the budget. Separate multiple addresses with commas.',
    label: 'Email', placeholder: 'you@example.com', secret: false, log,
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
  if (!id || !secret) return awsKeyFail('Access key ID and secret are both required.');
  awsKeyPending = { id, secret };
  $('awskey-err').hidden = true;
  $('awskey-go').disabled = true;
  $('awskey-go').textContent = 'Checking with AWS\u2026';
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
  awsKeyFail((err || 'Could not save the key.').split('\n')
    .filter(l => l.trim() && !l.startsWith('AWS credentials: paste'))
    .join('\n').trim() || 'Could not save the key.');
};

function setCreds() { openAwsKey(); }

// "1" means nothing to a person: a choice shows what it chose.
const CHOICE_LABEL = {
  GAME_SPOT: { '1': 'Spot', '0': 'On-demand', auto: 'Spot, else on-demand' },
  GAME_STEAM_LOGIN: { use: 'Use the saved login', fresh: 'Ask me to sign in' },
};
const choiceLabel = (key, v) => (CHOICE_LABEL[key] || {})[v] || v;

function settingValue(r) {
  if (r.secret) return r.is_set ? 'Set' : 'Not set';
  if (r.value != null) return choiceLabel(r.key, r.value);
  if (r.default != null) return `${choiceLabel(r.key, r.default)} (default)`;
  return 'Not set';
}

// Settings: only what this page sets (SETTINGS_CARDS). Every rule and value is
// cg's; the names and the cards are the app's.
function paintConfig(rows) {
  paintOnboardSoon();
  config = rows;
  // Which machines there are is read from the settings (a region chosen is
  // an AWS machine), so Home and its cards follow them.
  paintHome();
  paintDash();
  paintBuildLogin();
  if (watcher) paintGuards(watcher);
  const wrap = $('s-groups');
  if (!wrap) return;
  wrap.textContent = '';
  for (const [title, note, keys] of SETTINGS_CARDS) {
    const present = keys.map(k => rows.find(r => r.key === k)).filter(Boolean);
    if (!present.length) continue;
    const card = document.createElement('div');
    card.className = 'p-space-lg rounded-lg bg-surface-container-low';
    const head = document.createElement('div');
    head.className = 'pb-space-sm';
    const h = document.createElement('span');
    h.className = 'font-body-sm text-body-sm font-medium text-on-surface-variant';
    h.textContent = title;
    head.append(h);
    if (note) head.append(Object.assign(document.createElement('p'),
      { className: 'font-code-sm text-code-sm text-outline mt-0.5', textContent: note }));
    card.append(head);
    for (const r of present) card.append(settingRow(r));
    wrap.append(card);
  }
}

// What only Settings sets. The rest of cg's settings each have one home on the
// page they are about - the machine on Build, the guards and alerts on Guards,
// how long games are kept on Library - and three copies of one setting is how
// this page used to read.
const SETTINGS_CARDS = [
  ['Stream', 'Applied per session. Moonlight settings are not changed.',
   ['GAME_RES', 'GAME_FPS', 'GAME_BITRATE_KBPS']],
  ['Machine disk', '', ['GAME_DISK_GB']],
];
// The names a person uses; cg's own labels are for the terminal.
const PLAIN = { GAME_RES: 'Resolution', GAME_FPS: 'Frame rate', GAME_BITRATE_KBPS: 'Quality',
                GAME_DISK_GB: 'System disk',
                GAME_BUDGET_INR: 'Monthly budget', EMAIL_ALERTS: 'Alert email',
                GAME_WATCHDOG_IDLE_MIN: 'Stop after idle', GAME_WATCHDOG_STUCK_MIN: 'Force stop after',
                GAME_NTFY_URL: 'Phone alerts' };
const PLAIN_NOTE = {
  GAME_RES: 'e.g. 1920x1080. Empty uses Moonlight default.',
  GAME_DISK_GB: 'Applies at next build. Cannot be reduced later.',
  GAME_BUDGET_INR: 'Email alert only. Nothing is stopped.',
  EMAIL_ALERTS: 'Comma-separated.',
  GAME_WATCHDOG_IDLE_MIN: 'Idle time before auto-stop.',
  GAME_WATCHDOG_STUCK_MIN: 'Forces a stuck shutdown after this long.',
  GAME_NTFY_URL: 'ntfy topic. Empty disables phone alerts.',
};
// The value, said the way the row means it.
function plainValue(r) {
  const v = r.value != null ? r.value : r.default;
  if (r.key === 'GAME_RES') return v || 'Default';
  if (r.key === 'GAME_FPS') return v ? `${v} fps` : '—';
  if (r.key === 'GAME_DISK_GB') return v ? `${v} GB` : '—';
  if (r.key === 'GAME_BITRATE_KBPS') {
    if (!v) return '—';
    const gbHour = (Number(v) * 3600) / 8 / 1e6;
    const rate = (statusNow && statusNow.rates) || {};
    const inr = inrRate();
    const after = rate.egress_gb && isFinite(inr) ? `, then ${rs(gbHour * rate.egress_gb * inr)}/hour` : '';
    return `${(Number(v) / 1000).toFixed(0)} Mbps · about ${gbHour.toFixed(1)} GB an hour`
      + (rate.egress_free_gb ? ` · first ${rate.egress_free_gb} GB/month free${after}` : '');
  }
  return settingValue(r);
}

// The three settings the chooser table owns. They are one decision, so they
// have one control - see chooseMachine.
const CHOSEN_IN_TABLE = new Set(['GAME_REGION', 'GAME_INSTANCE_TYPE', 'GAME_SPOT']);

// One row: what it is, what it is for, what it says now, and how to change it.
function settingRow(r) {
  const row = document.createElement('div');
  // Wraps rather than squeezes: a narrow card - a 1000px window, the sidebar
  // beside it - put the value and its button on a line of their own, at the
  // right where every row's button is, instead of crushing the label to 62px
  // and pushing Edit past the card's edge.
  row.className = 'row flex-wrap border-b border-surface-variant/40 items-start';
  row.dataset.key = r.key;          // so anything can send you to this one row

  const left = document.createElement('div');
  left.className = 'min-w-[12rem] flex-1';
  const name = document.createElement('p');
  name.className = 'font-code-md text-code-md';
  name.textContent = PLAIN[r.key] || label(r);
  const note = document.createElement('p');
  note.className = 'font-code-sm text-code-sm text-outline mt-0.5';
  note.textContent = PLAIN[r.key] ? (PLAIN_NOTE[r.key] || '') : r.note;
  left.append(name, note);

  const right = document.createElement('div');
  right.className = 'flex items-center gap-space-sm min-w-0 max-w-full ml-auto';
  const val = document.createElement('span');
  // Anywhere: two addresses joined by a comma are one word to the browser,
  // and break-words would not break it.
  val.className = 'font-code-md text-code-md text-right max-w-[22rem] min-w-0 [overflow-wrap:anywhere] '
    + (r.is_set ? 'text-on-surface-variant' : 'text-outline');
  val.textContent = plainValue(r);

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
    where.textContent = 'set under Machine';
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
    eye.title = 'Show the value';
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
  // Kept, so Cancel can put the row back as it was: nothing changed, so
  // nothing needs reading again.
  const was = [...right.childNodes];
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
      ? (r.is_set ? 'Type a new value, or leave empty to clear' : 'Leave empty to go without')
      : (r.default || '');
  }
  input.className = 'bg-surface border border-surface-variant rounded px-space-sm py-0.5 '
                  + 'font-code-md text-code-md text-on-surface min-w-0 '
                  + 'w-64';
  const save = document.createElement('button');
  save.className = 'btn btn-primary'; save.textContent = 'Save';
  const cancel = document.createElement('button');
  cancel.className = 'btn'; cancel.textContent = 'Cancel';
  cancel.onclick = () => {
    right.replaceChildren(...was);
    row.classList.remove('editing');
    const reply = row.querySelector('.edit-reply');
    if (reply) reply.remove();
  };
  input.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); cancel.click(); } });
  save.onclick = async () => {
    const value = input.value.trim();
    if (r.secret && !value && r.is_set && !(await askConfirm({
          title: `Clear ${label(r)}?`,
          body: 'The value is removed and will not be asked for again.',
          yes: 'Clear', danger: true,
        }))) return;
    save.disabled = true;
    // cg's answer goes where the row is: Settings has its panel for it, and
    // anywhere else it goes under the row - a refusal sent to another page
    // read as a save that did nothing.
    let reply = row.querySelector('.edit-reply');
    if (!reply) {
      reply = document.createElement('pre');
      reply.id = 'edit-reply';
      reply.className = 'edit-reply font-code-sm text-code-sm whitespace-pre-wrap text-error mt-space-xs';
      row.firstElementChild.append(reply);
    }
    reply.textContent = '';
    const { rc } = await runCg(['config', 'set', r.key, value], { collect: 'edit-reply', wantRc: true });
    if (rc !== 0) { save.disabled = false; input.focus(); return; }
    // refresh() re-reads config, machines AND regions for this screen, so a new
    // region repaints the Build picker too - different regions rent different
    // machines, and the type in force may not exist in the one just chosen.
    await refresh();
  };
  input.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); save.click(); } });
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
let statusAt = null;   // when it was
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
      ? `Could not read saved games: ${d.error}`
      : 'No saved games. The machine starts empty.';
    tr.append(td); body.append(tr);
  }
  for (const g of d.games || []) {
    const tr = document.createElement('tr');
    tr.className = 'border-b border-surface-variant/40 hover:bg-surface-container cursor-pointer';
    const cell = (cls) => { const td = document.createElement('td'); td.className = cls; tr.append(td); return td; };

    const box = document.createElement('input');
    box.type = 'checkbox'; box.className = 'accent-primary align-middle'; box.dataset.appid = g.appid;
    // A game bigger than the machine's whole game disk can never be restored
    // onto it, whatever else is unticked: it is not offered, and says why.
    const cap = d.selectable_gb;
    const tooBig = cap != null && g.bytes / 1073741824 > cap;
    if (tooBig) { picked.delete(g.appid); box.dataset.toobig = 'yes'; }
    box.checked = picked.has(g.appid);
    box.onchange = () => { box.checked ? picked.add(g.appid) : picked.delete(g.appid); paintFit(); };
    cell('py-space-sm pr-space-sm').append(box);

    const nameCell = cell('py-space-sm pr-space-md text-on-surface');
    nameCell.textContent = g.name || g.installdir || g.appid;
    if (tooBig) {
      nameCell.append(el('span', 'block font-code-sm text-code-sm text-error',
        `Exceeds ${d.disk_type || 'machine'} capacity (${cap} GB). Choose a larger disk.`));
      tr.className = tr.className.replace('cursor-pointer', 'opacity-60');
    }
    cell('py-space-sm px-space-md text-right text-on-surface-variant').textContent = GB(g.bytes);
    cell('py-space-sm pl-space-md text-right text-outline').textContent = savedOn(g.pushed);

    tr.onclick = e => { if (!box.disabled && e.target !== box) { box.checked = !box.checked; box.onchange(); } };
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
  // Whose disk: the machine the next build makes, as cg read it.
  $('b-fit').textContent = archive.disk_type ? `Disk space (${archive.disk_type})` : 'Disk space';
  $('b-fit').className = 'font-code-sm text-code-sm text-outline';
  const pct = cap != null ? Math.min(100, (gb / cap) * 100) : 0;
  $('b-fit-pct').textContent = over ? `${(gb - cap).toFixed(1)} GB over. Deselect a game.`
    : cap != null ? `${gb.toFixed(1)} of ${cap} GB`
    : picked.size ? `${gb.toFixed(1)} GB · capacity unknown` : '';
  $('b-fit-pct').className = 'font-code-sm text-code-sm ' + (over ? 'text-error' : 'text-on-surface-variant');
  $('b-bar').style.width = pct + '%';
  $('b-bar').className = 'h-full ' + (over ? 'bg-error' : 'bg-primary');
  // A box is already running: there is nothing to build, and cg would refuse.
  // The screen says so and offers what you can actually do with it.
  const up = !!boxNow;
  $('b-build').disabled = over || jobs.size > 0;
  for (const box of $('b-games').querySelectorAll('input[type=checkbox]')) box.disabled = up || box.dataset.toobig === 'yes';
  // Nothing here applies while a box is up: what it holds was chosen at build.
  $('b-alloc').hidden = up;
  $('b-hint').textContent = up
    ? 'A machine is running. Games were selected at build time.'
    : 'Restored from saved games during startup.';
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
// A picked price being saved: three settings written, then read back.
let choosing = false;
// While either runs, the chooser is locked - nothing in it can be picked,
// pressed or closed until the answer is in, or a choice could land on a table
// that is about to change under it.
const machBusy = () => sweeping || choosing;
let sweepAnswered = false;
function paintSweep(d) { sweepNow = d; sweepAnswered = true; paintChooser(); paintOnboardSoon(); paintDash(); paintLibraryPage(); }

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
          type: m.type, gpu: m.gpu, vram: m.vram_gib, score: m.score, store: m.store_gb ?? null,
          spot: inrNow(m.usd_hour_spot, m.inr_hour_spot), spotMax: inrNow(m.usd_hour_spot_max, m.inr_hour_spot_max),
          od: inrNow(m.usd_hour_ondemand, m.inr_hour_ondemand),
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
          type: m.type, gpu: m.gpu, vram: m.vram_gib, score: null, store: m.store_gb ?? null,
          // No rate from cg, no rupee figure. The app holds no exchange rate.
          spot: inrNow(m.usd_hour_spot, m.inr_hour_spot),
          spotMax: inrNow(m.usd_hour_spot_max, m.inr_hour_spot_max),
          od: inrNow(m.usd_hour_ondemand, m.inr_hour_ondemand),
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
  radio.disabled = !usable || machBusy();
  radio.checked = row.region === cur.region && row.type === cur.type && spot === cur.spot;
  if (radio.checked) label.classList.add('on');
  radio.onchange = () => { if (radio.checked) chooseMachine(row, spot); };
  label.append(radio);

  // The cheapest zone, and nothing pins the zone: show the spread when the
  // zones disagree, because the cheap number alone is a promise cg cannot keep.
  // The same price the machine card shows: the address and the disk included.
  const range = hourText(perHour(inr), spot && row.spotMax != null ? perHour(row.spotMax) : null);
  const amount = document.createElement('span');
  amount.className = 'amount';
  amount.textContent = range == null ? 'none' : range;
  label.append(amount);

  // Why, on hover: a mark in the cell, the words in the tooltip and once
  // under the table, so the prices stay readable down the column.
  if (why) {
    const tag = document.createElement('span');
    tag.className = 'reason';
    tag.textContent = 'ⓘ';
    tag.title = `${REASON_LABEL[why] || why}: ${PICK_WHY[why] || why}`;
    label.append(tag);
    label.title = `${REASON_LABEL[why] || why}: ${PICK_WHY[why] || why}`;
  }
  td.append(label);
  return { td, usable, why };
}

// Said once, under the table, instead of a sentence in every cell.
// How a reason reads on screen; the keys stay the code's.
const REASON_LABEL = { 'no quota': 'Over GPU quota', 'needs opt-in': 'Region not enabled',
                       'no spot market': 'No spot price', 'no price': 'No price' };
const PICK_WHY = {
  'no quota': 'GPU quota here is too low for this machine. Increases are free to request.',
  'needs opt-in': 'this region is not enabled for your account. Enabling is free.',
  'no spot market': 'no spot market for this type here. On-demand may be available.',
  'no price': 'no price from AWS for this type here.',
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
      td.textContent = !machinesAnswered ? 'Reading prices…'
        : machinesNow && machinesNow.error ? machinesNow.error
        : 'No machine type fits your GPU quota here. Check all regions to compare.';
    } else {
      const head = table.createTHead().insertRow();
      // The price headers do NOT get text-right: the cells under them lead with
      // a radio at the cell's left edge, so a right-aligned header sat over
      // nothing. capacity is the only genuinely right-aligned column.
      for (const [label, cls] of [['Region', ''], ['Latency', ''], ['Machine', ''], ['GPU', ''],
                                  ['Game disk', 'num'], ['Spot availability', 'num'],
                                  ['Spot/hour', ''], ['On-demand/hour', '']]) {
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

        // The location by its city; AWS's code for it on hover.
        const place = cell(tr, first ? row.city || placeName(row.region) : '', 'region');
        if (first) place.title = row.region;
        cell(tr, first && row.rtt != null ? distance(row.rtt) : '', 'ms');
        cell(tr, row.type, '');
        cell(tr, row.gpu ? gpuName(row.gpu, row.vram) : '', 'city');
        // The fast disk games go on differs by machine - 125 GB to 250 GB here -
        // and decides which games fit; AWS's own figure for the type.
        cell(tr, row.store != null ? `${row.store} GB` : '', 'num');

        const sc = tr.insertCell();
        sc.className = 'num';
        if (row.score == null) { sc.textContent = ''; sc.classList.add('why'); }
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
    if (boxNow) parts.push('Delete the running machine before changing type.');
    else if (sweeping) parts.push('Checking all regions (~90 s)');
    else if (!swept && rows.length) parts.push('Showing this region only.');
    if (swept) {
      // Two numbers in a spot cell are the cheapest and dearest zone, and the
      // zone is not pinned, so the bill can be either.
      if (rows.some(r => r.spotMax != null && r.spot != null && r.spotMax > r.spot))
        parts.push('Spot ranges show the lowest and highest zone price');
      const far = (sweepNow.too_far || []).length;
      if (far) parts.push(`${far} region${far === 1 ? '' : 's'} hidden (${sweepNow.max_ms != null ? `over ${sweepNow.max_ms} ms` : 'too slow'})`);
    }
    $(mount.note).textContent = parts.join(' · ');

    // The legend. Only the reasons actually on screen, in plain words, so a
    // greyed-out half of a column reads as deliberate rather than broken.
    const legend = $(mount.legend);
    if (legend) {
      legend.textContent = '';
      // Nothing at all fits the quota: asking for more is the way on, and it was
      // offered only beside a greyed-out price - so an empty table, where it is
      // needed most, had no button.
      if (!rows.length && machinesAnswered && !(machinesNow && machinesNow.error)) {
        const b = document.createElement('button');
        b.className = 'btn mt-space-xs';
        b.textContent = 'Request quota increase';
        b.onclick = () => openQuota(null, machinesNow ? machinesNow.region : undefined);
        legend.append(b);
      }
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
        line.textContent = 'Checking all regions (~90 s). Showing '
          + `${machinesNow ? placeName(machinesNow.region) : 'one region'} until then.`;
        legend.append(line);
      } else if (!swept && rows.length) {
        const line = document.createElement('div');
        line.textContent = `Showing ${machinesNow ? placeName(machinesNow.region) : 'one region'} only. `
          + 'Checking all regions takes ~90 s. No charge.';
        legend.append(line);
        // The button, here, rather than the name of a button elsewhere: this
        // line is where the question gets asked, and the answer was two
        // scrolls away at the top of the screen.
        const b = document.createElement('button');
        b.className = 'btn mt-space-xs';
        b.textContent = 'Check all regions';
        b.onclick = () => scanRegions($('s-sweep'));
        legend.append(b);
      }
      const hidden = hiddenByQuota();
      if (hidden) {
        const line = document.createElement('div');
        line.textContent = `${hidden} more GPU type${hidden === 1 ? '' : 's'} here exceed${hidden === 1 ? 's' : ''} your quota.`;
        legend.append(line);
      }
      if (rows.length) {
        const line = document.createElement('div');
        // What each price holds, so it can be checked against the bill.
        const tax = ((statusNow && statusNow.rates) || {}).tax_pct;
        line.textContent = 'Spot is cheaper but can be reclaimed mid-session. On-demand is not. '
          + 'Prices include the IP address and disk'
          + (tax ? `, and ${tax}% GST.` : '.');
        legend.append(line);
      }
      if (reasons.size) {
        const intro = document.createElement('div');
        intro.className = 'mt-space-sm';
        intro.textContent = 'Greyed prices would be refused at launch:';
        legend.append(intro);
        // Each reason on one line, with the button that fixes it beside it.
        const FIX = {
          'no quota': ['Ask AWS for more', () => openQuota(null, shortOfQuota[0])],
          'needs opt-in': ['Switch it on', () => openOptin()],
        };
        for (const r of ['no quota', 'needs opt-in', 'no spot market', 'no price']) {
          if (!reasons.has(r)) continue;
          const line = document.createElement('div');
          line.className = 'flex flex-wrap items-center gap-space-sm mt-space-xs';
          const b = document.createElement('b');
          b.textContent = `${REASON_LABEL[r] || r}:`;
          const text = document.createElement('span');
          text.textContent = PICK_WHY[r];
          // Together, so the gap before the button is not also before the colon.
          const words = document.createElement('span');
          words.append(b, ' ', text);
          line.append(words);
          if (FIX[r]) {
            const btn = document.createElement('button');
            btn.className = 'btn';
            btn.textContent = FIX[r][0];
            btn.onclick = FIX[r][1];
            line.append(btn);
          }
          legend.append(line);
        }
      }
    }
    const ageEl = $(mount.age);
    if (ageEl) ageEl.textContent = sweepNow && sweepNow.cached && sweepNow.age_seconds != null
      ? `Checked ${ago(sweepNow.age_seconds)}` : '';
  }
  paintBuildPick();
  lockMachines();
}

// What the chooser is waiting for, said in a popup over it - the same one
// Refresh uses: a backdrop over everything, Esc does nothing, it closes itself
// when done and stays with the reason and a Close when not. Without it the
// table under a scan looked live, and Esc closed the chooser mid-scan.
function busyPopup(title, sub, step) {
  const dlg = $('refdlg');
  $('refdlg-title').textContent = title;
  $('refdlg-sub').textContent = sub;
  $('refdlg-menu').hidden = true;
  const list = $('refdlg-list');
  list.textContent = '';
  const row = document.createElement('div');
  row.className = 'flex items-start gap-space-sm font-body-md text-body-md';
  row.dataset.step = step;
  row.append(Object.assign(document.createElement('span'), { className: 'spinner mt-0.5' }),
             Object.assign(document.createElement('div'), { textContent: step }));
  list.append(row);
  if (!dlg.open) dlg.showModal();
  return {
    done() { dlg.close(); },
    fail(why) {
      $('refdlg-title').textContent = `${title} - not done`;
      list.textContent = '';
      const bad = document.createElement('div');
      bad.className = 'flex items-start gap-space-sm font-body-md text-body-md';
      bad.dataset.state = 'failed';
      bad.append(Object.assign(document.createElement('span'), { className: 'w-4 text-center text-error', textContent: '✗' }),
                 Object.assign(document.createElement('div'), { className: 'font-code-sm text-code-sm text-on-surface-variant break-words', textContent: why }));
      list.append(bad);
      $('refdlg-menu').hidden = false;
      $('refdlg-close').focus();
    },
  };
}

// Every button in the popup, the legend's included - they are redrawn each
// paint, so this runs after it.
function lockMachines() {
  const dlg = $('machdlg');
  if (!dlg) return;
  const busy = machBusy();
  for (const b of dlg.querySelectorAll('button')) b.disabled = busy;
  $('s-chooser').classList.toggle('busy', busy);
  $('machdlg-close').textContent = choosing ? 'Saving…' : 'Done';
}

// The choice changed, so the machine card says the new one, on both pages.
function paintBuildPick() { paintMachineCards(); }

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
  paintLibraryPage();       // where the games are kept, and for how long
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
  { doing: 'Launching the machine', done: 'Machine launched', bills: true,
    match: /provisioning|launching|confirming what shutdown|starting the existing|reusing the existing/i },
  { doing: 'Connecting to Tailscale', done: 'Connected to Tailscale',
    match: /join the tailnet|on the tailnet|key expiry/i },
  { doing: 'Installing the software', done: 'Software installed', parts: true,
    match: /building the box|^installing|^installed |^configuring|^setting up|^disabling|nvidia/i },
  { doing: 'Restoring games', done: 'Games restored', games: true, match: /finishing up|restor/i },
  { doing: 'Connecting Moonlight', done: 'Moonlight connected', match: /on-host watchdog|sunshine account|pairing/i },
  { doing: 'Starting Steam', done: 'Steam started', match: /waiting for steam/i },
];
// A session, as steps. `cg open` announces none - it prints lines, and under
// the app its waits print only once they are over ("waiting for sunshine ok") -
// so each step is closed by the line that says it is done.
const OPEN_STEPS = [
  { doing: 'Starting the machine', done: 'Machine started',
    end: /instance already running|^running after|waiting for tailscale|^\s*pong|\bvia\b/i },
  { doing: 'Connecting over Tailscale', done: 'Connected over Tailscale',
    end: /waiting for tailscale ok|tailscale is up|^\s*pong|\bvia\b/i },
  { doing: 'Starting the game stream', done: 'Game stream ready', end: /waiting for sunshine ok|sunshine is up|^disk:/i },
  { doing: 'Playing', done: 'Played', end: /session ended/i, stream: true,
    note: 'Close Moonlight to end the session, then choose to keep or delete the machine.' },
];
// What the machine installs, in the order it does it, each matched to the
// progress line the box prints when it starts that piece (lib/bootstrap.d).
// Shown as chips inside "Installing the software", ticked as the box moves on:
// the step installs far more than a driver, and said so in three words.
const BUILD_PARTS = [
  ['Base system', /^installing base packages/i],
  ['Game disk', /^setting up local nvme/i],
  ['Auto-stop', /^installing the idle watchdog/i],
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
  init: { running: 'Building', done: 'Ready to play', failed: 'Build failed' },
  destroy: { running: 'Deleting the machine', done: 'Machine deleted', failed: 'Delete failed' },
  open: { running: 'Starting session', done: 'Session ended', failed: 'Session failed' },
  library: { running: 'Updating saved games', done: 'Saved games updated', failed: 'Update failed' },
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
    $('b-log-title').textContent = 'Build log';
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
    body: 'The machine is deleted and billing stops. Saved games are not affected.',
    yes: 'Cancel build', no: 'Keep building', danger: true,
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
  title.textContent = r.cancelling ? 'Cancelling' : machine ? machineTitle()
    : r.kind === 'open' && r.state === 'running' && OPEN_STEPS[r.idx] && OPEN_STEPS[r.idx].stream
      ? (r.streamEnded ? 'Session ended' : 'Playing') : head[r.state];
  title.className = 'font-headline-md text-headline-md ' + (r.state === 'failed' ? 'text-error' : '');
  // The bill, in the heading, from the moment the machine is rented.
  const so = r.billFrom && r.rate != null ? r.rate * ((machine ? Date.now() : now) - r.billFrom) / 3600000 : null;
  $('b-strip-meta').textContent = [
    r.state === 'running' ? mins(now - r.start) : r.kind === 'machine' ? `up ${mins(now - r.start)}`
      : r.state === 'done' && r.kind === 'init' ? `built in ${mins(now - r.start)}` : null,
    so != null ? `${rs(so)} so far` : r.kind === 'init' && r.state === 'failed' ? 'Nothing was billed' : null,
    r.billFrom && r.rate != null ? `${rsh(r.rate)} an hour` : null,
  ].filter(Boolean).join(' · ');
  const s = statusNow || {};
  $('b-run-sum').textContent = r.kind === 'init' || r.kind === 'machine' || r.kind === 'open'
    ? [r.kind !== 'init' && liveBox() ? liveBox().type : s.instance_type, s.region ? placeName(s.region) : null,
       (r.kind !== 'init' && liveBox() ? liveBox().lifecycle !== 'spot' : (s.config || {}).spot === '0') ? 'On-demand' : 'Spot',
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
      textContent: `Build details · ${mins(now - r.start)}` }), ...wrap.children);
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
  InsufficientInstanceCapacity: () => [['Pick another machine', () => openMachines()]],
  SpotMaxPriceTooLow: (spot) => FAIL_ACTS.InsufficientInstanceCapacity(spot),
  // Try again is already beside the step; nothing more to offer.
  MaxSpotInstanceCountExceeded: () => [],
  VcpuLimitExceeded: () => [['Ask AWS for a higher GPU limit', () => openQuota()]],
  InstanceLimitExceeded: () => [['Ask AWS for a higher GPU limit', () => openQuota()]],
  'InvalidKeyPair.NotFound': () => [
    ['Fix it', () => runCg(['check', '--fix'])],
  ],
  // The region is not switched on for this account: another location is the
  // answer, and it is picked where the machine is.
  OptInRequired: () => [['Choose another location', () => openMachines()]],
  AuthFailure: () => [['Connect AWS again', () => openAwsKey()]],
  UnauthorizedOperation: () => [['Connect AWS again', () => openAwsKey()]],
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
  $('b-fail-why').textContent = [safe ? 'Nothing was launched. No charges.' : '',
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
  // The Build card's run: a build, a delete, a session. A change to the saved
  // games is reported by its own popup, on its own page.
  if (job.write && job.cmd[0] !== 'library') {
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
        buildFail(`${CgName(job.cmd)} exited without an error message. See the log above.`);
    }
  }
  if (event.t === 'step' && job.onStep) job.onStep(event.text);
  if (event.t === 'ask') {
    // The key dialog asked already: cg's two questions are answered from what
    // is in it, rather than putting two more modals on top of the one the
    // person is looking at.
    const pre = awsKeyAnswer(event.id) ?? oneFieldAnswer(event.id) ?? typedAnswer(event.id);
    if (pre !== null) window.cg.answer(id, pre);
    else if (!serverPwAnswer(id, event.id) && !sudoAnswer(id, event.id)) ask(id, event);
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
                        tskey: paintTskey, ping: paintPing, elsewhere: paintElsewhere,
                        hosts: paintHosts }[job.json]
          || (job.json.startsWith('host:') && (d => paintHostStatus(job.json.slice(5), d)));
        if (!paint) throw new Error(`no painter for ${job.json}`);
        paint(data);
      } catch (err) {
        failure = `Could not show ${cgName(job.cmd)}: ${err && err.message ? err.message : err}`;
      }
    }
    if (job.age) $(job.age).textContent = new Date().toLocaleTimeString();
    jobs.delete(id);
    for (const wake of jobEnded.splice(0)) wake();
    updateHeader();
    // A FAILED read used to be silent: note() and the follow-up refresh are
    // behind job.write, so a read that could not run at all left the screen empty
    // and the header busy with nothing anywhere saying why - which is exactly
    // what a packaged app pointed at the wrong directory looked like. This runs
    // AFTER updateHeader because updateHeader rewrites the same line.
    if (job.json) {
      if (event.rc !== 0 || failure) {
        readFailures.set(job.json, failure ? failure
          : job.err ? `${CgName(job.cmd)} could not run: ${job.err}`
          // A read that answered WITH its reason has already said it on the
          // screen it belongs to; repeating "exit 1" in the header adds a
          // number and takes away the reason.
          : painted && painted.error ? painted.error
          : `${CgName(job.cmd)} did not finish.`);
      } else {
        readFailures.delete(job.json);       // it worked this time
      }
      updateHeader();
    }
    // Not every painter repaints the pipeline, and the opening list is a line
    // per read: it ticks as each one lands, not all at once at the end.
    if (job.json && readingBehindGate) paintOnboardSoon();
    // A machine's check that failed: its card leaves the loading state to say so.
    if (job.json && job.json.startsWith('host:') && readFailures.has(job.json)) paintHostCards();
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
      note(`${CgName(job.cmd)} ${event.rc === 0 ? 'finished' : 'stopped'}`,
           event.rc === 0 ? 'text-primary' : 'text-error');
      // Even one that stopped part-way may have rented or deleted something.
      const change = byCommand(BILL_CHANGE, job.cmd);
      if (change && !(job.cmd[0] === 'library' && event.rc !== 0)) noteBillChange(change);
      afterWrite(job, event.rc);
    }
    if (job.resolve) job.resolve(job.wantRc ? { rc: event.rc, err: job.collected || '' }
                                 : job.capture ? job.out.join('\n') : undefined);
  }
});

// `group` names a run by what started it rather than by what it is: one click on
// Refresh is several reads, and naming them each made the Build screen offer to
// "Stop 2 runs" for a click that was one.
function runCg(args, { panel, age, json, env, collect, capture, wantRc, onStart, onStep, group } = {}) {
  return new Promise(async resolve => {
    const res = await window.cg.run(args, env);
    if (!res.ok) {
      const why = `Waiting for ${cgName(res.args)} to finish.`;
      if (collect) $(collect).textContent = why + '\n';
      if (panel) $(panel).textContent = why;
      return resolve(wantRc ? { rc: null, err: why } : undefined);
    }
    jobs.set(res.id, { cmd: args, view, panel, age, json, collect, capture, wantRc, onStep, group,
                      // cg's verdict, not a second guess at it.
                      write: !!res.write,
                      out: [], collected: '', resolve });
    if (onStart) onStart(res.id);
    if (res.write) note(`${cgName(args)} started`, 'text-primary');
    updateHeader();
    if (panel) $(panel).textContent = 'Running…';
  });
}

// --- Machines ------------------------------------------------------------------
// Home is the machines: the AWS one when this laptop plays on AWS, and each of
// yours (`cg host`). Every fact on a card is cg's - `cg host list` for what is
// saved, `cg host status <name>` for what each is ready for, over ssh and
// Tailscale - and every button is a cg command. Setting a machine up is adding
// it: the add dialog walks the steps it needs (prereqs), and a machine that
// needs something afterwards says so on its own card.
// What Home showed last time, kept in this window's storage: which machines
// there are, what each is, and whether AWS is one - so Home opens in its final
// layout while the reads that confirm it are on their way. Never a status: a
// machine's state and its buttons appear only once a live check has answered.
const HOME_KEY = 'cg.home';
const homeBoot = (() => {
  try { const v = JSON.parse(localStorage.getItem(HOME_KEY) || 'null'); return v && Array.isArray(v.hosts) ? v : null; }
  catch { return null; }
})();
const hostIdentity = (homeBoot && homeBoot.identity) || {};   // name -> { os_name, gpu }
function homeRemember() {
  try {
    localStorage.setItem(HOME_KEY, JSON.stringify({
      hosts: hostsNow || [], identity: hostIdentity,
      aws: config.length ? awsAdded() : !!(homeBoot && homeBoot.aws) }));
  } catch { /* this window only */ }
}
// Machines whose card has shown its loading state, so the answer fades in.
const hostWasLoading = new Set();
let hostsNow = homeBoot ? homeBoot.hosts : null;   // `cg host list --json`, as last read
const hostStatus = new Map();     // name -> `cg host status <name> --json`
const hostLogs = new Map();       // name -> its setup log <pre>, kept across paints
let machineTab = 'aws';           // what the Machine page shows: 'aws', or one of yours by name
let adding = null;                // 'aws' | 'host' while the add dialog is open
let addedHost = null;             // the machine that dialog has just added

// "An AWS machine" is a laptop set up to play on AWS: a region chosen, which is
// the last step of adding it. cg aws forget takes it away again.
const awsAdded = () => regionChosen();
// AWS is asked something only when there is an AWS machine, or one is being added.
const awsInPlay = () => awsAdded() || adding === 'aws';
// What the steps are judged for: the machine being added, else the AWS one.
const kindNow = () => adding || (awsAdded() ? 'aws' : 'host');
// The reads that ask AWS. A laptop with no AWS machine never asks them: each
// would come back "no key", and the pages would fill with it.
const AWS_JSON = new Set(['status', 'guards', 'library', 'elsewhere', 'machines', 'sweep', 'cost']);
const forMode = reads => (reads && !awsInPlay() ? reads.filter(([, j]) => !AWS_JSON.has(j)) : reads);
// The pages about the AWS machine alone, which leave the sidebar without one.
const AWS_VIEWS = ['build', 'library', 'guards', 'cost'];
// The tools this laptop needs - the AWS CLI only for AWS.
const neededTools = (kind = kindNow()) => ((depsNow && depsNow.tools) || []).filter(t => kind === 'aws' || t.for !== 'aws');

const HOSTS_READ = [['host', 'list', '--json'], 'hosts'];
const hostRead = name => [['host', 'status', name, '--json'], `host:${name}`];
const hostReads = () => (hostsNow || []).map(h => hostRead(h.name));
const hostJob = (name, sub) => [...jobs.values()].find(j => j.cmd[0] === 'host' && j.cmd[1] === sub && j.cmd[2] === name);

function paintHosts(list) {
  hostsNow = Array.isArray(list) ? list : [];
  for (const name of [...hostStatus.keys()]) if (!hostsNow.some(h => h.name === name)) hostStatus.delete(name);
  // Each one's status, once: ssh, a tailnet ping and a look at Sunshine -
  // seconds each - so it is asked for machines not already known or being
  // read, never again on every list.
  for (const h of hostsNow)
    if (!hostStatus.has(h.name) && !readOut(`host:${h.name}`)) {
      const [args, json] = hostRead(h.name);
      runCg(args, { json, group: 'refresh' });
    }
  for (const name of Object.keys(hostIdentity)) if (!hostsNow.some(h => h.name === name)) delete hostIdentity[name];
  homeRemember();
  paintOnboardSoon();
  paintHostCards();
}
function paintHostStatus(name, d) {
  hostStatus.set(name, d);
  if (d && (d.os_name || d.gpu)) { hostIdentity[name] = { os_name: d.os_name || '', gpu: d.gpu || '' }; homeRemember(); }
  paintHostCards();
  // The add dialog's server step names what was found.
  if (name === addedHost) paintOnboardSoon();
}

// What a machine is ready for, in one line and a tone, from what cg said.
function hostState(h) {
  const s = hostStatus.get(h.name);
  if (hostJob(h.name, 'setup')) return { title: 'Setting up', tone: 'run', sub: 'Installing missing components.' };
  if (hostJob(h.name, 'open')) return { title: 'Playing', tone: 'ok', sub: 'Close Moonlight to end the session.' };
  if (h.os === 'Windows') return { title: 'Windows not supported', tone: 'off', sub: 'Only Linux machines can be set up.' };
  if (!s) return { title: readFailures.has(`host:${h.name}`) ? 'Check failed' : 'Checking…', tone: 'off',
                   sub: (readFailures.get(`host:${h.name}`) || '').replace(/^.*? could not run: /, '') };
  if (!s.set_up) return { title: 'Not set up', tone: 'warn',
                          sub: s.reachable ? 'Run setup to enable streaming.' : 'No SSH response.' };
  if (!s.reachable && !s.online) return { title: 'Offline', tone: 'bad', sub: 'Powered off, asleep or disconnected.' };
  if (!s.sunshine) return { title: 'Not streaming', tone: 'bad', sub: 'Sunshine is not responding. Re-run setup to restart it.' };
  if (s.reachable && !s.desktop) return { title: 'No user session', tone: 'warn', sub: 'Sign in on the machine to start a desktop session.' };
  return { title: 'Ready to play', tone: 'ok', sub: '' };
}

// One machine's card. Home shows what it is ready for and its one next
// action; the Machine page adds the checks, the log, and removing it.
// A card before its first live answer: what the machine is, as remembered,
// and a loading line - no status, no buttons, nothing to press yet.
function hostCardLoading(h, full) {
  const id = hostIdentity[h.name] || {};
  const card = el('div', 'p-space-lg rounded-lg bg-surface-container-low');
  card.dataset.host = h.name;
  card.dataset.state = 'loading';
  card.append(el('p', 'font-body-sm text-body-sm font-medium text-on-surface-variant', h.name));
  const t = el('span', 'skel mt-space-xs ' + (full ? 'h-9' : 'h-7') + ' w-40'); t.dataset.f = 'title';
  card.append(t, el('span', 'skel mt-space-sm h-4 w-64'));
  const what = [id.os_name || h.os, id.gpu, full ? h.ssh : null].filter(Boolean).join(' · ');
  card.append(el('p', 'font-code-sm text-code-sm text-outline mt-space-md', what || '\u00a0'));
  const bar = el('div', 'onb-progress mt-space-lg'); bar.append(el('i'));
  const line = el('p', 'font-code-sm text-code-sm text-outline mt-space-xs', `Connecting to ${h.name}…`);
  line.dataset.f = 'sub';
  card.append(bar, line);
  return card;
}
function hostCard(h, full) {
  const failed = readFailures.has(`host:${h.name}`);
  if (!hostStatus.has(h.name) && !failed && !hostJob(h.name, 'setup') && !hostJob(h.name, 'open')) {
    hostWasLoading.add(h.name);
    return hostCardLoading(h, full);
  }
  const s = hostStatus.get(h.name) || {};
  const st = hostState(h);
  const setting = !!hostJob(h.name, 'setup');
  const playing = !!hostJob(h.name, 'open');
  const card = el('div', 'p-space-lg rounded-lg bg-surface-container-low');
  card.dataset.host = h.name;
  card.dataset.state = st.title;
  // The first answer after loading fades in where the loading state was.
  if (hostWasLoading.delete(h.name)) card.classList.add('card-in');
  const top = el('div', 'flex items-start justify-between gap-space-md');
  const head = el('div', 'min-w-0');
  head.append(el('p', 'font-body-sm text-body-sm font-medium text-on-surface-variant', h.name));
  const t = el('p', (full ? 'font-headline-lg text-headline-lg' : 'font-headline-md text-headline-md') + ' mt-space-xs', st.title);
  t.dataset.f = 'title';
  head.append(t);
  if (st.sub) { const p = el('p', 'font-body-md text-body-md text-on-surface-variant mt-space-xs', st.sub); p.dataset.f = 'sub'; head.append(p); }
  top.append(head);
  const tag = { ok: ['pill-ok', playing ? 'streaming' : 'ready'], run: ['pill-ok', 'setting up'],
                warn: ['pill-warn', 'needs you'], bad: ['pill-bad', 'offline'] }[st.tone];
  if (tag) top.append(el('span', `pill shrink-0 ${tag[0]}`, tag[1]));
  card.append(top);
  const what = [s.os_name || s.os || h.os, s.gpu, full ? h.ssh : null].filter(Boolean).join(' · ');
  card.append(el('p', 'font-code-sm text-code-sm text-outline mt-space-md', what));

  if (full && hostStatus.has(h.name)) {
    // The checks, each a fact cg read just now.
    const checks = el('div', 'flex flex-wrap gap-space-xs mt-space-md');
    checks.dataset.f = 'checks';
    for (const [ok, text] of [[s.reachable, 'SSH'], [s.online, 'Tailscale'], [s.sunshine, 'Sunshine'],
                              [s.login_ok, 'Sunshine login'], [s.paired, 'Moonlight paired'],
                              [s.steam, 'Steam']]) {
      if (ok == null) continue;
      checks.append(el('span', 'pill ' + (ok ? 'pill-ok' : 'pill-bad'), (ok ? '✓ ' : '✗ ') + text));
    }
    card.append(checks);
  }

  const row = el('div', 'flex flex-wrap items-center gap-space-sm mt-space-lg');
  const btn = (label, cls, go, f) => { const b = el('button', cls, label); b.dataset.f = f; b.onclick = go; row.append(b); return b; };
  const linux = h.os !== 'Windows';
  // Not known: nothing it could do is offered - only asking again.
  const unknown = failed && !hostStatus.has(h.name);
  if (unknown) {
    btn('Try again', 'btn btn-primary', () => { readFailures.delete(`host:${h.name}`); refreshHosts(h.name); }, 'retry');
  }
  if (!unknown && s.set_up && linux) {
    const p = btn(playing ? 'Streaming' : 'Play', 'btn btn-primary', () => playOn(h.name), 'play');
    p.disabled = playing || setting || !!sessionNow || !s.sunshine;
    p.title = sessionNow ? 'a session is already open' : '';
  }
  if (!unknown && linux && (full || !s.set_up)) {
    const b = btn(setting ? 'Setting up…' : s.set_up ? 'Re-run setup' : 'Set up',
                  s.set_up ? 'btn' : 'btn btn-primary', () => setUpHost(h.name), 'setup');
    b.disabled = setting || playing;
  }
  if (setting || playing) {
    // Ends it here; a setup stopped part-way carries on from there next time.
    btn('Stop', 'btn', () => {
      const j = [...jobs].find(([, x]) => hostRun(x) && x.cmd[2] === h.name);
      if (j) window.cg.cancel(j[0]);
    }, 'stop');
  }
  if (full) {
    const r = btn('Remove machine', 'btn btn-danger', () => removeHost(h.name), 'remove');
    r.disabled = setting || playing;
  } else {
    // The gear: this machine's detail - checks, log, removing it.
    const g = btn('', 'btn ml-auto', () => goHost(h.name), 'details');
    g.title = 'Details';
    g.append(Object.assign(el('span', 'material-symbols-outlined text-[16px]', ICON.settings), { ariaHidden: 'true' }), document.createTextNode('Details'));
  }
  card.append(row);

  // The setup's own words, while it runs and after: folded once it is over.
  const log = hostLogs.get(h.name);
  if (full && log) {
    const box = el('details', 'mt-space-md');
    box.open = setting || log.dataset.failed === 'yes';
    box.append(el('summary', 'font-code-sm text-code-sm text-outline cursor-pointer',
                  setting ? 'Progress' : log.dataset.failed === 'yes' ? 'Error details' : 'Setup log'));
    box.append(log);
    card.append(box);
  }
  return card;
}

function paintHostCards() {
  const list = hostsNow || [];
  // The logs go back to their parking place before the cards are rebuilt.
  for (const log of hostLogs.values()) $('h-logs').append(log);
  const home = $('d-hosts');
  home.textContent = '';
  for (const h of list) home.append(hostCard(h, false));
  const page = $('b-hosts');
  page.textContent = '';
  const open = list.find(h => h.name === machineTab);
  if (open) page.append(hostCard(open, true));
  paintMachineTab();
  paintHome();
  paintDash();
}

// The Machine page: the AWS machine, or the one of yours that was opened.
function paintMachineTab() {
  const host = machineTab !== 'aws' && (hostsNow || []).some(h => h.name === machineTab);
  if (!host) machineTab = 'aws';
  $('b-aws').hidden = !!host;
  $('b-own').hidden = !host;
  if (view === 'build') $('view-title').textContent = host ? machineTab : 'Machine';
}
function goHost(name) {
  machineTab = name;
  if (view === 'build') paintHostCards(); else goView('build');
  paintHostCards();
}
$('b-own-back').onclick = () => goView('dashboard');

// Home and the sidebar, from which machines there are.
function paintHome() {
  // Until the settings are read, whether AWS is one of the machines is what it
  // was last time - so its card is in place from the first frame.
  const aws = (config || []).length ? awsAdded() : !!(homeBoot && homeBoot.aws), hosts = hostsNow || [];
  const any = aws || hosts.length > 0;
  // Nothing is said until both have been read - or remembered: a laptop with
  // machines must not flash the welcome while the list is on its way.
  const known = ((config || []).length > 0 || !!homeBoot) && hostsNow !== null;
  $('d-welcome').hidden = !known || any;
  $('d-machines').hidden = !any;
  $('d-hero').hidden = !aws;
  $('d-add-aws').hidden = aws;
  $('d-money').hidden = !aws;
  $('d-cards').hidden = !any;
  for (const id of ['d-games-card', 'd-protect-card']) $(id).hidden = !aws;
  for (const v of AWS_VIEWS) {
    const link = document.querySelector(`.nav-item[data-view="${v}"]`);
    if (link) link.hidden = !aws;
  }
  // Settings are about streaming from a machine and the machines themselves:
  // with none yet there is nothing in it worth a visit - this laptop's own
  // steps are part of adding one.
  document.querySelector('.nav-item[data-view="settings"]').hidden = known && !any;
  if (known && !any && view === 'settings') goView('dashboard');
  // What only AWS needs, in Settings: the AWS key, the machine's disk.
  if ($('s-creds-card')) $('s-creds-card').hidden = !aws;
  const disk = settingEl('GAME_DISK_GB');
  if (disk && disk.parentElement) disk.parentElement.hidden = !aws;
  if (!aws && ['library', 'guards', 'cost'].includes(view)) goView('dashboard');
  if (!aws && view === 'build' && machineTab === 'aws') goView('dashboard');
}
for (const b of document.querySelectorAll('[data-add]')) b.onclick = () => openAdd(b.dataset.add);

function hostLog(name) {
  let log = hostLogs.get(name);
  if (!log) {
    log = el('pre', 'font-code-sm text-code-sm whitespace-pre-wrap text-on-surface-variant max-h-[40vh] overflow-auto mt-space-sm');
    log.id = `h-log-${name}`;
    hostLogs.set(name, log);
    $('h-logs').append(log);
  }
  return log;
}

// Setting one up: the same build an AWS machine gets, run on yours (cg host
// setup). It asks for the sudo password itself, once - the ask dialog - and
// saves nothing of it.
async function setUpHost(name) {
  const log = hostLog(name);
  log.textContent = '';
  log.dataset.fresh = 'yes';
  delete log.dataset.failed;
  const { rc } = await runCg(['host', 'setup', name], { collect: log.id, wantRc: true, onStart: paintHostCards });
  if (rc !== 0) log.dataset.failed = 'yes';
  note(rc === 0 ? `${name} set up` : `Setup of ${name} failed`, rc === 0 ? 'text-primary' : 'text-error');
  await refreshHosts(name);
}

// Streaming from it. Nothing to start and nothing billed by the hour: it is
// already there.
async function playOn(name) {
  const log = hostLog(name);
  log.textContent = '';
  log.dataset.fresh = 'yes';
  const { rc } = await runCg(['host', 'open', name], { collect: log.id, wantRc: true, onStart: paintHostCards });
  if (rc !== 0 && rc !== 130) { log.dataset.failed = 'yes'; note(`Stream from ${name} failed to start`, 'text-error'); }
  await refreshHosts(name);
}

// Removing a machine of yours: asked, run and reported in one dialog. cg says
// when the machine could not be reached to revoke the key; that result stays
// on screen to be read, anything else closes by itself.
async function removeHost(name) {
  const unreachable = out => /could not reach it/.test(out);
  const ok = await runInDialog({
    title: `Remove ${name}`,
    confirm: { body: 'Revokes the app\'s SSH key on the machine and removes it from the app.\n'
                   + 'Sunshine, Steam and games on it are not changed.', yes: 'Remove', danger: true },
    args: ['host', 'remove', name],
    starting: 'Revoking SSH key…',
    done: out => unreachable(out)
      ? 'Removed from the app. The SSH key could not be revoked (machine unreachable).'
      : 'Removed.',
    close: out => !unreachable(out),
    stoppable: false,
    // Before it says Removed: the list read again, and Home shown without it.
    after: async () => {
      hostStatus.delete(name);
      hostLogs.delete(name);
      await refreshHosts();
      goView('dashboard');
    },
    fail: () => 'Not removed. See details above.',
  });
  return ok;
}

// After anything changes a machine: the list, and that machine's status.
async function refreshHosts(name) {
  if (name) hostStatus.delete(name);
  await runCg(HOSTS_READ[0], { json: HOSTS_READ[1], group: 'refresh' });
}

// Removing AWS: cg aws forget, which refuses while a machine or saved games are
// still there and says which. When AWS cannot be asked (exit 3), whether
// anything still bills is not known - that is said, and it is your call.
async function removeAws() {
  const ok = await askConfirm({
    title: 'Disconnect AWS?',
    body: 'AWS is removed from the app. Nothing in your AWS account is deleted, '
        + 'and the access key is kept.\n\nNot allowed while a machine or saved games exist.',
    yes: 'Disconnect', danger: true,
  });
  if (!ok) return;
  const done = 'AWS disconnected. Nothing in AWS was deleted.';
  let removed = await runInDialog({ title: 'Disconnecting AWS', args: ['aws', 'forget'],
    starting: 'Checking for billable resources in AWS.', done,
    fail: rc => rc === 3 ? 'Could not check AWS for remaining resources.' : 'Not disconnected. See above.' });
  if (!removed && runDlgRc === 3 && await askConfirm({
        title: 'Disconnect anyway?',
        body: 'Could not check AWS for a machine or saved games. '
            + 'Anything left will keep billing and will no longer be shown.',
        yes: 'Disconnect anyway', danger: true })) {
    removed = await runInDialog({ title: 'Disconnecting AWS', args: ['aws', 'forget', '--anyway'],
      starting: 'Disconnecting…', done, fail: () => 'Not disconnected. See above.' });
  }
  if (removed) { goView('dashboard'); await refreshAll(); }
}
$('b-aws-remove').onclick = removeAws;

// --- Adding a machine ----------------------------------------------------------
// The add dialog: the steps the machine needs (prereqs), the active one with
// the one button that meets it. AWS ends when a location is chosen; a server
// of yours ends with setting it up, now or later.
function openAdd(kind) {
  // No engine: the dialog already says so, and there is nothing to add with.
  if (engineGone) return paintOnboard();
  adding = kind;
  addedHost = null;
  setupDone = false;
  onbNote = ''; onbTone = '';
  $('onb-title').textContent = kind === 'aws'
    ? (awsAdded() ? 'Finish setting up AWS' : 'Add AWS') : 'Add a server';
  paintOnboard();
  if (!$('adddlg').open) $('adddlg').showModal();
  // Everything its steps are judged on was read when the window opened, except
  // what only AWS answers: AWS not added yet, the reads behind the gate go now -
  // or, with a step still to do, as soon as it is (gateMayOpen).
  if (kind === 'aws' && !awsAdded()) { gateShut = true; gateMayOpen(); }
}
function closeAdd() {
  if (onbHandover) { clearTimeout(onbHandover); onbHandover = null; }
  adding = null;
  // Closed while it waits for the password: an empty answer, and cg stops with
  // nothing changed on the server.
  if (serverPwAsk) { window.cg.answer(serverPwAsk, ''); serverPwAsk = null; }
  serverForm.querySelector('#add-pw').value = '';
  if ($('adddlg').open) $('adddlg').close();
  paintHome();
}
$('adddlg-close').onclick = e => { e.preventDefault(); closeAdd(); };
// Esc closes neither the add dialog nor the run dialog: each is a flow under
// way, and leaving one is its own button - Close, Cancel, Later, Done. Stopped
// at the key, because a cancel event the dialog has already been sent is not
// reliably stoppable.
for (const id of ['adddlg', 'rundlg']) {
  $(id).addEventListener('keydown', e => { if (e.key === 'Escape') e.preventDefault(); });
  $(id).addEventListener('cancel', e => e.preventDefault());
}
// Closed any other way, it is closed all the same. A close event is queued, so
// it can land after the dialog was opened again; only one that finds it still
// closed is a close.
$('adddlg').addEventListener('close', () => { if (adding && !$('adddlg').open) closeAdd(); });

// The server step's form. Built once and kept, so a repaint while you type -
// every read that lands repaints the steps - never loses what was typed.
const serverForm = (() => {
  const wrap = el('div', 'flex flex-col gap-space-sm mt-space-sm');
  const field = (label, id, placeholder, note) => {
    const l = el('label', 'block font-body-sm text-body-sm text-on-surface-variant', label);
    const i = el('input', 'mt-space-xs w-full bg-surface border border-surface-variant rounded px-space-sm py-space-xs font-code-md text-code-md text-on-surface');
    i.id = id; i.placeholder = placeholder; i.autocomplete = 'off'; i.spellcheck = false;
    l.append(i);
    if (note) l.append(el('span', 'block font-code-sm text-code-sm text-outline mt-0.5', note));
    wrap.append(l);
    return i;
  };
  field('Host', 'add-addr', 'IP address or hostname');
  field('Username', 'add-user', 'SSH user');
  // Its password, here in the form rather than in a dialog on top of it. Only
  // asked of it when no key of the app's gets in yet - so empty is fine for a
  // server that already takes your key.
  const pw = field('Password', 'add-pw', '', 'Used once to install an SSH key. Not stored.');
  pw.type = 'password';
  pw.parentElement.id = 'add-pw-row';
  field('Display name', 'add-name', 'Defaults to its hostname');
  const log = el('pre', 'font-code-sm text-code-sm whitespace-pre-wrap text-on-surface-variant max-h-[20vh] overflow-auto');
  log.id = 'add-log'; log.hidden = true;
  wrap.append(log);
  for (const i of wrap.querySelectorAll('input'))
    i.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); connectServer(); } });
  return wrap;
})();
let connecting = false;
// Until a machine's status has answered once, or failed - asking for it if no
// read of it is under way.
async function hostAnswered(name) {
  const key = `host:${name}`;
  while (!hostStatus.has(name) && !readFailures.has(key)) {
    if (readOut(key)) { await new Promise(r => jobEnded.push(r)); continue; }
    const [args, json] = hostRead(name);
    await runCg(args, { json, group: 'refresh' });
    break;
  }
}
let serverPwAsk = null;   // the job whose password question the form is holding
// cg's password question while connecting: answered from the form - at once
// when it is filled in already, otherwise when you press Continue.
function serverPwAnswer(job, askId) {
  if (askId !== ASK.hostSshPw || !connecting) return false;
  const pw = $('add-pw');
  if (pw.value) { window.cg.answer(job, pw.value); pw.value = ''; return true; }
  serverPwAsk = job;
  $('add-log').textContent = 'Password required.';
  paintOnboard();
  pw.focus();
  return true;
}
async function connectServer() {
  if (serverPwAsk) {
    const pw = $('add-pw');
    if (!pw.value) { pw.focus(); return; }
    const job = serverPwAsk;
    serverPwAsk = null;
    window.cg.answer(job, pw.value); pw.value = '';
    $('add-log').textContent = 'Installing key…';
    paintOnboard();
    return;
  }
  if (connecting) return;
  const addr = $('add-addr').value.trim(), user = $('add-user').value.trim(), name = $('add-name').value.trim();
  const log = $('add-log');
  log.hidden = false;
  log.classList.remove('text-error');
  if (!addr || !user) { log.textContent = 'Host and username are required.'; log.classList.add('text-error'); return; }
  connecting = true;
  log.textContent = 'Connecting…';
  log.dataset.fresh = 'yes';
  paintOnboard();
  const before = new Set((hostsNow || []).map(h => h.name));
  const { rc } = await runCg(['host', 'add', ...(name ? [name] : []), '--ssh', `${user}@${addr}`],
                             { collect: 'add-log', wantRc: true });
  if (rc !== 0) { connecting = false; log.classList.add('text-error'); paintOnboard(); return; }
  await refreshHosts();
  const added = (hostsNow || []).map(h => h.name).find(n => !before.has(n)) || name || null;
  // The step is done with what the machine is, not before: its first status
  // has to answer, or the summary filled in under the next step.
  if (added) await hostAnswered(added);
  addedHost = added;
  connecting = false;
  paintOnboard();
  // Connected: setup follows by itself - there is nothing to decide in between.
  // Already set up (added again), it is done as it is.
  if (!added || adding !== 'host') return;
  if ((hostStatus.get(added) || {}).set_up) {
    setupDone = true;
    paintOnboard();
    onbHandOver(() => { if (adding === 'host' && setupDone) { note(`${added} added`, 'text-primary'); closeAdd(); } });
    return;
  }
  onbSetupHost();
}

// The setup step: run right here, its log open as it goes. Closes the dialog
// once it is done; a failure keeps it open, with the reason.
let setupDone = false;

// A password asked in passing - sudo, while a machine is set up: a small popup
// over whatever is running, one field, Continue. Resolves the password, or
// null when it is cancelled.
function askPassword({ title, sub, placeholder = '' }) {
  return new Promise(resolve => {
    const dlg = $('pwdlg'), input = $('pwdlg-input'), yes = $('pwdlg-yes');
    $('pwdlg-title').textContent = title;
    $('pwdlg-sub').textContent = sub || '';
    input.placeholder = placeholder;
    input.value = '';
    yes.disabled = true;
    input.oninput = () => { yes.disabled = !input.value; };
    // Enter would submit the form's first button, which is Cancel.
    input.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); if (input.value) yes.click(); } };
    // Answered by the buttons themselves, not the close event: that one is
    // queued, and can land after whatever runs next. Esc is a Cancel.
    let done = false;
    const finish = v => {
      if (done) return;
      done = true;
      input.value = '';
      if (dlg.open) dlg.close();
      resolve(v);
    };
    yes.onclick = e => { e.preventDefault(); if (input.value) finish(input.value); };
    $('pwdlg-no').onclick = e => { e.preventDefault(); finish(null); };
    dlg.onclose = () => finish(null);
    dlg.showModal();
    input.focus();
  });
}
// What cg asks while it sets a machine up - its sudo password, and the
// Tailscale auth key when it is not on the tailnet yet: the popup, and an empty
// answer if it is cancelled - cg then stops, with nothing changed.
const SETUP_ASKS = {
  [ASK.hostSudo]: name => ({ title: 'Sudo password', wait: 'Waiting for the sudo password…',
    sub: `${name ? name + ': ' : ''}used once for setup. Not stored.` }),
  [ASK.tsAuthKey]: name => ({ title: 'Tailscale auth key', wait: 'Waiting for a Tailscale auth key…',
    placeholder: 'tskey-auth-…',
    sub: `${name || 'This machine'} is not on your tailnet yet. login.tailscale.com → Settings → Keys → `
       + 'Generate auth key (Reusable on, Ephemeral off). Saved for later builds.' }),
};
function sudoAnswer(job, askId) {
  const j = jobs.get(job);
  if (!SETUP_ASKS[askId] || !j || j.cmd[0] !== 'host' || j.cmd[1] !== 'setup') return false;
  const q = SETUP_ASKS[askId](j.cmd[2]);
  const live = onbRunning === 'setup' ? $('onb-live-setup') : null;
  if (live) live.textContent = q.wait;
  askPassword(q).then(v => {
    window.cg.answer(job, v || '');
    if (live && v) live.textContent = 'Continuing…';
  });
  return true;
}
async function onbSetupHost() {
  const name = addedHost;
  if (!name || onbRunning) return;
  onbUnit('setup');
  onbLogOpen('setup', true);
  const ok = await runInPipeline('setup', ['host', 'setup', name], 'Starting setup…', paintHostCards);
  // Nothing to re-read for this step: its own exit is the verdict.
  if (onbVerifying === 'setup') onbVerifying = null;
  $('onb-prog-setup').hidden = true;
  await refreshHosts(name);
  if (!ok) { onbLogOpen('setup', true); paintOnboard(); return; }
  setupDone = true;
  paintOnboard();
  onbHandOver(() => {
    if (adding !== 'host' || !setupDone) return;
    note(`${name} set up`, 'text-primary');
    closeAdd();
  });
}

// Refresh means "this screen", and the reads behind it are independent, so
// they run together rather than one after another.
const NEEDS = {
  dashboard: [[['status', '--json'], 'status'], [['watcher', '--json'], 'guards'], HOSTS_READ],
  // machines too: the instance-type row is a picker, and its options are
  // whatever this region rents - see editSetting.
  settings:  [[['config', '--json'], 'config'], [['machines', '--json'], 'machines'],
              [['sweep', '--cached', '--json'], 'sweep'], [['creds', '--json'], 'creds'],
              [['creds', 'tailscale', '--json'], 'tskey']],
  // Build reads status too: if a box is already up there is nothing to build,
  // and its own Refresh must be able to find that out.
  build:     [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status'],
              [['machines', '--json'], 'machines'], [['sweep', '--cached', '--json'], 'sweep'],
              HOSTS_READ],
  library:   [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status'],
              [['library', 'elsewhere', '--json'], 'elsewhere']],
  // config too: the settings card is edited here, and a save has to come back
  // as the new value - the watcher alone left the old one showing.
  guards:    [[['watcher', '--json'], 'guards'], [['config', '--json'], 'config']],
};
const loaded = new Set();

// What a screen reads when it refreshes. Cost is not in NEEDS, so opening that
// tab fetches nothing: it bills, and only its Refresh asks.
// Home and Machine also read each machine of yours; a laptop with no AWS reads
// nothing that asks AWS.
const readsFor = v => forMode(v === 'cost' ? [[['cost', '--json'], 'cost']]
  : NEEDS[v] && [...NEEDS[v], ...(v === 'dashboard' || v === 'build' ? hostReads() : [])]);
async function refresh(each, need = readsFor(view)) {
  if (!need) return;               // logs need nothing
  if (view !== 'cost') loaded.add(view);
  await Promise.all(need.map(([args, json]) =>
    runCg(args, view === 'cost' ? { json } : { json, group: 'refresh' }).then(() => each && each(json))));
}

// Each read, in the words the page uses for what it shows.
const READ_NAME = {
  status: 'Machine and billing', guards: 'Safeguards', library: 'Saved games',
  elsewhere: 'Games in other regions',
  machines: 'Machine types and prices', sweep: 'Regions', config: 'Settings',
  creds: 'AWS key', tskey: 'Tailscale', deps: 'Local tools', cost: 'Exact cost this month',
  hosts: 'Servers',
};
const readName = json => (json.startsWith('host:') ? `${json.slice(5)}, your machine` : READ_NAME[json] || json);
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
    ? `Loading this month\'s bill${price ? `, ${price}` : ''}.`
    : 'Loading latest status.';
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
      text.append(Object.assign(document.createElement('div'), { textContent: readName(json) }));
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
function afterWrite(job, rc) {
  // A cancelled build goes straight on to its delete; the read waits for that.
  // A refused change to the saved games keeps its own popup, saying why.
  if (!SHOWN_AFTER.has(job.cmd[0]) || (run && run.cancelling)
      || (job.cmd[0] === 'library' && rc !== 0)) return refreshAll();
  // A change to the saved games touches the saved games, and nothing else -
  // not the tools on this laptop, the keys or the locations, which it used to
  // read all over again. Keep for also rewrites a setting and the watchdog.
  if (job.cmd[0] === 'library')
    return refreshShown(job.cmd[1] === 'keep-for' ? KEEP_FOR_READS : LIBRARY_READS);
  return refreshShown(forMode([...GATE_READS, ...ALL_READS]), each => refreshAll(each));
}
const LIBRARY_READS = [[['library', 'list', '--json'], 'library'],
                       [['library', 'elsewhere', '--json'], 'elsewhere']];
const KEEP_FOR_READS = [...LIBRARY_READS, [['config', '--json'], 'config'], [['watcher', '--json'], 'guards']];
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
  // A file on this laptop: the machines of yours it knows.
  [['host', 'list', '--json'], 'hosts'],
];
// The rest. Every one of them needs AWS, a tailnet, or both, so on a laptop
// that is not ready yet they would all come back unknown and the screen would
// fill with question marks instead of the one thing to do about it.
const ALL_READS = [
  [['status', '--json'], 'status'],
  [['watcher', '--json'], 'guards'],
  [['library', 'list', '--json'], 'library'],
  // Its own read: finding cg's other buckets takes seconds, and the archive
  // in use must not wait for it.
  [['library', 'elsewhere', '--json'], 'elsewhere'],
  [['machines', '--json'], 'machines'],
  // The REMEMBERED scan, never a fresh one: a scan takes 90 seconds and an
  // opening window must not wait on it. Rescanning is a button.
  [['sweep', '--cached', '--json'], 'sweep'],
];

// What a box needs before it can be built, in the order it has to be met, each
// with the one button that meets it.
//
// This used to be a ladder of `if`s that returned the first problem and nothing
// else. On a fresh laptop that means finding out about four jobs one at a time,
// each after finishing the last. So the list is a list, with a verdict for
// every rung, and setup shows the whole thing.
//
// `ok` is three-valued. true met, false not met, and null NOT KNOWN - the read
// behind it has not come back, or came back broken, or the rung above it has to
// be dealt with before this one can be judged at all. A rung whose read failed
// must never read as met.
//
// One sentence each. An old warning strip ran to three - cg's own sentence, then "Your
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
      return { title: 'Cannot reach AWS',
               body: 'Network error. The key was not rejected.',
               label: 'Try again', go: retryReads };
    case 'no-key':
      return { title: 'No AWS access key',
               body: 'Required to continue.',
               label: 'Add key', go: () => goSetting($('s-creds-card')) };
    default:
      return { title: 'AWS rejected this access key',
               body: 'Required to continue.',
               label: 'Add key', go: () => goSetting($('s-creds-card')) };
  }
}

// The done line for the region stage, which names the place rather than the
// setting: "ap-south-2" means nothing to someone who has not read .env.
function whereDone() {
  if (!machinesNow) return 'Region';
  const city = ((sweepNow && sweepNow.regions) || [])
    .find(r => r.region === machinesNow.region);
  return city && city.city ? `Runs in ${shortCity(city.city)}` : `Runs in ${machinesNow.region}`;
}

// Whether a region is written in .env - chosen - as against cg's default.
const regionChosen = () => {
  const r = (config || []).find(x => x.key === 'GAME_REGION');
  return !!(r && r.is_set);
};

function prereqs(kind = kindNow()) {
  const missing = depsNow ? neededTools(kind).filter(x => !x.present).map(x => x.label) : [];
  const email = (config || []).find(r => r.key === 'EMAIL_ALERTS');
  const all = [
    // Installed is not enough for the AWS CLI: it also has to run, which only
    // cg creds can say. Both answers decide this one step - the pipeline used
    // to show the second as a row of its own, also called Tools, that came and
    // went as the two answers landed a second apart.
    { key: 'tools', reads: 'deps', name: 'Required tools installed',
      ok: depsNow ? !missing.length && !cliBroken() : null,
      problem: { blocking: true,
                 title: `${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} not installed`,
                 body: 'Required to continue.',
                 ...toolAction(missing) } },
    { key: 'cli', reads: 'creds', name: 'AWS CLI installed',
      // Shown only when the tools stage is happy: when it is not, this is the
      // same missing package and the same button, one row further down.
      sameAs: 'tools',
      ok: credsNow ? !!credsNow.cli : null,
      problem: { blocking: true, title: 'The AWS CLI is not installed',
                 body: 'Required to continue.',
                 ...toolAction(['aws']) } },
    // Judged only once there is a CLI to ask with: "AWS rejected this key" is a
    // lie about a laptop that could not ask AWS anything.
    { key: 'key', reads: 'creds', name: 'AWS access key valid',
      ok: !credsNow ? null : credsNow.cli ? credsNow.valid === true : null,
      problem: { blocking: true, ...keyProblem() } },
    { key: 'tailnet', reads: 'tskey', name: 'Tailscale signed in',
      // Only a clear yes. cg says null when it cannot tell - Tailscale is not
      // installed - and "not false" read that as signed in: an empty laptop
      // showed this step ticked before it had Tailscale at all.
      ok: tskeyNow ? tskeyNow.signed_in === true : null,
      problem: { blocking: true, title: 'Tailscale not signed in',
                 body: 'Machines are reachable only over Tailscale.',
                 label: 'Sign in', go: signInTailscale } },
    { key: 'authkey', reads: 'tskey', name: 'Tailscale auth key saved',
      ok: tskeyNow ? !!(tskeyNow.auth_key_stored || tskeyNow.can_mint) : null,
      problem: { blocking: true, title: 'No Tailscale auth key',
                 body: 'Required for new machines to join the network.',
                 label: 'Add auth key', go: setAuthKey } },
    { key: 'email', reads: 'config', name: 'Alert email set',
      ok: email ? !!email.is_set : null,
      problem: { blocking: true, title: 'No alert email',
                 body: 'Required for the budget alert created at build time.',
                 label: 'Add email', go: () => goSetting(settingEl('EMAIL_ALERTS')) } },
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
            title: machinesNow ? `${placeName(machinesNow.region)} cannot run this machine` : 'No region selected',
            body: 'No GPU quota there, or no supported machine type. '
                + 'Measure all regions to pick another (free).',
            label: 'Choose region', go: openWhereTo }
        : { blocking: true, title: 'Choose a region',
            body: 'Lower latency is better. Measuring all regions takes ~90 s (free).',
            label: 'Choose region', go: openWhereTo } },
  ];
  if (kind === 'aws') return all;
  // A server of yours: this laptop's steps, then the server, then setting it up.
  // No auth key step: a server already on the tailnet never needs one, and one
  // that is not is asked for it during its setup.
  return [...all.filter(r => !['cli', 'key', 'authkey', 'email', 'where'].includes(r.key)),
    { key: 'server', reads: null, name: 'The server', ok: !!addedHost,
      problem: { blocking: false, title: 'The server', body: '', label: 'Connect', go: connectServer } },
    { key: 'setup', reads: null, name: 'Setup', ok: setupDone,
      problem: { blocking: false, title: 'Setup', body: '', label: 'Set up', go: () => {} } }];
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
  for (const h of ['', 'Region', 'Latency', 'Machine', 'Spot/hour', 'On-demand/hour']) {
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
    ms.textContent = r.rtt != null ? distance(r.rtt) : '—';
    const type = document.createElement('td');
    type.className = 'region';
    // Why it cannot be used, where the machine would go: an enabled region
    // with no GPU quota is the one that reads as a broken app.
    type.textContent = r.type || (r.enabled ? 'No GPU limit here yet' : 'Not switched on yet');
    const spot = document.createElement('td');
    spot.className = 'num';
    spot.textContent = r.spot != null ? rsh(perHour(r.spot)) : '—';
    const od = document.createElement('td');
    od.className = 'num';
    od.textContent = r.od != null ? rsh(perHour(r.od)) : '—';
    tr.append(pick, city, ms, type, spot, od);
    table.append(tr);
  }
  const usable = rows.filter(r => r.usable).length;
  $('whereto-sub').textContent = rows.length
    ? `Measured from this device \u00b7 ${usable} of ${rows.length} available`
    : 'Lower latency is better.';
  $('whereto-note').textContent = rows.length && !usable
    ? 'None available. New regions start with no GPU quota; request one under Machine type.'
    : '';
  $('whereto-use').disabled = !whereToPick || !rows.some(r => r.region === whereToPick && r.usable);
  // The button names the place, so what it does is never in doubt.
  $('whereto-use').textContent = whereToPick ? `Use ${placeName(whereToPick)}` : 'Select';

  // Three ways for there to be nothing to list, and each says which it is:
  // still measuring, the measurement failed, or nothing answered.
  const failed = !sweeping && !rows.length && readFailures.has('sweep');
  // Measuring shows the spinner whether or not there is a table yet. Measuring
  // AGAIN used to change one grey line of text and nothing else, so pressing
  // the button looked like it had done nothing: the old table stays, faded and
  // out of reach, under a spinner, until the new numbers replace it.
  $('whereto-busy').hidden = !sweeping;
  $('whereto-busy-text').textContent = rows.length
    ? 'Measuring again (~90 s).'
    : 'Measuring all AWS regions (~90 s, free).';
  $('whereto-list').hidden = !rows.length;
  $('whereto-list').classList.toggle('stale', sweeping);
  $('whereto-err').hidden = sweeping || rows.length > 0;
  $('whereto-err').textContent = failed
    ? `Measurement failed: ${readFailures.get('sweep')}`
    : 'No AWS region responded. Check your connection.';
  if (sweeping) $('whereto-sub').textContent = 'Lower latency is better.';
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
// What is on each stage comes from prereqs(). What cg is doing comes from cg.

// Which of three things the dashboard is doing:
//   setup      something is unmet, or not yet known - the pipeline is the screen
//   handover   all six are met, and the finished pipeline is held on screen for
//              a beat so you see it finish rather than having it vanish
//   dashboard  the cards
//
// It only ever moves forwards: dropping back into a setup flow out from under
// someone who is using the app would be worse than the problem. A prerequisite
// that breaks later is not announced - setup made sure of it once, and a strip
// above every page for a rare breakage was judged not worth its place.
// How many sets of the reads behind the gate are in flight. The pipeline's
// stages are judged on the fast ones, so it used to finish and hand over while
// the box, the archive and the guards were still being read - and the first
// thing on the new dashboard was "Stop refresh" and three empty cards. The
// handover waits for this to reach zero instead: the dashboard arrives filled.
let readingBehindGate = 0;
let onbHandover = null;
const ONB_HANDOVER_MS = 900;
// The dialog's last step is done: a beat, so the tick is seen landing, then
// `then` - closing it, for AWS and for a server set up alike.
function onbHandOver(then) {
  onbHandover = afterBeat(() => { onbHandover = null; then(); });
}
// The one delay in the app: a finished thing is held on screen for a beat, so
// it is seen to finish, then `then`. It starts no command.
function afterBeat(then) { return setTimeout(then, ONB_HANDOVER_MS); }

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
async function runInPipeline(key, args, status, started) {
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
  if ([...jobs.values()].some(j => !hostRun(j))) {
    $('onb-live-' + key).textContent = 'Waiting for the last checks to finish…';
    await readsSettled();
    $('onb-live-' + key).textContent = status || 'Starting…';
  }
  const { rc, err } = await runCg(args, { collect: onbLogId(key), wantRc: true,
                                          onStart: id => { onbJob = id; if (started) started(); } });
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
    onbNote = rc === null ? (err || 'Another task is running.')
      : rc === 130 ? 'Stopped.'
      : (ONB_FAIL[key] || 'Failed. See details below.');
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
  tools: 'Install failed. See details below.',
  cli: 'AWS CLI install failed. See details below.',
  tailnet: 'Sign-in failed. See details below.',
  where: 'Could not save the region. See details below.',
};

// Installing the tools runs here rather than opening something: it needs no
// answer from you beyond the password your OS asks for.
function onbInstall() {
  // What THIS machine needs: a server of yours never needs the AWS CLI, and
  // the button used to install it anyway.
  const missing = depsNow ? neededTools().filter(x => !x.present).map(x => x.tool) : [];
  onbWasMissing = new Set(missing);
  return runInPipeline('tools', ['deps', 'install', ...missing], 'Waiting for password…');
}
function onbInstallCli() {
  return runInPipeline('cli', ['deps', 'install', 'aws'], 'Waiting for password…');
}
function onbSignIn() {
  return runInPipeline('tailnet', ['creds', 'tailscale', 'signin'], 'Opening your browser…');
}

// What each step is called, in the words of someone who has never used AWS.
// prereqs() keeps short sentences of its own; these are for the first run, and
// nothing in them names a command, a flag or an AWS service without saying
// what it is.
//
//   name  the step, short - what the dim list of steps still to come shows
//   done  what is now true, said once it is
//   body  why it matters, and what pressing the button will do
const missingTools = () => depsNow
  ? neededTools().filter(x => !x.present).map(x => x.label) : [];
// Short and plain: what is needed and what it is for, in one or two sentences.
// The Tools step has no sentence at all - it shows the tools themselves.
// The AWS CLI is installed - cg deps found it - but does not run: cg creds
// says there is no CLI. Shown on its own chip, not as a second Tools row.
function cliBroken() {
  if (kindNow() !== 'aws' || !depsNow || !credsNow || credsNow.cli !== false) return false;
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
      ? [...missingTools(), ...(cliBroken() ? ['the AWS CLI (installed, but not working)'] : [])]
      : [];
    onbNote = still.length ? `Still missing: ${still.join(', ')}. See details below.`
      : (ONB_FAIL[key] || 'Failed. See details below.');
    onbTone = 'bad';
    onbLogOpen(key, true);
  }
  paintOnboardSoon();
}

const ONB_COPY = {
  open: { name: 'Loading', done: () => 'Ready', body: () => '' },
  server: { name: 'The server',
    done: () => { const s = hostStatus.get(addedHost) || {};
                  return [addedHost, s.os_name, s.gpu].filter(Boolean).join(' · ') || 'The server'; },
    body: () => 'Connect over SSH.' },
  setup: { name: 'Setup', done: () => 'Set up',
    body: () => 'Installs Tailscale, Sunshine and Steam if missing, and pairs Moonlight. '
              + 'Requires sudo. Can also be run later from the machine card.' },
  tools: { name: 'Tools', done: () => 'Tools installed', body: () => '' },
  cli: { name: 'Tools', done: () => 'Tools installed',
    body: () => 'AWS CLI not installed.' },
  key: { name: 'AWS account', done: () => 'AWS account connected',
    body: () => ({
      unreachable: 'Cannot reach AWS. The key was not verified.',
      'no-key': 'An AWS access key is used to launch and stop machines.',
    }[credsNow && credsNow.reason]
      || 'The saved access key was rejected. Add a new one.') },
  tailnet: { name: 'Tailscale', done: () => 'Tailscale signed in',
    body: () => 'Sign in to Tailscale. Machines are reachable only over your tailnet.' },
  authkey: { name: 'Auth key', done: () => 'Auth key saved',
    body: () => 'New machines use a Tailscale auth key to join your tailnet.' },
  email: { name: 'Budget alert',
    done: () => { const e = cfgVal('EMAIL_ALERTS'); return e ? `Alerts to ${e}` : 'Alerts on'; },
    body: () => 'Email address for budget alerts.' },
  where: { name: 'Region', done: () => whereDone(),
    body: () => regionChosen() && machinesNow
      ? `${placeName(machinesNow.region)} has no GPU quota for this machine. Choose another region.`
      : 'Choose a region. Lower latency is better.' },
};
// The city, when the scan knows it; the code otherwise.
function placeName(region) {
  const r = ((sweepNow && sweepNow.regions) || []).find(x => x.region === region);
  return r && r.city ? shortCity(r.city) : region;
}

// The one button a step offers, in the same words. Each opens its dialog right
// here or runs right here: nothing in the first run sends you to another screen.
const ONB_ACTION = {
  server:  () => [serverPwAsk ? { label: 'Continue', go: connectServer }
                             : { label: connecting ? 'Connecting…' : 'Connect', go: connectServer, busy: connecting }],
  // Only after a setup that failed or was stopped: it starts by itself.
  setup:   () => [{ label: 'Set up', go: onbSetupHost },
                  { label: 'Later', go: closeAdd, plain: true }],
  // Installed but will not run is not something installing fixes - cg deps
  // install skips a tool it can find - so that case offers a fresh look.
  tools:   () => [!missingTools().length && cliBroken()
                    ? { label: 'Check again', go: retryReads }
                    : { label: 'Install', go: onbInstall }],
  cli:     () => [{ label: 'Install', go: onbInstallCli }],
  tailnet: () => [{ label: 'Sign in to Tailscale', go: onbSignIn }],
  // A read that never reached AWS is not a request for a key, so it keeps the
  // rung's own Try again rather than opening the key form.
  key: r => r.problem.go === retryReads
    ? [{ label: 'Try again', go: retryReads }]
    : [{ label: credsNow && credsNow.reason === 'no-key' ? 'Connect AWS' : 'Connect again',
         go: () => openAwsKey(onbLogFresh('key')) }],
  authkey: () => [{ label: 'Add auth key', go: () => setAuthKey(onbLogFresh('authkey')) }],
  email:   () => [{ label: 'Add email', go: () => openAlertEmail(onbLogFresh('email')) }],
  where:   () => [{ label: 'Choose region', go: openWhereTo }],
};
const onbActions = r =>
  (ONB_ACTION[r.key] || (x => [{ label: x.problem.label, go: x.problem.go }]))(r);

// What each step looked like at the last paint, so the motion runs on the
// paint where a step CHANGED and not on every repaint after it.
const onbSeen = {};

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
    if (!$('adddlg').open) $('adddlg').showModal();
    $('onb-title').textContent = 'Scripts not found';
    $('onb-count').textContent = '';
    wrap.textContent = '';
    wrap.append(el('p', 'font-body-md text-body-md text-on-surface-variant mb-space-md',
      'Cloud Gaming requires its scripts, which are not installed.'));
    for (const [state, text, note] of [
      ['failed', `Expected at ${engineGone.cg}`, ''],
      ['locked', 'Install them with:',
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

  paintHome();
  if (!adding) return;
  // A rung that is the same fix as another is never a row of its own: the AWS
  // CLI is judged inside Tools.
  const rungs = prereqs().filter(r => !r.sameAs);
  const ready = rungs.every(r => r.ok === true);
  const firstOpen = rungs.findIndex(r => r.ok !== true);
  const done = rungs.filter(r => r.ok === true).length;
  // AWS is added once its last step is met: a beat first, so the ticks are seen
  // landing - six replaced in 200ms read as a glitch - then the dialog closes on
  // the new card. Reads that started meanwhile are waited for, so the card
  // arrives filled rather than reading.
  if (adding === 'aws' && ready && !readingBehindGate && !onbHandover) {
    onbHandOver(() => {
      if (adding !== 'aws') return;
      if (prereqs().every(x => x.ok === true) && !readingBehindGate) { note('AWS added', 'text-primary'); closeAdd(); }
      else paintOnboard();
    });
  }
  wrap.hidden = false;
  // The count is the only heading besides the title: the steps say the rest.
  $('onb-count').textContent = `${done} of ${rungs.length} done`;

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

    if (quiet || state === 'checking') { row.append(rail, body); wrap.append(row); return; }
    if (state === 'done') {
      // What it did stays, folded: you can still look at what the install said.
      if (hasLog) place();
      row.append(rail, body); wrap.append(row); return;
    }
    if (state === 'unknown') {
      const why = document.createElement('div');
      why.className = 'font-body-sm text-body-sm text-on-surface-variant mt-0.5';
      why.textContent = 'Check failed.';
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
      ? 'Complete sign-in in your browser. Setup continues automatically.'
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
      for (const t of neededTools()) {
        const chip = document.createElement('span');
        const broken = t.tool === 'aws' && cliBroken();
        const recheck = state === 'verifying' && onbWasMissing.has(t.tool);
        const ok = t.present && !broken;
        chip.className = 'pill ' + (recheck ? '' : ok ? 'pill-ok' : 'pill-bad');
        chip.dataset.tool = t.tool;
        chip.dataset.present = recheck ? 'checking' : ok ? 'yes' : 'no';
        chip.textContent = (recheck ? '\u2026 ' : ok ? '\u2713 ' : '\u2717 ') + t.label
          + (broken && !recheck ? ' (installed, but not working)' : '');
        list.append(chip);
      }
      inner.append(list);
    }
    // The server: the form, kept across paints so nothing typed is lost.
    if (r.key === 'server') inner.append(serverForm);
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
        b.className = a.plain ? 'btn' : 'btn btn-primary';
        b.disabled = !!a.busy;
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
  for (const [id, job] of [...jobs]) if (!job.write && !hostRun(job)) await window.cg.cancel(id);
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
  paintOnboardSoon();
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
const gateBlocked = () => awsInPlay() && prereqs('aws').some(r => r.ok === false && GATE_JSON.has(r.reads));
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
    await Promise.all(forMode(ALL_READS).map(([args, json]) =>
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
  // Locations are AWS's: with no AWS machine, there is nothing to measure.
  if (!awsInPlay()) return;
  if (sweepNow && (sweepNow.regions || []).length) return;
  // Something is running: a scan can wait, and cg would refuse to start one
  // underneath a build anyway.
  if (jobs.size) return;
  scanOffered = true;
  return scanRegions($('s-sweep'));
}

$('refresh').onclick = () => refreshShown();
// What Stop costs depends on what is running, so say it before doing it.
const STOP_WARNING = {
  init: 'The machine may already be running and billing. Delete it from Home, '
      + 'or auto-stop ends it after 30 idle minutes.',
  destroy: 'Games are being saved. Stopping may lose changes since the last save '
         + 'and leave the machine running.',
  open: 'Ends the session only. The machine keeps running.',
};
// Settings is a long screen, and arriving on it is not the same as finding the
// thing you came for: the first instance-type picker went unnoticed entirely
// because it was below the fold. So anything that sends you to a setting
// scrolls to it and flashes it, and that is the ONLY way a key is set - one
// place per thing, the same rule the machine chooser follows.
function openMachines() {
  paintChooser();
  if (!$('machdlg').open) $('machdlg').showModal();
}
$('machdlg-close').onclick = () => { if (!machBusy()) $('machdlg').close(); };
// Esc closes it, except mid-scan or mid-save. Both, because Chromium honours a
// prevented cancel only once per user activation; a prevented keydown never
// becomes a close request at all.
$('machdlg').oncancel = e => { if (machBusy()) e.preventDefault(); };
$('machdlg').addEventListener('keydown', e => { if (e.key === 'Escape' && machBusy()) e.preventDefault(); });

function goSetting(el) {
  // The page the row is on: a setting has one home, and it is not always here.
  const sec = el && el.closest('section[data-view]');
  goView(sec ? sec.dataset.view : 'settings');
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
const settingEl = key => document.querySelector(`.row[data-key="${key}"]`);

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
       || 'Read-only. Stopping them changes nothing.',
    yes: 'Stop', danger: true,
  });
  if (!ok) return;
  for (const [id, j] of jobs) if (j.view === view && !hostRun(j)) window.cg.cancel(id);
};
mountMachineCard($('d-hero'), 'd');
mountMachineCard($('b-machine'), 'b');
$('d-fix').onclick = $('b-fix').onclick = () => openAdd('aws');
$('d-build').onclick = () => goView('build');
$('d-watch').onclick = () => goView('build');
$('d-ts-signin').onclick = signInTailscale;
$('d-library').onclick = () => goView('library');
applyLogFilter('all');           // the default is shown as chosen, not just in force
restoreBill();                   // the last bill on this laptop, until a new check
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
    $('log-count').textContent = 'Copied';
  } catch { $('log-count').textContent = 'Could not copy'; }
};
// Reading CloudWatch logs is free; it is manual only because it is rarely the
// thing you want, not because it costs anything.
$('log-cloud').onclick = async () => {
  const btn = $('log-cloud');
  btn.disabled = true;
  $('log-cloud-label').textContent = 'Loading…';
  $('log-cloud-out').textContent = 'Loading…';
  const out = await runCg(['watchdog', 'logs'], { capture: true });
  btn.disabled = false;
  $('log-cloud-label').textContent = 'Load';
  $('log-cloud-out').textContent = watchdogDigest(out || '')
    || 'Nothing in the last 3 hours.';
};
// The watchdog writes a line every 5 minutes, so three hours is ~40 copies of
// "nothing to do" around the three hourly lines that say anything. A line seen
// more than twice is said once, with how often and over what span; the rest
// are kept as written. Times are this laptop's, not UTC.
function watchdogDigest(text) {
  const rows = [];
  for (const line of text.split('\n')) {
    const m = line.match(/^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\S*\s+(?:cg-watchdog:\s*)?(.*)$/);
    if (m) rows.push({ at: new Date(m[1] + 'Z'), msg: m[2] });
    else if (line.trim()) rows.push({ at: null, msg: line.trim() });
  }
  const hm = d => d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const seen = new Map();
  for (const r of rows) seen.set(r.msg, (seen.get(r.msg) || []).concat(r));
  const out = [], done = new Set();
  for (const r of rows) {
    const all = seen.get(r.msg);
    if (all.length > 2) {
      if (done.has(r.msg)) continue;
      done.add(r.msg);
      const first = all[0].at, last = all[all.length - 1].at;
      out.push({ at: last, text: `${first && last ? `${hm(first)}–${hm(last)}` : ''}  ${r.msg}  (${all.length} checks)` });
    } else {
      out.push({ at: r.at, text: `${r.at ? hm(r.at) : ''}  ${r.msg}` });
    }
  }
  return out.map(o => o.text.trim()).join('\n');
}
// Both of these delete things in S3 for good. The app asks once, then cg asks
// for the word typed out - CLEAN, FORGET - which the ask dialog renders.
// Keep for: the one rule for every saved game, saved and applied in one go
// (cg library keep-for), so the dates in the table are the ones AWS acts on.
$('lib-keepfor').onchange = async ev => {
  const n = Number(ev.target.value);
  await libraryRun(['library', 'keep-for', String(n)],
                   n ? `Retention set to ${n} days` : 'Retention set to forever');
};
$('lib-clean').onclick = async () => {
  const ok = await askConfirm({
    title: 'Delete leftover files?',
    body: 'Files from an incomplete save. No game uses them.\n\n'
        + 'Saved games are not affected.',
    yes: 'Clean up', danger: true, word: 'CLEAN',
  });
  if (ok) await libraryRun(['library', 'clean'], 'Deleting leftover files', 'clean-orphans', 'CLEAN');
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
  // Short lines in the words the table uses: what it is, what it costs, the
  // one catch. A move always says what it leaves behind: saved games belong to
  // a location, and a machine elsewhere cannot reach them.
  const body = [
    [row.type, row.gpu && gpuName(row.gpu, row.vram), row.store != null && `${row.store} GB game disk`].filter(Boolean).join(' · '),
    `${spot ? 'Spot' : 'On-demand'}${price != null
      ? ` · ${hourText(perHour(price), spot && row.spotMax != null ? perHour(row.spotMax) : null)} an hour while it runs` : ''}`,
    spot ? 'Cheaper; can be reclaimed mid-session.' : 'Not reclaimed.',
    spot && row.score != null && row.score <= 2
      ? `Low spot capacity (${row.score}/10). A spot launch will likely fail.` : '',
    moving
      ? `Games saved in ${cur.region ? placeName(cur.region) : 'other regions'} are not available in `
        + `${placeName(row.region)}. Move them on the Games page, or Steam re-downloads them.` : '',
    boxNow ? 'Applies to the next build. The running machine is not changed.' : '',
  ].filter(Boolean).join('\n\n');
  const ok = await askConfirm({
    title: `Use ${row.type} in ${placeName(row.region)}?`,
    body, yes: moving ? 'Move' : 'Use it', danger: moving,
  });
  if (!ok) { paintChooser(); return; }            // put the old choice back
  choosing = true;
  paintChooser();
  const pop = busyPopup('Saving',
    `${row.type}, ${spot ? 'spot' : 'on-demand'}, ${placeName(row.region)}. Applies to the next build.`,
    'Saving');
  let saved = false;
  try {
  // Type and model first, then the region. A half-applied change is possible
  // whatever the order, so the order is chosen to leave the least wrong state:
  // the wrong type in the right region is a refused launch with a clear reason,
  // while the right type in the wrong region silently builds the wrong box.
  await runCg(['config', 'set', 'GAME_INSTANCE_TYPE', row.type]);
  await runCg(['config', 'set', 'GAME_SPOT', spot ? '1' : '0']);
  if (moving) await runCg(['config', 'set', 'GAME_REGION', row.region]);
  // machines is per-region, so a move makes the old answer wrong; and the
  // games that fit depend on the machine's disk, so the library is read again.
  await Promise.all([runCg(['config', '--json'], { json: 'config' }),
                     runCg(['machines', '--json'], { json: 'machines' }),
                     runCg(['status', '--json'], { json: 'status' }),
                     runCg(['library', 'list', '--json'], { json: 'library' })]);
  saved = currentPick().type === row.type && currentPick().region === row.region;
  } finally {
    choosing = false;
    paintChooser();
    saved ? pop.done() : pop.fail('Not saved. See Activity for details.');
  }
}

// Scanning every region takes about 90 seconds, so nothing waits on it: the
// window opens on the remembered scan and this runs in the background, either
// from the button or - once, on a laptop that has never scanned - by itself.
// Every call it makes is free.
async function scanRegions(btn) {
  const was = btn && btn.textContent;
  if (btn) { btn.disabled = true; btn.textContent = 'Checking all regions…'; }
  sweeping = true;
  paintChooser();                 // the table says what it is waiting for
  repaintWhereTo();
  const pop = $('machdlg').open
    ? busyPopup('Checking all regions', 'Measuring latency and prices (~90 s, free).',
                'Checking all regions')
    : null;
  try {
    await runCg(['sweep', '--json'], { json: 'sweep' });
  } finally {
    sweeping = false;
    if (btn) btn.textContent = was;
    paintChooser();
    repaintWhereTo();
    if (pop) readFailures.has('sweep') ? pop.fail(readFailures.get('sweep')) : pop.done();
  }
}
const sweepBtn = $('s-sweep');
if (sweepBtn) sweepBtn.onclick = () => scanRegions(sweepBtn);

// Build's "Change": the chooser opens over the page you are on, so the choice
// is made where the build is - it used to send you to the top of Settings.
$('b-login-choice').onchange = async ev => {
  ev.target.disabled = true;
  await runCg(['config', 'set', 'GAME_STEAM_LOGIN', ev.target.value]);
  await runCg(['config', '--json'], { json: 'config' });
  ev.target.disabled = false;
};

$('d-guards').onclick = () => goView('guards');
$('d-bill-more').onclick = () => goView('cost');
$('c-egress-settings').onclick = () => goView('settings');
// The only button on the dashboard that spends money, and it says so.
// Exact cost is the Spending page's own check: go there and press its Refresh,
// so the bill is read once, behind the same popup, and you are looking at it.
$('d-cost').onclick = () => { goView('cost'); $('refresh').click(); };
// A build, a delete and a session all report the same way - steps, lines, an
// exit - so they all run on the Build screen as steps, and starting one goes
// there. Watching a delete in a panel that says nothing was the complaint.
let runKind = 'init';
function startRun(args, opts = {}) {
  runKind = args[0];
  // A build picked up again by itself does not take you off the page you are
  // on; the machine card says it is building, and Watch the build opens it.
  if (!opts.stay) { machineTab = 'aws'; goView('build'); paintMachineTab(); }
  $('b-log').dataset.fresh = 'yes';
  $('b-log').textContent = '';
  $('b-log-title').textContent = `${CgName(args)} · log`;
  buildSteps = 0;
  buildStarted = Date.now();
  $('b-prog').className = 'h-full bg-primary rounded-full';
  $('b-prog').style.width = '0%';
  $('b-prog-step').textContent = 'Starting…';
  buildFailClear();
  runBegin(args[0], opts);
  paintRun();
  return runCg(args, opts.env ? { env: opts.env } : {});
}

// A machine that runs but has not finished building. Closing the app in the
// middle of a build ends this laptop's half of it - waiting for the box, then
// pairing Moonlight - while the box carries on setting itself up; opened again,
// "running" read as ready and the card offered Play on a box with no desktop.
// cg status says whether the box is set up (ready) and whether this laptop's
// half finished (built). Either missing, it is shown as building, and the build
// is picked up again once: `cg init` finds the same instance and launches
// nothing new, so it costs nothing beyond the machine already running.
function unfinished(box) {
  return !!(box && box.state === 'running' && (box.ready === false || box.built === false));
}
let resumedFor = null;
function resumeBuild(s) {
  const box = s && s.box;
  // Reads run beside it freely; a build, a delete or a stream already going is
  // left alone.
  if (!unfinished(box) || resumedFor === box.id || ['init', 'destroy', 'open'].some(jobsFor)) return;
  resumedFor = box.id;
  // No GAME_APPS: the box was given its games when it launched, and cg keeps
  // that choice in .env - passing "none" here overwrote it, and with it the
  // restore's "109 of 160 GB" progress line.
  startRun(['init'], { stay: true });
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
    body: (sessionNow ? 'The current session is closed first.\n\n' : '')
        + 'Games are saved first; nothing is deleted if saving fails.\n\n'
        + 'The machine and its disk are deleted.'
        + (((statusNow || {}).build || {}).last_min != null
           ? ` The last build took ${statusNow.build.last_min} min.` : ''),
    yes: 'Delete machine', danger: true,
  });
  if (ok) await startRun(['destroy']);
};
$('b-build').onclick = async () => {
  const apps = picked.size ? [...picked].join(',') : 'none';
  const gb = selectedGb();
  const rate = statusNow ? machineFacts().priceText : null;
  const ok = await askConfirm({
    title: 'Build the machine?',
    body: `${picked.size ? `${picked.size} game${picked.size === 1 ? '' : 's'}, ${gb.toFixed(1)} GB, will be`
                         : 'No games will be'} restored during the build.\n\n`
        + `Billed ${rate != null ? `${rate}/hour` : 'hourly'} while running.`,
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
    if (e.isTrusted && view === 'build') machineTab = 'aws';
    if (view === 'build') paintMachineTab();
    for (const sec of document.querySelectorAll('main section[data-view]'))
      sec.hidden = sec.dataset.view !== view;
    updateHeader();
    // Reads run in parallel, so an open tab loads even while others are in flight.
    if (NEEDS[view] && !loaded.has(view)) refresh();
  };
}
// Drawn once before anything has been read, so the card has its rows and they
// say "reading…", rather than being blank until two reads land.
checkAsks();
// Is there an engine? Then what does it say. In that order: without cg the
// reads cannot even be started, and nine spawn errors describe one problem
// badly.
// The steps are drawn at once, all of them still being checked, so the window
// never opens on a blank page while the first answers come back.
paintOnboard();
// The remembered layout, filled with loading cards, from the first frame.
if (hostsNow) paintHostCards();
if (homeBoot && homeBoot.aws) paintMachineCards();
(async () => {
  if (!(await engineReady())) return;
  // The remembered machines are checked at once, beside the startup reads,
  // not after the list comes back: their cards are already on screen.
  for (const h of hostsNow || []) {
    const [args, json] = hostRead(h.name);
    runCg(args, { json, group: 'refresh' });
  }
  await refreshAll();
})();
