#!/usr/bin/env bash
# One stream at a time, from this laptop.
#
# This came from a real double: a stream was open, the desktop app was closed
# and reopened - which forgets everything it was running - and Play started a
# SECOND `cg open`. Two Moonlight windows, one box, egress spent twice, and two
# runs waiting to end the same session. The lock is local and free; the app
# learns about it through `cg status`, never by looking for Moonlight itself.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.ssh" "$T/lib" "$T/run"
cp "$REPO/lib/game" "$T/lib/game"
cp "$REPO/lib/common.sh" "$REPO/lib/session.sh" "$T/lib/"
printf 'GAME_INSTANCE_ID=i-test\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\n' > "$T/.env"

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *InstanceLifecycle*) echo none ;;
  *State.Name*)        echo running ;;
  *)                   echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"
# The stream itself is not what this file is about: everything after the lock
# fails fast, so `cg open` gets as far as taking it and no further.
for c in tailscale moonlight ssh scp; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"
done

LOCK="$T/run/cg-session-$(id -u).pid"
open_() { ( cd "$T" && HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" \
              XDG_RUNTIME_DIR="$T/run" CG_COLOR=never timeout 25 bash ./lib/game up 2>&1 ); }
lib_() { ( cd "$T" && HOME="$T/home" PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" \
             bash -c 'source lib/common.sh; source lib/session.sh; '"$1" 2>&1 ); }

echo "1. a run with nothing streaming takes the lock and gives it back"
rm -f "$LOCK"; : > "$T/log"
out=$(open_)
lacks    "it is not refused"             "$out" "Already streaming"
check    "  and the lock is released"    "$([[ -f $LOCK ]] && echo left || echo gone)" "gone"

echo "2. while a session holds the lock, a second one refuses"
# A live process whose command line looks like cg's: sleep would be rejected as
# a reused pid, which is the point of that check.
cp "$REPO/lib/session.sh" "$T/cg-fake-session"
( cd "$T" && exec -a "bash ./lib/game up" sleep 30 ) & held=$!
printf '%s %s\n' "$held" "$(date +%s)" > "$LOCK"
out=$(open_)
contains "it says a stream is running"   "$out" "A stream from this laptop is already running"
contains "  names the pid"               "$out" "$held"
contains "  and says how to stop it"     "$out" "kill $held"
check    "  the box was never touched"   "$(grep -c 'start-instances' "$T/log" 2>/dev/null || true)" "0"
check    "  and the lock is not stolen"  "$(head -c ${#held} "$LOCK")" "$held"

echo "3. cg status says what is streaming"
check    "the lock is reported as held"  "$(lib_ 'session_running >/dev/null && echo held || echo free')" "held"
check    "  with an age"                 "$(lib_ 'a=$(session_age_s); [[ $a =~ ^[0-9]+$ ]] && echo secs || echo none')" "secs"
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null

echo "4. a pid that is gone is not a session"
printf '%s %s\n' "999999" "$(date +%s)" > "$LOCK"
check    "a dead pid is ignored"         "$(lib_ 'session_running >/dev/null && echo held || echo free')" "free"
out=$(open_)
lacks    "  so a run is not refused"     "$out" "Already streaming"

echo "5. a pid reused by something else is not a session either"
sleep 30 & other=$!
printf '%s %s\n' "$other" "$(date +%s)" > "$LOCK"
check    "an unrelated process is ignored" "$(lib_ 'session_running >/dev/null && echo held || echo free')" "free"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
rm -f "$LOCK"

echo "6. junk in the file is not a session"
printf 'not-a-pid\n' > "$LOCK"
check    "a malformed lock is ignored"   "$(lib_ 'session_running >/dev/null && echo held || echo free')" "free"
: > "$LOCK"
check    "an empty lock is ignored"      "$(lib_ 'session_running >/dev/null && echo held || echo free')" "free"
rm -f "$LOCK"
check    "no lock at all is free"        "$(lib_ 'session_running >/dev/null && echo held || echo free')" "free"

echo "6b. destroy closes the stream before it takes the box"
# Moonlight streaming a box that is being deleted goes black mid-push, and the
# `cg open` behind it then offers to end a box that is already gone.
( cd "$T" && exec -a "bash ./lib/game up" sleep 40 ) & held=$!
printf '%s %s\n' "$held" "$(date +%s)" > "$LOCK"
check    "the stream is up"              "$(lib_ 'session_running >/dev/null && echo held || echo free')" "held"
out=$(lib_ 'CG_YES=1 session_end_first')
contains "it says what is open"          "$out" "a stream is open from this laptop"
contains "  and closes it"               "$out" "stream closed"
check    "  the process is gone"         "$(kill -0 $held 2>/dev/null && echo alive || echo gone)" "gone"
wait "$held" 2>/dev/null
rm -f "$LOCK"
check    "nothing open, nothing said"    "$(lib_ 'CG_YES=1 session_end_first')" ""
check    "cg destroy calls it first"     "$(grep -c 'session_end_first' cg)" "1"
check    "  before the push or the box"  "$(awk '/session_end_first/{s=NR} /library_push/{if(s && NR>s){print "after"; exit}}' cg)" "after"

echo "7. it costs nothing to ask"
check    "no AWS call in the lock"       "$(grep -c 'aws ' lib/session.sh)" "0"
check    "  the lock lives in the run dir" \
         "$(lib_ 'session_file')" "$T/run/cg-session-$(id -u).pid"
check    "status reports it"             "$(grep -c 'f session.pid' lib/setup)" "2"
check    "  and cg open takes it"        "$(grep -c 'session_claim' lib/game)" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
