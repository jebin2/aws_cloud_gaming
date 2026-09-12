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

mkdir -p "$T/bin" "$T/lib" "$T/host"
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

cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "ssh $*" >> "$LOG"
case "$*" in
  *"command -v aws"*)              exit 0 ;;   # CLI already present
  *"is-enabled remote-watchdog"*)  echo "${WD_ENABLED:-disabled}" ;;
  *list-timers*)                   echo "1 timers listed." ;;
  *"tail -1"*)                     echo "2026-01-01T00:00:00+00:00 no running instance tagged gamevps - nothing to do" ;;
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
  ( cd "$T" && LOG="$T/log" PATH="$T/bin:$PATH" WD_USER="${WD_USER:-0}" \
      WD_ENABLED="${WD_ENABLED:-disabled}" bash ./cg init 2>&1 )
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
