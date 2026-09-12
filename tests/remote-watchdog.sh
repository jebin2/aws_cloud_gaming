#!/usr/bin/env bash
# Tests the off-site watchdog's decisions against a stubbed AWS CLI.
# It is a script whose job is to stop instances, so every branch is checked.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=host/remote-watchdog.sh
T=$(mktemp -d); mkdir -p "$T/bin" "$T/state"; pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

mkfake() { # mkfake <instance-line> <nin> <nout>
  [[ -d $T/bin ]] || { echo "harness bug: $T/bin missing"; exit 1; }
  cat > "$T/bin/aws" <<FAKE
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *describe-instances*) printf '%s\n' '$1' ;;
  *NetworkIn*)  printf '%s\n' '$2' ;;
  *NetworkOut*) printf '%s\n' '$3' ;;
  *stop-instances*)      echo stop      >> "$T/stops"; printf '{}\n' ;;
  *terminate-instances*) echo terminate >> "$T/stops"; printf '{}\n' ;;
  *) printf 'None\n' ;;
esac
FAKE
  chmod +x "$T/bin/aws"
}

run() { # run <idle-counter-start>
  [[ -x $T/bin/aws ]] || { echo "harness bug: no aws stub"; exit 1; }
  echo "${1:-0}" > "$T/state/idle"
  rm -f "$T/stops"
  PATH="$T/bin:$PATH" CFG=/dev/null GAME_REGION=ap-south-2 GAME_TS_HOST=gamevps \
    STATE="$T/state" LOG="$T/log" IDLE_LIMIT=3 bash "$SRC" >/dev/null 2>&1
  echo "$(cat "$T/state/idle" 2>/dev/null)|$(cat "$T/stops" 2>/dev/null || echo -)"
}

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)

echo "1. no running instance"
mkfake "None	None" 0 0
check "counter reset, no stop" "$(run 2)" "0|-"

echo "2. inside the boot grace (just launched)"
mkfake "i-abc	$now" 0 0
check "counter reset, no stop" "$(run 2)" "0|-"

echo "3. past grace, busy (20 MB in+out)"
mkfake "i-abc	$old" 15000000 5000000
check "counter reset, no stop" "$(run 2)" "0|-"

echo "4. past grace, quiet, below the limit"
mkfake "i-abc	$old" 1000 2000
check "counter increments, no stop" "$(run 1)" "2|-"

echo "5. past grace, quiet, limit reached"
mkfake "i-abc	$old" 1000 2000
check "stop issued, counter reset" "$(run 2)" "0|stop"

echo "6. running past grace but publishing NO metrics (wedged)"
mkfake "i-abc	$old" None None
check "counts as idle, no stop yet" "$(run 0)" "1|-"
check "stops once the limit is hit" "$(run 2)" "0|stop"

echo "7. a SPOT instance is terminated, not stopped"
# Stopping a spot instance disables its request: the box can never start again
# and keeps billing for its root volume. Terminating is safe because the request
# is one-time and cannot relaunch. The verb is read from the same
# describe-instances call that found the instance.
mkfake "i-abc	$old	spot" 1000 2000
check "terminate issued, counter reset" "$(run 2)" "0|terminate"

echo "8. an on-demand instance is stopped, not terminated"
mkfake "i-abc	$old	None" 1000 2000
check "stop issued" "$(run 2)" "0|stop"

echo "9. an unknown lifecycle falls back to stop, the reversible verb"
# A describe-instances response this parser does not understand must not cause
# the guard to destroy something.
mkfake "i-abc	$old" 1000 2000
check "stop issued" "$(run 2)" "0|stop"

echo; echo "passed $pass, failed $fail"; rm -rf "$T"; [[ $fail -eq 0 ]]
