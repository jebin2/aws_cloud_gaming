#!/usr/bin/env bash
# Layer 3 must be armed only WHILE a stream is running.
#
# The CloudWatch alarm watches NetworkOut alone - CloudWatch refuses EC2 actions
# on a metric-math expression, so it cannot sum in+out and cannot tell a 140 GB
# download from an idle box. During a session that is fine: no outbound traffic
# for 30 minutes means the stream is dead. After a session it is simply wrong.
#
# `cg open` armed it and nothing ever disarmed it, so it stayed armed forever
# after the first session. It terminated two boxes mid-download, thirty minutes
# after streaming stopped, and its own history recorded both:
#
#   Action: Terminate EC2 Instance 'i-03de71b0974ddecf0' action completed successfully
#   Action: Terminate EC2 Instance 'i-0a384809f81212531' action completed successfully
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0

check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
cnt()   { local n; n=$(grep -c "$1" "$T/log" 2>/dev/null) || true; echo "${n:-0}"; }

mkdir -p "$T/bin" "$T/home"
cp -r "$REPO/lib" "$T/lib"
printf 'GAME_INSTANCE_ID=i-test\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\n' > "$T/.env"

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *State.Name*|*describe-instances*) echo running ;;
  *) echo None ;;
esac
FAKE
# The stream itself: exits immediately, standing in for a session that ended.
printf '#!/usr/bin/env bash\necho "MOONLIGHT $*" >> "$LOG"\nexit 0\n' > "$T/bin/moonlight"
# Point at localhost and actually LISTEN, so `up`'s "waiting for sunshine" TCP
# probe succeeds at once. Without a listener each run spent ~2 minutes retrying
# a port nothing answers, which is the whole suite's runtime spent on a wait
# that is not what this file tests.
printf '#!/usr/bin/env bash\ncase "$*" in *ip*) echo 127.0.0.1 ;; *) exit 0 ;; esac\n' > "$T/bin/tailscale"
python3 - "$T/listener.pid" <<'LISTEN' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:    s.bind(("127.0.0.1", 47989)); s.listen(16)
except OSError: sys.exit(0)
open(sys.argv[1], "w").write(str(1))
end = time.time() + 180
while time.time() < end:
    s.settimeout(2)
    try: s.accept()[0].close()
    except Exception: pass
LISTEN
LISTENER=$!
trap 'kill $LISTENER 2>/dev/null; rm -rf "$T"' EXIT
sleep 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/ssh"
printf '#!/usr/bin/env bash\necho "CG-DESTROY" >> "$LOG"\n' > "$T/cg"
chmod +x "$T/bin"/* "$T/cg"

# 'n' at the end-of-session prompt: leave the box running, which is exactly the
# state the alarm used to destroy.
rm -f "$T/log"
( cd "$T" && printf 'n\n' | HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" \
    timeout 60 bash ./lib/game up >/dev/null 2>&1 ) || true

echo "1. the alarm is armed when the session starts"
check "enable-alarm-actions called" "$(cnt 'enable-alarm-actions')" "1"

echo "2. and DISARMED when the stream ends"
check "disable-alarm-actions called" "$(cnt 'disable-alarm-actions')" "1"

echo "3. in that order - armed first, disarmed after"
order=$(grep -oE 'enable-alarm-actions|disable-alarm-actions' "$T/log" | tr '\n' ' ')
check "arm then disarm" "$order" "enable-alarm-actions disable-alarm-actions "

echo "4. disarming happens even when the box is left running"
# The failure mode: user declines to stop, box keeps downloading, alarm fires
# thirty minutes later and terminates it.
check "box was not destroyed" "$(cnt 'CG-DESTROY')" "0"
check "still disarmed anyway"  "$(cnt 'disable-alarm-actions')" "1"

echo "5. a session that dies before streaming still disarms"
# Sunshine never comes up, `up` dies at the wait. Without a trap the alarm stays
# armed with no session to justify it - the same end state as never disarming.
rm -f "$T/log"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/moonlight"; chmod +x "$T/bin/moonlight"
( cd "$T" && printf 'n\n' | HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" \
    timeout 60 bash ./lib/game up >/dev/null 2>&1 ) || true
check "armed"    "$(cnt 'enable-alarm-actions')"  "1"
check "disarmed despite the failure" "$(cnt 'disable-alarm-actions')" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
