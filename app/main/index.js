'use strict';
// The Electron main process: the only place allowed to start a process.
//
// One job at a time, because cg takes its own locks and a destroy must never
// race a build. The renderer gets events and sends answers; it has no node, no
// filesystem and no AWS.
const path = require('node:path');
const { app, BrowserWindow, Menu, ipcMain, dialog, shell } = require('electron');
const { run, answer, interrupt } = require('./runner');
const { findRepo } = require('./repo');

// Where the scripts are - see main/repo.js, which owns the order and the one
// rule that matters: `cg` has to be a file, not a directory with that name.
const REPO = findRepo();
let win = null;
let nextId = 1;

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

// `env` carries the few settings a screen may choose - GAME_APPS for a build.
// Anything else stays in .env, where cg owns it.
const ENV_ALLOWED = new Set(['GAME_APPS']);

// Reading AWS is independent work: status, the watcher and the archive index do
// not touch each other, so they run together. Anything that CHANGES something
// Which commands must run alone is cg's to say, not this file's. It was
// written down here AND in the renderer, and the two disagreed three times -
// each time silently, because a command that is never started looks exactly
// like one that returned nothing.
//
// Read once at startup. If cg cannot be asked, nothing is assumed to be safe:
// everything runs alone, which is slow and correct rather than fast and wrong.
const DEFAULT_CONTRACT = { runs_alone: null, asks: [] };
let CONTRACT = DEFAULT_CONTRACT;
function loadContract() {
  try {
    const out = require('node:child_process')
      .execFileSync('./cg', ['--contract'], { cwd: REPO, timeout: 10000, encoding: 'utf8' });
    const c = JSON.parse(out);
    if (!Array.isArray(c.runs_alone)) throw new Error('no runs_alone');
    CONTRACT = c;
  } catch (err) {
    console.error('cg --contract could not be read: ' + (err && err.message)
                  + ' - every command will run alone');
  }
}

// cg takes its flags BEFORE the command - `cg --region X quota --json` - so
// they are skipped before anything is matched. --region and --host take a
// value with them.
const FLAG_TAKES_VALUE = new Set(['--region', '--host']);
const verb = args => {
  const rest = [...args];
  while (rest.length && rest[0].startsWith('-')) {
    const flag = rest.shift();
    if (FLAG_TAKES_VALUE.has(flag)) rest.shift();
  }
  return rest;
};
// A command runs alone when cg lists a prefix of it.
const runsAlone = raw => {
  const cmd = verb(raw);
  if (!CONTRACT.runs_alone) return true;          // could not ask: assume the worst
  return CONTRACT.runs_alone.some(p => p.every((w, i) => cmd[i] === w));
};
const isReadOnly = raw => !runsAlone(raw);

const jobs = new Map();          // id -> { id, args, child, readOnly }
const anyMutating = () => [...jobs.values()].some(j => !j.readOnly);

function startJob(args, env = {}) {
  const readOnly = isReadOnly(args);
  // A mutating command waits for everything; a read-only one only waits for a
  // mutating command to finish.
  const blocker = readOnly
    ? [...jobs.values()].find(j => !j.readOnly)
    : [...jobs.values()][0];
  if (blocker) return { ok: false, reason: 'busy', args: blocker.args };

  const id = nextId++;
  const safe = Object.fromEntries(Object.entries(env).filter(([k]) => ENV_ALLOWED.has(k)));
  const child = run({
    repo: REPO,
    args, env: safe,
    onEvent: event => {
      send('cg:event', { id, event });
      if (event.t === 'exit') jobs.delete(id);
    },
  });
  jobs.set(id, { id, args, child, readOnly });
  // The renderer needs to know whether this was a write - for its note and its
  // re-read - and asking it to work that out again is how the two lists came
  // to disagree. It is told.
  return { ok: true, id, write: !readOnly };
}

ipcMain.handle('cg:run', (_e, { args, env }) => startJob(args, env || {}));
ipcMain.handle('cg:answer', (_e, { id, text }) => {
  const job = jobs.get(id);
  return job ? answer(job.child, text) : false;
});
ipcMain.handle('cg:cancel', (_e, id) => {
  const job = jobs.get(id);
  return job ? interrupt(job.child) : false;
});
ipcMain.handle('cg:busy', () => [...jobs.values()].map(j => ({ id: j.id, args: j.args })));
// The ids cg may ask under, as cg itself lists them. The window pre-answers a
// couple of them from a dialog it has already shown - and when an id is renamed
// in cg, that pre-answer silently stops matching and a modal appears in the
// middle of a build. So the list is handed over and checked against.
ipcMain.handle('cg:asks', () => CONTRACT.asks || []);

// The window denies every navigation and every new window on purpose - it is a
// viewer of local files. Tailscale's sign-in is the one exception: it finishes
// on login.tailscale.com and nothing else can finish it. So exactly that host,
// over https, checked HERE rather than trusting whatever asked.
// Two, and only two: Tailscale's sign-in cannot finish anywhere else, and a
// quota appeal is a reply on an AWS support case. Both are checked HERE rather
// than trusting whatever asked.
const OPENABLE = new Set(['login.tailscale.com', 'console.aws.amazon.com']);
ipcMain.handle('cg:open-signin', (_e, url) => {
  let u;
  try { u = new URL(String(url)); } catch { return false; }
  if (u.protocol !== 'https:' || !OPENABLE.has(u.hostname)) return false;
  shell.openExternal(u.toString());
  return true;
});

function createWindow() {
  win = new BrowserWindow({
    width: 1280, height: 860, backgroundColor: '#10141a', show: false,
    title: 'cg', autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.once('ready-to-show', () => win.show());
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  // A viewer of local files: nothing here should ever navigate to the web.
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', e => e.preventDefault());
  // The menu is gone, so bind the one shortcut worth keeping.
  win.webContents.on('before-input-event', (e, input) => {
    if (input.key === 'F12') { win.webContents.toggleDevTools(); e.preventDefault(); }
  });
}

// No File / Edit / View menu: this window runs cg and shows what it says.
// Electron's default menu offers nothing here except ways to confuse.
Menu.setApplicationMenu(null);

app.whenReady().then(() => { loadContract(); createWindow(); });
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });

// Killing cg mid-run can cost games: a destroy is pushing to S3 as it goes.
app.on('before-quit', e => {
  const risky = [...jobs.values()].filter(j => !j.readOnly);
  if (!risky.length) return;      // reading AWS can be abandoned safely
  e.preventDefault();
  const choice = dialog.showMessageBoxSync(win, {
    type: 'warning',
    buttons: ['Wait', 'Stop it and quit'],
    defaultId: 0,
    message: `"cg ${risky[0].args.join(' ')}" is still running.`,
    detail: 'Stopping a run that is uploading your games can lose whatever it had not sent yet.',
  });
  if (choice === 1) { risky.forEach(j => interrupt(j.child)); jobs.clear(); app.quit(); }
});
