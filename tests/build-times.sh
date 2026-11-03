#!/usr/bin/env bash
# The build says where its time went, and installs faster while it runs without
# leaving the running machine on the unsafe setting.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }

echo "1. every progress marker leaves its time, on the AWS box only"
# The function as written, with its file moved into the sandbox.
fn=$(sed -n '/^progress() {/,/^}/p' lib/bootstrap.d/00-header.sh | sed "s#/var/log/cg-build-times.log#$T/times.log#")
for target in aws host; do
  rm -f "$T/times.log"
  ( eval "$fn"; CG_TARGET=$target; SECONDS=7; progress "installing desktop" >/dev/null; sleep 0 ) 2>/dev/null
  [[ $target == aws ]] && recorded=$(cat "$T/times.log" 2>/dev/null)
  check "$target: the time is recorded only on aws" "$([[ -s $T/times.log ]] && echo yes || echo no)" "$([[ $target == aws ]] && echo yes || echo no)"
done
check "  with the seconds first" "$recorded" "7 installing desktop"

echo "2. the summary names the steps that took a while, and only those"
awkp=$(grep -o "awk 'NR > 1.*}'" lib/bootstrap.d/99-finish.sh | head -1)
out=$(printf '0 a\n5 installing base packages\n30 setting up\n31 installing desktop (several minutes)\n140 installing nvidia driver\n300 finishing up\n' | eval "$awkp")
check "the long ones, with their seconds" "$out" "installing base packages 25s, installing desktop (several minutes) 109s, installing nvidia driver 160s"

echo "3. dpkg is hurried while building and put back before the machine runs"
contains "unsafe-io is set at the start, on the AWS box" "$(cat lib/bootstrap.d/10-base.sh)" "force-unsafe-io"
contains "  inside the aws block" "$(sed -n '/^if aws_box; then/,/^fi/p' lib/bootstrap.d/10-base.sh | tail -6)" "99-cg-build-unsafe-io"
contains "  and removed before the reboot" "$(sed -n '/^progress "finishing up"/,/^reboot/p' lib/bootstrap.d/99-finish.sh)" "rm -f /etc/dpkg/dpkg.cfg.d/99-cg-build-unsafe-io"

echo; echo "build-times: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
