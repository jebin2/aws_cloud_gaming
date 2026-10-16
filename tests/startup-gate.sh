#!/usr/bin/env bash
# What the window asks for when it opens.
#
# It used to fire nine reads at once. On a laptop with no AWS CLI that is six
# reads that cannot work, a screen of unknowns on every tab, and the actual
# problem - a missing tool - somewhere in the middle of a log. The three reads
# that still answer on a laptop where nothing else can go first, and the rest
# only once they say this laptop can do anything at all.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export HOME="$T"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

BROWSER=""
for b in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$b" >/dev/null && { BROWSER=$b; break; }
done
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "startup-gate: 0 passed, 0 failed"; exit 0; }

# What cg says runs alone, verbatim, for the stub to answer `write` with.
ALONE=$(./cg --contract | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["runs_alone"]))')

mkdir -p "$T/r"
cp app/renderer/index.html app/renderer/app.js "$T/r/"
cp app/renderer/*.css "$T/r/"
cp -r app/renderer/fonts "$T/r/" 2>/dev/null || true

# cg, as a script: every command is recorded, and the three gate reads answer
# with whatever this case wants them to say. Nothing else answers at all, so a
# read that should not have been asked for shows up as a command with no reply.
cat > "$T/r/stub.js" <<'STUB'
window.__errs = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
window.__ran = [];
window.__cancelled = [];
window.__answers = {};     // set by the probe before the page loads
window.cg = {
  run: (args) => {
    const line = args.join(' ');
    window.__ran.push(line);
    const id = (window.__lastId = (window.__lastId || 0) + 1);
    if ((window.__broken || []).includes(line)) {
      setTimeout(() => {
        window.__emit(id, { t: 'error', stream: 'stderr', text: 'could not reach AWS' });
        window.__emit(id, { t: 'exit', rc: 1 });
      }, 0);
      return Promise.resolve({ ok: true, id });
    }
    const reply = window.__answers[line];
    if (reply !== undefined) {
      // Answer on a later turn, the way a real run does - or slowly, for a case
      // that needs the window caught mid-read.
      setTimeout(() => {
        window.__emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(reply) });
        window.__emit(id, { t: 'exit', rc: 0 });
      }, (window.__slow || []).includes(line) ? (window.__slowMs || 600) : 0);
    }
    // main answers with cg's own verdict, and it gets that verdict from
    // `cg --contract`. This stub used to carry a hand-written list instead,
    // which disagreed with cg about `creds tailscale authkey` - the very
    // disagreement the contract exists to prevent - so a stage that had just
    // been fixed looked, in here, like one that would never tick.
    const cmd = args.filter(a => !a.startsWith('-'));
    const write = (window.__alone || []).some(p => p.every((w, i) => cmd[i] === w));
    return Promise.resolve({ ok: true, id, write });
  },
  answer: () => Promise.resolve(true),
  // SIGINT to cg, which dies and reports it. Without the exit the job stays in
  // the renderer's map for ever, which is the bug this models.
  cancel: id => { window.__cancelled.push(id); window.__emit(id, { t: 'exit', rc: 130 });
                  return Promise.resolve(true); },
  busy: () => Promise.resolve([]), openSignIn: () => Promise.resolve(true),
  // main is the only place that knows whether there is a cg to talk to.
  engine: () => Promise.resolve(window.__engine === undefined
    ? { repo: '/home/u/cloud_gaming', cg: '/home/u/cloud_gaming/cg', found: true, contract: true }
    : window.__engine),
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB

probe() { # probe <json answers object literal>
  cat > "$T/r/answers.js" <<JS
window.__answers = $1;
window.__alone = $ALONE;
${ENGINE:-}
JS
  cat > "$T/r/probe.js" <<'PROBE'
(async () => {
  const out = [];
  // Appended first and filled last: a probe that threw halfway used to leave
  // NO PROBE OUTPUT, which says nothing about where it died.
  const pre = document.createElement('pre');
  pre.id = 'probe-out';
  document.body.append(pre);
  try {
  // Long enough for the gate's three reads to answer, for anything they unlock
  // to be asked for, and for what THOSE answers set off - the first scan is
  // started only once every gated read has come back.
  for (let i = 0; i < 30; i++) await new Promise(r => setTimeout(r, 2));
  // Past the opening popup's delay, so both of its answers can be seen: a
  // laptop whose reads all landed inside the delay must never have shown it.
  await new Promise(r => setTimeout(r, 700));
  out.push('RAN | ' + window.__ran.join(' ;; '));
  // The pipeline: one row per stage, each carrying its verdict, and the pane
  // beside it carrying cg's own words.
  out.push('ONB | ' + (document.getElementById('onb').hidden ? 'hidden' : 'shown')
           + ' cards=' + (document.getElementById('d-main').hidden ? 'hidden' : 'shown'));
  out.push('TITLE2 | ' + document.getElementById('onb-title').textContent.trim());
  out.push('COUNT | ' + document.getElementById('onb-count').textContent.trim());
  out.push('SUB | ' + document.getElementById('onb-sub').textContent.replace(/\s+/g, ' ').trim());
  out.push('STAGES | ' + [...document.querySelectorAll('#onb-steps [data-stage]')]
             .map(r => r.dataset.stage + '=' + r.dataset.state).join(','));
  out.push('STAGETEXT | ' + document.getElementById('onb-steps').innerText
             .replace(/\s+/g, ' ').trim());
  // Only the active stage may offer anything: you cannot start in the middle.
  out.push('TOOLS | ' + [...document.querySelectorAll('#onb-tools [data-tool]')]
             .map(c => c.dataset.tool + ':' + c.dataset.present).join(','));
  // Any sentence the Tools step says besides the tools themselves.
  out.push('TOOLTEXT | ' + [...document.querySelectorAll('[data-stage=tools] .font-body-sm')]
             .map(e => e.textContent.trim()).join(' '));
  out.push('BUTTONS | ' + [...document.querySelectorAll('#onb-steps [data-stage] button')]
             .map(b => b.closest('[data-stage]').dataset.stage + '=' + b.textContent.trim()).join(','));
  // Each step keeps its own log now: every one that has any lines, by step.
  out.push('LOG | ' + [...document.querySelectorAll('pre[id^="onb-log-"]')]
             .filter(p => p.textContent.trim())
             .map(p => p.id.slice(8) + ':' + p.textContent.replace(/\s+/g, ' ').trim()).join(' ;; '));
  // There is no splash any more: the steps are what every open shows.
  out.push('MODE | ' + (document.getElementById('onb-steps').hidden ? 'none' : 'steps')
           + ' setup=' + document.body.classList.contains('setup'));
  out.push('AFTER | ' + (window.__after ? await window.__after() : 'none'));
  out.push('BANNER | ' + (document.getElementById('banner').hidden ? 'hidden' : 'shown'));
  out.push('TITLE | ' + document.getElementById('banner-title').textContent.trim());
  out.push('BODY | ' + document.getElementById('banner-body').textContent.replace(/\s+/g, ' ').trim());
  out.push('FIX | ' + (document.getElementById('banner-fix').hidden ? 'hidden'
           : document.getElementById('banner-fix-label').textContent.trim()));
  window.__ran = [];
  if (!document.getElementById('banner-fix').hidden) document.getElementById('banner-fix').click();
  out.push('WENT | ' + (document.querySelector('.nav-item.on') || {}).dataset?.view);
  out.push('LEGEND | ' + document.getElementById('s-chooser-legend').innerText
                          .replace(/\s+/g, ' ').trim());
  out.push('SCANBTN | ' + (document.getElementById('s-sweep')
             ? document.getElementById('s-sweep').textContent.trim() : 'absent'));
  out.push('ERRS | ' + (window.__errs || []).join(' ;; '));
  } catch (e) { out.push('PROBE THREW | ' + e.message); }
  pre.textContent = out.join('\n');
})();
PROBE
  python3 -I - "$T/r" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "index.html"
t = p.read_text()
if 'stub.js' not in t:
    t = t.replace('<script src="app.js"',
                  '<script src="stub.js"></script>\n<script src="answers.js"></script>\n<script src="app.js"', 1)
    t = t.replace('</body>', '<script src="probe.js"></script>\n</body>', 1)
    p.write_text(t)
PY
  # Written to a file and then catted, rather than piped straight into python:
  # chromium's main process exits as soon as the DOM is dumped, but a child of
  # it keeps the write end of a pipe open for another 10-25 SECONDS, and
  # sys.stdin.read() waits for EOF. That idle wait, once per page load, was the
  # whole cost of this suite - minutes of it, at 0.5s of actual work per load.
  "$BROWSER" --headless --disable-gpu --no-sandbox --window-size=1280,900 \
    --virtual-time-budget=5000 --dump-dom "file://$T/r/index.html" > "$T/dom.html" 2>/dev/null
  cat "$T/dom.html" \
  | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")'
}
row() { grep -m1 "^$1 " <<<"$OUT" || true; }

TOOLS_OK='[{"tool":"python3","label":"python3","present":true,"why":"w"},
           {"tool":"aws","label":"AWS CLI v2","present":true,"why":"w"}]'
TOOLS_BAD='[{"tool":"python3","label":"python3","present":true,"why":"w"},
            {"tool":"aws","label":"AWS CLI v2","present":false,"why":"w"},
            {"tool":"moonlight","label":"Moonlight","present":false,"why":"w"}]'
deps() { echo "{\"tools\":$1,\"package_manager\":\"pacman\",\"root\":\"pkexec\",\"root_blocked\":null,\"tailscale_signed_in\":$2}"; }
creds_ok='{"cli":true,"source":"s","key_id":"****1234","account":"123456789012","arn":"arn","valid":true,"error":null}'
creds_bad='{"cli":false,"source":null,"key_id":null,"account":null,"arn":null,"valid":null,"error":"the AWS CLI is not installed"}'
tskey_in='{"present":true,"valid":true,"state":"ok","detail":null,"signed_in":true,"node":"laptop","auth_key_stored":true,"can_mint":true}'
tskey_out='{"present":false,"valid":null,"state":"absent","detail":null,"signed_in":false,"node":null,"auth_key_stored":false,"can_mint":false}'
# Signed in, no API token, and no key for the box: nothing to mint one with.
tskey_nokey='{"present":false,"valid":null,"state":"absent","detail":null,"signed_in":true,"node":"laptop","auth_key_stored":false,"can_mint":false}'
# The three ways a key can fail, as cg now reports them: nothing was rejected
# in the first two, and the window must not say it was.
creds_offline='{"cli":true,"source":"s","key_id":"****1234","account":null,"arn":null,"valid":false,
                "reason":"unreachable","error":"Could not connect to the endpoint URL: \"https://sts.ap-south-2.amazonaws.com/\""}'
creds_nokey='{"cli":true,"source":null,"key_id":null,"account":null,"arn":null,"valid":false,
              "reason":"no-key","error":"Unable to locate credentials."}'
creds_rejected='{"cli":true,"source":"s","key_id":"****1234","account":null,"arn":null,"valid":false,
                 "reason":"rejected","error":"An error occurred (InvalidClientTokenId)"}'
cfg_ok='[{"key":"EMAIL_ALERTS","kind":"text","secret":false,"is_set":true,"value":"a@b.c","default":null,"note":"n"},
         {"key":"GAME_REGION","kind":"text","secret":false,"is_set":true,"value":"ap-south-2","default":"ap-south-2","note":"n"}]'
cfg_noemail='[{"key":"EMAIL_ALERTS","kind":"text","secret":false,"is_set":false,"value":null,"default":null,"note":"n"},
             {"key":"GAME_REGION","kind":"text","secret":false,"is_set":true,"value":"ap-south-2","default":"ap-south-2","note":"n"}]'
# A fresh laptop: no region written, so cg is using its default - which is not
# a choice anybody made.
cfg_noregion='[{"key":"EMAIL_ALERTS","kind":"text","secret":false,"is_set":true,"value":"a@b.c","default":null,"note":"n"},
              {"key":"GAME_REGION","kind":"text","secret":false,"is_set":false,"value":null,"default":"ap-south-2","note":"n"}]'

# Signed in, with an API token the app can mint a key with.
tskey_canmint='{"present":true,"valid":true,"state":"ok","detail":null,"signed_in":true,"node":"laptop","auth_key_stored":false,"can_mint":true}'
# What `cg machines` says about the configured region: one machine the quota
# covers, and - the other case - a region that rents nothing you may launch.
machines_ok='{"region": "ap-south-2", "inr_per_usd": 88, "machines":
  [{"type": "g6.xlarge", "gpu": "L4", "vram_gib": 22.4, "fits_spot": true,
    "fits_ondemand": true, "inr_hour_spot": 16, "inr_hour_ondemand": 85}]}'
machines_noquota='{"region": "ap-south-2", "inr_per_usd": 88, "machines":
  [{"type": "g6.xlarge", "gpu": "L4", "vram_gib": 22.4, "fits_spot": false,
    "fits_ondemand": false, "inr_hour_spot": 16, "inr_hour_ondemand": 85}]}'

echo "0. there is no cg at all"
# Without an engine every read fails the same way - a spawn error each - and six
# broken reads is not what happened. One thing did, and only main can see it:
# the renderer has no filesystem.
ENGINE="window.__engine = { repo: '/opt/nope', cg: '/opt/nope/cg', found: false, contract: false };
window.__after = async () => {
  window.__engine = { repo: '/opt/nope', cg: '/opt/nope/cg', found: true, contract: true };
  document.querySelector('#onb-steps button').click();
  await new Promise(r => setTimeout(r, 20));
  return 'ran=' + window.__ran.join(' ');
};"
OUT=$(probe "{}")
check    "nothing is asked at all"     "$(row RAN)" "RAN | "
contains "the pipeline says so"        "$(row TITLE2)" "This app cannot find cg"
contains "  and what cg is"            "$(row SUB)" "this window is a face on it"
contains "  where it looked"           "$(row STAGETEXT)" "/opt/nope/cg"
contains "  and how to fix it"         "$(row STAGETEXT)" "CG_REPO"
contains "  with something to run"     "$(row STAGETEXT)" "git clone"
contains "the failed step is marked"   "$(row STAGES)" "engine=failed"
# Installed while the window sat there: no restart.
contains "Try again starts the reads"  "$(row AFTER)" "deps --json"
check    "nothing threw"               "$(row ERRS)" "ERRS | "
ENGINE=""

echo "1. a tool is missing: it is the first stage, and the only one with a button"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the three reads happen"      "$(row RAN)" "deps --json"
contains "  all of them"               "$(row RAN)" "creds tailscale --json"
# The six that need AWS or a tailnet would every one come back unknown.
lacks    "status is not asked"         "$(row RAN)" "status --json"
lacks    "  nor the library"           "$(row RAN)" "library list --json"
lacks    "and never cost"              "$(row RAN)" "cost"
contains "the pipeline is up"          "$(row ONB)" "ONB | shown"
# Six setup steps and the Dashboard: seven.
contains "  counting the steps"        "$(row COUNT)" "of 7 done"
contains "it shows the steps, not the splash" "$(row MODE)" "MODE | steps setup=true"
# The tools themselves, not a sentence about them: present in green, missing
# in red, and the count as the only heading.
contains "  each tool shown"           "$(row TOOLS)" "python3:yes"
contains "    the missing ones marked"  "$(row TOOLS)" "aws:no,moonlight:no"
check    "  and nothing else said"     "$(row TOOLTEXT)" "TOOLTEXT | "
contains "  the count is the heading"  "$(row COUNT)" "of 7 done"
contains "the tools stage is active"   "$(row STAGES)" "tools=active"
# You cannot start in the middle: there is exactly one button on the screen.
check    "only one stage offers anything" "$(row BUTTONS)" "BUTTONS | tools=Install them"
# What is already true is ticked wherever it sits, and what cannot be judged
# says so rather than reading as fine.
contains "  a met stage is still ticked"  "$(row STAGES)" "tailnet=done"
contains "  and an unjudgeable one asks"  "$(row STAGES)" "key=unknown"
# "The AWS CLI is not installed" and "the AWS CLI is missing from the tools"
# are one job with one button, and used to be two rows saying it.
lacks    "the same fix is not listed twice" "$(row STAGES)" "cli="
lacks    "  no chatty notes"              "$(row STAGETEXT)" "asks for your password once"
# The banner is for a problem that turns up mid-session. The pipeline has this
# one, in order, with the button - two copies of it is what this replaced.
check    "the banner stays out of it"  "$(row BANNER)" "BANNER | hidden"
check    "and no step has a log yet"   "$(row LOG)" "LOG | "
# A box, an archive and a bill are not worth showing to someone who cannot
# build one yet - and they sat under the pipeline saying "No box" as though
# that were the news.
contains "the cards wait their turn"   "$(row ONB)" "cards=hidden"

echo "1a. no Tailscale installed is not signed in"
# cg says signed_in null when it cannot tell - Tailscale is not installed - and
# the step read "not false" as signed in: an empty laptop showed "Private
# connection ready" before it had Tailscale at all.
tskey_none='{"present":false,"valid":null,"state":"absent","detail":null,"signed_in":null,"node":null,"auth_key_stored":false,"can_mint":false}'
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" null), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_none, \"config --json\": $cfg_ok}")
lacks    "the private connection is not ticked" "$(row STAGES)" "tailnet=done"
contains "  it waits behind the tools"          "$(row STAGES)" "tailnet=locked"

echo "1b. pressing Install them: the step itself is where cg speaks"
# Each step has its own log, folded under it: the line cg is on now, and the
# whole output behind Details. One shared pane meant step three's failure was
# shown beside whatever ran last.
ENGINE="window.__after = async () => {
  window.__broken = [];
  document.querySelector('#onb-steps [data-stage=tools] button').click();
  await new Promise(r => setTimeout(r, 10));
  window.__emit(window.__lastId, { t: 'line', text: 'resolving dependencies' });
  window.__emit(window.__lastId, { t: 'line', text: 'installing aws-cli' });
  await new Promise(r => setTimeout(r, 10));
  const row = document.querySelector('[data-stage=tools]');
  const pre = row.querySelector('pre');
  return 'live=' + document.getElementById('onb-live-tools').textContent.trim()
       + ' | log=' + (pre ? pre.textContent.replace(/\s+/g, ' ').trim() : 'none')
       + ' | folded=' + (pre ? pre.hidden : 'none')
       + ' | toggle=' + document.getElementById('onb-tog-tools').textContent.trim()
       + ' | sweep=' + !document.getElementById('onb-prog-tools').hidden
       + ' | state=' + row.dataset.state
       // The step's own buttons, not the ones inside its log unit.
       + ' | buttons=' + [...row.querySelectorAll('button.btn')]
           .filter(b => !b.closest('[id^=onb-unit-]')).map(b => b.textContent.trim()).join(',');
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the step shows the line cg is on" "$(row AFTER)" "live=installing aws-cli"
contains "  its own log carries the output" "$(row AFTER)" "log=resolving dependencies installing aws-cli"
contains "  folded, unless you open it"     "$(row AFTER)" "folded=true"
contains "  counting, so it looks alive"    "$(row AFTER)" "Details · 2 lines"
contains "  with a sweep, not a made-up %"  "$(row AFTER)" "sweep=true"
contains "the stage says it is running"     "$(row AFTER)" "state=running"
# Stopping has to reach cg: a package manager can be sitting on a lock.
check    "  and offers to stop it"          "$(row AFTER | sed 's/.*buttons=/buttons=/')" "buttons=Stop"
ENGINE=""

echo "1c. the log pane follows the output, unless you are reading it"
# An install prints for minutes and the pane is a few lines tall, so without
# this the interesting part - what it is doing NOW - is always off the bottom.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=tools] button').click();
  await new Promise(r => setTimeout(r, 10));
  document.getElementById('onb-tog-tools').click();
  const box = document.getElementById('onb-log-tools');
  const line = n => window.__emit(window.__lastId, { t: 'line', text: 'step ' + n });
  for (let i = 0; i < 80; i++) line(i);
  await new Promise(r => setTimeout(r, 10));
  const bottom = Math.abs(box.scrollHeight - box.scrollTop - box.clientHeight) < 2;
  // Now read back up the log, the way someone chasing an error would, and keep
  // printing: the view must stay where it was put.
  box.scrollTop = 0;
  for (let i = 80; i < 120; i++) line(i);
  await new Promise(r => setTimeout(r, 10));
  return 'scrollable=' + (box.scrollHeight > box.clientHeight)
       + ' followed=' + bottom
       + ' stayedPut=' + (box.scrollTop === 0)
       + ' lastline=' + box.textContent.trim().split('\n').pop().trim();
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the pane overflows, as it will"  "$(row AFTER)" "scrollable=true"
contains "  and it is at the bottom"       "$(row AFTER)" "followed=true"
contains "  showing the newest line"       "$(row AFTER)" "lastline=step 119"
# Yanking the view down while someone is reading up the log is worse than not
# following at all.
contains "but it leaves a reader alone"    "$(row AFTER)" "stayedPut=true"
ENGINE=""

echo "1d. an install that fails opens its own log"
# The reason is in cg's words, and nobody should have to find a toggle to read
# why the thing they just pressed did not work.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=tools] button').click();
  await new Promise(r => setTimeout(r, 10));
  window.__emit(window.__lastId, { t: 'error', text: 'error: failed retrieving file moonlight-qt' });
  window.__emit(window.__lastId, { t: 'exit', rc: 1 });
  await new Promise(r => setTimeout(r, 20));
  const row = document.querySelector('[data-stage=tools]');
  const pre = row.querySelector('pre');
  return 'state=' + row.dataset.state
       + ' | open=' + (pre ? !pre.hidden : 'none')
       + ' | log=' + (pre ? pre.textContent.trim() : '')
       + ' | text=' + row.innerText.replace(/\s+/g, ' ')
       + ' | buttons=' + [...row.querySelectorAll('button.btn')]
           .filter(b => !b.closest('[id^=onb-unit-]')).map(b => b.textContent.trim()).join(',');
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the step says it failed"     "$(row AFTER)" "state=failed"
contains "  its log is open by itself" "$(row AFTER)" "open=true"
contains "  carrying cg's own words"   "$(row AFTER)" "failed retrieving file moonlight-qt"
contains "  under one plain sentence"  "$(row AFTER)" "The install did not finish"
contains "  and the button that helps" "$(row AFTER)" "buttons=Try again"
ENGINE=""

echo "1e. after a good install, the step says it is checking, not what it said before"
# The install finished and the step went straight back to red marks and
# "Install them" until the tools had been read again - which looked like the
# install had not happened. It now says so, and waits for the answer.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=tools] button').click();
  await new Promise(r => setTimeout(r, 10));
  window.__answers['deps --json'] = { tools: [{tool: 'python3', label: 'python3', present: true, why: 'w'},
    {tool: 'aws', label: 'AWS CLI v2', present: true, why: 'w'}], package_manager: 'pacman',
    root: 'pkexec', root_blocked: null, tailscale_signed_in: true };
  // The AWS CLI is there now, so cg creds finds it too.
  window.__answers['creds --json'] = { cli: true, source: null, key_id: null, account: null,
    arn: null, valid: false, reason: 'no-key', error: 'Unable to locate credentials.' };
  window.__slow = ['deps --json']; window.__slowMs = 600;
  window.__emit(window.__lastId, { t: 'exit', rc: 0 });
  await new Promise(r => setTimeout(r, 100));
  const row = () => document.querySelector('[data-stage=tools]');
  const mid = 'mid=' + row().dataset.state + ' text=' + row().innerText.replace(/\s+/g, ' ')
    + ' buttons=' + [...row().querySelectorAll('button.btn')]
        .filter(b => !b.closest('[id^=onb-unit-]')).length
    + ' sweep=' + !document.getElementById('onb-prog-tools').hidden;
  await new Promise(r => setTimeout(r, 800));
  return mid + ' | end=' + row().dataset.state
    + ' sweepEnd=' + !document.getElementById('onb-prog-tools').hidden;
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "while the tools are read again" "$(row AFTER)" "mid=verifying"
contains "  it says the install happened" "$(row AFTER)" "Installed. Checking"
contains "  offers nothing to press"      "$(row AFTER)" "buttons=0"
contains "  and keeps the sweep going"    "$(row AFTER)" "sweep=true"
contains "then the step is ticked"        "$(row AFTER)" "end=done"
contains "  and the sweep stops"          "$(row AFTER)" "sweepEnd=false"
ENGINE=""

echo "1f. the AWS CLI check landing late never adds a second Tools row"
# What you saw: the tool list came back all green, the AWS CLI check still held
# its answer from before the install, and a second "Tools" row appeared and then
# vanished when that answer caught up. Now the step waits for both.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=tools] button').click();
  await new Promise(r => setTimeout(r, 10));
  window.__answers['deps --json'] = { tools: [{tool: 'python3', label: 'python3', present: true, why: 'w'},
    {tool: 'aws', label: 'AWS CLI v2', present: true, why: 'w'}], package_manager: 'pacman',
    root: 'pkexec', root_blocked: null, tailscale_signed_in: true };
  window.__answers['creds --json'] = { cli: true, source: null, key_id: null, account: null,
    arn: null, valid: false, reason: 'no-key', error: 'x' };
  // The tool list answers at once; the AWS CLI check is slow.
  window.__slow = ['creds --json']; window.__slowMs = 600;
  window.__emit(window.__lastId, { t: 'exit', rc: 0 });
  const rows = () => [...document.querySelectorAll('#onb-steps [data-stage]')]
    .map(r => r.dataset.stage + '=' + r.dataset.state).join(',');
  const chips = () => [...document.querySelectorAll('#onb-tools [data-tool]')]
    .map(c => c.dataset.tool + ':' + c.dataset.present).join(',');
  await new Promise(r => setTimeout(r, 150));
  const mid = 'mid=' + rows() + ' chips=' + chips();
  await new Promise(r => setTimeout(r, 800));
  return mid + ' | end=' + rows();
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "half the answers in: still checking"  "$(row AFTER)" "mid=tools=verifying"
lacks    "  with no second Tools row"           "$(row AFTER)" "cli="
contains "  the re-checked tools say ..."       "$(row AFTER)" "aws:checking"
contains "  the others keep their tick"         "$(row AFTER)" "python3:yes"
contains "all answers in: Tools is done"        "$(row AFTER)" "end=tools=done"
contains "  and the next step is open"          "$(row AFTER)" "key=active"

echo "1g. an install that exits cleanly but leaves a tool missing says so"
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=tools] button').click();
  await new Promise(r => setTimeout(r, 10));
  window.__answers['deps --json'] = { tools: [{tool: 'python3', label: 'python3', present: true, why: 'w'},
    {tool: 'aws', label: 'AWS CLI v2', present: true, why: 'w'},
    {tool: 'moonlight', label: 'Moonlight', present: false, why: 'w'}], package_manager: 'pacman',
    root: 'pkexec', root_blocked: null, tailscale_signed_in: true };
  window.__answers['creds --json'] = { cli: true, source: null, key_id: null, account: null,
    arn: null, valid: false, reason: 'no-key', error: 'x' };
  window.__emit(window.__lastId, { t: 'line', text: 'error: target not found: moonlight-qt' });
  window.__emit(window.__lastId, { t: 'exit', rc: 0 });
  await new Promise(r => setTimeout(r, 100));
  const row = document.querySelector('[data-stage=tools]');
  return 'state=' + row.dataset.state + ' open=' + !row.querySelector('pre').hidden
       + ' text=' + row.innerText.replace(/\s+/g, ' ');
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the step says it failed"     "$(row AFTER)" "state=failed"
contains "  naming what is still missing" "$(row AFTER)" "Still missing: Moonlight."
contains "  with the log open"         "$(row AFTER)" "open=true"
contains "  carrying cg's words"       "$(row AFTER)" "target not found: moonlight-qt"
ENGINE=""

echo "2. tools are there, the key is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
# The CLI does not run, so Tools is not done: it is the step, not a row below it.
# Installed but not running is the AWS CLI's own chip, in the one Tools row -
# it used to be a second row also called Tools, that came and went.
lacks    "  never a second Tools row"  "$(row STAGES)" "cli="
contains "  Tools is still the step"   "$(row STAGES)" "tools=active"
contains "  the CLI chip says why"     "$(row STAGETEXT)" "AWS CLI v2 - installed, will not run"
contains "  and it is red"             "$(row TOOLS)" "aws:no"
# Installing skips a tool cg can find, so it offers a fresh look instead.
contains "  offering a fresh look"     "$(row BUTTONS)" "tools=Check again"

echo "3. tools and key are there, the tailnet is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" false), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_out, \"config --json\": $cfg_ok}")
contains "three stages are ticked"     "$(row STAGES)" "key=done"
contains "the tailnet stage is active" "$(row STAGES)" "tailnet=active"
contains "  saying why it matters"     "$(row STAGETEXT)" "reachable only over your private Tailscale network"
check    "one button, the sign-in"     "$(row BUTTONS)" "BUTTONS | tailnet=Sign in to Tailscale"
lacks    "  no chatty notes"           "$(row STAGETEXT)" "opens your browser"

echo "3b. the box has no key to join with"
# This one used to be a dialog in the MIDDLE of a build: fifteen minutes of
# log, then "paste auth key". It is a prerequisite, so it is a stage.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_nokey, \"config --json\": $cfg_ok}")
contains "the auth key stage is active" "$(row STAGES)" "authkey=active"
contains "  saying what it is for"      "$(row STAGETEXT)" "Each new games machine uses it to join your network"
# No API token here, so there is nothing to mint one with: one button, not two.
check    "and only pasting is offered"  "$(row BUTTONS)" "BUTTONS | authkey=Paste a key"

echo "3b2. pasting the key saves it, and the stage moves on"
# The save worked and the screen did not change: cg wrote .env, the dialog
# closed, and nothing re-read - because `creds tailscale authkey` was missing
# from `cg --contract`, so main called it a read. A write is what triggers the
# re-read, so a real save read as nothing happening at all.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"authkey\"] button').click();
  const open1 = document.getElementById('onefield').open;
  document.getElementById('onefield-input').value = 'tskey-auth-abc123';
  window.__ran = [];
  document.getElementById('onefield-go').click();
  await new Promise(r => setTimeout(r, 40));
  return 'dialog=' + open1
       + ' saved=' + window.__ran.includes('creds tailscale authkey')
       + ' closed=' + !document.getElementById('onefield').open
       + ' reread=' + window.__ran.includes('creds tailscale --json')
       + ' type=' + document.getElementById('onefield-input').type;
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_nokey, \"config --json\": $cfg_ok, \"creds tailscale authkey\": {}}")
contains "the paste dialog opens here" "$(row AFTER)" "dialog=true"
contains "  and Save reaches cg"       "$(row AFTER)" "saved=true"
contains "  the dialog closes"         "$(row AFTER)" "closed=true"
contains "  and the stage is re-read"  "$(row AFTER)" "reread=true"
contains "  a key is still bulleted"   "$(row AFTER)" "type=password"
ENGINE=""

echo "3c. a token that can mint a key means there is no stage at all"
# cg makes the key when the build needs it, so the prerequisite is already met
# and the pipeline does not ask you for one.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_canmint, \"config --json\": $cfg_ok}")
# Nothing is missing here: the step is ticked where it sits, like every other.
contains "the auth key step is ticked"  "$(row STAGES)" "authkey=done"
lacks    "  and asks for nothing"       "$(row BUTTONS)" "authkey"

echo "3d. nowhere to send a billing alert"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_noemail}")
contains "the alerts stage is active"  "$(row STAGES)" "email=active"
contains "  and says what it is for"   "$(row STAGETEXT)" "when spending passes your budget"

echo "3d2. the address is asked for here too"
# Same detour as the key stage: this one sent you to Settings, to find the row
# among the watchdog knobs and edit it in place. `cg config set` takes the
# value as an argument and validates it, so it is the same one-line dialog.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"email\"] button').click();
  const open1 = document.getElementById('onefield').open;
  document.getElementById('onefield-input').value = 'me@example.com';
  // From now on cg reports the address as set, the way the real one would.
  window.__answers['config --json'] = [{key: 'EMAIL_ALERTS', kind: 'text', secret: false,
                                        is_set: true, value: 'me@example.com'},
                                       {key: 'GAME_REGION', kind: 'text', secret: false,
                                        is_set: true, value: 'ap-south-2'}];
  window.__ran = [];
  document.getElementById('onefield-go').click();
  await new Promise(r => setTimeout(r, 40));
  return 'dialog=' + open1
       + ' saved=' + window.__ran.includes('config set EMAIL_ALERTS me@example.com')
       + ' closed=' + !document.getElementById('onefield').open
       + ' reread=' + window.__ran.includes('config --json')
       + ' type=' + document.getElementById('onefield-input').type
       + ' aws=' + window.__ran.includes('machines --json')
       + ' view=' + (document.querySelector('.nav-item.on') || {}).dataset?.view;
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_noemail, \"config set EMAIL_ALERTS me@example.com\": {}}")
contains "the address dialog opens here" "$(row AFTER)" "dialog=true"
contains "  and Save reaches cg"         "$(row AFTER)" "saved=true"
contains "  the dialog closes"           "$(row AFTER)" "closed=true"
# `cg config set` is not a command cg says runs alone, so nothing re-reads on
# its own: the dialog asks for the read itself.
contains "  and the setting is re-read"  "$(row AFTER)" "reread=true"
lacks    "  nobody went to Settings"     "$(row AFTER)" "view=settings"
# An address is not a credential, and a bulleted one cannot be proof-read.
contains "  and it is readable"          "$(row AFTER)" "type=text"
# The last blocking stage just cleared, by a save that is not a write: the
# reads behind the gate still have to be asked, or "where it runs" waits on a
# cg machines that nobody will ever start.
contains "  and the gate opens behind it" "$(row AFTER)" "aws=true"
ENGINE=""

echo "3e. the laptop could not reach AWS, which is not the key's fault"
# It used to say "AWS rejected this access key" to a laptop with no network - a
# lie about a call that never arrived, and it sent people to replace a key that
# was fine. cg says which it was; the stage only reads it.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_offline, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "it says the call never arrived" "$(row STAGETEXT)" "AWS could not be reached"
lacks    "  and blames nothing"           "$(row STAGETEXT)" "rejected"
contains "  saying the key may be fine"   "$(row STAGETEXT)" "It may be fine"
contains "  offering another go"          "$(row BUTTONS)" "key=Try again"

echo "3f. there is no key at all, which is not a rejection either"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_nokey, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "it says what the key is for"  "$(row STAGETEXT)" "start and stop your games machine"
lacks    "  and accuses no key"         "$(row STAGETEXT)" "rejected"
contains "  and offers to connect"     "$(row BUTTONS)" "key=Connect Amazon"

echo "3f2. the key is asked for where you are standing"
# The stage used to send you to Settings and flash the card there, which puts a
# first-time user on the one screen written for someone who already knows what
# a vCPU is, to press a second button for the dialog they could have had here.
# It is the same dialog either way, so there is still one place a key is set.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"key\"] button').click();
  await new Promise(r => setTimeout(r, 10));
  return 'dialog=' + document.getElementById('awskey').open
       + ' halves=' + !!(document.getElementById('awskey-id')
                         && document.getElementById('awskey-secret'))
       + ' view=' + (document.querySelector('.nav-item.on') || {}).dataset?.view;
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_nokey, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the key dialog opens here"  "$(row AFTER)" "dialog=true"
contains "  asking for both halves"   "$(row AFTER)" "halves=true"
lacks    "  and nothing navigated"    "$(row AFTER)" "view=settings"
ENGINE=""

echo "3g. a key AWS actually refused still says so"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_rejected, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "a refusal is said, where it is true" "$(row STAGETEXT)" "AWS rejected the saved access key"
contains "  and offers a new one"      "$(row BUTTONS)" "key=Connect again"

echo "4. the prerequisites pass: the reads that need AWS go at once"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "status is asked"          "$(row RAN)" "status --json"
contains "  the guards"             "$(row RAN)" "watcher --json"
contains "  the library"            "$(row RAN)" "library list --json"
contains "  the machines"           "$(row RAN)" "machines --json"
# The remembered scan, never a fresh one: a scan takes 90 seconds.
contains "  and the cached sweep"   "$(row RAN)" "sweep --cached --json"
lacks    "cost is never automatic"  "$(row RAN)" "cost"
# Nothing answered those, so where it runs cannot be judged - which is not the
# same as judging it ready.
# Nothing answered those, so where it runs cannot be judged - which is not the
# same as judging it missing: still the splash, still checking.
contains "still checking, on the steps" "$(row MODE)" "MODE | steps setup=true"
contains "  location says it is checking" "$(row STAGES)" "where=checking"
contains "the pipeline is still up" "$(row ONB)" "ONB | shown"

echo "4b. a laptop that has never scanned scans itself, once"
READY="\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok,
       \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok,
       \"status --json\": {\"box\": null, \"session\": null, \"region\": \"ap-south-2\",
         \"host\": \"laptop\", \"instance_type\": \"g6.xlarge\", \"archive\": null,
         \"budget\": null, \"tailnet\": {}, \"config\": {\"spot\": \"auto\"},
         \"local\": {\"tailscale\": true, \"moonlight\": true, \"ssh_key\": true, \"auth_key\": true},
         \"account\": {\"plan\": \"PAID\", \"credits\": 0}},
       \"watcher --json\": {\"guards\": []},
       \"library list --json\": {\"games\": [], \"bucket\": \"b\", \"total_bytes\": 0},
       \"machines --json\": $machines_ok"
EMPTY_SWEEP='{"cached": false, "regions": [], "too_far": [], "unreachable": []}'
FULL_SWEEP='{"cached": true, "age_seconds": 90, "too_far": [], "unreachable": [],
             "regions": [{"region": "ap-south-2", "city": "Asia Pacific (Hyderabad)",
                          "rtt_ms": 19, "enabled": true, "machines": []}]}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $EMPTY_SWEEP}")
contains "the remembered scan is read first" "$(row RAN)" "sweep --cached --json"
contains "  and a real scan follows it"      "$(row RAN)" "sweep --json"

echo "4c. everything ready: the same steps, all ticked, then the dashboard"
# Every open is the same flow. A laptop that is already set up watches its six
# steps tick, the finished list is held for a beat, and then the sidebar slides
# in and the cards come up. There used to be a "Checking your rig" splash that
# stayed up until something was found missing - which, with five steps done,
# meant sitting on it for as long as the slow reads behind Location took.
ENGINE="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const at = n => document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'then=' + at('onb') + '/' + at('d-main')
       + ' setup=' + document.body.classList.contains('setup')
       + ' arriving=' + document.body.classList.contains('arriving');
};"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
contains "the steps are shown"          "$(row MODE)" "MODE | steps"
check    "  every one ticked"           "$(row STAGES)" "STAGES | tools=done,key=done,tailnet=done,authkey=done,email=done,where=done,open=done"
contains "  and held for a beat"        "$(row ONB)" "ONB | shown cards=hidden"
contains "then the dashboard takes over" "$(row AFTER)" "then=hidden/shown"
contains "  with the sidebar back"      "$(row AFTER)" "setup=false"
contains "  and it arrives, not appears" "$(row AFTER)" "arriving=true"
lacks    "nothing rescans"              "$(row RAN)" ";; sweep --json"
check    "nothing threw"                "$(row ERRS)" "ERRS | "
ENGINE=""

echo "4c2. it hands over only once the dashboard has something to show"
# The stages are judged on the fast reads, so the pipeline finished while the
# box, the archive and the guards were still being read: the dashboard opened
# on "Stop refresh" and empty cards, which reads as the app starting again.
# Sampled past the handover beat but before the box answers: that is the
# window in which it used to have handed over already.
ENGINE="window.__slow = ['status --json']; window.__slowMs = 2500;
window.__after = async () => {
  const at = n => document.getElementById(n).hidden ? 'hidden' : 'shown';
  await new Promise(r => setTimeout(r, 1000));
  const before = 'onb=' + at('onb') + ' cards=' + at('d-main');
  const step = document.querySelector('[data-stage=open]');
  const opening = 'open=' + step.dataset.state + ' '
    + [...step.querySelectorAll('[data-tab]')]
        .map(r => r.dataset.tab + ':' + r.dataset.state).join(',');
  await new Promise(r => setTimeout(r, 2200));
  return before + ' | after: onb=' + at('onb') + ' cards=' + at('d-main')
       + ' stop=' + at('cancel') + ' | ' + opening;
};"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
contains "every step is ticked"             "$(row STAGES)" "where=done"
contains "  but the box is still being read, so it waits" "$(row AFTER)" "onb=shown cards=hidden |"
# And the wait is shown as a wait, as the pipeline's last step - not a loose
# list under the finished ones - with one chip per TAB: what each tab shows has
# to be read before it can show it. The box is slow here, and three tabs show
# it; Guards and Settings do not.
contains "  the last step is loading"       "$(row AFTER)" "open=loading"
contains "    one chip per tab"             "$(row AFTER)" "dashboard:checking,build:checking,library:checking,guards:done,settings:done"
# Cost reads Cost Explorer, which bills: only on Fetch, never here.
lacks    "    and never Cost"               "$(row AFTER)" "cost:"
contains "then the dashboard arrives"       "$(row AFTER)" "after: onb=hidden cards=shown"
contains "  with nothing left running"      "$(row AFTER)" "stop=hidden"
ENGINE=""

echo "4c3. one click on Refresh is one run to stop"
# The Build screen's Refresh is four reads. Named each by what it is, two of
# them were "refresh" and one was "machines" - and the button offered to
# "Stop 2 runs" for a single click.
ENGINE="window.__after = async () => {
  await new Promise(r => setTimeout(r, 400));
  document.querySelector('.nav-item[data-view=\"build\"]').click();
  window.__slow = ['status --json', 'machines --json', 'library list --json'];
  window.__slowMs = 800;
  document.getElementById('refresh').click();
  await new Promise(r => setTimeout(r, 50));
  return 'stop=' + document.getElementById('cancel-label').textContent.trim();
};"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
check "it is one refresh" "$(row AFTER)" "AFTER | stop=Stop refresh"
ENGINE=""

echo "4d. a region that cannot rent the machine is not 'ready'"
# An enabled region with no GPU quota looks completely set up and cannot build.
# That is the Malaysia case, and it read as a broken app rather than a step.
OUT=$(probe "{$READY, \"machines --json\": $machines_noquota, \"sweep --cached --json\": $FULL_SWEEP}")
contains "the pipeline stays up"       "$(row ONB)" "ONB | shown"
contains "  with where it runs active" "$(row STAGES)" "where=active"
contains "  naming the place, not a code" "$(row STAGETEXT)" "Hyderabad has no GPU quota for your machine"
contains "  offering the choice"       "$(row BUTTONS)" "where=Choose a location"

echo "4d2. a region nobody chose is not a choice"
# A fresh laptop names no region, cg falls back to its default, the default
# rents the machine - and the stage used to tick itself. The pipeline finished
# and vanished without ever showing the list to choose from.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 20));
  const popup = document.getElementById('whereto').open;
  const usable = !document.getElementById('whereto-use').disabled;
  const useLabel = document.getElementById('whereto-use').textContent.trim();
  // From here on cg reports the region as written, the way the real one would.
  window.__answers['config --json'] = [
    {key: 'EMAIL_ALERTS', kind: 'text', secret: false, is_set: true, value: 'a@b.c'},
    {key: 'GAME_REGION', kind: 'text', secret: false, is_set: true, value: 'ap-south-2'}];
  window.__ran = [];
  document.getElementById('whereto-use').click();
  await new Promise(r => setTimeout(r, 60));
  const at = n => document.getElementById(n).hidden ? 'hidden' : 'shown';
  // The last step just went green: the finished list is held for a beat.
  // Redraw on purpose, 50ms after the change: the tick must still be there,
  // carrying on from 50ms in rather than starting again.
  await new Promise(r => setTimeout(r, 50));
  paintOnboard();
  const tick = document.querySelector('[data-stage=\"where\"] .onb-tick');
  const held = 'held=' + at('onb') + '/' + at('d-main') + ' count='
             + document.getElementById('onb-count').textContent.trim()
             + ' tick=' + !!tick
             // Redrawn since the change, so it must be resuming, not restarting.
             + ' resumed=' + (tick ? parseFloat(tick.style.animationDelay) < 0 : 'none');
  await new Promise(r => setTimeout(r, 1200));
  return held + ' then=' + at('onb') + '/' + at('d-main')
       + ' use=' + useLabel + ' popup=' + popup + ' usable=' + usable
       + ' saved=' + window.__ran.includes('config set GAME_REGION ap-south-2')
       + ' reread=' + window.__ran.includes('config --json')
       + ' where=' + document.querySelector('#onb-steps [data-stage=\"where\"]').dataset.state
       + ' status=' + window.__ran.includes('status --json');
};"
# A scan where Hyderabad can rent the machine, so it can be picked.
FIT_SWEEP='{"cached": true, "age_seconds": 90, "too_far": [], "unreachable": [],
            "regions": [{"region": "ap-south-2", "city": "Asia Pacific (Hyderabad)",
                         "rtt_ms": 19, "enabled": true,
                         "machines": [{"type": "g6.xlarge", "fits_spot": true, "fits_ondemand": true,
                                       "inr_hour_spot": 16, "inr_hour_ondemand": 85}]}]}'
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $FIT_SWEEP,
              \"config set GAME_REGION ap-south-2\": {}}")
contains "the pipeline stays up"        "$(row ONB)" "ONB | shown"
contains "  with where it runs active"  "$(row STAGES)" "where=active"
contains "  asking, not blaming"        "$(row STAGETEXT)" "Choose where your games machine runs"
lacks    "  and no region is accused"   "$(row STAGETEXT)" "no GPU quota"
# The stage is judged on cg machines, which is behind the gate: it must not
# be what keeps the gate shut, or the list it opens has nothing in it.
contains "the reads behind the gate ran" "$(row RAN)" "machines --json"
contains "  and so did the scan"        "$(row RAN)" "sweep --cached --json"
contains "its button opens the list"    "$(row AFTER)" "popup=true"
contains "  with the region in use offered" "$(row AFTER)" "usable=true"
contains "  on a button that names it"  "$(row AFTER)" "use=Use Hyderabad"
contains "using it reaches cg"          "$(row AFTER)" "saved=true"
# Not a write by cg's contract, so the popup has to ask for the read itself -
# without it the stage sat on "Pick where it runs" after you had picked.
contains "  and the setting is re-read" "$(row AFTER)" "reread=true"
contains "  so the stage is done"       "$(row AFTER)" "where=done"
# Everything behind the gate is per region, so it is read again for the new one.
contains "  and the box is read for it" "$(row AFTER)" "status=true"
# A checklist you watched finish is held for a beat - six ticks replaced in
# 200ms reads as a glitch - and then the dashboard arrives.
contains "the finished list is held"    "$(row AFTER)" "held=shown/hidden"
contains "  counting it"                "$(row AFTER)" "count=7 of 7 done"
contains "  the tick lands, animated"   "$(row AFTER)" "tick=true"
contains "  and a redraw resumes it"    "$(row AFTER)" "resumed=true"
contains "  then the dashboard arrives" "$(row AFTER)" "then=hidden/shown"
ENGINE=""

echo "4d3. choosing the location waits for that location's reads"
# Saving the region ticked the last step before the reads for the new region
# had started, so the beat ran out with nothing to wait for and the dashboard
# opened on "Stop refresh". The reads start with the save, and the beat is a
# minimum, not a deadline.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 20));
  window.__answers['config --json'] = [
    {key: 'EMAIL_ALERTS', kind: 'text', secret: false, is_set: true, value: 'a@b.c'},
    {key: 'GAME_REGION', kind: 'text', secret: false, is_set: true, value: 'ap-south-2'}];
  window.__slow = ['status --json']; window.__slowMs = 1500;
  document.getElementById('whereto-use').click();
  const at = n => document.getElementById(n).hidden ? 'hidden' : 'shown';
  await new Promise(r => setTimeout(r, 1200));
  const mid = at('onb') + '/' + at('d-main');
  await new Promise(r => setTimeout(r, 1500));
  return 'mid=' + mid + ' end=' + at('onb') + '/' + at('d-main') + ' stop=' + at('cancel');
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $FIT_SWEEP,
              \"config set GAME_REGION ap-south-2\": {}}")
contains "past the beat, the box still out: held" "$(row AFTER)" "mid=shown/hidden"
contains "  then the dashboard, filled"          "$(row AFTER)" "end=hidden/shown"
contains "  with nothing left running"           "$(row AFTER)" "stop=hidden"
ENGINE=""

echo "4e. the location popup on a laptop that has never measured"
# It opened on an empty table with two greyed buttons and only Cancel live -
# while the measuring it needed was running, twice: the app had started one by
# itself and the popup started another on top.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 30));
  const at = n => document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'busy=' + at('whereto-busy') + ' list=' + at('whereto-list')
       + ' use=' + at('whereto-use') + ' measure=' + at('whereto-measure')
       + ' sweeps=' + window.__ran.filter(c => c === 'sweep --json').length;
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $EMPTY_SWEEP}")
contains "it says it is measuring"        "$(row AFTER)" "busy=shown"
contains "  instead of an empty table"    "$(row AFTER)" "list=hidden"
contains "  with nothing greyed to press" "$(row AFTER)" "use=hidden measure=hidden"
contains "  and measures once, not twice" "$(row AFTER)" "sweeps=1"

echo "4e2. measuring again shows it is measuring"
# Pressing "Measure again" with a table already up used to change one grey line
# and nothing else - it looked like the button did nothing.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 30));
  document.getElementById('whereto-measure').click();
  await new Promise(r => setTimeout(r, 30));
  const at = n => document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'busy=' + at('whereto-busy') + ' spinner=' + !!document.querySelector('#whereto-busy .spinner')
       + ' text=' + document.getElementById('whereto-busy-text').textContent.trim()
       + ' list=' + at('whereto-list') + ' stale=' + document.getElementById('whereto-list').classList.contains('stale')
       + ' use=' + at('whereto-use');
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $FIT_SWEEP}")
contains "a spinner, while it measures"   "$(row AFTER)" "busy=shown spinner=true"
contains "  saying it is measuring again"  "$(row AFTER)" "text=Measuring again"
contains "  the old table kept, faded"     "$(row AFTER)" "list=shown stale=true"
contains "  and not choosable meanwhile"   "$(row AFTER)" "use=hidden"
ENGINE=""

echo "4f. a measurement that fails says why, and offers another go"
ENGINE="window.__broken = ['sweep --json'];
window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"where\"] button').click();
  await new Promise(r => setTimeout(r, 30));
  const at = n => document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'busy=' + at('whereto-busy') + ' err=' + at('whereto-err')
       + ' why=' + document.getElementById('whereto-err').textContent.trim()
       + ' measure=' + document.getElementById('whereto-measure').textContent.trim()
       + '/' + at('whereto-measure');
};"
OUT=$(probe "{$READY, \"config --json\": $cfg_noregion, \"sweep --cached --json\": $EMPTY_SWEEP}")
contains "it stops saying measuring"      "$(row AFTER)" "busy=hidden"
contains "  says it failed"               "$(row AFTER)" "err=shown"
contains "  in cg's words"                "$(row AFTER)" "could not reach AWS"
contains "  and offers another go"        "$(row AFTER)" "measure=Try again/shown"
ENGINE=""

echo "6. the dashboard: what is billing, item by item, in rupees"
# It used to say "nothing is billing by the hour" and stop there - while the game
# archive, a disk left behind or a reserved address billed by the month. Now it
# lists each thing that costs money with what it costs, or says there are none.
RATES='"rates": {"s3_gb_month": 0.025, "ebs_gb_month": 0.0912, "snapshot_gb_month": 0.0125,
                 "ipv4_hour": 0.005, "inr_per_usd": 88, "ce_call_usd": 0.01}'
st() { # st <box json> <archive json> <res json> <budget json>
  echo "{\"box\": $1, \"session\": null, \"region\": \"ap-south-2\", \"host\": \"laptop\",
         \"instance_type\": \"g6.xlarge\", \"archive\": $2, \"res\": $3, \"budget\": $4,
         \"spec\": {\"gpu\": \"L4\"}, \"tailnet\": {}, \"config\": {\"spot\": \"auto\"},
         \"local\": {}, \"account\": {\"plan\": \"PAID\", \"credits\": 0}, $RATES}"
}
DASH="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const t = id => document.getElementById(id).innerText.replace(/\\s+/g, ' ').trim();
  const shown = id => !document.getElementById(id).hidden;
  return 'title=' + t('d-title') + ' | machine=' + t('d-machine') + ' | rate=' + t('d-rate')
       + ' | bill=' + t('d-bill') + ' | total=' + t('d-bill-total')
       + ' | month=' + t('d-month') + ' | src=' + t('d-month-src') + ' | price=' + t('d-cost-price')
       + ' | games=' + t('d-games') + ' ' + t('d-games-sub') + ' ' + t('d-games-keep')
       + ' | protect=' + t('d-protect')
       + ' | buttons=' + ['d-build', 'd-open', 'd-destroy'].filter(shown).join(',')
       + ' | destroy=' + t('d-destroy');
};"

ENGINE="$DASH"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0, "snapshots": 0, "elastic_ips": 0}' '{"limit": 57, "spent": 4.5, "alerts": 2}')}")
contains "no machine, said plainly"        "$(row AFTER)" "title=No machine running"
lacks    "  not 'nothing is billed'"        "$(row AFTER)" "billed by the hour"
contains "  what it would be"              "$(row AFTER)" "machine=g6.xlarge · NVIDIA L4 · Hyderabad · spot when available"
contains "  and what it would cost"        "$(row AFTER)" "rate=₹16/hour while it runs"
contains "nothing billing: no items"       "$(row AFTER)" "bill=No billing items."
contains "the month, in rupees, of the budget" "$(row AFTER)" "month=₹396 of ₹5,016"
contains "  from Budgets, which is free"   "$(row AFTER)" "src=From AWS Budgets"
contains "the exact figure's price, in rupees" "$(row AFTER)" "price=₹0.88"
contains "no games yet"                    "$(row AFTER)" "games=No games saved yet"
contains "the budget is protection"        "$(row AFTER)" "Budget alert at ₹5,016 - emails 2 addresses"
contains "one action: build"               "$(row AFTER)" "buttons=d-build |"
lacks    "no dollars anywhere on it"       "$(row AFTER)" "$"

OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st '{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "public_ip": "13.1.1.1", "launched": "2026-01-01T00:00:00Z"}' \
     '{"bytes": 136365211648, "usd_month": 3.18, "expiry_days": 14}' \
     '{"volumes_gb": 50, "snapshots": 0, "elastic_ips": 0}' '{"limit": 57, "spent": 4.5, "alerts": 2}')}")
contains "a running machine: ready"        "$(row AFTER)" "title=Ready to play"
contains "  the machine, priced by the hour" "$(row AFTER)" "Machine · g6.xlarge, spot ₹16/hour"
contains "  its public address"            "$(row AFTER)" "Public IP address ₹0.44/hour"
contains "  its disk, by the month"        "$(row AFTER)" "Machine disk · 50 GB ₹401/month"
contains "  the archive, by the month"     "$(row AFTER)" "Game archive · 127.0 GB ₹280/month"
contains "  totalled both ways"            "$(row AFTER)" "total=While running ₹16.44/hour Storage ₹681/month"
contains "  how long the games are kept"   "$(row AFTER)" "Deleted after 14 days with no machine."
contains "play and delete, nothing else"   "$(row AFTER)" "buttons=d-open,d-destroy |"
# (The icon glyph comes first, so this checks the words after it.)
contains "  it says delete, not destroy"   "$(row AFTER)" " Delete machine"
lacks    "    anywhere on the page"         "$(row AFTER)" "Destroy"

OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 30, "snapshots": 2, "snapshots_gb": 80, "elastic_ips": 1}' '{"limit": 57, "spent": 4.5, "alerts": 2}')}")
# No machine, and things still billing: each one named, and the ones cg did not
# make or that nothing is using marked as such.
contains "a disk left behind"              "$(row AFTER)" "Disk left behind · 30 GB no machine is using it ₹241/month"
contains "  snapshots, as the most they cost" "$(row AFTER)" "Snapshots · 2, 80 GB cg does not make these up to ₹88/month"
contains "  a reserved address"            "$(row AFTER)" "Elastic IP address · 1 reserved with no machine ₹0.44/hour"
echo "6b. the dashboard: Tailscale"
TS="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  const t = id => document.getElementById(id).innerText.replace(/\\s+/g, ' ').trim();
  return 'ts=' + t('d-ts') + ' | signin=' + !document.getElementById('d-ts-signin').hidden
       + ' | pings=' + window.__ran.filter(c => c === 'ping --json').length;
};"
ENGINE="$TS"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "the laptop, by name"             "$(row AFTER)" "This laptop is signed in as laptop"
contains "  no machine on the network"     "$(row AFTER)" "No machine on the network"
contains "  and no path to measure"        "$(row AFTER)" "pings=0"
contains "  nothing to sign in to"         "$(row AFTER)" "signin=false"

ONLINE=$(st '{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}' '{"bytes": 0}' '{"volumes_gb": 50}' '{"limit": 57}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d["tailnet"]={"node":"gamevps","online":True}; print(json.dumps(d))')
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP, \"status --json\": $ONLINE,
  \"ping --json\": {\"node\": \"gamevps\", \"path\": \"direct\", \"median_ms\": 18}}")
contains "a running machine, online"       "$(row AFTER)" "Machine gamevps is online"
contains "  the path, measured once"       "$(row AFTER)" "Direct connection · 18 ms"
contains "  only once"                     "$(row AFTER)" "pings=1"

OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP, \"status --json\": $ONLINE,
  \"ping --json\": {\"node\": \"gamevps\", \"path\": \"DERP\", \"median_ms\": 74}}")
contains "a relayed path says it is slower" "$(row AFTER)" "Relayed through Tailscale · 74 ms - slower for streaming"

ENGINE="$DASH"
# An older cg sends no price table: every figure is unknown, never ₹0.
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": {\"box\": null, \"region\": \"ap-south-2\", \"instance_type\": \"g6.xlarge\",
     \"archive\": {\"bytes\": 1073741824, \"usd_month\": 0.03}, \"res\": {\"volumes_gb\": 0},
     \"budget\": {\"limit\": 57, \"spent\": 4.5}, \"config\": {}, \"local\": {}, \"account\": {}}}")
contains "no price table: the archive cost is unknown" "$(row AFTER)" "Game archive · 1.0 GB —"
lacks    "  never zero"                    "$(row AFTER)" "₹0.00"
ENGINE=""

echo "7. the Build page: a build is eight plain steps"
# cg reports a dozen steps of its own and the box a dozen more ("installing
# nvidia driver", "configuring headless X"); the page shows eight, in plain
# words, with the bill in the heading from the moment the machine is rented.
BUILD="window.__after = async () => {
  await new Promise(r => setTimeout(r, 1200));
  document.querySelector('.nav-item[data-view=build]').click();
  const plan = !document.getElementById('b-plan').hidden;
  const chip = document.getElementById('b-chip').textContent.trim();
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
    + ' | text=' + document.getElementById('b-steps').innerText.replace(/\\s+/g, ' ')
    + ' | plan=' + !document.getElementById('b-plan').hidden;
  window.__emit(id, { t: 'line', kind: 'fail', text: 'the driver did not install' });
  window.__emit(id, { t: 'exit', rc: 1 });
  await new Promise(r => setTimeout(r, 30));
  const failed = 'failed=' + st() + ' | head=' + document.getElementById('b-strip-title').textContent
    + ' | acts=' + [...document.querySelectorAll('#b-run-acts button')].map(b => b.textContent.trim()).join(',')
    + ' | panelIn=' + (document.getElementById('b-fail').closest('[data-step]') || {}).dataset?.step;
  return 'plan=' + plan + ' | chip=' + chip + ' | ask=' + ask + ' || ' + mid + ' || ' + failed;
};"
ENGINE="$BUILD"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "before a build: the plan"          "$(row AFTER)" "plan=true"
contains "  saying what Build starts billing" "$(row AFTER)" "chip=Billing starts when the machine launches · ₹16.44/hour"
contains "the confirm names the rate"        "$(row AFTER)" "Billing starts when the machine launches, at ₹16.44/hour"
# Mid-build: setup, budget, machine and Tailscale done; the box's own steps
# (base packages, the driver) are one step, installing.
contains "four steps done, the fifth running" "$(row AFTER)" "mid=0=done,1=done,2=done,3=done,4=running,5=locked,6=locked,7=locked"
contains "  in plain words"                   "$(row AFTER)" "Checked your setup"
contains "    the rental, with when billing began" "$(row AFTER)" "Machine rented · billing from"
contains "    the box's steps as one"         "$(row AFTER)" "Installing the software"
contains "    with the line it is on"         "$(row AFTER)" "nvidia-driver-580 unpacked"
contains "  the heading is the build"         "$(row AFTER)" "title=Building your machine"
contains "  with the rate in it"              "$(row AFTER)" "₹16.44/hour"
contains "  and the plan is put away"         "$(row AFTER)" "plan=false"
contains "a failure stops at its step"        "$(row AFTER)" "failed=0=done,1=done,2=done,3=done,4=failed,5=skipped"
contains "  the heading says so"              "$(row AFTER)" "head=The build stopped"
contains "  the reason sits in that step"     "$(row AFTER)" "panelIn=4"
contains "  with try again, or close"         "$(row AFTER)" "acts=Try again,Close"
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
  run = null; paintRun();
  const b = await go(['preflight', 'arming the budget', 'provisioning instance', 'waiting for the box to join the tailnet',
                      'building the box', 'finishing up', 'moonlight pairing', 'waiting for Steam to finish installing'], 0);
  const st = [...document.querySelectorAll('#b-steps [data-step]')].map(r => r.dataset.state).join(',');
  return 'failed=' + a + ' | done=' + b + ' | steps=' + st;
};"
ENGINE="$B2"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st null '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a failed rental: nothing was billed" "$(row AFTER)" "failed=The build stopped / Nothing was billed"
contains "a finished build: ready to play"     "$(row AFTER)" "done=Ready to play / built in"
contains "  with play, and delete"            "$(row AFTER)" "▶ Play,Delete machine"
contains "  and all eight steps ticked"        "$(row AFTER)" "steps=done,done,done,done,done,done,done,done"
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
  const done = card() + ' acts=' + acts() + ' folded=' + !!document.querySelector('#b-steps details:not([open])');
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
contains "a build shows the run"              "$(row AFTER)" "during=run:Building your machine acts=Cancel"
contains "  and still does after leaving"     "$(row AFTER)" "back=run:Building your machine |"
contains "a finished build is the machine"    "$(row AFTER)" "done=run:Ready to play acts=▶ Play,Delete machine folded=true"
contains "  and stays it after leaving"       "$(row AFTER)" "done2=run:Ready to play |"
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
  return 'plan=' + !document.getElementById('b-plan').hidden
    + ' | title=' + document.getElementById('b-strip-title').textContent
    + ' | meta=' + document.getElementById('b-strip-meta').textContent
    + ' | acts=' + [...document.querySelectorAll('#b-run-acts button')].map(b => b.textContent.trim()).join(',');
};"
ENGINE="$B5"
BOX='{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOX" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "no plan beside a machine"   "$(row AFTER)" "plan=false"
contains "  the machine, ready"       "$(row AFTER)" "title=Ready to play"
contains "  how long it has been up"  "$(row AFTER)" "meta=up "
contains "  play, or delete it"       "$(row AFTER)" "acts=▶ Play,Delete machine"
ENGINE=""

echo "7f. play is a session, as steps, ending in keep or delete"
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
    [...document.querySelectorAll('#b-run-acts button')].find(b => b.textContent.includes('Play')).click();
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
  const kept = card();
  id = await play();
  for (const t of ['instance already running', 'waiting for sunshine ok', 'session ended after 1m'])
    window.__emit(id, { t: 'line', text: t });
  window.__emit(id, { t: 'step', text: 'destroying the box' });
  await wait();
  const deleting = card();
  window.__emit(id, { t: 'exit', rc: 0 });
  await wait();
  return 'starting=' + starting + ' | playing=' + playing + ' | kept=' + kept
    + ' | deleting=' + deleting + ' | after=' + card();
};"
ENGINE="$B6"
BOX='{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOX" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "play starts with the machine"     "$(row AFTER)" "starting=run:Starting the stream running,locked,locked,locked"
contains "  then is playing"                "$(row AFTER)" "playing=run:Playing done,done,done,running"
contains "  saying how to stop"             "$(row AFTER)" "Close Moonlight to stop"
contains "  and what it costs"              "$(row AFTER)" "so far"
contains "kept: back to the machine"        "$(row AFTER)" "kept=run:Ready to play"
contains "deleted: the delete is shown"     "$(row AFTER)" "deleting=run:Deleting the machine"
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
contains "refresh opens a popup"           "$(row AFTER)" "open=true title=Refreshing Dashboard"
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
  [...document.querySelectorAll('#b-run-acts button')].find(b => b.textContent.includes('Play')).click();
  await wait();
  const id = window.__lastId;
  for (const l of ['instance already running', 'waiting for sunshine ok', 'disk:']) window.__emit(id, { t: 'line', text: l });
  await wait();
  const playing = card();
  window.__ran = [];
  window.__emit(id, { t: 'exit', rc: 130 });
  const popup = 'open=' + document.getElementById('refdlg').open + ' title=' + document.getElementById('refdlg-title').textContent;
  await wait(); await wait();
  return 'playing=' + playing + ' | popup=' + popup + ' | after=' + card() + ' closed=' + !document.getElementById('refdlg').open
    + ' fail=' + !document.getElementById('b-fail').classList.contains('hidden')
    + ' | statusReads=' + window.__ran.filter(l => l === 'status --json').length + ' stillReading=' + jobs.size
    + ' rows=' + document.querySelectorAll('#refdlg-list [data-read]').length;
};"
ENGINE="$B8"
BOX='{"id": "i-1", "state": "running", "type": "g6.xlarge", "lifecycle": "spot", "launched": "2026-01-01T00:00:00Z"}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
  \"status --json\": $(st "$BOX" '{"bytes": 0}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "a session is playing"            "$(row AFTER)" "playing=run:Playing"
contains "stopping it opens the popup"     "$(row AFTER)" "popup=open=true title=Refreshing Build"
contains "  which leaves it ready to play" "$(row AFTER)" "after=run:Ready to play closed=true"
contains "  and calls nothing a failure"   "$(row AFTER)" "fail=false"
# One round of reads, under the popup: not the page's, then all of them again.
contains "  read once, all under the popup" "$(row AFTER)" "statusReads=1 stillReading=0 rows=9"
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
  [...document.querySelectorAll('#b-run-acts button')].find(b => b.textContent.includes('Play')).click();
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
contains "after a session: ready to play"  "$(row AFTER)" "title=Ready to play"
contains "  with how it was built"         "$(row AFTER)" "built=How it was built"
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
  [...document.querySelectorAll('#lib-rows button')].find(b => b.textContent === 'Forget').click();
  await wait();
  const id = window.__lastId;
  window.__emit(id, { t: 'ask', id: 'forget-game', prompt: 'type FORGET to confirm: ' });
  const during = 'view=' + view() + ' word=' + (asked && asked.word) + ' ran=' + window.__ran.slice(-1)[0]
    + ' popup=' + document.getElementById('refdlg').open + ':' + document.getElementById('refdlg-title').textContent
    + ' answered=' + answered.join(',') + ' askdlg=' + document.getElementById('ask').open;
  window.__emit(id, { t: 'exit', rc: 0 });
  const reading = document.getElementById('refdlg-title').textContent;
  await wait(); await wait();
  const after = 'view=' + view() + ' popup=' + document.getElementById('refdlg').open;
  [...document.querySelectorAll('#lib-rows button')].find(b => b.textContent === 'Forget').click();
  await wait();
  const id2 = window.__lastId;
  window.__emit(id2, { t: 'line', text: 'aborted - nothing was deleted' });
  window.__emit(id2, { t: 'exit', rc: 1 });
  await wait(); await wait();
  const refused = 'popup=' + document.getElementById('refdlg').open + ' title=' + document.getElementById('refdlg-title').textContent
    + ' why=' + document.getElementById('refdlg-list').innerText.replace(/\\s+/g, ' ')
    + ' close=' + !document.getElementById('refdlg-menu').hidden + ' view=' + view();
  return 'during=' + during + ' | reading=' + reading + ' | after=' + after + ' | refused=' + refused;
};"
ENGINE="$B10"
LIB='{"games": [{"appid": "2344520", "name": "Diablo IV", "bytes": 96636764160, "usd_month": 2.21, "pushed": "2026-10-12T00:00:00Z"}],
      "total_bytes": 96636764160, "usd_month": 2.21, "selectable_gb": 209, "bucket": "b", "login": {"present": false}}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP, \"library list --json\": $LIB,
  \"status --json\": $(st null '{"bytes": 96636764160}' '{"volumes_gb": 0}' '{"limit": 57}')}")
contains "forget stays on Library"           "$(row AFTER)" "during=view=library word=FORGET"
contains "  runs cg's forget"                "$(row AFTER)" "ran=library forget 2344520"
contains "  with the popup saying so"        "$(row AFTER)" "popup=true:Forgetting Diablo IV"
contains "  and cg gets the word, no second dialog" "$(row AFTER)" "answered=FORGET askdlg=false"
contains "done: the popup reads the page again" "$(row AFTER)" "reading=Refreshing Library"
contains "  and closes, still on Library"    "$(row AFTER)" "after=view=library popup=false"
contains "refused: the popup stays"          "$(row AFTER)" "refused=popup=true title=Forgetting Diablo IV - not done"
contains "  with cg's reason"                "$(row AFTER)" "aborted - nothing was deleted"
contains "  a Close, and still on Library"   "$(row AFTER)" "close=true view=library"
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
    + ' pageScrolls=' + (document.scrollingElement.scrollHeight > innerHeight + 1);
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
contains "a long build scrolls in its card, not the page" "$(row AFTER)" "pageScrolls=false"
contains "it finishes ready to play"       "$(row AFTER)" "end=Ready to play done,done,done,done,done,done,done,done"
ENGINE=""

echo "5. nothing threw"
check "the page logged no errors"   "$(row ERRS)" "ERRS | "

echo ""
echo "startup-gate: $pass passed, $fail failed"
(( fail == 0 ))
