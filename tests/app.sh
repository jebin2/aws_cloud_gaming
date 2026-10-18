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
# And is CURRENT. Tailwind only emits rules for classes it finds in the markup,
# so a class added without rebuilding is a class with no rule: `sticky` sat in
# index.html for two commits while the header kept scrolling away, because
# position:sticky was never in the stylesheet. Nothing in the app can tell the
# difference between that and a typo.
if [[ -x app/node_modules/.bin/tailwindcss ]]; then
  css_tmp=$(mktemp -d)
  ( cd app && ./node_modules/.bin/tailwindcss -i renderer/src.css -o "$css_tmp/tailwind.css" --minify ) >/dev/null 2>&1
  if cmp -s "$css_tmp/tailwind.css" app/renderer/tailwind.css; then
    echo "  ok     and up to date with the markup"; pass=$((pass+1))
  else
    echo "  FAIL   the stylesheet is stale - run: cd app && npm run build:css"; fail=$((fail+1))
  fi
  rm -rf "$css_tmp"
else
  echo "  SKIP - tailwindcss is not installed, cannot check the stylesheet is current"
fi
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

echo "3c. the package carries everything cg reaches for"
# The installed app shipped cg, lib and lambda - and not host/, which
# provision.sh tars and sends to the box. A build from a checkout was fine; a
# build from the package died at "tar: host: Cannot open" after creating the
# bucket, the key pair and the security group.
#
# Derived from the scripts, not typed here: a directory they `cd` into, source
# from or tar up is a directory the package needs.
reach=$(grep -ohE '(-C|cd|source|\. ) +(host|lib|lambda)(/[A-Za-z0-9._-]+)?' cg lib/*.sh lib/setup lib/game \
        | awk '{print $2}' | cut -d/ -f1 | sort -u)
packed=$(python3 -I -c '
import json
d = json.load(open("app/package.json"))
print(" ".join(r["from"].removeprefix("../") for r in d["build"]["extraResources"]))')
check "every directory the scripts reach for is packaged" \
      "$(for d in $reach; do [[ " $packed " == *" $d "* ]] || echo "MISSING:$d"; done)" ""
# cg itself, and the file that documents .env, are not directories.
contains "  cg itself ships"             "$packed" "cg"
contains "  and .env.example with it"    "$packed" ".env.example"

echo "4. the promises the app makes about cost and safety"
contains "cg is run with CG_JSON=1"      "$(cat app/main/runner.js)" "CG_JSON: '1'"
# Reads are independent, so they run together; anything that changes something
# runs alone, because cg takes its own locks.
# Which commands must run alone is cg's to say: it takes the locks. The app
# used to write the list down - twice, in two processes - and the two disagreed
# three times, each time silently, because a command that is never started
# looks exactly like one that returned nothing.
contract=$(./cg --contract)
check "the contract is valid JSON" \
      "$(python3 -I -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$contract")" "yes"
alone=$(python3 -I -c 'import json,sys
print(" ".join(" ".join(p) for p in json.load(sys.stdin)["runs_alone"]))' <<<"$contract")
contains "a build runs alone"            "$alone" "init"
contains "  a destroy too"               "$alone" "destroy"
contains "  the library writes"          "$alone" "library push"
contains "  setting a key"               "$alone" "creds set"
# It writes .env, and the app re-reads only after a write: left out of this
# list, saving the box auth key changed nothing on screen.
contains "  the box auth key too"        "$alone" "creds tailscale authkey"
contains "  and installing a tool"       "$alone" "deps install"
# Naming the free ones here would be the same duplication in a third place, so
# this asserts only that they are NOT in the alone list.
for free in status watcher machines sweep regions quota; do
  lacks "  $free is not in it"           "$alone" "$free"
done
contains "the main process reads it"     "$main" "cg --contract"
contains "  assuming the worst if it cannot" "$main" "every command will run alone"
contains "  and skipping the flags first" "$main" "FLAG_TAKES_VALUE"
contains "a write waits for everything"  "$main" "[...jobs.values()][0]"
contains "  and a read waits only for a write" "$main" "find(j => !j.readOnly)"
# The renderer is TOLD the verdict rather than working it out again.
contains "the verdict travels with the job" "$main" "write: !readOnly"
contains "  and the renderer uses it"    "$js" "j.write"
lacks    "  with no list of its own"     "$js" "const WRITES = new Set("
# The ids cg asks under are cg's. The window answers two of them from a dialog
# it has already shown - and when an id is renamed in cg, that pre-answer
# silently stops matching and a modal appears in the middle of a build.
asks=$(python3 -I -c 'import json,sys
print(" ".join(json.load(sys.stdin)["asks"]))' <<<"$contract")
contains "cg lists what it asks for"     "$asks" "aws-access-key-id"
contains "  including the ones with a dialog" "$asks" "tailscale-auth-key"
contains "the main process hands the list over" "$main" "ipcMain.handle('cg:asks'"
contains "  across the bridge"           "$(cat app/main/preload.js)" "cg:asks"
contains "the window checks its own names against it" "$js" "async function checkAsks()"
contains "  and says so when they differ" "$js" "cg no longer asks under"
# Every id the window names must be one cg actually asks under.
for id in $(python3 -I -c "
import re, sys
src = open('app/renderer/app.js').read()
block = re.search(r'const ASK = \{(.*?)\n\};', src, re.S).group(1)
print(' '.join(re.findall(r\"'([^']+)'\", block)))"); do
  contains "  $id is one of cg's"        "$asks" "$id"
done
# And each is written down once: a second copy is the drift this removed.
for id in aws-access-key-id aws-secret-access-key tailscale-api-token tailscale-auth-key; do
  check  "  $id appears once"            "$(grep -c "'$id'" app/renderer/app.js)" "1"
done
contains "quitting mid-run asks first"   "$main" "before-quit"
contains "the cost refresh carries its price" "$(tr -s ' ' < app/renderer/index.html)" 'id="refresh-cost"'
contains "  shown only on the cost screen" "$js" "refresh-cost').hidden = view !== 'cost'"
# Nothing POLLS: a window that asked AWS something every so often would bill
# for it without anyone touching the machine, and `cg cost` is $0.01 a call.
check    "nothing repeats on a timer"        "$(grep -c 'setInterval' app/renderer/app.js)" "0"
echo "5. the screens, and what each reads"
for v in dashboard build library guards cost settings logs; do
  contains "a $v screen"                 "$html" "data-view=\"$v\""
done
contains "the dashboard reads status"    "$js" "dashboard: [[['status', '--json']"
contains "the library reads its index"   "$js" "library:   [[['library', 'list', '--json']"
contains "the guards read the watcher"   "$js" "guards:    [[['watcher', '--json']"
contains "a screen's reads go together"  "$js" "await Promise.all(need.map("
contains "every free read fires on open" "$js" "async function refreshAll(each) {"
contains "  and cost is not one of them" "$js" "it waits for its button"
contains "  and load when it is opened"  "$js" "if (NEEDS[view] && !loaded.has(view)) refresh()"
contains "refresh is per screen"         "$js" "async function refresh(each, need = readsFor(view))"
contains "stop belongs to the screen that started the run" "$js" "j.view === view"
# A tab's button answers for that tab: only a build or destroy, which cg runs
# alone, disables anything elsewhere.
contains "only a write blocks a read"    "$js" "jobs.size > 0"
contains "  refresh waits for a write only" "$js" 'refresh'"'"').disabled = busy'
contains "  writes wait for everything"  "$js" '$(b).disabled = jobs.size > 0'
# Single quotes: a needle in double quotes runs $(...) as a command, which made
# this assertion pass against nothing at all.
contains "  and takes refresh's place while it runs" "$js" "|| !!mine.length"
contains "stop says what it stops"       "$js" 'Stop ${hereNames[0]}'
# status + watcher are one refresh to the person looking at the dashboard.
contains "  counting actions, not commands" "$js" "hereNames.length === 1"
contains "only a long run is worth pointing at" "$js" "const WATCHABLE = new Set(['init', 'destroy', 'open'])"
contains "  which the pointer uses"      "$js" 'is running · show it'
check    "every icon carries its name"   "$(python3 - <<'PY'
import re
html = open("app/renderer/index.html").read()
spans = re.findall(r'<span class="material-symbols-outlined[^>]*>', html)
print(sum(1 for s in spans if 'data-icon=' not in s))
PY
)" "0"
contains "  and hidden where it means nothing" "$js" "(!NEEDS[view] && view !== 'cost')" 
contains "cost reads the same one call"  "$js" "v === 'cost' ? [[['cost', '--json'], 'cost']]"
check    "no button is left mid-page"    "$(grep -c 'cost-run' app/renderer/index.html app/renderer/app.js | grep -vc ':0')" "0"

echo "5a. the first-run pipeline"
# The dashboard, on a laptop that is not ready. It replaces three attempts at
# this: a banner naming one problem at a time, a modal popup over a window you
# could not use yet, and that popup moved into a corner so it would stop
# blocking. All three avoided the fact that a new laptop had no screen.
contains "the dashboard carries it"      "$html" 'id="onb"'
contains "  one row per stage"           "$html" 'id="onb-steps"'
# Each step keeps its own log, folded under it, parked here between paints.
contains "  and a home for each step's log" "$html" 'id="onb-logs"'
contains "  built per step, in the painter"  "$js" "u.id = 'onb-unit-' + key"
# A sign-in finishes in a browser: the link has to be reachable while the
# command is still waiting for it - on the step that is waiting.
contains "  with room for a sign-in link"   "$js" "link.id = 'onb-link-' + key"
# Setup hands over to the dashboard and leaves nothing behind: the "Runs in
# Mumbai" line it used to leave above the cards said what the Build tab says.
lacks    "it leaves no line behind"      "$html" 'id="onb-done"'
contains "  which the painter decides"   "$js" "\$('onb').hidden = !showPipeline"
# Setup is the whole window: no sidebar or header until it is done, and every
# open starts on the splash.
contains "the window opens in setup"     "$html" '<body class="setup'
lacks    "  and no splash in front of it" "$html" 'id="onb-splash"'
contains "  and the CSS hides the rest"  "$(cat app/renderer/src.css)" 'body.setup > aside'
contains "  for less motion, none"       "$(cat app/renderer/src.css)" 'prefers-reduced-motion: reduce' 
# The stages ARE the prerequisites - the same list the banner reads, so the two
# cannot disagree about what is left.
contains "the stages come from prereqs"  "$js" "const setup = prereqs().filter"
contains "  one of them active"          "$js" "const firstOpen = rungs.findIndex(r => r.ok !== true)"
contains "  the rest locked"             "$js" "      : 'locked';"
# You cannot start in the middle, and a met stage is still ticked where it sits.
contains "a locked stage offers nothing" "$js" "if (quiet || state === 'checking') { row.append(rail, body); wrap.append(row); return; }"
# Every step's button is the first run's own - written for someone new, where
# the banner's are for someone mid-session - and a stage without one falls
# back to the rung's.
contains "the steps have their own buttons" "$js" "const ONB_ACTION = {"
contains "  and fall back to the rung's"  "$js" "[{ label: x.problem.label, go: x.problem.go }]"
contains "the install runs in the pane"  "$js" "return runInPipeline('tools', ['deps', 'install'"
contains "  so does the sign-in"         "$js" "return runInPipeline('tailnet', ['creds', 'tailscale', 'signin']"
# Stopping has to reach cg: a sign-in waits on a browser that may never answer.
contains "a run in flight can be stopped" "$js" "if (onbJob !== null) window.cg.cancel(onbJob)"
# Where it runs is a stage, judged on whether AWS will actually let you launch
# there - not on whether a button was pressed.
contains "where it runs is a stage"      "$js" "{ key: 'where', reads: 'machines', name: whereDone()"
contains "  judged on what fits"         "$js" "(machinesNow.machines || []).some(m => m.fits_spot || m.fits_ondemand)"
contains "  and chosen in a dialog"      "$html" 'id="whereto"'
contains "  that can measure again"      "$html" 'id="whereto-measure"'
# Every figure in that dialog is cg's: latency, rupees, and whether it fits.
contains "the choice shows cg's numbers" "$js" "best ? best.inr_hour_spot : null"
contains "  and why one cannot be used"  "$js" "No GPU limit here yet"
# The popup and the header line are gone, and nothing may bring them back.
check "no popup is left"                 "$(grep -c \"id=.stage\" app/renderer/index.html)" "0"
check "  nor the header's command line"  "$(grep -c 'job-line' app/renderer/index.html app/renderer/app.js | grep -vc ':0')" "0"
# Nothing polls: a window that asked AWS something every so often would bill
# for it without anyone touching the machine.
check "nothing repeats on a timer"       "$(grep -c 'setInterval' app/renderer/app.js)" "0"
# One delay, and it starts no command: the finished pipeline is held on screen
# for a beat so you see it finish, instead of six ticks flashing for 200ms.
check "  and one delay, which it is"     "$(grep -c 'setTimeout' app/renderer/app.js)" "1"
contains "  the handover beat"           "$js" 'onbHandover = setTimeout('
contains "  after which it is the cards" "$js" "onbPhase = 'dashboard';"
# The cards are not worth showing to someone who cannot build a box yet, and
# they sat under the setup flow saying "No box" as though that were the news.
contains "the dashboard waits its turn"  "$html" 'id="d-main"'
contains "  hidden until handed over"    "$js" "\$('d-main').hidden = showPipeline"
# A read in flight and a read that came back broken are not the same sentence.
contains "a stage being read says so"    "$js" "(waiting ? 'checking' : 'unknown')"

echo "5a2. no engine, and a read that cannot be painted"
# Without cg every read fails identically - a spawn error each - and six broken
# reads is not what happened. Only main can see it: the renderer has no
# filesystem, so it asks.
contains "main says whether cg is there"  "$main" 'function engineFacts()'
contains "  over the bridge"              "$(cat app/main/preload.js)" 'cg:engine'
contains "  and re-reads the contract"    "$main" 'if (found && !CONTRACT.runs_alone) loadContract();'
contains "the window asks before reading" "$js" 'if (await engineReady()) await refreshAll();'
contains "  and says the one true thing"  "$js" "'This app cannot find its scripts'"
contains "  naming where it looked"       "$js" 'Looked for it at ${engineGone.cg}'
# A main process too old to answer, or a test stub, is taken at its word.
contains "  an unanswered ask carries on" "$js" 'try { e = await window.cg.engine(); } catch { return true; }'
# Reads do not block each other, so a second set would leave the stuck ones in
# `jobs` - and a job in flight is what disables Build, Play and Destroy.
contains "trying again cancels first"     "$js" 'if (!job.write) await window.cg.cancel(id)'
# The key's sentence is cg's answer, not a guess at an error string.
contains "why a key failed comes from cg" "$js" "switch (credsNow && credsNow.reason)"
contains "  unreachable is not rejected"  "$js" 'Nothing was rejected; AWS just could not be reached'
contains "  and an old cg still works"    "$js" "title: 'AWS rejected this access key'"

echo "5b. the build screen, as the design draws it"
# The archive table, the allocation bar and the machine strip are the parts the
# mockup has; each is fed by a field from cg, never by a number typed in here.
contains "an archive table"              "$html" 'id="b-games"'
lacks    "  by name, not by Steam's id"   "$js" 'appid ${g.appid}'
contains "  and when each is deleted"    "$js" "deleteOn(g, days, seen, marks)"
contains "the allocation bar"            "$html" 'id="b-bar"'
contains "  says what is left, plainly"  "$js" "Too big by"
contains "the machine comes from cg"     "$js" "const spec = s.spec || {}"
check    "  with no type hardcoded"      "$(grep -c 'g6\.xlarge\|L4\|16 GiB' app/renderer/app.js)" "0"
lacks    "no build time, no second rate line" "$js" "from the moment it starts"
# cg's dozen-odd steps, and the box's own, are placed in eight plain ones.
contains "steps are the eight plain ones" "$js" "const BUILD_STEPS = ["
contains "  and only move forwards"       "$js" "if (at > run.idx)"
contains "  and carry how long they took" "$js" "function buildStepEnd(event)"
contains "  the live line shows in the strip" "$js" "\$('b-prog-step').textContent = event.text"
# A box that is already up cannot be built again - cg would refuse, so the
# screen offers what you can actually do with it instead.
contains "a machine replaces the build button" "$js" '$(`${p}-build`).hidden = !!box'
contains "  with play and delete"        "$js" '$(`${p}-destroy`).hidden = !box'
contains "  and the picker goes read-only" "$js" "box.disabled = up"
contains "  build re-reads the box state" "$js" "build:     [[['library', 'list', '--json'], 'library'], [['status', '--json'], 'status'],"
# The panel sits in a content-sized grid row, so flex-1 had no height to divide
# and the log grew forever instead of scrolling. It is bounded.
contains "the log is bounded and scrolls" "$html" 'max-h-[46vh] overflow-y-auto'
# Progress used to live in the right panel: a step list that grew beside a log
# that grew, which stretched the grid row and made the whole page taller than
# the window on every build. One strip across the top, one bounded transcript.
# A run is the steps, as setup is; the full transcript is behind "Full log".
contains "a run is a panel of its own"   "$html" 'id="b-strip"'
contains "  with a bar"                   "$html" 'id="b-prog"'
contains "  the time and the bill in its heading" "$js" "\$('b-strip-meta').textContent"
contains "  the steps"                    "$html" 'id="b-steps"'
contains "  and the full log folded away" "$html" 'id="b-logbox"'
contains "the transcript keeps cg's headings" "$js" "head.className = 'step flex items-baseline"
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
contains "a failure gets its own panel"    "$html" 'id="b-fail"'
contains "  hidden until something fails"  "$html" '<div class="hidden" id="b-fail">'
# The headline above the fold, cg's full text behind a disclosure, and the two
# or three things worth doing as buttons - because "cg config set GAME_SPOT 0"
# is a command to type at someone who is looking at a window.
contains "  with a headline"               "$html" 'id="b-fail-head"'
contains "  what it means"                 "$html" 'id="b-fail-why"'
contains "  what to do about it"           "$html" 'id="b-fail-acts"'
contains "  and cg's own words kept"       "$html" ">Details</summary>"
contains "the actions are keyed by the AWS code" "$js" "const FAIL_ACTS = {"
contains "  spot capacity offers another machine"   "$js" "InsufficientInstanceCapacity: () => [['Pick another machine'"
contains "  a quota failure offers the ask"      "$js" "Ask AWS for a higher GPU limit"
# It lives in the strip, taking the BAR's place: a bar frozen at 35% says
# nothing, and in the right-hand panel the reason sat under a 200-line
# auto-scrolling log that had already moved past it.
check    "  and sits in the strip, not the panel" \
         "$(awk '/id="b-strip"/{s=NR} /id="b-error"/{e=NR} /id="b-log"/{l=NR} END{print (s && e && l && s < e && e < l) ? "yes" : "no"}' app/renderer/index.html)" "yes"
contains "  the bar gives way to it"       "$js" "\$('b-bar-track').hidden = true"
contains "  and comes back on the next run" "$js" "\$('b-bar-track').hidden = false"
contains "  and the step that failed holds it" "$js" "if (state === 'failed') body.append(fail);"
# A fixed "launch failed" heading sat directly above cg's own "launch failed:
# InsufficientInstanceCapacity", which read as the same sentence twice.
contains "  the heading says it stopped"  "$js" "failed: 'The build stopped'"
check    "  with no second heading under it" \
         "$(grep -c 'b-error-title' app/renderer/app.js app/renderer/index.html | awk -F: '{s+=$2} END{print s}')" "0"
contains "  fed by the lines cg marked"    "$js" "if (event.kind === 'fail') { buildFailing = true;"
contains "  and the report under them"     "$js" "else if (buildFailing && event.t === 'line')"
contains "  an error event lands there too" "$js" "if (event.t === 'error') buildFail(event.text)"
contains "  a nonzero exit is never silent" "$js" 'stopped without saying why'
contains "  and the next run clears it"    "$js" "buildFailClear();"

# The machine chooser. Its whole point is that the app knows nothing about any
# machine: a list of types typed in here goes stale the first time the region
# gains a shape, and this rig hit exactly that - a launch that failed for
# capacity on the only type it had ever used.
#
# It was three dropdowns - region, type, purchase model - and that was the
# complaint: three controls for one decision, most of whose combinations cannot
# launch. It is one table now, on Settings, where a row is a (region, machine)
# and picking a PRICE sets all three settings together. What it RENDERS is
# pinned in tests/chooser-dom.sh, which loads the real page; this file holds
# the wiring either side of it.
contains "the table is fed by cg sweep"   "$js" "[['sweep', '--cached', '--json'], 'sweep']"
# --cached, never a fresh scan: a scan is 90 seconds and an opening window must
# not wait on it.
contains "  the remembered scan, not a new one" "$js" "[['sweep', '--cached', '--json'], 'sweep'],"
lacks    "  a startup read never scans"   "$js" "[['sweep', '--json'], 'sweep'],"
contains "  and falls back to this region" "$js" "[['machines', '--json'], 'machines']"
contains "  rescanning is a button"       "$js" "function scanRegions"
contains "a price cell is the control"    "$js" "function priceCell"
contains "  disabled when no quota covers it" "$js" "fits === false) why = 'no quota'"
contains "  or the region is not enabled" "$js" "!row.enabled) why = 'needs opt-in'"
contains "  capacity is shown beside price" "$js" "row.score >= 7 ? 'good'"
contains "choosing one writes the type"   "$js" "'config', 'set', 'GAME_INSTANCE_TYPE'"
contains "  and the purchase model"       "$js" "'config', 'set', 'GAME_SPOT'"
contains "  and the region, last"         "$js" "if (moving) await runCg(['config', 'set', 'GAME_REGION'"
contains "  after confirming the rate"    "$js" 'title: `Use ${row.type} in ${placeName(row.region)}?`' 
contains "  saying what each model means" "$js" "Never taken back mid-game."
contains "  and warning when capacity says no" "$js" "a spot start will likely be refused."
contains "a running box locks every pick" "$js" "const usable = !why && !boxNow"
# The three settings it owns get no second editor, or the dropdowns are back.
contains "settings defer to the table"    "$js" "CHOSEN_IN_TABLE"
contains "  listing exactly those three"  "$js" "new Set(['GAME_REGION', 'GAME_INSTANCE_TYPE', 'GAME_SPOT'])"
# ...unless AWS cannot be read at all, when the table can offer nothing and
# locking the only other way in would leave no way in.
contains "  but come back if the table is dead" "$js" "function chooserDead"

# Build does not carry a second copy of the table. It says what will be built
# and sends you to the one that exists.
lacks    "no picker on the Build screen"  "$html" 'id="b-type"'
lacks    "  and no table either"          "$html" 'id="b-chooser"'
contains "Build shows the machine card"  "$html" 'id="b-machine"'
contains "  and so does Home, the same one" "$html" 'id="d-hero"'
check    "  built by one recipe, buttons too" "$(grep -cE "^mountMachineCard\(\\$\('(d-hero|b-machine)'\), '[db]'\);$" app/renderer/app.js)" "2"
check    "  and no page keeps its own copy" "$(grep -cE 'id="[db]-(build|open|destroy)"' app/renderer/index.html)" "0"
# ...as a dialog over the page, not a trip to the top of Settings.
contains "  which offers the chooser here" "$js" "ch.onclick = () => openMachines();"
check    "every popup has the one look"   "$(grep -c '<dialog ' app/renderer/index.html)" "$(grep -c '<dialog id="[a-z]*" class="dlg ' app/renderer/index.html)"
check    "  and one title style"          "$(grep -c '<dialog ' app/renderer/index.html)" "$(grep -c 'class="dlg-title' app/renderer/index.html)"
check    "  and one button row"           "$(grep -c '<menu class=' app/renderer/index.html)" "$(grep -c '<menu class="dlg-actions"' app/renderer/index.html)"
contains "  the one table, in a dialog"    "$html" '<dialog id="machdlg"'
# Settings is a long screen. Arriving is not enough - the first picker went
# unnoticed because it was below the fold - so whatever you came for is
# scrolled to and flashed. Three screens do this now, through one helper.
contains "  and flashes what you came for" "$js" "el.classList.add('flash-attn')"
contains "  having scrolled to it"        "$js" "el.scrollIntoView"
contains "  by one helper, not three"     "$js" "function goSetting(el)"
# No timer: the animation says when it is over. tests/app.sh asserts elsewhere
# that nothing in this file runs on setTimeout.
contains "  ending on its own"            "$js" "animationend"
contains "  with the animation defined"   "$(cat app/renderer/src.css)" "@keyframes flash-attn"
check    "  and the card it points at exists"          "$(grep -c 'id="s-machine-card"' app/renderer/index.html)" "1"
# The summary must sit above the button that spends the money, not below it.
contains "the summary is above Build"    "$js" 'box.append(body, busy, row);'
contains "  and says why"                 "$js" "Delete it before changing machines"
contains "  the unpinned zone is priced too" "$js" "usd_hour_spot_max"
check    "  and still no machine is named here" \
         "$(grep -cE 'g6\.|g6e\.|L40S|L4 ' app/renderer/app.js)" "0"

echo "5c. the library and cost screens, in the same language"
# One Games table: every game, its place, what it costs and when it goes.
contains "the library is one table of games" "$html" 'id="lib-rows"'
contains "  each with its place"          "$html" '>Location</th>'
contains "  and when it is deleted"       "$html" '>Auto-delete</th>'
contains "  what each game costs, in rupees" "$js" 'cell(tr, r(g.usd_month)'
contains "  and a total row"              "$html" 'id="lib-foot"'
contains "  kept for: one setting, applied at once" "$js" "['library', 'keep-for', String(n)]"
contains "  the Steam login is a card of its own" "$html" 'id="lib-login-box"'
# A fallback that looks like an answer is worse than no answer: the app used to
# print 209 GB of box disk and a rupee rate of 88 when cg had told it neither.
check    "no disk size is guessed"        "$(grep -c '|| 209' app/renderer/app.js)" "0"
check    "  nor a starting value for one"  "$(grep -c 'selectable_gb: 209' app/renderer/app.js)" "0"
contains "  it says it does not know"     "$js" "the machine's space is not known yet"
check    "no exchange rate is guessed"    "$(grep -c 'inr_per_usd || 88' app/renderer/app.js)" "0"
contains "cost projects the month"       "$js" "m.projected_usd"
contains "  against the budget you set, in rupees" "$js" "Number(setting('GAME_BUDGET_INR', NaN))"
contains "  which only emails"            "$js" "AWS emails you if you pass it; it stops nothing"
# Rupees only: the Cost page was the last one showing dollars beside them.
lacks    "  no dollar column"             "$html" "TOTAL ($)"
check    "  no dollar helper left"        "$(grep -c 'const money = ' app/renderer/app.js)" "0"
contains "  what recurs, every month"     "$html" 'id="c-recurring-card"'
lacks    "  and no guess at what the bill says beyond it" "$js" "unknown_usd_month"
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
contains "a run opens the panel it reports in" "$js" "function startRun(args, opts = {})"
contains "  which is the build screen"   "$js" "goView('build')"
contains "  titled for what is running"  "$js" "running: 'Deleting the machine'"
contains "  with what is running, by name" "$js" '$('"'"'b-log-title'"'"').textContent = `${CgName(args)} · log`;'
# Billing counts from a machine that exists: the rental has to have finished.
contains "  and the bill from when it was rented" "$js" "if (!run.billFrom && at > rent && run.steps[rent])"
contains "destroy runs through it"       "$js" "startRun(['destroy'])"
contains "  and so does play"            "$js" "startRun(['open'])"
contains "every long run paints the steps" "$js" "if (job.write) {"
contains "  and the free reads follow it" "$js" "refreshAll();"

echo "5f. the app holds no prices"
# This is the rule, checked rather than asserted: while the Cost and Library
# screens were built, $0.025, $0.0912 and $0.1093 all found their way into the
# renderer. Every one of them now arrives from cg.
check "no price literal in the renderer" \
      "$(grep -vE '^\s*(//|\*)' app/renderer/app.js | grep -cE '[^0-9.](0\.[0-9]{2,})')" "0"
# None, buttons included: Refresh on the Cost page takes the dashboard's
# price, which comes from status, in rupees.
check "  nor in the markup"              "$(grep -cE '\$0\.[0-9]+' app/renderer/index.html)" "0"
contains "  which is what Refresh costs" "$html" 'id="refresh-cost"'
contains "  priced from cg, in rupees"   "$js" "\$('refresh-cost').textContent = \$('d-cost-price').textContent"
contains "rates come from cg"            "$js" "const rate = d.rates || {}"
contains "  the standby burn too"        "$js" "const standby = d.standby || {}"
contains "  and each game's monthly cost" "$js" "r(g.usd_month)"
# Twice: `cg cost --json` and `cg status --json` both carry it, each read from
# the one variable rates.sh sets.
check    "cg publishes the table"        "$(grep -c 'ce_call_usd' lib/setup)" "2"
check    "  status carries the prices"   "$(grep -c 'out\["rates"\]' lib/setup)" "1"
check    "  from one file"               "$(grep -c 'CG_EGRESS_USD_GB=' lib/rates.sh)" "1"
lacks    "the build confirm quotes no rate" "$js" "an hour on spot"

echo "5g. the dashboard and guards screens"
# The dashboard answers "what is it doing and what is it spending" without
# spending anything itself; only its Fetch button bills.
contains "one painter draws the dashboard" "$js" "function paintDash()"
contains "  money in rupees only"         "$js" "const rs = n =>"
# Home and Spending draw the same two cards, from the same last bill check, so
# a build cannot show on one and not the other.
contains "  one Recurring cost card for both pages" "$js" 'renderRecurring($('"'"'d-recurring-card'"'"')'
contains "  and on Spending"             "$js" 'renderRecurring($('"'"'c-recurring-card'"'"'))'
contains "  one This month card for both" "$js" 'renderMonth($('"'"'d-month-card'"'"')'
contains "  building means a build is running" "$js" "jobsFor('init')"
contains "the machine strip"             "$js" 'gpuName(row.gpu, row.vram)'
contains "the archive repaints the dashboard" "$js" "function paintArchiveCard() { paintDash(); }"
contains "spend comes from a fetch"      "$js" "function paintSpend(d)"
# Two places ask for it, both a click: the dashboard button, and the Cost
# screen's own Refresh.
# One place reads the bill: Spending's Refresh. Home's Exact cost goes there
# and presses it, rather than being a second paid call of its own.
check    "  which is the only paid button" \
         "$(grep -c "runCg(\['cost', '--json'\]\|v === 'cost' ? \[\[\['cost', '--json'\]" app/renderer/app.js)" "1"
contains "  Exact cost opens Spending and refreshes it" "$js" "\$('d-cost').onclick = () => { goView('cost'); \$('refresh').click(); };"
contains "  and it carries the price"    "$html" 'id="d-cost-price"'
contains "activity is this window's own" "$js" "function note(text, tone)"
# What happened, not which command did it: "cg library push started" named a
# command, and the one it named was wrong - see the duplicate key below.
contains "  recording what happened"     "$js" 'note(`${cgName(args)} started`'
# Guards: one card per layer cg reports, never a layer the app invented.
contains "guards come from the watcher"  "$js" "for (const g of guards) {"
# The minutes are cg's: the page wrote "30 min" and "1 h" whatever was set.
contains "  with cg's minutes"           "$js" '${g.idle_min || 30} min with no stream'
contains "  and the last check, aged"    "$js" 'Last check ${ago(cloud.last_decision_age_s)}'
# Rupees only: the budget read "$57 a month" from AWS's own figure.
contains "the budget is in rupees"       "$js" '${rs(Number(v))} a month'
lacks    "  never dollars"               "$js" '`$${b.usd} a month`'
contains "the knobs are settings rows"   "$js" "const WANT = ['GAME_BUDGET_INR'"
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
# Settings used to render the instance type as a box to TYPE a machine name
# into, beside a Build screen that offered a picker - two controls, one setting.
# Both are gone: the chooser table owns region, type and model together, and
# this screen is where it lives.
contains "the chooser table is on this screen"    "$html" 'id="s-chooser"'
contains "  and settings asks cg for its rows"    "$js" "[['config', '--json'], 'config'], [['machines', '--json'], 'machines']"
lacks    "  no second editor for what it owns"    "$js" "r.key === 'GAME_INSTANCE_TYPE' && machinesNow"
contains "  those rows point at the table"        "$js" "set in Machine, above"
# The row is flex/justify-between with a shrink-0 right side, so the editor's
# control and its two buttons took their width out of the only flexible thing
# in the row - the label, which squeezed and wrapped on every Edit click.
contains "editing stacks instead of squeezing" "$css" '.row.editing'
contains "  the controls get their own line"   "$css" 'flex-col'
contains "  and the editor marks the row"      "$js" "row.classList.add('editing')"
# The editor that remains is for ordinary settings, which fit a fixed width -
# the full-width special case existed only for a machine label carrying a GPU
# and two prices, and that lives in the table now.
contains "  the editor keeps its fixed width"  "$js" "+ 'w-64';"
contains "the event stream can be filtered" "$js" "function applyLogFilter(which)"
contains "  and copied"                  "$html" 'id="log-copy"'
contains "  and cleared"                 "$html" 'id="log-clear"'
check    "  it keeps a bounded number"   "$(grep -c "log.children.length > 2000" app/renderer/app.js)" "1"
contains "the watchdog's own log is reachable" "$js" "runCg(['watchdog', 'logs']"
contains "  and reading it is free"      "$html" "Free to load"
# Which card a setting belongs on is cg's answer now; this file keeps the
# ORDER of the cards and the sentence under each heading, which is layout.
contains "the registry carries the grouping" "$(./cg config --json)" '"group"'
contains "  and the name to show"            "$(./cg config --json)" '"label"'
# Settings shows only what nothing else sets: the stream, the disk and the two
# accounts. Each other setting has one home on the page it is about.
contains "Settings is the stream and the disk" "$js" "['GAME_RES', 'GAME_FPS', 'GAME_BITRATE_KBPS']"
contains "  and the disk"                "$js" "['Machine disk', '', ['GAME_DISK_GB']]"
lacks    "  not the guards' settings again" "$js" "'The guards': "
lacks    "  nor the jargon line"          "$html" "Editing one here runs"
lacks    "  not by editing the file"     "$html" "or by editing the file"
# The archive's destructive actions were unreachable: the orphan line said
# "remove with: cg library clean" and there was no button.
contains "orphans can be cleaned"        "$js" "libraryRun(['library', 'clean']"
contains "  a game can be forgotten"     "$js" "libraryRun(['library', 'forget'"
contains "  both ask for the word, once"  "$js" "word: 'DELETE'"
# They stay on Library: the Build page is for builds, deletes and sessions.
lacks    "  and never go to the Build page" "$js" "startRun(['library'"
# The line that used to be drawn in both processes - and drifted - is drawn by
# cg now, once, and the app is told the verdict with the job.
contains "  and both count as writes"    "$(./cg --contract | tr -d ' \n')" '["library","forget"]'
contains "  cleaning too"                "$(./cg --contract | tr -d ' \n')" '["library","clean"]'
lacks    "  with no copy in the renderer" "$js" "'push', 'pull', 'forget', 'clean', 'account'"

echo "5i. packaging keeps the scripts outside the package"
# A cg bundled into the .asar would be a second, stale engine. The app finds
# the repo instead - and still works when it is somewhere else.
check "the build config exists"          "$(node -e 'console.log(require("./app/package.json").build ? 1 : 0)')" "1"
check "  and ships only the app"         "$(node -e 'console.log(require("./app/package.json").build.files.join(","))')" "main/**,renderer/**,package.json"
# findRepo lives in main/repo.js, not in here: inside index.js it could not be
# required without starting Electron, and the bug that shipped - a DIRECTORY
# named cg winning over the script - went uncaught for exactly that reason.
contains "the scripts are found, wherever they are" "$main" "require('./repo')"
repo=$(cat app/main/repo.js)
contains "  CG_REPO can say where it is" "$repo" "env.CG_REPO"
contains "  and cg must be a file, not a directory" "$repo" "isFile()"
lacks    "  the old existsSync test is gone" "$repo" "existsSync(path.join(dir, 'cg'))"
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
# fpm shells out to bsdtar for the Arch package's .MTREE, and the Ubuntu runner
# does not have it - the build spent four minutes on the other three formats
# and then died with exit 127. Arch has bsdtar, so only CI ever saw it.
contains "  and installs what fpm needs for them" \
         "$(cat .github/workflows/desktop-release.yml)" "libarchive-tools"
# electron-builder's default pacman dependencies are a Debian list with Debian
# names: http-parser was dropped from Arch's repos and libappindicator-gtk3 is
# AUR-only, so pacman refused the package outright - "cannot resolve
# http-parser". These are the packages that own the libraries ldd actually
# reports against the built binary.
check "  the Arch package depends on Arch packages" \
      "$(node -e 'console.log(require("./app/package.json").build.pacman.depends.join(" "))')" \
      "gtk3 nss alsa-lib libcups libdrm mesa"
lacks "  not a name Arch has never had" \
      "$(node -e 'console.log(JSON.stringify(require("./app/package.json").build.pacman))')" "http-parser"
lacks "  nor one that lives only in the AUR" \
      "$(node -e 'console.log(JSON.stringify(require("./app/package.json").build.pacman))')" "libappindicator"
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
contains "a build confirms, with its rate" "$js" 'It costs ${rate != null ? `${rsh(rate)} an hour` : '"'"'by the hour'"'"'} while it runs.'
contains "  and passes the chosen games" "$js" "GAME_APPS: apps"
contains "a delete confirms"             "$js" "Delete the machine?"
contains "only GAME_APPS may cross"      "$(cat app/main/index.js)" "ENV_ALLOWED = new Set(['GAME_APPS'])"
check    "no secret is rendered"         "$(grep -cE 'TAILSCALE_AUTH_KEY|SUNSHINE_PASS|GAME_NTFY_URL *=' app/renderer/app.js)" "0"
# Settings are read from the registry and written back through it: the app
# never touches .env, and a secret can be replaced but not read.
contains "settings read the registry"    "$js" "settings:  [[['config', '--json']"
contains "  and write through cg"        "$js" "runCg(['config', 'set', r.key, value]"
contains "  showing a secret as set"     "$js" "r.is_set ? 'Set' : 'Not set'"
contains "  replacing, never revealing"  "$js" "r.secret ? '' : (r.value || '')"
contains "  and confirming a clear"      "$js" "you will not be asked for it again"
# "1" means nothing to a person, and a secret is worth seeing once, on purpose.
contains "a choice is shown in words"    "$js" "'1': 'Spot', '0': 'Standard'"
contains "a secret can be revealed"      "$js" "runCg(['config', 'get', r.key]"
contains "  deliberately, then hidden"   "$js" "click again to hide it"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
