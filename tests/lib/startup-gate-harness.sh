# Shared by tests/startup-gate-*.sh: the page builder (probe), the fake cg, the
# canned answers, and the check helpers. Sourced, not run - it lives outside
# tests/*.sh so that run-all.sh does not treat it as a suite.
#
# The original single file took 79s in CI, 56 browser launches in a row. It is
# five files now, so run-all.sh runs them side by side.
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
[[ -n $BROWSER ]] || { echo "  (no chromium - skipped)"; echo "$GATE_NAME: 0 passed, 0 failed"; exit 0; }

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
    // Games in other places, machines of your own: no case here is about
    // them, so the answer is "none" unless a case says otherwise - an
    // unanswered read holds the gate.
    const reply = window.__answers[line]
      ?? (line === 'library elsewhere --json' ? { error: null, places: [] }
        : line === 'host list --json' ? [] : undefined);
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
  // The steps are the add dialog's now, not a screen of their own: open it on
  // AWS, as Add or Finish setting up does, unless a case is about Home itself.
  if (!window.__noAdd) {
    openAdd('aws');
    for (let i = 0; i < 30; i++) await new Promise(r => setTimeout(r, 2));
    await new Promise(r => setTimeout(r, 200));
  }
  out.push('RAN | ' + window.__ran.join(' ;; '));
  // The pipeline: one row per stage, each carrying its verdict, and the pane
  // beside it carrying cg's own words.
  out.push('ONB | ' + (document.getElementById('adddlg').open ? 'shown' : 'hidden')
           + ' cards=' + (document.getElementById('d-main').hidden ? 'hidden' : 'shown'));
  out.push('TITLE2 | ' + document.getElementById('onb-title').textContent.trim());
  out.push('COUNT | ' + document.getElementById('onb-count').textContent.trim());
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
  // What is on screen, not just the class: a CSS edit once left the class on
  // and the sidebar showing, and the class check passed.
  const shown = sel => { const el = document.querySelector(sel); return el ? getComputedStyle(el).display !== 'none' : 'gone'; };
  out.push('MODE | ' + (document.getElementById('onb-steps').hidden ? 'none' : 'steps')
           + ' setup=' + document.body.classList.contains('setup')
           + ' header=' + shown('body > header') + ' viewbar=' + shown('#viewbar'));
  out.push('AFTER | ' + (window.__after ? await window.__after() : 'none'));
  out.push('BANNER | ' + (document.getElementById('banner') ? 'exists' : 'none'));
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
  "$BROWSER" --headless --disable-gpu --no-sandbox --lang=en-IN --window-size=1280,900 \
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
# a choice anybody made. No AWS machine yet: these cases add one.
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


# Answers shared by more than one file.
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

# A status answer, for the files that draw the dashboard and the Build page.
RATES='"rates": {"s3_gb_month": 0.025, "ebs_gb_month": 0.0912, "snapshot_gb_month": 0.05,
                 "ipv4_hour": 0.005, "inr_per_usd": 88, "fx_inr_per_usd": 88, "ce_call_usd": 0.01}'
st() { # st <box json> <archive json> <res json> <budget json>
  echo "{\"box\": $1, \"session\": null, \"region\": \"ap-south-2\", \"host\": \"laptop\",
         \"instance_type\": \"g6.xlarge\", \"archive\": $2, \"res\": $3, \"budget\": $4,
         \"spec\": {\"gpu\": \"L4\"}, \"tailnet\": {}, \"config\": {\"spot\": \"auto\"},
         \"local\": {}, \"account\": {\"plan\": \"PAID\", \"credits\": 0}, $RATES}"
}

# Every file ends the same way.
gate_finish() {
  echo ""
  echo "$GATE_NAME: $pass passed, $fail failed"
  (( fail == 0 ))
}
