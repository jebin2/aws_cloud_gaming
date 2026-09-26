// The runner is the whole contract between the app and cg, so it is tested
// against a fake cg: events on stderr, data on stdout, answers on stdin.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, chmodSync, readFileSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { run, answer, interrupt, spawnArgs } = require('../main/runner.js');

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

function fakeRepo(script) {
  const dir = mkdtempSync(join(tmpdir(), 'cg-app-'));
  writeFileSync(join(dir, 'cg'), '#!/usr/bin/env bash\n' + script, { mode: 0o755 });
  chmodSync(join(dir, 'cg'), 0o755);
  return dir;
}

function collect(repo, args, onAsk) {
  return new Promise(resolve => {
    const events = [];
    const child = run({
      repo, args,
      onEvent: e => {
        events.push(e);
        if (e.t === 'ask' && onAsk) answer(child, onAsk(e));
        if (e.t === 'exit') resolve({ events, child });
      },
    });
  });
}

test('events come from stderr, raw output from stdout', async () => {
  const repo = fakeRepo(`
    echo '{"t":"step","at":"2026-09-26T10:00:00+05:30","text":"provisioning"}' >&2
    echo '{"t":"line","at":"2026-09-26T10:00:01+05:30","kind":"ok","text":"launched"}' >&2
    echo 'a table row from aws'
    echo 'not an event either' >&2
    echo '{"t":"step_end","at":"2026-09-26T10:00:02+05:30","rc":0,"secs":2}' >&2
    exit 0`);
  const { events } = await collect(repo, ['init']);
  // stdout and stderr are separate pipes, so their lines interleave however the
  // OS delivers them. What matters is that each arrives, typed correctly.
  assert.deepEqual(events.filter(e => e.t !== 'raw').map(e => e.t), ['step', 'line', 'step_end', 'exit']);
  assert.equal(events.find(e => e.t === 'line').kind, 'ok');
  const raws = events.filter(e => e.t === 'raw');
  assert.equal(raws.find(r => r.stream === 'stdout').text, 'a table row from aws');
  assert.equal(raws.find(r => r.stream === 'stderr').text, 'not an event either');
  assert.equal(events.at(-1).rc, 0);
});

test('a question is answered on stdin', async () => {
  const repo = fakeRepo(`
    echo '{"t":"ask","id":"terminate-box","prompt":"terminate? [y/N] ","default":"N"}' >&2
    IFS= read -r a
    echo "{\\"t\\":\\"line\\",\\"kind\\":\\"ok\\",\\"text\\":\\"answered:$a\\"}" >&2
    exit 0`);
  const { events } = await collect(repo, ['destroy'], () => 'y');
  assert.equal(events.find(e => e.t === 'line').text, 'answered:y');
});

test('a newline in an answer cannot smuggle a second one', async () => {
  const repo = fakeRepo(`
    echo '{"t":"ask","id":"a","prompt":"q"}' >&2
    IFS= read -r one; IFS= read -r -t 1 two || two='(nothing)'
    echo "{\\"t\\":\\"line\\",\\"kind\\":\\"ok\\",\\"text\\":\\"one=$one two=$two\\"}" >&2
    exit 0`);
  const { events } = await collect(repo, ['x'], () => 'yes\nDESTROY-ALL');
  const line = events.find(e => e.t === 'line');
  assert.match(line.text, /one=yesDESTROY-ALL/);     // the newline was stripped
  assert.match(line.text, /two=\(nothing\)/);        // so there is no second answer
});

test('a failing command reports its exit code', async () => {
  const repo = fakeRepo(`echo '{"t":"error","text":"AWS refused"}' >&2; exit 1`);
  const { events } = await collect(repo, ['status']);
  assert.equal(events.find(e => e.t === 'error').text, 'AWS refused');
  assert.equal(events.at(-1).rc, 1);
});

test('cg is always run with CG_JSON=1', async () => {
  const repo = fakeRepo(`echo "{\\"t\\":\\"line\\",\\"kind\\":\\"info\\",\\"text\\":\\"json=$CG_JSON\\"}" >&2; exit 0`);
  const { events } = await collect(repo, ['status']);
  assert.equal(events.find(e => e.t === 'line').text, 'json=1');
});

test('Windows goes through WSL, since the scripts are bash', () => {
  const { file, argv } = spawnArgs('/home/me/cloud_gaming', ['library', 'list']);
  if (process.platform === 'win32') {
    assert.equal(file, 'wsl.exe');
    assert.match(argv.at(-1), /CG_JSON=1 \.\/cg 'library' 'list'/);
  } else {
    assert.equal(file, './cg');
    assert.deepEqual(argv, ['library', 'list']);
  }
});

test('Stop signals everything cg started, not just cg', async () => {
  // A build spawns aws, ssh, provision.sh. Signalling the child alone left
  // those running, which is why cg runs in its own process group.
  const marker = join(tmpdir(), `cg-app-grandchild-${process.pid}`);
  const repo = fakeRepo(`
    trap 'exit 130' INT
    # trap - INT: a background job in a script inherits SIGINT ignored, while
    # aws and ssh, started in the foreground, do receive it.
    ( trap - INT; while :; do sleep 0.1; done; ) &
    echo $! > ${marker}
    echo '{"t":"step","text":"working"}' >&2
    wait`);
  const events = [];
  const child = run({ repo, args: ['init'], onEvent: e => events.push(e) });
  await new Promise(r => setTimeout(r, 400));
  const grandchild = Number(readFileSync(marker, 'utf8').trim());
  assert.equal(alive(grandchild), true, 'the grandchild should be running before Stop');

  assert.equal(interrupt(child), true);
  await new Promise(r => setTimeout(r, 600));
  assert.equal(alive(grandchild), false, 'Stop must reach the grandchild too');
  assert.equal(events.some(e => e.t === 'exit'), true);
  unlinkSync(marker);
});
