#!/usr/bin/env bash
# host/cg-build: the supervisor that runs the build's stages on the box. Run here
# against a sandbox with fake stages - kill it, fail them, race them - since a
# real box is about fifteen minutes and some rupees a try.
#
# Only processes this script started are ever killed, by the pid it was given.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=$PWD/host/cg-build
T=$(mktemp -d); pass=0; fail=0
SUPPID=""
trap '[[ -n $SUPPID ]] && kill -9 "$SUPPID" 2>/dev/null; rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3' in: $2"; fail=$((fail+1)); fi; }

# A fresh sandbox with a prelude the stages share.
fresh() {
  rm -rf "$T/r" "$T/stages.list"; mkdir -p "$T/r/opt/cloud-gaming-host/stages" "$T/r/etc/cg-build" "$T/home"
  : > "$T/order"; : > "$T/reboot.log"
  {
    echo "ORDER=$T/order; FLAG=$T/flag; PIDFILE=$T/slowpid"
    echo 'progress() { set +x; echo ">>> $*"; set -x; }'
    echo 'verify() { set +x; if "${@:2}" >/dev/null 2>&1; then echo ">>> ok: $1"; else echo ">>> FAILED: $1"; set -x; return 1; fi; set -x; }'
  } > "$T/r/opt/cloud-gaming-host/prelude.sh"
  printf 'NAME=world\n' > "$T/r/etc/cg-build/env"
  rm -f "$T/flag"
}
# stage name needs lock retries timeout reboot   (the script is on stdin)
stage() {
  local name=$1 needs=${2:-} lock=${3:-} retries=${4:-0} timeout=${5:-30} reboot=${6:-0}
  cat > "$T/r/opt/cloud-gaming-host/stages/$name.sh"
  echo "$name|$needs|$lock|$retries|$timeout|$reboot" >> "$T/stages.list"
}
writeplan() {
  python3 - "$T/stages.list" "$T/r/opt/cloud-gaming-host/plan.json" <<'PY'
import json, sys
out = []
for line in open(sys.argv[1]).read().splitlines():
    name, needs, lock, retries, timeout, reboot = line.split("|")
    out.append({"name": name, "file": name + ".sh", "needs": [n for n in needs.split(",") if n], "lock": lock,
                "retries": int(retries), "timeout": int(timeout), "reboot_after": reboot == "1"})
json.dump({"version": 1, "max_parallel": 4, "stages": out}, open(sys.argv[2], "w"))
PY
}
supenv() {
  CG_BUILD_ROOT=$T/r CG_BUILD_BACKOFF=0 CG_BUILD_TICK=0.05 CG_BUILD_HOME=$T/home CG_BUILD_NO_WAIT=1 CG_BUILD_NO_SYSTEMD=1 \
  CG_BUILD_BOOT_ID=${BOOT:-boot1} CG_BUILD_REBOOT="echo REBOOT >> $T/reboot.log" "$@"
}
sup() { supenv python3 "$SRC" "$@" 2>&1; }
# The supervisor itself, in the background: the pid kept IS python's (exec, not a
# function's subshell), so killing that pid is killing it.
bg_sup() {
  ( export CG_BUILD_ROOT=$T/r CG_BUILD_BACKOFF=0 CG_BUILD_TICK=0.05 CG_BUILD_HOME=$T/home CG_BUILD_NO_WAIT=1 CG_BUILD_NO_SYSTEMD=1 \
      CG_BUILD_BOOT_ID=boot1 CG_BUILD_REBOOT="echo REBOOT >> $T/reboot.log"
    exec setsid python3 "$SRC" run >/dev/null 2>&1 ) &
  SUPPID=$!
}
st() { python3 -c "import json;d=json.load(open('$T/r/var/lib/cg-build/state.json'))['stages'];print(d['$1']['state'], d['$1']['attempts'])"; }
rc() { tr -d '\n' < "$T/r/var/lib/cloud-gaming-bootstrap.rc" 2>/dev/null; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
compat() { cat "$T/r/var/log/cloud-gaming-bootstrap.log" 2>/dev/null; }

echo "1. stages run in the order they need, and finish the build"
fresh
stage a "" "" 0 30 <<'S'
progress "step a"; echo a >> "$ORDER"
S
stage b a "" 0 30 <<'S'
progress "step b"; echo b >> "$ORDER"
S
stage c b "" 0 30 <<'S'
echo c >> "$ORDER"
S
writeplan; sup run >/dev/null
check "in the plan's order"           "$(tr '\n' ' ' < "$T/order")" "a b c "
check "  the build is done"           "$(rc)" "0"
check "  every stage is done"         "$(st a) $(st b) $(st c)" "done 1 done 1 done 1"
contains "  the old reader's log has the markers" "$(compat)" ">>> step a"
contains "  and says it is complete"     "$(compat)" "bootstrap complete"
contains "  and where the time went"     "$(compat)" "where the time went"

echo "2. stages that need nothing from each other run together"
fresh
for n in p q; do
stage $n "" "" 0 30 <<'S'
echo "start $CG_STAGE $(python3 -c 'import time;print(int(time.time()*1000))')" >> "$ORDER"; sleep 1.2; echo "end $CG_STAGE $(python3 -c 'import time;print(int(time.time()*1000))')" >> "$ORDER"
S
done
writeplan
t0=$(now_ms); sup run >/dev/null; t1=$(now_ms)
check "both finished"                  "$(st p | cut -d' ' -f1) $(st q | cut -d' ' -f1)" "done done"
check "  in well under two stages' time" "$(( (t1 - t0) < 2300 ))" "1"
first_end=$(awk '$1=="end"{print $3}' "$T/order" | sort -n | head -1); last_start=$(awk '$1=="start"{print $3}' "$T/order" | sort -n | tail -1)
check "  each started before the other ended" "$(( last_start < first_end ))" "1"

echo "3. stages that share a lock never overlap, and go in the plan's order"
fresh
for n in l1 l2 l3; do
stage $n "" apt 0 30 <<'S'
echo "start $CG_STAGE" >> "$ORDER"; sleep 0.4; echo "end $CG_STAGE" >> "$ORDER"
S
done
writeplan; sup run >/dev/null
check "one at a time, in order" "$(tr '\n' ',' < "$T/order")" "start l1,end l1,start l2,end l2,start l3,end l3,"

echo "4. a stage that fails is tried again, and then done"
fresh
stage flaky "" "" 2 30 <<'S'
if [ ! -f "$FLAG" ]; then touch "$FLAG"; echo "first try fails"; exit 1; fi
S
writeplan; sup run >/dev/null
check "done on the second try" "$(st flaky)" "done 2"
contains "  the retry is on record" "$(sup events)" '"kind":"retry"'
check "  and the build succeeded" "$(rc)" "0"

echo "5. a failed stage stops what needs it, and not what does not"
fresh
stage bad "" "" 1 30 <<'S'
echo "no luck"; exit 3
S
stage after bad "" 0 30 <<'S'
echo should-not-run >> "$ORDER"
S
stage free "" "" 0 30 <<'S'
echo free-ran >> "$ORDER"
S
writeplan; sup run >/dev/null
check "the failed one is failed after its retry" "$(st bad)" "failed 2"
check "  what needed it is blocked"        "$(st after | cut -d' ' -f1)" "blocked"
check "  and never ran"                    "$(grep -c should-not-run "$T/order")" "0"
check "  the free one ran"                  "$(grep -c free-ran "$T/order")" "1"
check "  the build is reported as failed"  "$(rc)" "1"
contains "  naming the stage for the old reader" "$(compat)" ">>> FAILED: bad"

echo "6. killed in the middle, it carries on from where it was"
fresh
stage first "" "" 0 30 <<'S'
echo first >> "$ORDER"
S
stage slow first "" 0 30 <<'S'
echo $$ > "$PIDFILE"; echo slow-start >> "$ORDER"; sleep 2; echo slow-end >> "$ORDER"
S
stage last slow "" 0 30 <<'S'
echo last >> "$ORDER"
S
writeplan
# The supervisor in a session of its own, so killing it by its pid is all it takes
# to also leave its stages running, as a power cut would not - then those by theirs.
bg_sup
for _ in $(seq 1 80); do grep -q slow-start "$T/order" && break; sleep 0.1; done
kill -9 "$SUPPID" 2>/dev/null; kill -9 "$(cat "$T/slowpid")" 2>/dev/null; wait "$SUPPID" 2>/dev/null; SUPPID=""
sleep 0.3
check "it was cut off in the middle"   "$(grep -c slow-end "$T/order")" "0"
sup run >/dev/null
check "everything is done now"         "$(st first | cut -d' ' -f1) $(st slow | cut -d' ' -f1) $(st last | cut -d' ' -f1)" "done done done"
check "the first stage was not run again" "$(grep -c '^first$' "$T/order")" "1"
check "the cut-off one was"            "$(grep -c slow-start "$T/order")" "2"
check "  and its retries were not spent" "$(st slow)" "done 1"
contains "  the cut-off is on record"   "$(sup events)" '"kind":"interrupted"'

echo "7. its record can be read from where a reader stopped"
all=$(sup events | wc -l); seq3=$(sup events --since 3 | wc -l)
check "events after number 3 are all but the first three" "$seq3" "$((all - 3))"
check "the numbers go up by one, across the restart" "$(sup events | python3 -c 'import sys,json;s=[json.loads(l)["seq"] for l in sys.stdin];print(s==list(range(1,len(s)+1)))')" "True"

echo "8. values are filled in from the box's own file, and a missing one is said"
fresh
stage greet "" "" 0 30 <<'S'
echo "hello __NAME__" >> "$ORDER"
S
stage lost "" "" 0 30 <<'S'
echo "__NOT_THERE__"
S
writeplan; sup run >/dev/null
check "a value is filled in"       "$(cat "$T/order")" "hello world"
check "a missing one fails the stage" "$(st lost | cut -d' ' -f1)" "failed"
contains "  and says which"          "$(sup events)" "NOT_THERE"

echo "9. the last stage reboots, once, after it is done"
fresh
stage prep "" "" 0 30 <<'S'
true
S
stage finish prep "" 0 30 1 <<'S'
echo finishing >> "$ORDER"
S
writeplan; sup run >/dev/null
check "it rebooted"                    "$(grep -c REBOOT "$T/reboot.log")" "1"
check "  after being marked done"      "$(st finish)" "done 1"
BOOT=boot2 sup run >/dev/null
check "after the reboot nothing runs again" "$(grep -c finishing "$T/order")" "1"
check "  and it does not reboot again"  "$(grep -c REBOOT "$T/reboot.log")" "1"

echo "10. a stage that takes too long is stopped"
fresh
stage hang "" "" 0 1 <<'S'
sleep 30
S
writeplan
t0=$(now_ms); sup run >/dev/null; t1=$(now_ms)
check "it failed"                    "$(st hang | cut -d' ' -f1)" "failed"
contains "  saying it timed out"     "$(sup events)" "timed out after 1s"
check "  without waiting it out"     "$(( (t1 - t0) < 12000 ))" "1"

echo "11. a daemon left running does not hold the stage"
fresh
stage daemon "" "" 0 30 <<'S'
( sleep 25 ) &
echo started
S
writeplan
t0=$(now_ms); sup run >/dev/null; t1=$(now_ms)
check "the stage is done"            "$(st daemon | cut -d' ' -f1)" "done"
check "  at once, not when the daemon ends" "$(( (t1 - t0) < 9000 ))" "1"

echo "12. a plan that loops, or needs a stage that is not there, is refused"
fresh
stage x y "" 0 30 <<'S'
true
S
stage y x "" 0 30 <<'S'
true
S
writeplan
contains "a loop"                    "$(sup run; true)" "wait on each other"
fresh
stage z nothing "" 0 30 <<'S'
true
S
writeplan
contains "a missing need"            "$(sup run; true)" "which is not a stage"

echo; echo "supervisor: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
