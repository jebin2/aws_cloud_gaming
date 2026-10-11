#!/usr/bin/env bash
# `cg open` waited two minutes for a port that was never opened.
#
# The nvidia check aborted a build at step 40 of 99. Sunshine is step 95, so the
# box came up with no streaming stack at all - but it booted, joined the tailnet,
# answered ping in 18ms and took ssh, so it looked completely alive. `cg open`
# then waited the full 60 tries on tcp/47989 and died with "TIMEOUT" and
# "exit 1", which says nothing about why and invites you to try again.
#
# The question worth asking is not "is sunshine slow" but "was sunshine ever
# installed". This pins that it gets asked, and that it is only answered out
# loud when the evidence is unambiguous.
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

# The shipped function, with `box` and the printing helpers stubbed - so this
# runs the real logic and never needs a machine.
diag() { # diag <sunshine> <marker> [failed-step] [ssh-dead]
  # Exported explicitly: a `VAR=x func` prefix reaching a nested `bash -c` is
  # exactly the kind of thing that works until it does not.
  export SN=$1 MK=$2 FL=${3:-} SSH_DEAD=${4:-}
  bash -c '
    set -uo pipefail
    TS_HOST=gamevps
    cg_echo() { echo "$*"; }
    cg_block() { echo "BLOCK:$2"; cat; }
    box() {
      [[ -n ${SSH_DEAD:-} ]] && return 255
      echo "sunshine=$SN"
      echo "marker=$MK"
      [[ -n $FL ]] && echo ">>> FAILED: $FL"
      return 0
    }
    '"$(sed -n '/^open_no_sunshine()/,/^}/p' lib/game)"'
    open_no_sunshine 100.64.0.1 && echo "RC=0" || echo "RC=1"
  ' 2>&1
}

echo "1. the real case: the build aborted, so there is no sunshine"
out=$(diag no no "nvidia driver packages installed")
check    "it is certain"                "$(grep -o 'RC=[01]' <<<"$out")" "RC=0"
contains "  and says so plainly"        "$out" "Sunshine is not installed on this box"
contains "  names the step it died at"  "$out" "It stopped at:  nvidia driver packages installed"
contains "  explains why it looks alive" "$out" "joins the tailnet and answers ssh"
contains "  and that waiting cannot help" "$out" "waiting longer cannot change that"
contains "  gives the one command"      "$out" "cg destroy && cg init"
contains "  and how to read the log"    "$out" "sudo tail -50 /var/log/cloud-gaming-bootstrap.log"
contains "  under a clear heading"      "$out" "BLOCK:This box never finished building"

echo "2. a finished box with a real streaming fault is NOT called unfinished"
# This is the claim that must not be made loosely: sunshine installed means the
# build worked and something else is wrong, so the caller's timeout stands.
out=$(diag yes yes)
check "it declines to explain"   "$(grep -o 'RC=[01]' <<<"$out")" "RC=1"
lacks "  and stays quiet"        "$out" "never finished building"
# Marker present but sunshine missing - contradictory, so make no claim.
out=$(diag no yes)
check "a contradiction is not a diagnosis" "$(grep -o 'RC=[01]' <<<"$out")" "RC=1"
lacks "  no block printed"                 "$out" "never finished building"
out=$(diag yes no)
check "nor the other way round"            "$(grep -o 'RC=[01]' <<<"$out")" "RC=1"

echo "3. no FAILED line in the log and it still explains the box"
out=$(diag no no)
check    "still certain"            "$(grep -o 'RC=[01]' <<<"$out")" "RC=0"
contains "  still names the cause"  "$out" "Sunshine is not installed on this box"
lacks    "  without an empty step"  "$out" "It stopped at:  "

echo "4. an unreachable box makes no claim either"
# Reachable by tailscale but not by ssh: that happens, and it is not evidence.
out=$(diag no no "" 1)
check    "it gives up honestly" "$(grep -o 'RC=[01]' <<<"$out")" "RC=1"
contains "  saying it cannot ask" "$out" "cannot ask it why"
lacks    "  and claims nothing"   "$out" "never finished building"

echo "5. the caller still fails, and only after asking"
src=$(cat lib/game)
contains "the wait is checked"        "$src" 'if ! wait_for "waiting for sunshine" 60'
contains "  the diagnosis is tried"   "$src" "open_no_sunshine \"\$ip\" || true"
contains "  and it still dies"        "$src" 'die "sunshine never answered on $ip:47989"'
# `|| true` matters: a diagnosis that itself failed must not replace the error.
check "the diagnosis cannot mask the failure" \
      "$(grep -c 'open_no_sunshine "\$ip" || true' lib/game)" "1"

echo "6. this file's own needles are safe"
bad=$(sed 's/\\\$//g' "$0" | grep -nE '^(contains|lacks|check) +"[^"]*" +"[^"]*" +"[^"]*(\$\{|\$\()' || true)
if [[ -z $bad ]]; then echo "  ok   every needle with a \$ is single-quoted"; pass=$((pass+1))
else echo "  FAIL double-quoted needles bash will expand:"; echo "$bad"; fail=$((fail+1)); fi

echo ""
echo "open-unfinished: $pass passed, $fail failed"
(( fail == 0 ))
