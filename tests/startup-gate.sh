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
window.__answers = {};     // set by the probe before the page loads
window.cg = {
  run: (args) => {
    const line = args.join(' ');
    window.__ran.push(line);
    const id = (window.__lastId = (window.__lastId || 0) + 1);
    const reply = window.__answers[line];
    if (reply !== undefined) {
      // Answer on a later turn, the way a real run does.
      setTimeout(() => {
        window.__emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify(reply) });
        window.__emit(id, { t: 'exit', rc: 0 });
      }, 0);
    }
    return Promise.resolve({ ok: true, id });
  },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
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
  await new Promise(r => setTimeout(r, 500));
  out.push('RAN | ' + window.__ran.join(' ;; '));
  const stage = document.getElementById('stage');
  out.push('STAGE | ' + (stage.open ? 'open' : 'closed'));
  out.push('STAGETITLE | ' + document.getElementById('stage-title').textContent.trim());
  out.push('STAGESUB | ' + document.getElementById('stage-sub').textContent.replace(/\s+/g, ' ').trim());
  out.push('STEPS | ' + [...document.querySelectorAll('#stage-steps [data-step]')]
             .map(r => r.dataset.step + '=' + r.dataset.state).join(','));
  out.push('STEPTEXT | ' + document.getElementById('stage-steps').innerText
             .replace(/\s+/g, ' ').trim());
  out.push('STEPBTNS | ' + [...document.querySelectorAll('#stage-steps [data-step] button')]
             .map(b => b.closest('[data-step]').dataset.step + '=' + b.textContent.trim()).join(','));
  out.push('SKIPLABEL | ' + document.getElementById('stage-skip').textContent.trim());
  out.push('GO | ' + (document.getElementById('stage-go').hidden ? 'hidden'
              : document.getElementById('stage-go').textContent.trim()));
  // Whatever this case wants to try on the dialog as the window left it - see
  // the ENGINE snippets below.
  out.push('AFTER | ' + (window.__after ? await window.__after() : 'none'));
  // A rung's button, taken as a person would: the modal must be out of the way
  // of whatever it leads to, and it must actually lead there.
  const rung = [...document.querySelectorAll('#stage-steps [data-step] button')].pop();
  if (rung) {
    rung.click();
    await new Promise(r => setTimeout(r, 5));
    out.push('RUNGWENT | ' + rung.closest('[data-step]').dataset.step
             + ' stage=' + (stage.open ? 'open' : 'closed')
             + ' view=' + ((document.querySelector('.nav-item.on') || {}).dataset || {}).view);
  } else {
    out.push('RUNGWENT | none');
  }
  if (stage.open) document.getElementById('stage-skip').click();
  out.push('AFTERSKIP | ' + (stage.open ? 'open' : 'closed'));
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
  "$BROWSER" --headless --disable-gpu --no-sandbox --window-size=1280,900 \
    --virtual-time-budget=5000 --dump-dom "file://$T/r/index.html" 2>/dev/null \
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

echo "0. there is no cg at all"
# Without an engine every read fails the same way - a spawn error each - and six
# broken reads is not what happened. One thing did, and only main can see it:
# the renderer has no filesystem.
ENGINE="window.__engine = { repo: '/opt/nope', cg: '/opt/nope/cg', found: false, contract: false };
// Installed while the window was open, and Try again pressed: nothing here
// needs restarting.
window.__after = async () => {
  window.__engine = { repo: '/opt/nope', cg: '/opt/nope/cg', found: true, contract: true };
  document.getElementById('stage-go').click();
  await new Promise(r => setTimeout(r, 20));
  return 'stage=' + (document.getElementById('stage').open ? 'open' : 'closed')
       + ' ran=' + window.__ran.join(' ');
};"
OUT=$(probe "{}")
check    "nothing is asked at all"   "$(row RAN)" "RAN | "
check    "the popup says so"         "$(row STAGE)" "STAGE | open"
contains "  naming the one problem"  "$(row STAGETITLE)" "This app cannot find cg"
contains "  and what cg is"          "$(row STAGESUB)" "this window is a face on it"
contains "  where it looked"         "$(row STEPTEXT)" "/opt/nope/cg"
contains "  and how to fix it"       "$(row STEPTEXT)" "CG_REPO"
contains "  with something to run"   "$(row STEPTEXT)" "git clone"
contains "and there is one thing to do" "$(row GO)" "Try again"
# Installed while the window sat there: Try again starts it, with no restart.
contains "  which starts the reads"   "$(row AFTER)" "deps --json"
contains "  and gets out of the way"  "$(row AFTER)" "stage=closed"
check    "nothing threw"             "$(row ERRS)" "ERRS | "
ENGINE=""

echo "1. a tool is missing: nothing else is asked"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_BAD" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the three reads happen"   "$(row RAN)" "deps --json"
contains "  all three"              "$(row RAN)" "creds tailscale --json"
# The six that need AWS or a tailnet would every one come back unknown.
lacks    "status is not asked"      "$(row RAN)" "status --json"
lacks    "  nor the library"        "$(row RAN)" "library list --json"
lacks    "  nor the machines"       "$(row RAN)" "machines --json"
lacks    "  nor the guards"         "$(row RAN)" "watcher --json"
lacks    "and never cost"           "$(row RAN)" "cost"
check    "the banner is up"         "$(row BANNER)" "BANNER | shown"
# One line, naming them: the old banner spent a sentence saying that some
# tools were missing and another saying which.
contains "  naming them"            "$(row TITLE)"  "AWS CLI v2, Moonlight are not installed"
contains "  and what that means"    "$(row BODY)"   "Nothing here can run without them"
contains "  with somewhere to go"   "$(row FIX)"    "Open Dependencies"
check    "  that goes there"        "$(row WENT)"   "WENT | deps"
# The banner shows the first problem, which is right for one that turns up
# mid-session. On a fresh laptop it means finding out about four jobs one at a
# time, so the window opening shows the whole ladder instead.
check    "the ladder is up"         "$(row STAGE)" "STAGE | open"
contains "  counting the jobs"      "$(row STAGETITLE)" "to do before this can build a box"
contains "  the tools rung first"   "$(row STEPS)" "tools=todo"
# The key cannot be judged with no CLI to ask AWS with, and "AWS rejected this
# key" about a laptop that never asked is a lie.
contains "  the key not yet judged" "$(row STEPS)" "key=unknown"
contains "  saying why"             "$(row STEPTEXT)" "the one above it comes first"
# What is already true is ticked, not left blank: the list is the whole job.
contains "  and what is already done" "$(row STEPS)" "tailnet=done"
contains "each rung carries its button" "$(row STEPBTNS)" "tools=Open Dependencies"
contains "  and the way out is patient" "$(row SKIPLABEL)" "I'll do it later"
# Clicking a rung must get the modal out of the way of the screen it opens.
contains "its button closes the modal" "$(row RUNGWENT)" "stage=closed"

echo "2. tools are there, the key is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
lacks    "still nothing else is asked" "$(row RAN)" "status --json"
contains "it says what is wrong"       "$(row TITLE)" "The AWS CLI is not installed"
contains "  and what that costs"       "$(row BODY)"  "unknown, not empty"
contains "  and the same way out"      "$(row FIX)"   "Open Dependencies"

echo "3. tools and key are there, the tailnet is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" false), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_out, \"config --json\": $cfg_ok}")
lacks    "still nothing else is asked" "$(row RAN)" "status --json"
contains "it says so"                  "$(row TITLE)" "not signed in to Tailscale"
contains "  and why it matters"        "$(row BODY)"  "no public SSH port"
# The sign-in is a button here, not a page to go to: there is one thing to do.
contains "  offering the sign-in"      "$(row FIX)"   "Sign in"

echo "3b. the box has no key to join with"
# This one used to be a dialog in the MIDDLE of a build: fifteen minutes of
# log, then "paste auth key". It is a prerequisite, so it is checked with the
# other prerequisites, before anything launches.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_nokey, \"config --json\": $cfg_ok}")
lacks    "nothing else is asked"       "$(row RAN)" "status --json"
contains "it says what is missing"     "$(row TITLE)" "The box has no Tailscale auth key"
contains "  and what that stops"       "$(row BODY)"  "cannot join it to your tailnet"
contains "  offering to take one"      "$(row FIX)"   "Set auth key"

echo "3c. nowhere to send a billing alert"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_noemail}")
lacks    "nothing else is asked"       "$(row RAN)" "status --json"
contains "it says so"                  "$(row TITLE)" "No address for billing alerts"
contains "  and why a build needs one" "$(row BODY)"  "budget alarm"

echo "3d. the ladder, on a laptop with three things to do"
# The case this step exists for: a fresh install. Tools are there, the key is
# good, and nothing else is - which used to be three separate banners, found one
# at a time, each after fixing the last.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" false), \"creds --json\": $creds_ok,
              \"creds tailscale --json\": $tskey_out, \"config --json\": $cfg_noemail}")
check    "the ladder is up"           "$(row STAGE)" "STAGE | open"
contains "  counting them in words"   "$(row STAGETITLE)" "Three things to do"
contains "  and saying it is free"    "$(row STAGESUB)" "None of it costs anything"
contains "the met rungs are ticked"   "$(row STEPS)" "tools=done"
contains "  including the key"        "$(row STEPS)" "key=done"
contains "the tailnet needs doing"    "$(row STEPS)" "tailnet=todo"
contains "  so does the auth key"     "$(row STEPS)" "authkey=todo"
contains "  so does the address"      "$(row STEPS)" "email=todo"
# Each with the one button that does it, and no shared "go to Settings".
contains "the sign-in is a button"    "$(row STEPBTNS)" "tailnet=Sign in"
contains "  the auth key its own"     "$(row STEPBTNS)" "authkey=Set auth key"
contains "  the address its own"      "$(row STEPBTNS)" "email=Set an address"
# cg's sentence for each, not a new one invented here.
contains "and each says what it costs you" "$(row STEPTEXT)" "no public SSH port"
contains "  in cg's words"            "$(row STEPTEXT)" "budget alarm"
# The last rung's button, clicked: the modal goes, and the window is left on
# the screen that sets the thing.
contains "a rung gets out of its own way" "$(row RUNGWENT)" "email stage=closed"
contains "  and lands on the settings"    "$(row RUNGWENT)" "view=settings"
check    "nothing threw"              "$(row ERRS)" "ERRS | "

echo "3e. the laptop could not reach AWS, which is not the key's fault"
# It used to say "AWS rejected this access key" to a laptop with no network -
# a lie about a call that never arrived, and it sent people to replace a key
# that was fine. cg says which it was; this only reads it.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_offline,
              \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "it says the call never arrived" "$(row TITLE)" "could not reach AWS"
lacks    "  and blames nothing"           "$(row TITLE)" "rejected"
contains "  saying the key may be fine"   "$(row BODY)"  "The key may be fine"
# Nothing to retype: the one thing that helps is doing it again.
contains "  offering another go"          "$(row FIX)"   "Try again"
contains "  on the ladder too"            "$(row STEPTEXT)" "could not reach AWS"

echo "3f. there is no key at all, which is not a rejection either"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_nokey,
              \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "it says there is none"          "$(row TITLE)" "no AWS access key on this laptop"
lacks    "  not that one was refused"     "$(row TITLE)" "rejected"
contains "  and offers to take one"       "$(row FIX)"   "Set AWS key"

echo "3g. a key AWS actually refused still says so"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_rejected,
              \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "the old sentence, where it is true" "$(row TITLE)" "AWS rejected this access key"
contains "  and the old button"               "$(row FIX)"   "Set AWS key"

echo "4. everything is ready: the rest goes at once"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "status is asked"          "$(row RAN)" "status --json"
contains "  the guards"             "$(row RAN)" "watcher --json"
contains "  the library"            "$(row RAN)" "library list --json"
contains "  the machines"           "$(row RAN)" "machines --json"
# The remembered scan, never a fresh one: a scan takes 90 seconds.
contains "  and the cached sweep"   "$(row RAN)" "sweep --cached --json"
lacks    "cost is never automatic"  "$(row RAN)" "cost"
check    "no banner"                "$(row BANNER)" "BANNER | hidden"
# Nothing answers those five here, so the popup is still up listing them -
# which is the shape of a laptop whose network has gone.
contains "the popup lists both batches" "$(row STEPS)" "deps=done"
contains "  including what it waits on" "$(row STEPS)" "machines=doing"

echo "4b. a laptop that has never scanned scans itself, once"
# One region in the table - the one .env names - reads as "where did the other
# regions go", and the answer was a button somewhere else on the screen. The
# scan is free, so a window with no remembered scan starts one itself. It is
# never awaited: nothing on screen waits for it.
#
# No answer is given for `sweep --json` here, so it stays in flight and the
# table can be caught saying what it is waiting for.
READY="\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok,
       \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok,
       \"status --json\": {\"box\": null, \"session\": null, \"region\": \"ap-south-2\",
         \"host\": \"laptop\", \"instance_type\": \"g6.xlarge\", \"archive\": null,
         \"budget\": null, \"tailnet\": {}, \"config\": {\"spot\": \"auto\"},
         \"local\": {\"tailscale\": true, \"moonlight\": true, \"ssh_key\": true, \"auth_key\": true},
         \"account\": {\"plan\": \"PAID\", \"credits\": 0}},
       \"watcher --json\": {\"guards\": []},
       \"library list --json\": {\"games\": [], \"bucket\": \"b\", \"total_bytes\": 0},
       \"machines --json\": {\"region\": \"ap-south-2\", \"inr_per_usd\": 88, \"machines\":
         [{\"type\": \"g6.xlarge\", \"gpu\": \"L4\", \"vram_gib\": 22.4,
           \"fits_spot\": true, \"fits_ondemand\": true,
           \"inr_hour_spot\": 16, \"inr_hour_ondemand\": 85}]}"
EMPTY_SWEEP='{"cached": false, "regions": [], "too_far": [], "unreachable": []}'
FULL_SWEEP='{"cached": true, "age_seconds": 90, "too_far": [], "unreachable": [],
             "regions": [{"region": "ap-south-2", "city": "Asia Pacific (Hyderabad)",
                          "rtt_ms": 19, "enabled": true, "machines": []}]}'
OUT=$(probe "{$READY, \"sweep --cached --json\": $EMPTY_SWEEP}")
contains "the remembered scan is read first" "$(row RAN)" "sweep --cached --json"
contains "  and a real scan follows it"      "$(row RAN)" "sweep --json"
# Said by the table, not only by the button: the button is at the top of a long
# screen and the question is asked at the table.
contains "the table says what it waits for" "$(row LEGEND)" "scanning every region now - about 90 seconds"
contains "  and which region it has"        "$(row LEGEND)" "This is ap-south-2 until it lands"
contains "  while the button agrees"        "$(row SCANBTN)" "scanning all regions"
check    "and nothing threw"                "$(row ERRS)" "ERRS | "

echo "4c. a laptop that HAS scanned is left alone"
# However old. A remembered scan is what Rescan is for, and scanning on every
# open would be 90 seconds of work nobody asked for.
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
contains "the remembered scan is read" "$(row RAN)" "sweep --cached --json"
lacks    "  and nothing rescans"       "$(row RAN)" ";; sweep --json"
contains "  the button is idle"        "$(row SCANBTN)" "Scan all regions"
# The one that matters most: every read came back inside the popup's delay, so
# it was never shown at all. A modal that appears and vanishes again is worse
# than no modal, and this is the common case - every open after the first.
check    "and the popup never appeared" "$(row STAGE)" "STAGE | closed"
# It was being filled in all the same, so a laptop that IS slow has a list.
contains "  though it tracked the reads" "$(row STEPS)" "deps=done"
contains "  both batches of them"        "$(row STEPS)" "sweep=done"
lacks    "  with nothing left hanging"   "$(row STEPS)" "=doing"

echo "4d. a read that does not come back: the popup says what it is waiting for"
# `cg library list` is left unanswered, as it is on a laptop where S3 is slow or
# the network has gone. Past the delay, the popup is up and names the step in a
# person's words - not "running: cg library".
OUT=$(probe "{${READY/'library list --json'/'library list --unanswered'}, \"sweep --cached --json\": $FULL_SWEEP}")
check    "the popup is up"            "$(row STAGE)" "STAGE | open"
contains "  with a plain title"       "$(row STAGETITLE)" "Getting your rig ready"
contains "  saying it is free"        "$(row STAGESUB)" "None of it costs anything"
contains "  the slow read still going" "$(row STEPS)" "library=doing"
contains "  the rest ticked off"      "$(row STEPS)" "status=done"
# cg's words are what the header is for. This is the other audience.
contains "  in words, not commands"  "$(row STEPTEXT)" "Reading your game archive"
lacks    "  naming no commands"      "$(row STEPTEXT)" "cg "
# Skip, not Cancel: the reads carry on, the window behind this one works.
check    "  and Skip closes it"      "$(row AFTERSKIP)" "AFTERSKIP | closed"

echo "4e. a read that cannot be painted is a failure, not a tick"
# It answered, so the step is not "still going"; the painter threw, so it is not
# "done" either. The popup used to be the only place this showed at all: the
# header's failure line is overwritten by whatever read finishes next.
#
# This stub sends a status with no `local` block, which is what took the whole
# status paint down - and what this test's own stub did, unnoticed, until the
# popup started reporting each read's verdict.
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP,
              \"library list --json\": {\"games\": [], \"bucket\": \"b\", \"total_bytes\": 0},
              \"status --json\": {\"box\": null, \"session\": null}}")
contains "the step says it failed"   "$(row STEPS)" "status=fail"
lacks    "  and not that it is done" "$(row STEPS)" "status=done"
contains "  the rest are fine"       "$(row STEPS)" "machines=done"

echo "5. nothing threw"
check "the page logged no errors"   "$(row ERRS)" "ERRS | "

echo ""
echo "startup-gate: $pass passed, $fail failed"
(( fail == 0 ))
