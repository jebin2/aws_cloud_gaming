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
  init: 'build', destroy: 'destroy', open: 'session', check: 'check',
  status: 'refresh', watcher: 'refresh', library: 'refresh', cost: 'cost fetch',
};
const runName = cmd => RUN_NAME[cmd[0]] || cmd[0];
// Runs long enough to be worth going back to.
const WATCHABLE = new Set(['init', 'destroy', 'open']);
const jobsHere = () => [...jobs.values()].filter(j => j.view === view);

// A screen's button answers for that screen. The one real dependency is that a
// build or a destroy runs alone - cg refuses anything else while one is in
// flight - so those disable the rest. Reads never block each other.
const WRITES = new Set(['init', 'destroy', 'open']);
const writing = () => [...jobs.values()].some(j => WRITES.has(j.cmd[0]));
const runningHere = cmd => jobsHere().some(j => j.cmd[0] === cmd);

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
  const elsewhere = [...jobs.values()].find(j => WATCHABLE.has(j.cmd[0]) && j.view !== view);
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
}

function logLine(event) {
  const kind = event.kind || event.t;
  const row = document.createElement('div');
  row.innerHTML = '<time></time><span class="k"></span><span class="t"></span>';
  row.querySelector('time').textContent = (event.at || '').slice(11, 19);
  row.querySelector('.k').textContent = event.t === 'line' ? (event.kind || '') : event.t;
  row.querySelector('.k').className = 'k ' + kind;
  row.querySelector('.t').textContent =
    event.text || event.prompt || (event.t === 'exit' ? `exit ${event.rc}` : '');
  $('log').append(row);
  $('log').scrollTop = $('log').scrollHeight;
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
  $('box-state').textContent = s.box ? s.box.state : 'No box';
  $('box-state').className = 'font-headline-xl text-headline-xl mb-space-lg '
    + (s.box ? 'text-primary' : 'text-outline');
  $('dot-conn').className = 'w-2 h-2 rounded-full ' + (s.box ? 'bg-primary animate-pulse' : 'bg-outline');
  $('chip-conn').textContent = s.box ? 'box running' : 'no box';
  $('box-type').textContent = s.box ? s.box.type : s.instance_type;
  $('box-region').textContent = s.region;
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
    $('arch-size').textContent = s.archive.bytes ? GB(s.archive.bytes) : 'empty';
    $('arch-objects').textContent = s.archive.objects ?? '—';
    $('arch-cost').textContent = s.archive.usd_month != null ? `$${s.archive.usd_month}` : '—';
    $('arch-chip').hidden = !s.archive.decision;
    $('arch-expiry').textContent = s.archive.decision || '';
    // Expiry off reads as reassurance, not a warning.
    $('arch-expiry').className = 'font-code-sm text-code-sm '
      + (s.archive.expiry_days === 0 ? 'text-primary' : 'text-tertiary');
  }

  const pills = $('pills');
  pills.textContent = '';
  if (s.budget && s.budget.limit != null) {
    pill(pills, `budget $${s.budget.limit} a month`, 'ok', 'shield');
    pill(pills, `${s.budget.alerts} alert address${s.budget.alerts === 1 ? '' : 'es'}`,
         s.budget.alerts ? 'ok' : 'bad', 'info');
  } else pill(pills, 'no budget - nothing will warn you', 'bad', 'warning');
  pill(pills, s.archive && s.archive.expiry_days
        ? `archive deleted after ${s.archive.expiry_days} days with no box`
        : 'archive kept forever',
       s.archive && s.archive.expiry_days ? 'warn' : 'ok', 'schedule');
  pill(pills, 'watchdogs in detail: Guards', null, 'terminal');

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

function paintCost(d) {
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
    cell(tr, daysAgo(g.pushed), 'text-right pl-space-md text-outline');
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

  $('lib-orphans').hidden = !d.orphan_bytes;
  if (d.orphan_bytes) {
    $('lib-orphans').textContent =
      `plus ${(d.orphan_bytes / 1073741824).toFixed(1)} GB orphaned by an unfinished push, `
      + `costing $${d.orphan_usd_month}/month and unusable - remove with: cg library clean`;
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

const ago = s => s == null ? '' : s < 90 ? `${s}s ago` : s < 5400 ? `${Math.round(s / 60)}m ago` : `${Math.round(s / 3600)}h ago`;

// Rendered from `cg watcher --json`: one card per layer, in the order they fire.
function paintGuards(d) {
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
            <span class="font-code-sm text-code-sm text-outline">layer ${g.layer}</span>
          </div>
          <p class="font-code-sm text-code-sm text-on-surface-variant mt-space-xs"></p>
        </div>
        <span class="pill ${tone}">${state}</span>
      </div>
      <dl class="grid grid-cols-3 gap-space-md mt-space-md">
        <div><dt class="font-label-caps text-label-caps uppercase text-outline">catches</dt>
             <dd class="font-code-sm text-code-sm mt-0.5 catches"></dd></div>
        <div><dt class="font-label-caps text-label-caps uppercase text-outline">reaction</dt>
             <dd class="font-code-sm text-code-sm mt-0.5 reaction"></dd></div>
        <div><dt class="font-label-caps text-label-caps uppercase text-outline">dies with</dt>
             <dd class="font-code-sm text-code-sm mt-0.5 dies"></dd></div>
      </dl>
      <p class="font-code-sm text-code-sm text-outline mt-space-md last"></p>`;
    card.querySelector('.font-headline-md').textContent = g.name;
    card.querySelector('p.font-code-sm').textContent = g.note || '';
    card.querySelector('.catches').textContent = g.catches;
    card.querySelector('.reaction').textContent = g.reaction;
    card.querySelector('.dies').textContent = g.dies_with;
    card.querySelector('.last').textContent = g.last_decision
      ? `last decision ${ago(g.last_decision_age_s)}: ${g.last_decision}` : '';
    wrap.append(card);
  }
  const b = d.budget || {};
  $('g-budget').textContent = b.usd != null ? `$${b.usd} a month` : 'missing';
  $('g-budget-note').textContent = b.usd == null
    ? 'no budget exists - nothing will warn you'
    : `${b.alerts} alert address${b.alerts === 1 ? '' : 'es'}. It emails you; it does not stop anything.`;
  const sd = d.shutdown_action || {};
  $('g-shutdown').textContent = sd.value || (d.instance_state === 'none' ? 'no box' : 'unknown');
  $('g-shutdown-note').textContent = sd.expected
    ? (sd.ok ? `correct for this box (${sd.expected})` : `WRONG - must be ${sd.expected}`)
    : 'decided at launch; a spot box must terminate';
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

function paintConfig(rows) {
  config = rows;
  const wrap = $('s-rows');
  wrap.textContent = '';
  for (const r of rows) {
    const row = document.createElement('div');
    row.className = 'row border-b border-surface-variant/40 items-start';

    const left = document.createElement('div');
    left.innerHTML = '<p class="font-code-md text-code-md"></p>'
                   + '<p class="font-code-sm text-code-sm text-outline mt-0.5"></p>';
    left.querySelector('p').textContent = LABEL[r.key] || r.key;
    left.querySelectorAll('p')[1].textContent = r.note;

    const right = document.createElement('div');
    right.className = 'flex items-center gap-space-sm';
    const val = document.createElement('span');
    val.className = 'font-code-md text-code-md text-on-surface-variant';
    val.textContent = settingValue(r);
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
      glyph.dataset.icon = 'visibility';
      glyph.textContent = '\ue8f4';                    // visibility
      eye.append(glyph);
      let shown = false;
      eye.onclick = async () => {
        if (shown) {
          val.textContent = 'set';
          glyph.textContent = '\ue8f4';                // visibility
          shown = false; eye.title = 'show the value';
          return;
        }
        val.textContent = 'reading…';
        const value = await runCg(['config', 'get', r.key], { capture: true });
        val.textContent = (value || '').trim() || 'not set';
        glyph.textContent = '\ue8f5';                  // visibility_off
        shown = true; eye.title = 'hide it again';
      };
      right.append(val, eye, edit);
    } else {
      right.append(val, edit);
    }

    row.append(left, right);
    wrap.append(row);
  }
}

function editSetting(r, row) {
  const right = row.lastElementChild;
  right.textContent = '';
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
                  + 'font-code-md text-code-md text-on-surface w-64';
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
  paintFit();
}

// Numbered steps, the way cg reports them: the one running is marked, the ones
// before it carry how long they took. No timer - each event repaints.
let buildStarted = 0;
function buildStep(text) {
  const steps = $('b-steps');
  if (steps.dataset.fresh !== 'no') { steps.textContent = ''; steps.dataset.fresh = 'no'; buildStarted = Date.now(); }
  for (const li of steps.children) {
    li.classList.remove('bg-surface-container');
    const dot = li.querySelector('.dot');
    if (dot) { dot.textContent = ICON.check_circle; dot.className = 'dot material-symbols-outlined text-[16px] text-primary'; }
  }
  const n = steps.children.length + 1;
  const li = document.createElement('li');
  li.className = 'flex items-start gap-space-sm px-space-sm py-space-xs rounded bg-surface-container font-code-sm text-code-sm';
  li.innerHTML = '<span class="dot material-symbols-outlined text-[16px] text-primary animate-pulse"></span>'
               + '<span class="text-outline w-5 shrink-0"></span>'
               + '<span class="min-w-0"><span class="t text-on-surface block"></span>'
               + '<span class="sub text-outline block truncate"></span></span>';
  li.querySelector('.dot').textContent = ICON.bolt;
  li.querySelector('span.text-outline').textContent = String(n).padStart(2, '0');
  li.querySelector('.t').textContent = text;
  steps.append(li);
  steps.scrollTop = steps.scrollHeight;
  paintElapsed();
}

// cg times every step; the finished ones carry how long they took, which is the
// only honest answer to "how much longer" on a box that varies.
function buildStepEnd(event) {
  const last = $('b-steps').lastElementChild;
  if (!last) return;
  const dot = last.querySelector('.dot');
  const ok = !event.rc;
  dot.textContent = ok ? ICON.check_circle : ICON.error;
  dot.className = 'dot material-symbols-outlined text-[16px] ' + (ok ? 'text-primary' : 'text-error');
  last.classList.remove('bg-surface-container');
  const sub = last.querySelector('.sub'); if (sub) sub.textContent = '';
  const meta = document.createElement('span');
  meta.className = 'ml-auto pl-space-sm text-outline shrink-0';
  meta.textContent = event.secs != null ? `${Math.round(event.secs)}s` : (ok ? 'ok' : `exit ${event.rc}`);
  last.append(meta);
  paintElapsed();
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
}

function buildLine(event) {
  const log = $('b-log');
  const row = document.createElement('div');
  row.className = event.kind === 'fail' ? 'text-error'
                : event.kind === 'ok' ? 'text-primary' : 'text-on-surface-variant';
  row.textContent = event.text || '';
  log.append(row);
  const running = $('b-steps').lastElementChild?.querySelector('.sub');
  if (running && event.text) running.textContent = event.text;
  while (log.children.length > 200) log.firstChild.remove();
  if ($('b-follow').checked) log.scrollTop = log.scrollHeight;
  paintElapsed();
}

window.cg.onEvent(({ id, event }) => {
  const job = jobs.get(id);
  if (!job) return;
  logLine(event);
  if (WRITES.has(job.cmd[0])) {
    if (event.t === 'step') buildStep(event.text);
    if (event.t === 'step_end') buildStepEnd(event);
    if (event.t === 'line' || (event.t === 'raw' && event.stream === 'stdout')) buildLine(event);
    if (event.t === 'exit') buildStatus(event.rc === 0 ? 'done' : `stopped (exit ${event.rc})`,
                                       event.rc === 0 ? 'text-primary' : 'text-error');
  }
  if (event.t === 'ask') ask(id, event);
  // JSON comes back on stdout as the command's own data; reports arrive as events.
  if (event.t === 'raw' && event.stream === 'stdout' && (job.json || job.capture)) job.out.push(event.text);
  if (event.t === 'report' && job.panel) $(job.panel).textContent = event.text;
  if (job.collect && (event.t === 'line' || event.t === 'step' || event.t === 'error')) {
    const box = $(job.collect);
    if (box.textContent === 'running…') box.textContent = '';
    box.textContent += (event.t === 'step' ? '\n' + event.text : '  ' + (event.text || '')) + '\n';
  }
  if (event.t === 'exit') {
    if (job.json && event.rc === 0) {
      try {
        const data = JSON.parse(job.out.join('\n'));
        ({ cost: paintCost, library: paintLibrary, guards: paintGuards,
           config: paintConfig, status: paintStatus }[job.json])(data);
      } catch (err) { $('job-line').textContent = `could not read cg ${job.cmd[0]} --json`; }
    }
    if (job.age) $(job.age).textContent = new Date().toLocaleTimeString();
    jobs.delete(id);
    updateHeader();
    // A build, a destroy or a session changes what every free screen shows -
    // the box, the archive, the guards - so read them again once it is over.
    if (WRITES.has(job.cmd[0])) refreshAll();
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
    updateHeader();
    if (panel) $(panel).textContent = 'running…';
  });
}

// Refresh means "this screen", and the reads behind it are independent, so
// they run together rather than one after another.
const NEEDS = {
  dashboard: [[['status', '--json'], 'status'], [['watcher', '--json'], 'guards']],
  settings:  [[['config', '--json'], 'config']],
  // Build reads status too: if a box is already up there is nothing to build,
  // and its own Refresh must be able to find that out.
  build:     [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status']],
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
// A build, a destroy and a session all report the same way - steps, lines, an
// exit - so they all run in the Build screen's panel, and starting one goes
// there. Watching a destroy in a panel that says nothing was the complaint.
const RUN_TITLE = { init: 'Provisioning', destroy: 'Destroying', open: 'Session' };
// The footer says what the money is doing, which is not the same for all three.
const RUN_FOOT = {
  init: ['the box bills from the moment it launches', 'of 10-20'],
  destroy: ['the games are pushed to S3 first; billing stops when the box is gone', ''],
  open: ['the box bills while this streams', ''],
};
let runKind = 'init';
function startRun(args) {
  runKind = args[0];
  goView('build');
  $('b-steps').dataset.fresh = 'yes';
  $('b-steps').textContent = '';
  $('b-log').textContent = '';
  $('b-log-title').textContent = 'cg ' + args.join(' ');
  $('b-panel').textContent = RUN_TITLE[args[0]] || 'Running';
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
  $('b-steps').dataset.fresh = 'yes';
  $('b-steps').textContent = '';
  $('b-log').textContent = '';
  $('b-log-title').textContent = 'cg init';
  $('b-panel').textContent = RUN_TITLE.init;
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
