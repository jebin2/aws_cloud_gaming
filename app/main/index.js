'use strict';
// The Electron main process: the only place allowed to start a process.
//
// One job at a time, because cg takes its own locks and a destroy must never
// race a build. The renderer gets events and sends answers; it has no node, no
// filesystem and no AWS.
const path = require('node:path');
const { app, BrowserWindow, Menu, ipcMain, dialog } = require('electron');
const { run, answer, interrupt } = require('./runner');

const REPO = path.resolve(__dirname, '..', '..');   // the repo that owns cg
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
// runs alone - cg takes its own locks, and a destroy must never race a build.
// `config` belongs here too: reading the registry touches nothing, and even
// `config set` only writes .env locally - it cannot collide with a build. Left
// out, it counted as a write and was refused while the other reads ran, so the
// Settings screen stayed empty until someone pressed Refresh.
const READ_ONLY = new Set(['status', 'watcher', 'library', 'cost', 'check', 'ping', 'games', 'config']);
const isReadOnly = args =>
  READ_ONLY.has(args[0]) && !['push', 'pull', 'forget', 'clean', 'account'].includes(args[1] || '');

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
  return { ok: true, id };
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

app.whenReady().then(createWindow);
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
