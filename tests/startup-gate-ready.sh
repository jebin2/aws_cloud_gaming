#!/usr/bin/env bash
# The prerequisites pass: the reads that need AWS, and the first scan.
# One of five files that were tests/startup-gate.sh; see lib/startup-gate-harness.sh.
GATE_NAME=startup-gate-ready
source "$(dirname "$0")/lib/startup-gate-harness.sh"

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
contains "still checking, on the steps" "$(row MODE)" "MODE | steps setup=false"
contains "  location says it is checking" "$(row STAGES)" "where=checking"
contains "the pipeline is still up" "$(row ONB)" "ONB | shown"

echo "4b. a laptop that has never scanned scans itself, once"
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
  const at = n => n === 'onb' ? (document.getElementById('adddlg').open ? 'shown' : 'hidden') : document.getElementById(n).hidden ? 'hidden' : 'shown';
  return 'then=' + at('onb') + '/' + at('d-main')
       + ' setup=' + document.body.classList.contains('setup')
       + ' arriving=' + document.body.classList.contains('arriving')
       + ' back=' + (goView('cost'), goView('dashboard'), document.body.classList.contains('arriving'));
};"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
contains "the steps are shown"          "$(row MODE)" "MODE | steps"
check    "  every one ticked"           "$(row STAGES)" "STAGES | tools=done,key=done,tailnet=done,authkey=done,email=done,where=done"
contains "  and held for a beat"        "$(row ONB)" "ONB | shown cards=shown"
contains "then it closes on Home"       "$(row AFTER)" "then=hidden/shown"
contains "  which never left"           "$(row AFTER)" "setup=false"
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
  const at = n => n === 'onb' ? (document.getElementById('adddlg').open ? 'shown' : 'hidden') : document.getElementById(n).hidden ? 'hidden' : 'shown';
  await new Promise(r => setTimeout(r, 1000));
  const before = 'onb=' + at('onb') + ' cards=' + at('d-main');
  await new Promise(r => setTimeout(r, 2200));
  return before + ' | after: onb=' + at('onb') + ' cards=' + at('d-main')
       + ' stop=' + at('cancel');
};"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
contains "every step is ticked"             "$(row STAGES)" "where=done"
contains "  but the box is still being read, so it waits" "$(row AFTER)" "onb=shown cards=shown |"
contains "then it closes, the card filled"  "$(row AFTER)" "after: onb=hidden cards=shown"
contains "  with nothing left running"      "$(row AFTER)" "stop=hidden"
ENGINE=""

echo "4c3. a Refresh offers no Stop"
# The Build screen's Refresh is four reads. Named each by what it is, the
# button once offered to "Stop 2 runs" for a single click; now a read offers no
# Stop at all - the Refresh popup says what it is reading, and it is over in
# seconds. Stop is for what changes something.
ENGINE="window.__after = async () => {
  await new Promise(r => setTimeout(r, 400));
  document.querySelector('.nav-item[data-view=\"build\"]').click();
  window.__slow = ['status --json', 'machines --json', 'library list --json'];
  window.__slowMs = 800;
  document.getElementById('refresh').click();
  await new Promise(r => setTimeout(r, 50));
  const reads = 'stop=' + (document.getElementById('cancel').hidden ? 'none' : document.getElementById('cancel-label').textContent.trim());
  // Something that changes something still gets its Stop, named.
  runCg(['library', 'clean']);
  await new Promise(r => setTimeout(r, 50));
  const write = document.getElementById('cancel').hidden ? 'none' : document.getElementById('cancel-label').textContent.trim();
  // A build has Cancel on its card, which deletes the machine too: no second
  // button beside it that would stop cg and leave the machine billing.
  for (const [id, j] of jobs) window.__emit(id, { t: 'exit', rc: 0 });
  await new Promise(r => setTimeout(r, 50));
  runCg(['init']);
  await new Promise(r => setTimeout(r, 50));
  const build = document.getElementById('cancel').hidden ? 'none' : document.getElementById('cancel-label').textContent.trim();
  return reads + ' | write=' + write + ' | build=' + build;
};"
OUT=$(probe "{$READY, \"sweep --cached --json\": $FULL_SWEEP}")
check "no Stop for reads" "$(row AFTER | cut -d'|' -f1-2 | sed 's/ $//')" "AFTER | stop=none"
contains "  but a change still has one" "$(row AFTER)" "write=Stop "
contains "  except a build, whose card has Cancel" "$(row AFTER)" "build=none"
ENGINE=""


gate_finish
