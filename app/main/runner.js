'use strict';
// Runs cg and turns its output into events. This module is the whole contract
// between the app and the engine, which is why it is plain Node and tested
// without Electron.
//
// The app never calls AWS. It runs cg with CG_JSON=1 and renders what comes
// back: events on stderr, the command's own data on stdout, answers on stdin.
const { spawn } = require('node:child_process');
const readline = require('node:readline');

// Windows has no bash. The realistic path is WSL, where the same scripts run
// unchanged - rewriting them in PowerShell would fork the source of truth.
function spawnArgs(repo, args) {
  if (process.platform === 'win32') {
    const quoted = args.map(a => `'${String(a).replace(/'/g, "'\\''")}'`).join(' ');
    return { file: 'wsl.exe', argv: ['--', 'bash', '-lc', `cd ${repo} && CG_JSON=1 ./cg ${quoted}`], opts: {} };
  }
  return { file: './cg', argv: args, opts: { cwd: repo } };
}

// run({repo, args, onEvent}) -> the child process.
// onEvent receives parsed events, plus {t:'raw'} for anything that is not one
// and {t:'exit', rc} at the end. A raw line is a command cg ran talking - show
// it or ignore it, but never parse it as data.
function run({ repo, args, onEvent, env = {} }) {
  const { file, argv, opts } = spawnArgs(repo, args);
  const child = spawn(file, argv, {
    ...opts,
    env: { ...process.env, ...env, CG_JSON: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
    // Its own process group, so Stop can signal everything cg started - aws,
    // ssh, provision.sh - the way Ctrl+C does in a terminal. Signalling the
    // child alone left those running.
    detached: true,
  });

  readline.createInterface({ input: child.stderr }).on('line', line => {
    if (line.startsWith('{')) {
      try {
        const event = JSON.parse(line);
        if (event && typeof event.t === 'string') return onEvent(event);
      } catch { /* not an event after all */ }
    }
    onEvent({ t: 'raw', stream: 'stderr', text: line });
  });
  readline.createInterface({ input: child.stdout })
    .on('line', text => onEvent({ t: 'raw', stream: 'stdout', text }));

  // Every job MUST end in exactly one exit event: the app deletes a job when it
  // sees one, so a job that never emits it stays "running" for the life of the
  // window. Node emits 'error' and 'close' but NOT 'exit' when the process
  // could not be spawned at all, which is how a packaged build pointing at the
  // wrong directory turned into a permanent "refreshing" with nothing to read.
  let settled = false;
  const settle = rc => { if (!settled) { settled = true; onEvent({ t: 'exit', rc }); } };

  child.on('error', err => {
    onEvent({ t: 'error', text: err.message });
    settle(127);                       // could not run it at all
  });
  // `exit`, not `close`: close waits for stdio to close, and a process cg left
  // behind holds those pipes open - the job would never look finished. `close`
  // stays only as a backstop for the case where 'exit' never comes; once
  // settled it is a no-op, so the lateness that ruled it out cannot bite.
  child.on('exit', (rc, signal) =>
    settle(rc === null ? (signal === 'SIGINT' ? 130 : 1) : rc));
  child.on('close', () => settle(1));
  return child;
}

// An ask event is answered with one line on stdin. Nothing else may be written
// there, so a stray write cannot be read as an answer to the next question.
function answer(child, text) {
  if (!child || child.killed || !child.stdin.writable) return false;
  child.stdin.write(String(text).replace(/[\r\n]/g, '') + '\n');
  return true;
}

// Ctrl+C, to the whole group. cg traps it, closes its step and exits 130.
function interrupt(child) {
  if (!child || child.killed) return false;
  try { process.kill(-child.pid, 'SIGINT'); return true; }
  catch { try { child.kill('SIGINT'); return true; } catch { return false; } }
}

module.exports = { run, answer, interrupt, spawnArgs };
