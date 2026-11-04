#!/usr/bin/env bash
# The package installer is hurried while the box builds and put back before it runs,
# and waits for a busy lock instead of failing. (Where the time went is the
# supervisor's: tests/supervisor.sh.)
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }

echo "1. dpkg is hurried while building and put back before the machine runs"
base=$(cat lib/bootstrap.d/10-base.sh)
contains "unsafe-io is set at the start"        "$base" "force-unsafe-io"
contains "  on the AWS box only"                  "$(sed -n '/^if aws_box; then/,/^fi/p' lib/bootstrap.d/10-base.sh | tail -9)" "99-cg-build-unsafe-io"
contains "  and removed before the reboot"        "$(sed -n '/^progress "finishing up"/,/^cat > /p' lib/bootstrap.d/99-finish.sh)" "rm -f /etc/dpkg/dpkg.cfg.d/99-cg-build-unsafe-io"

echo "2. a busy package lock is waited for"
contains "the first boot has the image's own updater holding it" "$base" 'DPkg::Lock::Timeout "900"'

echo; echo "build-times: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
