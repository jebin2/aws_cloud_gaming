#!/usr/bin/env bash
# ntfy notifications from the laptop side: off unless GAME_NTFY_URL is set, a
# malformed value is off too, a send never fails a command, and the topic -
# effectively a password on ntfy.sh - is never printed.
#
# The Lambda's notifications are in tests/cloud-watchdog.sh, the on-host
# watchdog's in tests/idle-watchdog.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' contains '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home"
# Records every argument separately, so a header or the body can be asserted.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf 'CURL' >> "$LOG"
for a in "$@"; do printf ' [%s]' "$a" >> "$LOG"; done
echo >> "$LOG"
exit "${CURL_RC:-0}"
FAKE
chmod +x "$T/bin/curl"

url() { GAME_NTFY_URL="$1" bash -c 'source lib/common.sh; cg_ntfy_url'; }

echo "1. the value: a topic or a full URL; anything else is off"
check "unset is off"                  "$(url '')" ""
check "a topic goes to ntfy.sh"       "$(url 'cg_Alerts-7f3k')" "https://ntfy.sh/cg_Alerts-7f3k"
check "a full URL is kept"            "$(url 'https://ntfy.sh/abc')" "https://ntfy.sh/abc"
check "self-hosted, http and a port"  "$(url 'http://100.64.0.9:8080/games')" "http://100.64.0.9:8080/games"
long=$(printf 'a%.0s' {1..65})
for bad in 'has space' 'https://ntfy.sh/a/b' 'https://ntfy.sh/t?x=1' "$long" 'ftp://x/t' 'https://ntfy.sh/' 'a,b'; do
  check "rejected: ${bad:0:24}" "$(url "$bad")" ""
done

send() { # send <GAME_NTFY_URL> [curl exit code]
  ( cd "$REPO" && LOG="$T/log" PATH="$T/bin:$PATH" TS_HOST=gamevps CG_COLOR=never \
      GAME_NTFY_URL="$1" CURL_RC="${2:-0}" \
      bash -c 'source lib/common.sh; cg_notify "box ready" "Built." high tada; echo "rc=$?"' 2>&1 )
}

echo "2. sending"
rm -f "$T/log"; out=$(send '')
check    "unset: no request"            "$(cat "$T/log" 2>/dev/null)" ""
check    "  and returns 0"              "$out" "rc=0"
rm -f "$T/log"; out=$(send 'mytopic')
contains "posts to the URL"             "$(cat "$T/log")" "[https://ntfy.sh/mytopic]"
contains "the host is in the title"     "$(cat "$T/log")" "[Title: gamevps: box ready]"
contains "the message is the body"      "$(cat "$T/log")" "[-d] [Built.]"
contains "with its priority"            "$(cat "$T/log")" "[Priority: high]"
contains "and a time limit"             "$(cat "$T/log")" "[-m] [5]"
rm -f "$T/log"; out=$(send 'has space')
check    "malformed: no request"        "$(cat "$T/log" 2>/dev/null)" ""
rm -f "$T/log"; out=$(send 'mytopic' 7)
contains "a failed send is logged"      "$out" "notification not sent"
contains "  and still returns 0"        "$out" "rc=0"
lacks    "  without printing the topic" "$out" "mytopic"

echo "3. the cloud watchdog gets the same URL, or none at all"
envline() { TS_HOST=gamevps GAME_S3_BUCKET=b GAME_NTFY_URL="$1" \
  bash -c 'source lib/common.sh; source lib/cloud-watchdog.sh; cw_env 123456789012'; }
contains "set: passed on, normalised"   "$(envline mytopic)" ",CG_NTFY_URL=https://ntfy.sh/mytopic}"
lacks    "unset: not passed at all"     "$(envline '')" "CG_NTFY_URL"
lacks    "malformed: not passed at all" "$(envline 'has space')" "CG_NTFY_URL"

echo "4. cg notify"
mkdir -p "$T/repo"
cp -r "$REPO/cg" "$REPO/lib" "$T/repo/"
cgnotify() { # cgnotify <.env line or empty> [curl exit code]
  rm -f "$T/log"
  printf '%s\n' "$1" > "$T/repo/.env"
  ( cd "$T/repo" && HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" CG_COLOR=never \
      CURL_RC="${2:-0}" bash ./cg notify 2>&1; echo "rc=$?" )
}
out=$(cgnotify '')
contains "unset: says what to set"      "$out" "set GAME_NTFY_URL"
contains "  and fails"                  "$out" "rc=1"
out=$(cgnotify 'GAME_NTFY_URL=has space')
contains "malformed: says so"           "$out" "not a topic"
contains "  and fails"                  "$out" "rc=1"
out=$(cgnotify 'GAME_NTFY_URL=secret-topic-4q9z')
contains "sent"                         "$out" "sent to ntfy.sh"
contains "  and succeeds"               "$out" "rc=0"
lacks    "  naming the host, not the topic" "$out" "secret-topic-4q9z"
check    "  one request"                "$(grep -c '^CURL' "$T/log")" "1"
out=$(cgnotify 'GAME_NTFY_URL=secret-topic-4q9z' 6)
contains "unreachable: says so"         "$out" "could not send to ntfy.sh"
contains "  and fails"                  "$out" "rc=1"
lacks    "  still without the topic"    "$out" "secret-topic-4q9z"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
