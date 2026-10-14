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
      }, (window.__slow || []).includes(line) ? 600 : 0);
    }
    // main answers with cg's own verdict; these are the ones cg lists.
    const write = ['init', 'destroy', 'open'].includes(args[0])
      || (args[0] === 'library' && args[1] !== 'list');
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
           + ' done=' + (document.getElementById('onb-done').hidden ? 'hidden' : 'shown'));
  out.push('TITLE2 | ' + document.getElementById('onb-title').textContent.trim());
  out.push('COUNT | ' + document.getElementById('onb-count').textContent.trim());
  out.push('SUB | ' + document.getElementById('onb-sub').textContent.replace(/\s+/g, ' ').trim());
  out.push('STAGES | ' + [...document.querySelectorAll('#onb-steps [data-stage]')]
             .map(r => r.dataset.stage + '=' + r.dataset.state).join(','));
  out.push('STAGETEXT | ' + document.getElementById('onb-steps').innerText
             .replace(/\s+/g, ' ').trim());
  // Only the active stage may offer anything: you cannot start in the middle.
  out.push('BUTTONS | ' + [...document.querySelectorAll('#onb-steps [data-stage] button')]
             .map(b => b.closest('[data-stage]').dataset.stage + '=' + b.textContent.trim()).join(','));
  out.push('LOG | ' + document.getElementById('onb-log').textContent.replace(/\s+/g, ' ').trim());
  out.push('LOGCMD | ' + document.getElementById('onb-log-cmd').textContent.trim());
  out.push('LINK | ' + (document.getElementById('onb-link').hidden ? 'hidden' : 'shown'));
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
cfg_ok='[{"key":"EMAIL_ALERTS","kind":"text","secret":false,"is_set":true,"value":"a@b.c","default":null,"note":"n"}]'
cfg_noemail='[{"key":"EMAIL_ALERTS","kind":"text","secret":false,"is_set":false,"value":null,"default":null,"note":"n"}]'

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
contains "  counting the stages"       "$(row COUNT)" "of 6 done"
contains "  naming the missing tools"  "$(row STAGETEXT)" "AWS CLI v2, Moonlight are not installed"
contains "  and what that means"       "$(row STAGETEXT)" "Nothing here can run without them"
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
contains "  saying what it will ask for"  "$(row STAGETEXT)" "asks for your password once"
# The banner is for a problem that turns up mid-session. The pipeline has this
# one, in order, with the button - two copies of it is what this replaced.
check    "the banner stays out of it"  "$(row BANNER)" "BANNER | hidden"
check    "and the log pane is empty"   "$(row LOG)" "LOG | "

echo "1b. pressing Install them: the log pane is where cg speaks"
# Not a dialog over the window, and not "running: cg deps install" in the
# header. The pane beside the stage, which is permanent furniture.
ENGINE="window.__after = async () => {
  window.__broken = [];
  document.querySelector('#onb-steps button').click();
  await new Promise(r => setTimeout(r, 10));
  window.__emit(window.__lastId, { t: 'line', text: 'installing aws-cli' });
  await new Promise(r => setTimeout(r, 10));
  return 'cmd=' + document.getElementById('onb-log-cmd').textContent.trim()
       + ' | log=' + document.getElementById('onb-log').textContent.replace(/\s+/g, ' ').trim()
       + ' | state=' + document.querySelector('[data-stage=tools]').dataset.state
       + ' | buttons=' + [...document.querySelectorAll('#onb-steps button')].map(b => b.textContent.trim()).join(',');
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the pane names the command"  "$(row AFTER)" "cmd=cg deps install"
contains "  and carries its output"    "$(row AFTER)" "installing aws-cli"
contains "the stage says it is running" "$(row AFTER)" "state=running"
# Stopping has to reach cg: a package manager can be sitting on a lock.
contains "  and offers to stop it"     "$(row AFTER)" "buttons=Stop waiting"
ENGINE=""

echo "2. tools are there, the key is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the tools stage is ticked"   "$(row STAGES)" "tools=done"
contains "  and the CLI is the problem" "$(row STAGETEXT)" "The AWS CLI is not installed"
contains "  with the install button"   "$(row BUTTONS)" "cli=Install them"

echo "3. tools and key are there, the tailnet is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" false), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_out, \"config --json\": $cfg_ok}")
contains "three stages are ticked"     "$(row STAGES)" "key=done"
contains "the tailnet stage is active" "$(row STAGES)" "tailnet=active"
contains "  saying why it matters"     "$(row STAGETEXT)" "no public SSH port"
contains "  and that it is free"       "$(row STAGETEXT)" "Free."
check    "one button, the sign-in"     "$(row BUTTONS)" "BUTTONS | tailnet=Sign in"
contains "  which finishes elsewhere"  "$(row STAGETEXT)" "finishes in your browser"

echo "3b. the box has no key to join with"
# This one used to be a dialog in the MIDDLE of a build: fifteen minutes of
# log, then "paste auth key". It is a prerequisite, so it is a stage.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_nokey, \"config --json\": $cfg_ok}")
contains "the auth key stage is active" "$(row STAGES)" "authkey=active"
contains "  saying what it stops"       "$(row STAGETEXT)" "cannot join it to your tailnet"
# No API token here, so there is nothing to mint one with: one button, not two.
check    "and only pasting is offered"  "$(row BUTTONS)" "BUTTONS | authkey=Paste a key"

echo "3c. a token that can mint a key means there is no stage at all"
# cg makes the key when the build needs it, so the prerequisite is already met
# and the pipeline does not ask you for one.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_canmint, \"config --json\": $cfg_ok}")
contains "the auth key stage is ticked" "$(row STAGES)" "authkey=done"
lacks    "  and asks for nothing"       "$(row BUTTONS)" "authkey"

echo "3d. nowhere to send a billing alert"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_noemail}")
contains "the alerts stage is active"  "$(row STAGES)" "email=active"
contains "  and says a build needs it" "$(row STAGETEXT)" "budget alarm"

echo "3e. the laptop could not reach AWS, which is not the key's fault"
# It used to say "AWS rejected this access key" to a laptop with no network - a
# lie about a call that never arrived, and it sent people to replace a key that
# was fine. cg says which it was; the stage only reads it.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_offline, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "it says the call never arrived" "$(row STAGETEXT)" "could not reach AWS"
lacks    "  and blames nothing"           "$(row STAGETEXT)" "rejected this access key"
contains "  saying the key may be fine"   "$(row STAGETEXT)" "The key may be fine"
contains "  offering another go"          "$(row BUTTONS)" "key=Try again"

echo "3f. there is no key at all, which is not a rejection either"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_nokey, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "it says there is none"       "$(row STAGETEXT)" "no AWS access key on this laptop"
contains "  and offers to take one"    "$(row BUTTONS)" "key=Add your key"

echo "3g. a key AWS actually refused still says so"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_rejected, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the old sentence, where it is true" "$(row STAGETEXT)" "AWS rejected this access key"

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
contains "where it runs is unknown" "$(row STAGES)" "where=unknown"
contains "  and says why"           "$(row STAGETEXT)" "could not be checked"
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

echo "4c. everything ready: the pipeline collapses to a line"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
check    "the pipeline is gone"        "$(row ONB)" "ONB | hidden done=shown"
contains "  and names where it runs"   "$(row STAGETEXT)" ""
lacks    "  nothing rescans"           "$(row RAN)" ";; sweep --json"
check    "nothing threw"               "$(row ERRS)" "ERRS | "

echo "4d. a region that cannot rent the machine is not 'ready'"
# An enabled region with no GPU quota looks completely set up and cannot build.
# That is the Malaysia case, and it read as a broken app rather than a step.
OUT=$(probe "{$READY, \"machines --json\": $machines_noquota, \"sweep --cached --json\": $FULL_SWEEP}")
contains "the pipeline stays up"       "$(row ONB)" "ONB | shown"
contains "  with where it runs active" "$(row STAGES)" "where=active"
contains "  naming the region"         "$(row STAGETEXT)" "ap-south-2 cannot rent this machine"
contains "  and the two reasons"       "$(row STAGETEXT)" "no GPU quota there, or none of its machines fit"
contains "  offering the choice"       "$(row BUTTONS)" "where=Choose where"

echo "5. nothing threw"
check "the page logged no errors"   "$(row ERRS)" "ERRS | "

echo ""
echo "startup-gate: $pass passed, $fail failed"
(( fail == 0 ))
