#!/usr/bin/env bash
# Drives `cg init`'s pre-launch watchdog arming with a stubbed AWS CLI and ssh.
#
# It exists because of one bug. `watchdog_iam_ensure` used a temp file with
# `trap 'rm -f "$pol"' RETURN`, and a RETURN trap set inside a function is not
# scoped to that function - it stays installed and fires on every later function
# return, where $pol is out of scope. Under `set -u` that is fatal, so `cg init`
# exited with "pol: unbound variable" AFTER arming the watchdog and BEFORE
# launching anything.
#
# What made it survive: that code only runs on the branch where the IAM user
# does not exist - a first-ever init, or the first one after `cg destroy --all`.
# Every init in between took the early return and never installed the trap. So
# the case this file covers is specifically "the watchdog credential is absent".
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output contains '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.ssh" "$T/lib" "$T/host"
cp "$REPO/cg" "$T/cg"
cp "$REPO/lib/common.sh" "$T/lib/common.sh"
touch "$T/host/remote-watchdog.sh" "$T/host/remote-watchdog.service" \
      "$T/host/remote-watchdog.timer"
cat > "$T/.env" <<EOF
GAME_INSTANCE_ID=i-test
GAME_REGION=ap-south-2
GAME_TS_HOST=gamevps
GAME_WATCHDOG_HOST=ubuntu@10.0.0.1
EOF

# The thing init hands off to. If this never runs, init died on the way.
cat > "$T/lib/setup" <<'FAKE'
#!/usr/bin/env bash
echo "SETUP-REACHED" >> "$LOG"
FAKE
chmod +x "$T/lib/setup"

# WD_USER=0 is the case that matters: no watchdog user yet, so the creation
# branch runs.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "aws $args" >> "$LOG"
case "$args" in
  *"iam get-user"*)     [[ ${WD_USER:-0} == 1 ]] || exit 1; echo "gamevps-watchdog" ;;
  *"iam create-user"*)  echo '{"User":{"UserName":"gamevps-watchdog"}}' ;;
  *put-user-policy*)    : ;;
  *list-access-keys*)   echo "" ;;
  *create-access-key*)  printf 'AKIANEW\tsecretnew\n' ;;
  *get-caller-identity*) echo "arn:aws:iam::123456789012:user/gamevps-watchdog" ;;
  *describe-instances*) echo "None" ;;
  *)                    echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"

# The stub keeps what an install WRITES as the host's fingerprint ($T/fp) and
# serves it back on the next run - so "unchanged" is tested against the real
# fingerprint, not a copy of how it is computed.
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "ssh $*" >> "$LOG"
last="${WD_LAST_TS:-2026-01-01T00:00:00+00:00} i-test quiet: in=1B out=1B total=2B < 10485760B idle=1/6"
case "$*" in
  *"command -v aws"*)              exit 0 ;;   # CLI already present
  *installed.sha256*tee*|*tee*installed.sha256*) cat > "$FP" ;;
  # Only the WRITE takes stdin. The credential check also names this file
  # (". /etc/cloud-gaming-watchdog.conf; aws sts ...") and pipes nothing, so a
  # broader pattern had `cat` wait on stdin forever and hung the suite.
  *"tee /etc/cloud-gaming-watchdog.conf"*) cat >/dev/null ;;
  *"is-enabled remote-watchdog"*)  echo "${WD_ENABLED:-disabled}"
                                   cat "$FP" 2>/dev/null || echo ""
                                   echo "$last" ;;
  *list-timers*)                   echo "1 timers listed." ;;
  *"tail -1"*)                     echo "$last" ;;
  *)                               : ;;
esac
FAKE
chmod +x "$T/bin/ssh"
for c in scp tailscale; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\n' "$c" > "$T/bin/$c"
  chmod +x "$T/bin/$c"
done

run() {
  rm -f "$T/log"
  ( cd "$T" && HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" WD_USER="${WD_USER:-0}" \
      WD_ENABLED="${WD_ENABLED:-disabled}" FP="$T/fp" WD_LAST_TS="${WD_LAST_TS:-}" \
      bash ./cg init 2>&1 )
}
did() { grep -q "$1" "$T/log" 2>/dev/null && echo yes || echo no; }

echo "1. no watchdog user yet: init arms it and still reaches the launch"
out=$(WD_USER=0 run)
lacks "no unbound variable" "$out" "unbound variable"
lacks "no bash error at all" "$out" "cg: line"
check "created the IAM user"  "$(did 'iam create-user')" "yes"
check "attached the policy"   "$(did 'put-user-policy')" "yes"
check "issued a key"          "$(did 'create-access-key')" "yes"
check "installed on the host" "$(did 'ssh ')" "yes"
check "REACHED the launch"    "$(did 'SETUP-REACHED')" "yes"

echo "2. the key it issued is saved for the next run"
check "key in .env"    "$(grep -c '^GAME_WATCHDOG_AWS_KEY_ID=AKIANEW' "$T/.env")" "1"
check "secret in .env" "$(grep -c '^GAME_WATCHDOG_AWS_SECRET=secretnew' "$T/.env")" "1"

echo "3. an existing, working credential is left alone and still reaches the launch"
out=$(WD_USER=1 WD_ENABLED=enabled run)
lacks "no bash error"        "$out" "unbound variable"
check "did NOT recreate the user" "$(did 'iam create-user')" "no"
check "REACHED the launch"   "$(did 'SETUP-REACHED')" "yes"

echo "3b. nothing changed since the last install: no reinstall, no new check, one connection"
# The slow part of init was all of this, every time: ~8 ssh handshakes, a
# re-copy, an aws call from the host and a sleep, before the first line. And the
# "proof" ran a real watchdog check - which counts towards stopping the box.
[[ -s $T/fp ]] && { echo "  ok   the previous install recorded a fingerprint"; pass=$((pass+1)); } \
               || { echo "  FAIL no fingerprint was written by the install"; fail=$((fail+1)); }
out=$(WD_USER=1 WD_ENABLED=enabled WD_LAST_TS="$(date -Iseconds)" run)
check "no copy to the host"           "$(did '^scp ')" "no"
check "no reinstall"                  "$(did 'sudo install -m 755 /tmp/remote-watchdog.sh')" "no"
check "no new watchdog check run"     "$(did 'systemctl start remote-watchdog.service')" "no"
check "says it is up to date"         "$(grep -c 'off-site watchdog: up to date' <<<"$out")" "1"
check "and shows the last check"      "$(grep -c 'last check' <<<"$out")" "1"
lacks "a fresh check is not called stale" "$out" "not running"
check "ONE ssh round trip to the host" "$(grep -c '^ssh ' "$T/log")" "1"
check "REACHED the launch"            "$(did 'SETUP-REACHED')" "yes"

echo "3c. every ssh to the host shares one connection"
check "ControlMaster on"  "$(did 'ControlMaster=auto')" "yes"
check "a ControlPath set" "$(did 'ControlPath=')" "yes"

echo "3d. a last check older than the timer allows is flagged"
out=$(WD_USER=1 WD_ENABLED=enabled WD_LAST_TS="2026-01-01T00:00:00+00:00" run)
check "says the timer is not running" "$(grep -c 'not running' <<<"$out")" "1"

echo "3e. a changed credential DOES reinstall"
sed -i 's/^GAME_WATCHDOG_AWS_KEY_ID=.*/GAME_WATCHDOG_AWS_KEY_ID=AKIAROTATED/' "$T/.env"
out=$(WD_USER=1 WD_ENABLED=enabled WD_LAST_TS="$(date -Iseconds)" run)
check "copied to the host again"      "$(did '^scp ')" "yes"
check "and proved it with a new check" "$(did 'systemctl start remote-watchdog.service')" "yes"
lacks "no fixed sleep in the proof"   "$(grep 'systemctl start remote-watchdog.service' "$T/log")" "sleep 2;"

echo "4. an unreachable off-site host must not stop the launch"
# The whole promise of watchdog_ensure is that it is never fatal - a missing
# guard must not prevent you building a box.
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "ssh $*" >> "$LOG"
exit 255
FAKE
chmod +x "$T/bin/ssh"
out=$(WD_USER=1 run)
check "said it was unreachable" "$(grep -c 'unreachable' <<<"$out")" "1"
check "REACHED the launch"      "$(did 'SETUP-REACHED')" "yes"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
