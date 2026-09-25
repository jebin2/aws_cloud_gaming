#!/usr/bin/env bash
# CG_JSON=1: one NDJSON event per line, for a GUI or another program driving cg.
#
# The point of the mode is that nothing has to scrape text written for people.
# So the tests that matter are: every line parses, the kinds survive, escaping
# holds for the characters that break naive JSON, no escape code ever reaches
# the stream - and the human formats are untouched, because they remain what
# everyone else reads.
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

run() { # run '<code>' [CG_JSON value] - the library, then the code
  ( env -i PATH="$PATH" HOME="$T" CG_JSON="${2-1}" CG_COLOR="${CG_COLOR-}" \
      bash -c 'source lib/common.sh; '"$1" )
}
# Every line must parse, and each is reported as <t>[:<kind>] for easy assertions.
kinds() { python3 -c '
import json,sys
for ln in sys.stdin.read().splitlines():
    if not ln.strip(): continue
    try: e=json.loads(ln)
    except Exception: print("UNPARSED:"+ln[:40]); continue
    print(e["t"] + (":"+e["kind"] if "kind" in e else ""))'; }

echo "1. the events a build emits"
out=$(run 'say "provisioning instance"; log "launching"; log_as ok "i-0abc launched"; log_as warn "no API key"; say "confirming"; log_as fail "it refused"')
check "step, lines, the next step closes the first, and exit closes the last" \
      "$(kinds <<<"$out" | tr '\n' ' ')" "step line:info line:ok line:warn step_end step line:fail step_end "
contains "a step carries its text"      "$out" '"t":"step","at":"'
contains "  and step_end its duration"  "$out" '"rc":0,"secs":'
check    "every line is JSON"           "$(kinds <<<"$out" | grep -c UNPARSED)" "0"

echo "2. escaping, and what never reaches the stream"
out=$(run 'log_as info "$(printf "a \"quoted\" path C:\\\\Users and a\treal tab")"; log_as info "$(printf "an \033[31mescape\033[0m code")"')
check    "quotes, backslashes and tabs survive as JSON" \
         "$(python3 -c 'import json,sys;print(json.loads(sys.stdin.readline())["text"])' <<<"$out")" \
         "$(printf 'a "quoted" path C:\\Users and a\treal tab')"
check    "a whole escape sequence is dropped, not just the escape character" \
         "$(python3 -c 'import json,sys;l=sys.stdin.read().splitlines()[1];print(json.loads(l)["text"])' <<<"$out")" \
         "an escape code"
lacks    "  nothing raw is left behind"  "$out" $'\033'

echo "3. reports, blocks and the box's own output"
out=$(run 'printf "row a\nrow b\n" | cg_report "X" "billed so far"; printf " box says\n\n more\n" | cg_relay; printf "a line\n" | cg_block "X" "What this does"')
check "a report is one event, a block is one, box lines are their own" \
      "$(kinds <<<"$out" | tr '\n' ' ')" "report line:cont line:cont block "
contains "the report keeps its title"    "$out" '"title":"billed so far"'
contains "  and its rows, newline-escaped" "$out" '"text":"row a\nrow b"'
contains "box output is marked as the box's" "$out" '"source":"box"'
lacks    "  and blank relay lines are dropped" "$out" '"text":""'

echo "4. an error"
out=$(run 'say "provisioning"; die "AWS refused"; echo UNREACHABLE' 2>&1); rc=$?
contains "an error event"                "$out" '"t":"error","at":'
contains "  with the message"            "$out" '"text":"AWS refused"'
lacks    "  and nothing after it"        "$out" "UNREACHABLE"
check    "  exits 1"                     "$rc" "1"
contains "  the open step is closed as failed" "$out" '"t":"step_end"'

echo "5. the human formats are untouched"
plain=$(CG_COLOR=never run 'say "provisioning instance"; log_as ok "done"' 0)
contains "plain: the arrow heading"      "$plain" "==> provisioning instance"
contains "  and the line"                "$plain" "      done"
lacks    "  no JSON"                     "$plain" '{"t":'
styled=$(CG_COLOR=always run 'say "provisioning instance"; log_as ok "done"' 0)
contains "styled: still boxed"           "$styled" "╭─"
out=$(CG_COLOR=always run 'say "provisioning instance"; log_as ok "done"')
lacks    "CG_JSON wins over CG_COLOR=always" "$out" "╭─"
check    "  and emits events instead"    "$(kinds <<<"$out" | tr '\n' ' ')" "step line:ok step_end "

echo "6. cg itself speaks it"
out=$(CG_JSON=1 timeout 60 ./cg help 2>&1 | head -3)
lacks "cg help stays readable text"      "$out" '"t":"'

# cg check ended with two lines printed by bare echo - raw output in a stream a
# program is reading.
check "the check-only ending is events too" \
      "$(sed -n '/if (( CHECK_ONLY )); then/,/^fi/p' lib/setup | grep -c 'log_as ok "preflight passed')" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
