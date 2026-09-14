#!/usr/bin/env bash
# Nothing that can fail may run before tailscale.
#
# Twice now a failure in an early stage has left a box with no network identity:
# once a corrupted presigned URL, once a GitHub 504 while fetching s5cmd. Both
# times the box was unreachable - no ssh, no log streaming, only
# get-console-output - for a failure that had nothing to do with networking.
#
# Tailscale is what makes a box debuggable. It goes first, and the stages before
# it must be the ones that cannot plausibly fail on a third party.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

num() { basename "$1" | cut -d- -f1; }
TS=$(num "$(ls lib/bootstrap.d/*-tailscale.sh)")

echo "1. tailscale runs before anything that fetches from a third party"
for f in lib/bootstrap.d/*.sh; do
  n=$(num "$f")
  # Stages that download from outside AWS: the ones that can 504 on us.
  if grep -qE 'curl .*https?://(github|raw\.githubusercontent|repo\.steampowered|packages\.mozilla)' "$f" 2>/dev/null; then
    if [[ $n -gt $TS ]]; then
      echo "  ok   $(basename "$f") is after tailscale ($n > $TS)"; pass=$((pass+1))
    else
      echo "  FAIL $(basename "$f") fetches from a third party at stage $n, before tailscale at $TS"
      fail=$((fail+1))
    fi
  fi
done

echo "1b. the library stage itself is after tailscale"
# It shells out to host/install-library.sh, which fetches s5cmd from GitHub -
# the actual 504 that killed a build - so the grep above does not see it.
LIB_N=$(num "$(ls lib/bootstrap.d/*-library.sh)")
if [[ $LIB_N -gt $TS ]]; then
  echo "  ok   library at $LIB_N, after tailscale at $TS"; pass=$((pass+1))
else
  echo "  FAIL library at $LIB_N runs before tailscale at $TS"; fail=$((fail+1))
fi

echo "2. the library stage does not abort the build"
# Its verifies are reported, never fatal: no mirror is a bad day, an unreachable
# GPU instance is one you can only kill from the AWS console.
lib=lib/bootstrap.d/*-library.sh
# A bare verify is one WITHOUT `|| true`. The first version of this check used
# `^verify .*[^)]$`, which matches the guarded lines too - they end in "true" -
# so it reported 4 unguarded verifies in a file that had none.
bare=$(grep -E '^verify ' $lib 2>/dev/null | grep -vc '|| true' || true)
guarded=$(grep -cE '^verify .*\|\| true$' $lib 2>/dev/null || true)
check "every verify is guarded" "${bare:-0}" "0"
if [[ ${guarded:-0} -ge 3 ]]; then echo "  ok   $guarded guarded verifies"; pass=$((pass+1));
else echo "  FAIL expected several guarded verifies, found ${guarded:-0}"; fail=$((fail+1)); fi

echo "3. the watchdog stage tolerates a failed download too"
wd=lib/bootstrap.d/*-watchdog.sh
if grep -q 'the box is still reachable' $wd 2>/dev/null; then
  echo "  ok   host-bundle failure is non-fatal"; pass=$((pass+1))
else
  echo "  FAIL a failed host-bundle download can still abort the build"; fail=$((fail+1))
fi

echo "4. third-party downloads retry rather than dying on one bad response"
for f in host/install-library.sh; do
  if grep -qE 'curl[^|]*--retry' "$f"; then echo "  ok   $(basename "$f") retries"; pass=$((pass+1));
  else echo "  FAIL $(basename "$f") fetches without --retry"; fail=$((fail+1)); fi
done

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
