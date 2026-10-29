#!/usr/bin/env bash
# What the window asks for when there is no cg, and when a tool is missing.
# One of five files that were tests/startup-gate.sh; see lib/startup-gate-harness.sh.
GATE_NAME=startup-gate-tools
source "$(dirname "$0")/lib/startup-gate-harness.sh"

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
contains "the pipeline says so"        "$(row TITLE2)" "Scripts not found"
contains "  and what cg is"            "$(row STAGETEXT)" "requires its scripts"
contains "  where it looked"           "$(row STAGETEXT)" "/opt/nope/cg"
contains "  and how to fix it"         "$(row STAGETEXT)" "Install them with"
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
# AWS's six steps: tools, the key, the tailnet, the machine key, alerts, where.
contains "  counting the steps"        "$(row COUNT)" "of 6 done"
# In the add dialog, over Home: there is no full-window setup screen any more.
contains "it shows the steps, not the splash" "$(row MODE)" "MODE | steps setup=false"
contains "  over the window, which stays as it is" "$(row MODE)" "header=true viewbar=true"
# The tools themselves, not a sentence about them: present in green, missing
# in red, and the count as the only heading.
contains "  each tool shown"           "$(row TOOLS)" "python3:yes"
contains "    the missing ones marked"  "$(row TOOLS)" "aws:no,moonlight:no"
check    "  and nothing else said"     "$(row TOOLTEXT)" "TOOLTEXT | "
contains "  the count is the heading"  "$(row COUNT)" "of 6 done"
contains "the tools stage is active"   "$(row STAGES)" "tools=active"
# You cannot start in the middle: there is exactly one button on the screen.
check    "only one stage offers anything" "$(row BUTTONS)" "BUTTONS | tools=Install"
# What is already true is ticked wherever it sits, and what cannot be judged
# says so rather than reading as fine.
contains "  a met stage is still ticked"  "$(row STAGES)" "tailnet=done"
contains "  and an unjudgeable one asks"  "$(row STAGES)" "key=unknown"
# "The AWS CLI is not installed" and "the AWS CLI is missing from the tools"
# are one job with one button, and used to be two rows saying it.
lacks    "the same fix is not listed twice" "$(row STAGES)" "cli="
lacks    "  no chatty notes"              "$(row STAGETEXT)" "asks for your password once"
# The pipeline has this one, in order, with the button - and there is no
# warning strip above the pages to say it a second time.
check    "no strip says it again"      "$(row BANNER)" "BANNER | none"
check    "and no step has a log yet"   "$(row LOG)" "LOG | "
# The steps are a dialog over Home, not a screen in its place: Home is there,
# and closing the dialog leaves you on it.
contains "Home is behind it"           "$(row ONB)" "cards=shown"

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
contains "  under one plain sentence"  "$(row AFTER)" "Install failed"
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


gate_finish
