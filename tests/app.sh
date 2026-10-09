#!/usr/bin/env bash
# The desktop app: its runner, and the rules that keep it a viewer.
#
# The app must never grow AWS logic - the moment it does, there are two sources
# of truth and the scripts stop being the one that matters. These checks are
# cheap and they are the reason that rule holds.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

if [[ ! -d app/node_modules ]]; then
  echo "  SKIP - app dependencies are not installed (cd app && npm install)"; exit 0
fi
command -v node >/dev/null || { echo "  SKIP - node is not installed"; exit 0; }

echo "1. the runner, against a fake cg"
# TAP, because its "# fail 0" line is the one thing worth grepping for.
out=$(cd app && node --test --test-reporter=tap test/*.test.mjs 2>&1)
if grep -qE '^# fail 0' <<<"$out"; then
  n=$(grep -cE '^ok [0-9]+' <<<"$out")
  echo "  ok   node tests pass ($n)"; pass=$((pass+1))
else
  echo "  FAIL node tests"; sed -n '1,25p' <<<"$out" | sed 's/^/      /'; fail=$((fail+1))
fi

echo "2. the app holds no AWS logic"
# No SDK, no bucket names, no keys, no prices: it asks cg and renders the answer.
hits=$(grep -rniE 'aws-sdk|@aws-sdk|boto3|cg-library-|AKIA[0-9A-Z]{8}|s3\.amazonaws' \
         app/main app/renderer app/package.json 2>/dev/null | wc -l)
check "no AWS SDK or identifiers"        "$hits" "0"
check "  and no AWS dependency"          "$(node -e 'const p=require("./app/package.json");console.log(Object.keys({...p.dependencies,...p.devDependencies}).filter(d=>/aws/i.test(d)).length)')" "0"
check "the renderer never spawns anything" "$(grep -rc 'child_process' app/renderer 2>/dev/null | grep -vc ':0')" "0"

echo "3. the window is locked down"
main=$(cat app/main/index.js); js=$(cat app/renderer/app.js); html=$(cat app/renderer/index.html)
# The hand-written stylesheet, not the Tailwind build: component rules live here.
css=$(cat app/renderer/src.css)
contains "context isolation"             "$main" "contextIsolation: true"
contains "no node in the renderer"       "$main" "nodeIntegration: false"
contains "sandboxed"                     "$main" "sandbox: true"
contains "no new windows"                "$main" "setWindowOpenHandler"
contains "no navigation away"            "$main" "will-navigate"
contains "no File/Edit/View menu"        "$main" "Menu.setApplicationMenu(null)"
contains "a content security policy"     "$(cat app/renderer/index.html)" "Content-Security-Policy"

echo "3b. the Stitch design, vendored - nothing is fetched at runtime"
# What matters is that nothing is FETCHED remotely; the generated stylesheet
# carries tailwindcss.com in its banner comment, which loads nothing.
check "nothing is loaded from the network" \
      "$(grep -rhoE '(href|src)="https?://|url\(https?://' app/renderer/*.html app/renderer/*.js app/renderer/*.css app/renderer/fonts/fonts.css | wc -l)" "0"
check "tailwind is built from their config" "$(grep -c 'tailwind.config' app/tailwind.config.js)" "1"
check "  and the stylesheet is committed" "$([[ -s app/renderer/tailwind.css ]] && echo yes || echo no)" "yes"
check "the fonts are local"              "$([[ -s app/renderer/fonts/fonts.css ]] && echo yes || echo no)" "yes"
check "  with no CDN left in them"       "$(grep -c 'https://' app/renderer/fonts/fonts.css)" "0"
contains "the icon font is wired up"     "$(cat app/renderer/src.css)" "Material Symbols Outlined"
# Google's icon subsetting drops the ligatures, so writing an icon's NAME in the
# markup renders the word: "dashboardDashboard" in the sidebar. Icons are
# addressed by codepoint, with the name kept in data-icon for readability.
check "no icon is written as its name"   "$(grep -c 'material-symbols-outlined[^>]*>[a-z_]\+<' app/renderer/index.html app/renderer/app.js | grep -vc ':0')" "0"
if python3 -c 'import fontTools, brotli' 2>/dev/null; then
  check "every codepoint exists in the vendored font" "$(python3 - <<'PY'
import re
from fontTools.ttLib import TTFont
# The markup writes &#xe871; and the renderer writes "\ue8f4" - check both, or an
# icon built in JavaScript can point at a glyph the subset does not carry.
text = open("app/renderer/index.html").read() + open("app/renderer/app.js").read()
codes = set(re.findall(r'&#x([0-9a-f]{4});', text)) | set(re.findall(r'\\u(e[0-9a-f]{3})', text))
cmap = TTFont("app/renderer/fonts/msym-1.woff2").getBestCmap()
print(len([c for c in codes if int(c, 16) not in cmap]))
PY
)" "0"
else
  echo "  SKIP - fontTools not installed, cannot verify the glyphs"
fi
# .btn sets display, which beat the browser's [hidden] rule: Stop, Play and
# Destroy stayed visible after they were hidden.
contains "hidden beats a display class"  "$(cat app/renderer/src.css)" "[hidden] { display: none !important; }"

echo "4. the promises the app makes about cost and safety"
contains "cg is run with CG_JSON=1"      "$(cat app/main/runner.js)" "CG_JSON: '1'"
# Reads are independent, so they run together; anything that changes something
# runs alone, because cg takes its own locks.
contains "reads may run together"        "$main" "const READ_ONLY = new Set("
contains "  a write waits for everything" "$main" "[...jobs.values()][0]"
contains "  and a read waits only for a write" "$main" "find(j => !j.readOnly)"
# config was missing from that set, so the Settings screen was refused at startup
# while the other reads ran, and stayed empty.
contains "  config counts as a read"     "$main" "'games', 'config'"
# `machines` reads describe-* and the Pricing API: free, and it launches nothing,
# so the picker must not be refused while the other reads are in flight.
contains "  so does machines"             "$main" "'config', 'machines']"
contains "quitting mid-run asks first"   "$main" "before-quit"
contains "the cost refresh carries its price" "$(tr -s ' ' < app/renderer/index.html)" 'id="refresh-cost"'
contains "  shown only on the cost screen" "$js" "refresh-cost').hidden = view !== 'cost'"
check    "nothing is on a timer"             "$(grep -c 'setInterval\|setTimeout' app/renderer/app.js)" "0"
# Two buttons fetch cost - the Cost tab's Refresh and the dashboard's Fetch -
# and both say the price. Nothing else may run it.
check    "  and cost runs only from a button" \
         "$(grep -c "runCg(\['cost', '--json'\]" app/renderer/app.js)" "2"
contains "  never on opening the tab"    "$js" "Cost is not in NEEDS"
contains "the dashboard reads fields, not tables" "$(cat app/renderer/app.js)" "dashboard: [[['status', '--json']"

echo "5. the screens, and what each reads"
for v in dashboard build library guards cost settings logs; do
  contains "a $v screen"                 "$html" "data-view=\"$v\""
done
contains "the dashboard reads status"    "$js" "dashboard: [[['status', '--json']"
contains "the library reads its index"   "$js" "library:   [[['library', 'list', '--json']"
contains "the guards read the watcher"   "$js" "guards:    [[['watcher', '--json']"
contains "a screen's reads go together"  "$js" "await Promise.all(need.map("
contains "every free read fires on open" "$js" "function refreshAll()"
contains "  and cost is not one of them" "$js" "it waits for its button"
contains "  and load when it is opened"  "$js" "if (NEEDS[view] && !loaded.has(view)) refresh()"
contains "refresh is per screen"         "$js" "const need = NEEDS[view]"
contains "stop belongs to the screen that started the run" "$js" "j.view === view"
# A tab's button answers for that tab: only a build or destroy, which cg runs
# alone, disables anything elsewhere.
contains "only a write blocks a read"    "$js" "const WRITES = new Set(['init', 'destroy', 'open'])"
contains "  refresh waits for a write only" "$js" 'refresh'"'"').disabled = busy'
contains "  writes wait for everything"  "$js" '$(b).disabled = jobs.size > 0'
# Single quotes: a needle in double quotes runs $(...) as a command, which made
# this assertion pass against nothing at all.
contains "  and takes refresh's place while it runs" "$js" "|| !!mine.length"
contains "stop says what it stops"       "$js" 'Stop ${hereNames[0]}'
# status + watcher are one refresh to the person looking at the dashboard.
contains "  counting actions, not commands" "$js" "hereNames.length === 1"
contains "only a long run is worth pointing at" "$js" "const WATCHABLE = new Set(['init', 'destroy', 'open'])"
contains "  which the pointer uses"      "$js" 'running - show it'
check    "every icon carries its name"   "$(python3 - <<'PY'
import re
html = open("app/renderer/index.html").read()
spans = re.findall(r'<span class="material-symbols-outlined[^>]*>', html)
print(sum(1 for s in spans if 'data-icon=' not in s))
PY
)" "0"
contains "  and hidden where it means nothing" "$js" "(!NEEDS[view] && view !== 'cost')" 
contains "cost reads the same one call"  "$js" "runCg(['cost', '--json']"
check    "no button is left mid-page"    "$(grep -c 'cost-run' app/renderer/index.html app/renderer/app.js | grep -vc ':0')" "0"

echo "5b. the build screen, as the design draws it"
# The archive table, the allocation bar and the machine strip are the parts the
# mockup has; each is fed by a field from cg, never by a number typed in here.
contains "an archive table"              "$html" 'id="b-games"'
contains "  with the appid"              "$js" 'appid ${g.appid}' 
contains "  and when it was archived"    "$js" "daysAgo(g.pushed)"
contains "the allocation bar"            "$html" 'id="b-bar"'
contains "  says what is left"           "$js" "buffer remaining"
contains "the machine comes from cg"     "$js" "const spec = s.spec || {}"
check    "  with no type hardcoded"      "$(grep -c 'g6\.xlarge\|L4\|16 GiB' app/renderer/app.js)" "0"
contains "  and the chip names the purchase model" "$js" "on demand' : spot === '1'"
contains "steps are numbered"            "$js" "String(buildSteps).padStart(2, '0')"
contains "  and carry how long they took" "$js" "function buildStepEnd(event)"
contains "  the live line shows in the strip" "$js" "\$('b-prog-step').textContent = event.text"
# A box that is already up cannot be built again - cg would refuse, so the
# screen offers what you can actually do with it instead.
contains "a running box replaces the build button" "$js" '$('"'"'b-build'"'"').hidden = up'
contains "  with play and destroy"       "$js" '$('"'"'b-destroy'"'"').hidden = !up'
contains "  and the picker goes read-only" "$js" "box.disabled = up"
contains "  build re-reads the box state" "$js" "[['status', '--json'], 'status']],"
# The panel sits in a content-sized grid row, so flex-1 had no height to divide
# and the log grew forever instead of scrolling. It is bounded.
contains "the log is bounded and scrolls" "$html" 'max-h-[46vh] overflow-y-auto'
# Progress used to live in the right panel: a step list that grew beside a log
# that grew, which stretched the grid row and made the whole page taller than
# the window on every build. One strip across the top, one bounded transcript.
contains "progress is a strip above both columns" "$html" 'id="b-strip"'
contains "  with a bar"                   "$html" 'id="b-prog"'
contains "  the step number and elapsed"  "$js" "\$('b-strip-meta').textContent"
contains "  and the line cg is on now"    "$html" 'id="b-prog-step"'
contains "steps are headings in the transcript" "$js" "head.className = 'step flex items-baseline"
check    "  so there is no second list to grow" \
         "$(grep -c 'b-steps' app/renderer/app.js app/renderer/index.html | awk -F: '{s+=$2} END{print s}')" "0"
# The bar is time against the estimate, not steps done: cg never says how many
# steps a run has, so a fraction built from the ones seen so far would go
# backwards the moment another arrived.
contains "the bar measures time, not steps" "$js" "const RUN_EXPECT = { init: 20 }"
contains "  and a run with no estimate does not pretend" "$js" "animate-pulse"
contains "  nor does it reach full before the end" "$js" "Math.min(95"
contains "the log follows only if asked" "$js" '$('"'"'b-follow'"'"').checked' 
check    "  and it is still not a timer" "$(grep -c 'setInterval' app/renderer/app.js)" "0"
# A failed build used to report itself as the words "stopped (exit 1)" in a
# small label, with the actual AWS error somewhere in a 200-line auto-scrolling
# log that had already moved past it. cg marks the headline as `fail`; the panel
# keeps that and everything under it until the next step.
contains "a failure gets its own panel"    "$html" 'id="b-error"'
contains "  hidden until something fails"  "$html" 'class="hidden font-code-sm'
# It lives in the strip, taking the BAR's place: a bar frozen at 35% says
# nothing, and in the right-hand panel the reason sat under a 200-line
# auto-scrolling log that had already moved past it.
check    "  and sits in the strip, not the panel" \
         "$(awk '/id="b-strip"/{s=NR} /id="b-error"/{e=NR} /id="b-log"/{l=NR} END{print (s && e && l && s < e && e < l) ? "yes" : "no"}' app/renderer/index.html)" "yes"
contains "  the bar gives way to it"       "$js" "\$('b-bar-track').hidden = true"
contains "  and comes back on the next run" "$js" "\$('b-bar-track').hidden = false"
contains "  a failed run paints no full bar" "$js" "if (buildFailures.length) return;"
# A fixed "launch failed" heading sat directly above cg's own "launch failed:
# InsufficientInstanceCapacity", which read as the same sentence twice.
contains "  the strip's own heading names the phase" "$js" 'RUN_TITLE[runKind] || RUN_TITLE.init} stopped'
check    "  with no second heading under it" \
         "$(grep -c 'b-error-title' app/renderer/app.js app/renderer/index.html | awk -F: '{s+=$2} END{print s}')" "0"
contains "  fed by the lines cg marked"    "$js" "if (event.kind === 'fail') { buildFailing = true;"
contains "  and the report under them"     "$js" "else if (buildFailing && event.t === 'line')"
contains "  an error event lands there too" "$js" "if (event.t === 'error') buildFail(event.text)"
contains "  a nonzero exit is never silent" "$js" 'exited ${event.rc} without saying why'
contains "  and the next run clears it"    "$js" "buildFailClear();"

# The machine picker. Its whole point is that the app knows nothing about any
# machine: a list of types typed in here goes stale the first time the region
# gains a shape, and this rig hit exactly that - a launch that failed for
# capacity on the only type it had ever used.
contains "an instance-type dropdown"      "$html" 'id="b-type"'
# It first went in the machine panel further down the column, where a narrow
# window - the grid collapses to one column under lg - put it below the fold
# and it could not be found at all. It belongs beside the button that spends
# the money.
check    "  above the Build button, not below it" \
         "$(awk '/id="b-type"/{a=NR} /id="b-build"/{b=NR} END{print (a && b && a < b) ? "yes" : "no"}' app/renderer/index.html)" "yes"
contains "  fed by cg machines"           "$js" "[['machines', '--json'], 'machines']"
contains "  and read at startup with the rest" "$js" "[['machines', '--json'], 'machines'],"
contains "  only what a quota covers is offered" "$js" "if (spot ? !m.fits_spot : !m.fits_ondemand) continue"
contains "  the GPU and price come from cg" "$js" "spot ? m.inr_hour_spot : m.inr_hour_ondemand"
# The purchase model is the bigger lever - on demand is about six times spot,
# and it is the only thing that launches when a region has no spare capacity -
# so it is the same choice, not a separate setting to go and find.
contains "  each row is a machine AND a purchase model" "$js" "for (const spot of [true, false])"
contains "  priced cheapest first"        "$js" "options.sort((a, b) => a.price - b.price"
contains "  'auto' counts as spot"        "$js" "d.spot !== '0'"
contains "  a row with no market is not offered" "$js" "if (price == null) continue"
contains "  choosing one writes the type" "$js" "'config', 'set', 'GAME_INSTANCE_TYPE'"
contains "  and the purchase model"       "$js" "'config', 'set', 'GAME_SPOT'"
contains "  after confirming the rate"    "$js" 'Build on ${type}, ${onSpot ? '"'"'spot'"'"' : '"'"'on demand'"'"'}?'
contains "  saying what each model means" "$js" "launches even when spot has none left"
contains "  a running box locks it"       "$js" "sel.disabled = !!boxNow"
contains "  and says why"                 "$js" "destroy it before changing the machine"
contains "  the unpinned zone is priced too" "$js" "usd_hour_spot_max"
check    "  and still no machine is named here" \
         "$(grep -cE 'g6\.|g6e\.|L40S|L4 ' app/renderer/app.js)" "0"

echo "5c. the library and cost screens, in the same language"
contains "the library leads with three numbers" "$html" 'id="lib-cost"'
contains "  a share bar per game"         "$js" "g.bytes / d.total_bytes"
contains "  what each game costs"         "$js" "money(g.usd_month)"
contains "  and a total row"              "$html" 'id="lib-foot"'
contains "  over capacity is not capped at 100%" "$js" '$('"'"'lib-fit-num'"'"').textContent = `${Math.round((gb / cap) * 100)}%`'
contains "  it says what a running box means" "$js" "this is the last push"
contains "cost shows the billing cycle"   "$html" 'id="c-cycle"'
contains "  the month projected against the budget" "$js" "(m.total_usd / day) * days"
contains "  which only emails"            "$js" "emails you and stops nothing"
contains "  dollars beside rupees"        "$html" "TOTAL ($)"
contains "  the archive as its own card"  "$html" 'id="c-arch-card"'
contains "  with the watchdog's countdown" "$js" "arch.decision"
contains "  the standby burn"             "$js" "standby burn"
contains "  and the egress hours from your bitrate" "$js" "setting('GAME_BITRATE_KBPS', 20000)"
check    "  reading the same registry"    "$(grep -c 'function setting(key, fallback)' app/renderer/app.js)" "1"

echo "5d. a stream the app never started"
# Closing the window does not end `cg open`; reopening it must not start a
# second Moonlight. The app asks cg, which holds the lock.
contains "the app reads the session from cg" "$js" "sessionNow = s.session || null"
contains "  play refuses while one runs"  "$js" "if (sessionNow) return refresh()"
contains "  and the button says so"       "$js" "live ? 'Streaming' : 'Play'"
contains "  on both screens"              "$js" "['d-open', 'b-open']"
check    "  the app never hunts for moonlight" "$(grep -ci 'moonlight' app/main/index.js app/main/runner.js | grep -vc ':0')" "0"

echo "5e. one panel for every long run"
# A destroy reports the same way a build does - steps, lines, an exit - so it is
# watched in the same panel, and starting one goes there.
contains "a run opens the panel it reports in" "$js" "function startRun(args)"
contains "  which is the build screen"   "$js" "goView('build')"
contains "  titled for what is running"  "$js" "destroy: 'Destroying'"
contains "  with the command on the log" "$js" "'cg ' + args.join(' ')"
contains "  and a footer about the money" "$js" "billing stops when the box is gone"
contains "destroy runs through it"       "$js" "startRun(['destroy'])"
contains "  and so does play"            "$js" "startRun(['open'])"
contains "every long run paints the steps" "$js" "if (isWrite(job.cmd)) {"
contains "  and the free reads follow it" "$js" "refreshAll();"

echo "5f. the app holds no prices"
# This is the rule, checked rather than asserted: while the Cost and Library
# screens were built, $0.025, $0.0912 and $0.1093 all found their way into the
# renderer. Every one of them now arrives from cg.
check "no price literal in the renderer" \
      "$(grep -vE '^\s*(//|\*)' app/renderer/app.js | grep -cE '[^0-9.](0\.[0-9]{2,})')" "0"
check "  nor in the markup, bar the buttons" "$(grep -cE '\$0\.[0-9]+' app/renderer/index.html)" "3"
contains "  which is what Refresh costs" "$html" 'id="refresh-cost"'
contains "  and cg overwrites it"        "$js" "money(rate.ce_call_usd)"
contains "rates come from cg"            "$js" "const rate = d.rates || {}"
contains "  the standby burn too"        "$js" "const standby = d.standby || {}"
contains "  and each game's monthly cost" "$js" "money(g.usd_month)"
check    "cg publishes the table"        "$(grep -c 'ce_call_usd' lib/setup)" "1"
check    "  from one file"               "$(grep -c 'CG_EGRESS_USD_GB=' lib/rates.sh)" "1"
lacks    "the build confirm quotes no rate" "$js" "an hour on spot"

echo "5g. the dashboard and guards screens"
# The dashboard answers "what is it doing and what is it spending" without
# spending anything itself; only its Fetch button bills.
contains "the stages from the mockup"    "$js" "for (const name of ['No box', 'Building', 'Ready'])"
contains "  building means a build is running" "$js" "jobsFor('init')"
contains "the machine strip"             "$js" "GB VRAM"
contains "the archive lists its games"   "$js" "function paintArchiveCard(d)"
contains "spend comes from a fetch"      "$js" "function paintSpend(d)"
check    "  which is the only paid button" \
         "$(grep -c "runCg(\['cost', '--json'\]" app/renderer/app.js)" "2"
contains "  and it carries the price"    "$html" 'id="d-cost-price"'
contains "activity is this window's own" "$js" "function note(text, tone)"
contains "  recording what cg ran"       "$js" 'note(`cg ${args.join('"'"' '"'"')} started`'
# Guards: one card per layer cg reports, never a layer the app invented.
contains "guards come from the watcher"  "$js" "for (const g of d.guards || [])"
contains "  tier badges"                 "$js" 'tier ${g.layer}'
contains "  and the audit line"          "$js" 'last audit ${ago(g.last_decision_age_s)}'
contains "always-on is not counted as unarmed" "$js" "const guardCount = guards =>"
contains "the knobs are settings rows"   "$js" "const WANT = ['GAME_WATCHDOG_IDLE_MIN'"
contains "  edited through cg"           "$js" "editSetting(r, row)"
# The Logs screen names the cloud watchdog in a heading, which is a label, not
# a guard definition; no guard's state, timing or existence is in the markup.
# id="d-armed" and id="g-armed" are placeholders cg fills; what must not be in
# the markup is a guard's name, its timing or its state.
check    "no guard is hardcoded"         "$(grep -c '15 min\|30 min\|ARMED\|watchdog idle' app/renderer/index.html)" "0"

echo "5g2. the needles in this file are quoted so bash cannot eat them"
# A needle holding ${...} or $(...) inside DOUBLE quotes is expanded by bash
# before the comparison runs, so the assertion either dies with "unbound
# variable" or silently passes against the wrong text. It has happened three
# times; single quotes are the fix, and this is how we stop a fourth.
# A backslash-escaped \$ is safe - bash leaves it alone - so it is removed before
# the search, or every correctly written needle would be reported.
bad=$(sed 's/\\\$//g' "$0" | grep -nE '^(contains|lacks|check) +"[^"]*" +"\$[a-z_]+" +"[^"]*(\$\{|\$\()' || true)
if [[ -z $bad ]]; then echo "  ok   every needle with a \$ is single-quoted"; pass=$((pass+1))
else echo "  FAIL double-quoted needles bash will expand:"; echo "$bad"; fail=$((fail+1)); fi

echo "5h. the logs and settings screens"
# The instance type is `text` in cg's registry - it has to be, because what a
# region rents is not knowable until AWS is asked - so Settings rendered it as a
# box to type a machine name into, beside a Build screen that offered a picker.
contains "the instance type is a picker here too" "$js" "r.key === 'GAME_INSTANCE_TYPE' && machinesNow"
contains "  offering only what a quota covers"    "$js" "if (!m.fits_spot && !m.fits_ondemand) continue"
contains "  with both prices on the row"          "$js" 'on demand INR ${od}'
contains "  and settings asks cg for them"        "$js" "[['config', '--json'], 'config'], [['machines', '--json'], 'machines']"
contains "  falling back to typing a name"        "$js" "} else if (r.kind === 'choice') {"
# The row is flex/justify-between with a shrink-0 right side, so the editor's
# control and its two buttons took their width out of the only flexible thing
# in the row - the label, which squeezed and wrapped on every Edit click.
contains "editing stacks instead of squeezing" "$css" '.row.editing'
contains "  the controls get their own line"   "$css" 'flex-col'
contains "  and the editor marks the row"      "$js" "row.classList.add('editing')"
contains "  a machine label is too long for a fixed width" "$js" "machineRow ? 'w-full' : 'w-64'"
contains "the event stream can be filtered" "$js" "function applyLogFilter(which)"
contains "  and copied"                  "$html" 'id="log-copy"'
contains "  and cleared"                 "$html" 'id="log-clear"'
check    "  it keeps a bounded number"   "$(grep -c "log.children.length > 2000" app/renderer/app.js)" "1"
contains "the watchdog's own log is reachable" "$js" "runCg(['watchdog', 'logs']"
contains "  and reading it is free"      "$html" "costs nothing to read"
contains "settings are grouped"          "$js" "const SETTING_GROUPS = ["
contains "  a new setting still appears" "$js" "New settings cg knows about"
contains "  and the screen says how it saves" "$html" "cg config set"
lacks    "  not by editing the file"     "$html" "or by editing the file"
# The archive's destructive actions were unreachable: the orphan line said
# "remove with: cg library clean" and there was no button.
contains "orphans can be cleaned"        "$js" "startRun(['library', 'clean'])"
contains "  a game can be forgotten"     "$js" "startRun(['library', 'forget'"
contains "  both warn first"             "$js" "cg will ask you to type FORGET"
contains "  and both count as writes"    "$js" "const LIBRARY_WRITES = new Set("
check    "  the same line the main process draws" \
         "$(grep -c "'push', 'pull', 'forget', 'clean', 'account'" app/main/index.js app/renderer/app.js | grep -vc ':0')" "2"

echo "5i. packaging keeps the scripts outside the package"
# A cg bundled into the .asar would be a second, stale engine. The app finds
# the repo instead - and still works when it is somewhere else.
check "the build config exists"          "$(node -e 'console.log(require("./app/package.json").build ? 1 : 0)')" "1"
check "  and ships only the app"         "$(node -e 'console.log(require("./app/package.json").build.files.join(","))')" "main/**,renderer/**,package.json"
contains "the scripts are found, wherever they are" "$main" "function findRepo()"
contains "  CG_REPO can say where it is" "$main" "process.env.CG_REPO"
check "an icon is committed"             "$([[ -s app/build/icon.png ]] && echo yes || echo no)" "yes"
check "  the binary is called cg"        "$(node -e 'console.log(require("./app/package.json").build.executableName)')" "cg"
# Four Linux formats, because one was not enough. A type-2 AppImage dlopens
# libfuse.so.2 and distributions have moved to fuse3, so on Arch the "standalone"
# download dies with "error loading libfuse.so.2" until a package is installed.
# .tar.gz needs nothing; the two native packages are for the two families.
check "  every Linux format is built" \
      "$(node -e 'console.log(require("./app/package.json").build.linux.target.join(","))')" \
      "AppImage,deb,pacman,tar.gz"
# electron-builder writes "<name>-<version>.pacman", NOT a .pkg.tar.zst. The
# file is a zstd package either way, but a glob for the wrong extension would
# have shipped a release with the Arch package silently missing.
contains "  and the workflow ships them"  "$(cat .github/workflows/desktop-release.yml)" "artifacts/**/*.pacman"
contains "  including the one with no dependencies" "$(cat .github/workflows/desktop-release.yml)" "artifacts/**/*.tar.gz"
contains "the release says which file to take" "$(cat .github/workflows/desktop-release.yml)" "Arch, CachyOS, Omarchy"
contains "  and warns what the AppImage needs" "$(cat .github/workflows/desktop-release.yml)" "needs FUSE 2 on the machine"
# A path INSIDE it, not the directory itself: the rule is `app/dist/`, which git
# matches only against something it can see is a directory. On a fresh clone -
# a release runner - app/dist does not exist yet, so asking about the directory
# said "not ignored" and failed the build that was about to create it.
check "  and the build output is ignored" \
      "$(git check-ignore app/dist/any-built-file >/dev/null 2>&1 && echo yes || echo no)" "yes"
contains "the README says Windows is untested" "$(cat app/README.md)" "Windows is written but untested"
# Verified by running it: `npm run pack` produced dist/linux-unpacked/cg, whose
# app.asar holds the app and nothing else - no cg, no lib/*.sh.
contains "  and how it was proven"       "$(cat app/README.md)" "verified by packing it"
# A tag builds the release. The workflow runs this very suite first, so a
# release cannot ship an app that grew AWS logic or a price of its own.
check    "a release workflow exists"     "$([[ -s .github/workflows/desktop-release.yml ]] && echo yes || echo no)" "yes"
contains "  triggered by a v tag"        "$(cat .github/workflows/desktop-release.yml)" "- 'v*'"
contains "  the tag decides the version" "$(cat .github/workflows/desktop-release.yml)" "npm version --no-git-tag-version"
contains "  and it runs these checks first" "$(cat .github/workflows/desktop-release.yml)" "bash tests/app.sh"
# The release notes used to say the download needed a checkout. It carries the
# scripts now, so saying otherwise would send people to clone a repo they do
# not need - and the notes are the only instructions a downloader ever sees.
contains "  the release says the scripts are included" \
         "$(cat .github/workflows/desktop-release.yml)" "The scripts travel with the app"
contains "  and where settings go instead"  \
         "$(cat .github/workflows/desktop-release.yml)" "~/.config/cg/.env"
lacks    "  not that a checkout is required" \
         "$(cat .github/workflows/desktop-release.yml)" "This app needs the repo"
# Only Linux is published, because only Linux has been run. The day someone
# tries macOS or Windows, the matrix is one line.
check    "  it publishes Linux only"     "$(grep -c 'windows-latest, macos-latest: untested' .github/workflows/desktop-release.yml)" "1"
check    "  and builds no untested installer" "$(grep -cE '\*\.exe|\*\.dmg' .github/workflows/desktop-release.yml)" "0"
contains "  the release says why"        "$(cat .github/workflows/desktop-release.yml)" "an untested download is worse than none"
check    "the deb can be built"          "$(node -e 'const b=require("./app/package.json");console.log(b.homepage && b.build.linux.maintainer ? "yes" : "no")')" "yes"

echo "6. the actions that spend money ask first"
# window.confirm draws a native alert that belongs to no design.
check    "no native alert boxes"         "$(grep -cE '(^|[^a-zA-Z.])confirm\(' app/renderer/app.js)" "0"
contains "  the app asks in its own dialog" "$html" 'id="confirm-title"'
contains "a build confirms"              "$js" "This starts billing"
contains "  and passes the chosen games" "$js" "GAME_APPS: apps"
contains "a destroy confirms"            "$js" "Destroy the box?"
contains "only GAME_APPS may cross"      "$(cat app/main/index.js)" "ENV_ALLOWED = new Set(['GAME_APPS'])"
check    "no secret is rendered"         "$(grep -cE 'TAILSCALE_AUTH_KEY|SUNSHINE_PASS|GAME_NTFY_URL *=' app/renderer/app.js)" "0"
# Settings are read from the registry and written back through it: the app
# never touches .env, and a secret can be replaced but not read.
contains "settings read the registry"    "$js" "settings:  [[['config', '--json']"
contains "  and write through cg"        "$js" "runCg(['config', 'set', r.key, value]"
contains "  showing a secret as set"     "$js" "r.is_set ? 'set' : 'not set'"
contains "  replacing, never revealing"  "$js" "r.secret ? '' : (r.value || '')"
contains "  and confirming a clear"      "$js" "remembered as"
# "1" means nothing to a person, and a secret is worth seeing once, on purpose.
contains "a choice is shown in words"    "$js" "'1': 'spot', '0': 'on demand'"
contains "a secret can be revealed"      "$js" "runCg(['config', 'get', r.key]"
contains "  deliberately, then hidden"   "$js" "click again to hide it"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
