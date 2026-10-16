#!/usr/bin/env bash
# Turning a region on.
#
# The opposite of a quota: no case, no person, one call - and AWS works through
# DISABLED -> ENABLING -> ENABLED over a few minutes. What it needs instead is
# care. It is an ACCOUNT-level change, and undoing it is slower than doing it,
# so it is asked about rather than done quietly, and it is watched rather than
# assumed - "asked AWS" is not "the region works".
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home" "$T/repo"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
for b in bash sh env grep sed awk python3 cat cut tr sort head tail date stat \
         mktemp rm mv cp chmod id uname dirname basename readlink wc find \
         mkdir tee touch timeout; do
  p=$(command -v "$b") && ln -sf "$p" "$T/bin/$b"
done
# sleep, faked: region_enable waits ten seconds between looks, and a test that
# honours that takes a minute to say what it could say instantly.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"

# The Account API. STATUSES is a list of statuses the region reports on
# successive calls, so a test can watch it move.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "${AWS_LOG:-/dev/null}"
# What the real CLI accepts, and nothing else. `aws account list-regions` has no
# --region-names, and a fake that answered it anyway is why a call that could
# never work passed every assertion in this file.
for a in "$@"; do
  case $a in
    --*) case $a in
           --max-results|--query|--output|--region-name|--region-opt-status-contains) ;;
           *) echo "aws: [ERROR]: Unknown options: $a" >&2; exit 252 ;;
         esac ;;
  esac
done
case "$*" in
  *"get-region-opt-status"*)
    n=$(wc -l < "${TICK:-/dev/null}" 2>/dev/null || echo 0)
    echo "$n" >> "${TICK:?}"
    set -- ${STATUSES-DISABLED}
    [[ $# -eq 0 ]] && exit 0          # AWS knows no such region
    idx=$(( n + 1 )); [[ $idx -gt $# ]] && idx=$#
    eval "printf '%s\n' \"\${$idx}\"" ;;
  *"list-regions"*)
    printf 'af-south-1\tDISABLED\nap-east-1\tDISABLED\nap-south-1\tENABLED_BY_DEFAULT\nap-south-2\tENABLED\nap-southeast-5\t%s\n' "${LIST_AP5:-DISABLED}" ;;
  *"enable-region"*)
    if [[ -n ${ENABLE_FAIL:-} ]]; then
      echo "An error occurred (${ENABLE_FAIL}) when calling the EnableRegion operation: no." >&2
      exit 254
    fi ;;
esac
exit 0
FAKE
chmod +x "$T/bin/aws"

cg_() {
  # shellcheck disable=SC2086
  ( cd "$T/repo" && env -i CG_INR_PER_USD=88 PATH="$T/bin" HOME="$T/home" CG_COLOR=never \
      AWS_LOG="$T/awslog" TICK="$T/tick" STATUSES="${STATUSES-DISABLED}" \
      LIST_AP5="${LIST_AP5:-DISABLED}" ENABLE_FAIL="${ENABLE_FAIL:-}" \
      GAME_REGION=ap-south-1 ${EXTRA:-} bash ./cg "$@" 2>&1 )
}
fresh() { rm -f "$T/awslog" "$T/tick"; touch "$T/tick"; }

echo "1. which regions this account may use"
fresh
j=$(cg_ regions optin --json)
check    "it is valid JSON"           "$(python3 -I -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$j")" "yes"
check    "  disabled ones are listed" "$(python3 -I -c 'import json,sys;print(",".join(json.load(sys.stdin)["disabled"]))' <<<"$j")" "af-south-1,ap-east-1,ap-southeast-5"
# describe-regions only lists what is already on, which is the opposite of what
# this question is about.
contains "it asks the Account API"    "$(cat "$T/awslog")" "account list-regions"
# The call for ONE region is its own API. list-regions has no --region-names,
# and asking for one that way fails as "no such region" - which reads as AWS
# not having the region at all.
contains "one region has its own call" "$(cat lib/sweep.sh)" "get-region-opt-status --region-name"
lacks    "  and not a filter that does not exist" "$(cat lib/sweep.sh)" "list-regions --region-names"
lacks    "  not describe-regions"     "$(cat "$T/awslog")" "describe-regions"
out=$(cg_ regions optin)
contains "the human view counts the enabled ones" "$out" "enabled: 2"
contains "  and names the rest"       "$out" "ap-southeast-5   disabled"

echo "2. enabling one"
fresh
out=$(STATUSES="DISABLED ENABLING ENABLED" cg_ regions enable ap-southeast-5)
contains "it says what it is doing"   "$out" "enabling ap-southeast-5"
# Said before it happens, not after: it is account-wide and slow to undo.
contains "  that it is account-level" "$out" "account-level change"
contains "  and slow to undo"         "$out" "slower than turning it on"
contains "the call is made"           "$(cat "$T/awslog")" "account enable-region --region-name ap-southeast-5"
contains "it waits for AWS"           "$out" "still enabling"
contains "  and confirms the end"     "$out" "ap-southeast-5 is enabled"

echo "3. one that is already on"
fresh
out=$(STATUSES="ENABLED" cg_ regions enable ap-southeast-5)
contains "it says so"                 "$out" "already enabled"
lacks    "  and asks nothing"         "$(cat "$T/awslog")" "enable-region"

echo "4. one that is already on its way"
fresh
out=$(STATUSES="ENABLING ENABLING ENABLED" cg_ regions enable ap-southeast-5)
contains "it does not ask twice"      "$out" "already being enabled"
lacks    "  no second call"           "$(cat "$T/awslog")" "enable-region"
contains "  but it still watches"     "$out" "is enabled"

echo "5. a region AWS has never heard of"
fresh
out=$(STATUSES="" cg_ regions enable xx-nowhere-1; echo "rc=$?")
contains "it says so"                 "$out" "does not list a region called xx-nowhere-1"
contains "  and fails"                "$out" "rc=1"
lacks    "  without calling enable"   "$(cat "$T/awslog")" "enable-region"

echo "6. the two refusals worth naming"
fresh
out=$(ENABLE_FAIL=AccessDeniedException cg_ regions enable ap-southeast-5; echo "rc=$?")
contains "AWS's refusal is quoted"    "$out" "AWS refused"
contains "  and the permission named" "$out" "account:EnableRegion"
contains "  and it fails"             "$out" "rc=1"
fresh
out=$(ENABLE_FAIL=OrganizationNotEmptyException cg_ regions enable ap-southeast-5)
contains "an Organization is named too" "$out" "only the management account"

echo "7. still enabling when the watch runs out"
fresh
out=$(STATUSES="DISABLED ENABLING ENABLING ENABLING ENABLING ENABLING ENABLING ENABLING" \
      cg_ regions enable ap-southeast-5; echo "rc=$?")
# Minutes, not seconds: an unfinished enable is not a failure, and saying so is
# the difference between waiting and retrying.
contains "it says it is still going"  "$out" "still enabling - this is normal"
contains "  and how to look again"    "$out" "cg regions optin"
contains "  without failing"          "$out" "rc=0"

echo "8. wired in"
contains "cg dispatches optin"        "$(cat cg)" "optin)   shift"
contains "  and enable"               "$(cat cg)" "enable)  shift"
contains "  and help names both"      "$(cat cg)" "cg regions [optin|enable <r>]"
js=$(cat app/renderer/app.js)
contains "the app offers it"          "$js" "Switch on a location"
contains "  reads the list"           "$js" "'regions', 'optin', '--json'"
contains "  and runs cg to enable"    "$js" "'regions', 'enable'"
# The sweep's own numbers next to each candidate: a bare region code is a
# guess, "Malaysia, 48ms, 9/10" is a decision.
contains "  with latency and capacity" "$js" "at \${best.score}/10"

echo "9. a region that is already on, in the dialog that enables them"
# "I enabled Malaysia and the table still will not let me pick it" was asked
# three times. The dialog listed only DISABLED regions, so the one you had just
# enabled was absent - and nothing to enable looks exactly like nothing
# happened. The real blocker was quota, which no screen said.
BROWSER=""
for b in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$b" >/dev/null && { BROWSER=$b; break; }
done
if [[ -z $BROWSER ]]; then
  echo "  (no chromium - skipped)"
else
  R=$T/r; mkdir -p "$R"
  cp app/renderer/index.html app/renderer/app.js "$R/"
  cp app/renderer/*.css "$R/"; cp -r app/renderer/fonts "$R/" 2>/dev/null || true
  cat > "$R/stub.js" <<'STUB'
window.__errs = [];
addEventListener('error', e => window.__errs.push(e.message));
addEventListener('unhandledrejection', e => window.__errs.push('reject: ' + e.reason));
// Only `cg regions optin --json` is asked for here, and this is cg's answer:
// Malaysia ENABLED, Jakarta DISABLED, Mumbai on by default.
window.cg = {
  run: args => {
    const id = 1;
    if (args.join(' ') === 'regions optin --json') setTimeout(() => {
      window.__emit(id, { t: 'raw', stream: 'stdout', text: JSON.stringify({
        regions: [
          { region: 'ap-south-1', status: 'ENABLED_BY_DEFAULT' },
          { region: 'ap-southeast-5', status: 'ENABLED' },
          { region: 'ap-southeast-3', status: 'DISABLED' },
          { region: 'me-south-1', status: 'DISABLED' },
        ],
        disabled: ['ap-southeast-3', 'me-south-1'], enabling: [],
      }) });
      window.__emit(id, { t: 'exit', rc: 0 });
    }, 0);
    return Promise.resolve({ ok: true, id });
  },
  answer: () => Promise.resolve(true), cancel: () => Promise.resolve(true),
  busy: () => Promise.resolve([]), asks: () => Promise.resolve([]),
  onEvent(cb) { window.__emit = (id, event) => cb({ id, event }); return () => {}; },
};
STUB
  # The sweep as it really comes back for Malaysia: measured, enabled, one
  # machine offered, and both G quotas at zero.
  cat > "$R/probe.js" <<'PROBE'
(async () => {
  const out = [];
  const sleep = (n = 20) => new Promise(r => setTimeout(r, n));
  try {
    paintSweep({ cached: true, age_seconds: 30, too_far: [], unreachable: [], regions: [
      { region: 'ap-southeast-5', city: 'Asia Pacific (Malaysia)', rtt_ms: 48.2,
        enabled: true, optin: 'opted-in', quota: { ondemand_vcpu: 0, spot_vcpu: 0 },
        machines: [{ type: 'g6.xlarge', score: 9, gpu: 'L4', offered: true,
                     fits_spot: false, fits_ondemand: false }] },
      { region: 'ap-southeast-3', city: 'Asia Pacific (Jakarta)', rtt_ms: 57.7,
        enabled: false, machines: [{ type: 'g5.xlarge', score: 1, gpu: 'A10G',
                                     fits_spot: false, fits_ondemand: false }] },
    ] });
    await openOptin();
    for (let i = 0; i < 8; i++) await sleep();
    const sel = document.getElementById('optin-pick');
    out.push('GROUPS | ' + [...sel.querySelectorAll('optgroup')].map(g => g.label).join(' / '));
    for (const g of sel.querySelectorAll('optgroup'))
      out.push('IN ' + g.label.toUpperCase() + ' | '
               + [...g.children].map(o => o.textContent.trim()).join(' ;; '));
    sel.value = 'ap-southeast-5';
    sel.onchange();
    for (let i = 0; i < 6; i++) await sleep();
    out.push('ON STATE | ' + document.getElementById('optin-state').textContent.trim());
    out.push('ON BODY | ' + document.getElementById('optin-log').textContent.replace(/\s+/g, ' ').trim());
    out.push('ON BTN | go=' + document.getElementById('optin-go').hidden
             + '/' + document.getElementById('optin-go').disabled);
    sel.value = 'ap-southeast-3';
    sel.onchange();
    for (let i = 0; i < 6; i++) await sleep();
    out.push('OFF STATE | ' + document.getElementById('optin-state').textContent.trim());
    out.push('OFF BTN | go=' + document.getElementById('optin-go').hidden
             + '/' + document.getElementById('optin-go').disabled);
  } catch (e) { out.push('THREW | ' + e.message); }
  out.push('ERRS | ' + window.__errs.join(' ;; '));
  const pre = document.createElement('pre');
  pre.id = 'probe-out'; pre.textContent = out.join('\n');
  document.body.append(pre);
})();
PROBE
  python3 -I - "$R" <<'WIRE'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "index.html"
t = p.read_text()
t = t.replace('<script src="app.js"', '<script src="stub.js"></script>\n<script src="app.js"', 1)
t = t.replace('</body>', '<script src="probe.js"></script>\n</body>', 1)
p.write_text(t)
WIRE
  # Written to a file and then catted, rather than piped straight into python:
  # chromium's main process exits as soon as the DOM is dumped, but a child of
  # it keeps the write end of a pipe open for another 10-25 SECONDS, and
  # sys.stdin.read() waits for EOF. That idle wait, once per page load, was the
  # whole cost of this suite - minutes of it, at 0.5s of actual work per load.
  OUT=$("$BROWSER" --headless --disable-gpu --no-sandbox --window-size=1280,900 \
          --virtual-time-budget=6000 --dump-dom "file://$R/index.html" > "$R/dom.html" 2>/dev/null
        cat "$R/dom.html" \
        | python3 -I -c '
import sys, re, html
m = re.search(r"<pre id=\"probe-out\">(.*?)</pre>", sys.stdin.read(), re.S)
print(html.unescape(m.group(1)) if m else "NO PROBE OUTPUT")')
  lacks    "nothing threw"                  "$OUT" "THREW"
  check    "  and no uncaught error"        "$(sed -n 's/^ERRS | //p' <<<"$OUT")" ""
  contains "the list is in two groups"      "$OUT" "GROUPS | Not on yet / Already on"
  contains "  the measured candidate first" "$OUT" "IN NOT ON YET | ap-southeast-3 - Jakarta, 58ms, g5.xlarge at 1/10"
  contains "  and the bare ones after"      "$OUT" "me-south-1"
  # The one people go looking for, which used to be absent entirely.
  contains "an enabled region is listed"    "$OUT" "IN ALREADY ON | ap-southeast-5 - Malaysia, 48ms, g6.xlarge at 9/10"
  # Enabled by default and never scanned: listing a dozen of those would bury it.
  lacks    "  but not every default one"    "$OUT" "ap-south-1 -"
  contains "picking it says it is on"       "$OUT" "ON STATE | ● enabled"
  contains "  and names the real blocker"   "$OUT" "What stops it being picked is the GPU limit"
  contains "  with both quotas"             "$OUT" "on demand 0 vCPU spot 0 vCPU"
  contains "  and where to ask"             "$OUT" "Ask AWS for a higher GPU limit"
  check    "  with nothing to confirm"      "$(sed -n 's/^ON BTN | //p' <<<"$OUT")" "go=true/true"
  contains "a disabled one still enables"   "$OUT" "OFF STATE | ap-southeast-3 · Jakarta · 58ms"
  check    "  and Confirm is live"          "$(sed -n 's/^OFF BTN | //p' <<<"$OUT")" "go=false/false"
fi

echo ""
echo "region-optin: $pass passed, $fail failed"
(( fail == 0 ))
