#!/usr/bin/env bash
# What the window asks for once the tools are there: the key, the tailnet, the alert address.
# One of five files that were tests/startup-gate.sh; see lib/startup-gate-harness.sh.
GATE_NAME=startup-gate-account
source "$(dirname "$0")/lib/startup-gate-harness.sh"

echo "2. tools are there, the key is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_bad, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
# The CLI does not run, so Tools is not done: it is the step, not a row below it.
# Installed but not running is the AWS CLI's own chip, in the one Tools row -
# it used to be a second row also called Tools, that came and went.
lacks    "  never a second Tools row"  "$(row STAGES)" "cli="
contains "  Tools is still the step"   "$(row STAGES)" "tools=active"
contains "  the CLI chip says why"     "$(row STAGETEXT)" "AWS CLI v2 (installed, but not working)"
contains "  and it is red"             "$(row TOOLS)" "aws:no"
# Installing skips a tool cg can find, so it offers a fresh look instead.
contains "  offering a fresh look"     "$(row BUTTONS)" "tools=Check again"

echo "3. tools and key are there, the tailnet is not"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" false), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_out, \"config --json\": $cfg_ok}")
contains "three stages are ticked"     "$(row STAGES)" "key=done"
contains "the tailnet stage is active" "$(row STAGES)" "tailnet=active"
contains "  saying why it matters"     "$(row STAGETEXT)" "reachable only over your tailnet"
check    "one button, the sign-in"     "$(row BUTTONS)" "BUTTONS | tailnet=Sign in to Tailscale"
lacks    "  no chatty notes"           "$(row STAGETEXT)" "opens your browser"

echo "3a. pressed while the last checks are still landing, it waits its turn"
# Sign-in runs alone, so it was refused outright while any read was in flight -
# and the step offers its button the moment its own read lands, with the rest
# still landing. After an install that was every time: "Something else is
# running", on a fresh laptop, as the first thing it ever did.
ENGINE="window.__after = async () => {
  window.__slow = ['watcher --json']; window.__slowMs = 600;
  window.__answers['watcher --json'] = { guards: [] };
  runCg(['watcher', '--json'], { json: 'guards' });
  await new Promise(r => setTimeout(r, 20));
  document.querySelector('#onb-steps [data-stage=tailnet] button').click();
  await new Promise(r => setTimeout(r, 50));
  const live = document.getElementById('onb-live-tailnet');
  const during = 'ran=' + window.__ran.includes('creds tailscale signin') + ' says=' + (live ? live.textContent : 'none');
  await new Promise(r => setTimeout(r, 900));
  return during + ' | after: ran=' + window.__ran.includes('creds tailscale signin')
       + ' note=' + document.querySelector('#onb-steps [data-stage=tailnet]').innerText.replace(/\\s+/g, ' ');
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" false), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_out, \"config --json\": $cfg_ok}")
contains "while a read is out, it waits"     "$(row AFTER)" "ran=false says=Waiting for the last checks to finish"
contains "  then signs in, once it has landed" "$(row AFTER)" "after: ran=true"
lacks    "  and is never refused"            "$(row AFTER)" "is still running"
ENGINE=""

echo "3b. the box has no key to join with"
# This one used to be a dialog in the MIDDLE of a build: fifteen minutes of
# log, then "paste auth key". It is a prerequisite, so it is a stage.
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_nokey, \"config --json\": $cfg_ok}")
contains "the auth key stage is active" "$(row STAGES)" "authkey=active"
contains "  saying what it is for"      "$(row STAGETEXT)" "New machines join your tailnet with an auth key"
# No access token, so nothing can check a key or make one: the token is asked
# for, not a key - a pasted key with no token is what the build refuses.
check    "and the access token is asked for" "$(row BUTTONS)" "BUTTONS | authkey=Add access token"
tskey_keyonly='{"present":false,"valid":null,"state":"absent","detail":null,"signed_in":true,"node":"laptop","auth_key_stored":true,"can_mint":false}'
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_keyonly, \"config --json\": $cfg_ok}")
contains "a saved key alone does not tick it" "$(row STAGES)" "authkey=active"
check    "  the token is still asked for"     "$(row BUTTONS)" "BUTTONS | authkey=Add access token"

echo "3b2. saving the token reaches cg, and the stage is read again"
# The save worked and the screen did not change: cg wrote .env, the dialog
# closed, and nothing re-read - because `creds tailscale authkey` was missing
# from `cg --contract`, so main called it a read. A write is what triggers the
# re-read, so a real save read as nothing happening at all.
ENGINE="window.__after = async () => {
  document.querySelector('#onb-steps [data-stage=\"authkey\"] button').click();
  const open1 = document.getElementById('onefield').open;
  const title = document.getElementById('onefield-title').textContent;
  document.getElementById('onefield-input').value = 'tskey-api-' + 'tok1-secret';   // in halves: a scanner reads it whole as a real key
  window.__ran = [];
  window.__slow = ['creds tailscale --json']; window.__slowMs = 400;
  document.getElementById('onefield-go').click();
  await new Promise(r => setTimeout(r, 150));
  // Saved, and the read that shows it still out: the dialog waits, saying so,
  // rather than closing onto the step's old button.
  const mid = document.getElementById('onefield').open + ':' + document.getElementById('onefield-go').textContent;
  await new Promise(r => setTimeout(r, 800));
  return 'dialog=' + open1 + ' title=' + title + ' mid=' + mid
       + ' saved=' + window.__ran.includes('creds set tailscale')
       + ' closed=' + !document.getElementById('onefield').open
       + ' reread=' + window.__ran.includes('creds tailscale --json')
       + ' type=' + document.getElementById('onefield-input').type;
};"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_ok, \"creds tailscale --json\": $tskey_nokey, \"config --json\": $cfg_ok, \"creds set tailscale\": {}}")
contains "the token dialog opens here" "$(row AFTER)" "dialog=true title=Tailscale access token"
contains "  and stays until the token is read back" "$(row AFTER)" "mid=true:Saved. Checking…"
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
contains "  and says what it is for"   "$(row STAGETEXT)" "Email address for budget alerts"

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
  await new Promise(r => setTimeout(r, 400));
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
contains "it says the call never arrived" "$(row STAGETEXT)" "Cannot reach AWS"
lacks    "  and blames nothing"           "$(row STAGETEXT)" "rejected"
contains "  saying the key may be fine"   "$(row STAGETEXT)" "The key was not verified"
contains "  offering another go"          "$(row BUTTONS)" "key=Try again"

echo "3f. there is no key at all, which is not a rejection either"
OUT=$(probe "{\"deps --json\": $(deps "$TOOLS_OK" true), \"creds --json\": $creds_nokey, \"creds tailscale --json\": $tskey_in, \"config --json\": $cfg_ok}")
contains "it says what the key is for"  "$(row STAGETEXT)" "launch and stop machines"
lacks    "  and accuses no key"         "$(row STAGETEXT)" "rejected"
contains "  and offers to connect"     "$(row BUTTONS)" "key=Connect AWS"

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
contains "a refusal is said, where it is true" "$(row STAGETEXT)" "The saved access key was rejected"
contains "  and offers a new one"      "$(row BUTTONS)" "key=Connect again"


gate_finish
