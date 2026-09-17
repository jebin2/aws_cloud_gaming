#!/usr/bin/env bash
# The .env settings: asked for when missing, saved, and never printed.
#
# On a new laptop with no .env, cg check --fix asked for the auth key and alert
# email, kept them for that one run only, and never asked for the Tailscale API
# key or the ntfy address. A cg init from there would then have redeployed the
# cloud watchdog without notifications. Runs in a copy of lib/, so no real .env
# is touched; AWS is a fake.
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

mkdir -p "$T/bin" "$T/home" "$T/repo"
cp -r lib lambda "$T/repo/"
# NTFY: what the deployed watchdog holds as CG_NTFY_URL ("None" when unset).
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
[[ ${AWS_FAIL:-0} == 1 ]] && exit 255
case "$*" in *get-function-configuration*) echo "${NTFY:-None}" ;; esac
FAKE
chmod +x "$T/bin/aws"

fresh() { rm -f "$T/repo/.env" "$T/log"; touch "$T/log"; }
# run '<code>' [stdin] - EXTRA holds KEY=value pairs, as lib/setup's .env loader exports them.
run() {
  # shellcheck disable=SC2086
  ( cd "$T/repo" && printf '%b' "${2:-}" | env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" LOG="$T/log" \
      NTFY="${NTFY:-None}" AWS_FAIL="${AWS_FAIL:-0}" REGION=ap-south-2 TS_HOST=gamevps CG_COLOR=never ${EXTRA:-} \
      bash -c 'source lib/common.sh; source lib/cloud-watchdog.sh; source lib/settings.sh; settings_tty() { true; }; '"$1" 2>&1 )
}
envfile() { cat "$T/repo/.env" 2>/dev/null; }

echo "1. env_set"
fresh
run 'env_set A 1; env_set B '\''x y=$z'\''; env_set A 2' >/dev/null
check "replaces a key, keeps the others, in order" "$(envfile)" $'B=x y=$z\nA=2'
check "  readable by you alone"               "$(stat -c %a "$T/repo/.env")" "600"
printf 'C=3' > "$T/repo/.env"
run 'env_set D 4' >/dev/null
check "a last line with no newline is kept"   "$(envfile)" $'C=3\nD=4'

echo "2. cw_adopt_ntfy: notifications carry over from the deployed watchdog"
fresh
r=$(NTFY=https://ntfy.sh/topic-abc123 run 'cw_adopt_ntfy; echo "rc=$?"; echo "now=${GAME_NTFY_URL:-}"')
contains "copied into .env"                   "$(envfile)" "GAME_NTFY_URL=https://ntfy.sh/topic-abc123"
contains "  and used by this run"             "$r" "now=https://ntfy.sh/topic-abc123"
contains "  said"                             "$r" "copied the ntfy address from the cloud watchdog"
lacks    "  without printing it"              "$(grep -v '^now=' <<<"$r")" "topic-abc123"
fresh
r=$(NTFY=https://ntfy.sh/topic-abc123 EXTRA="GAME_NTFY_URL=" run 'cw_adopt_ntfy; echo "rc=$?"')
check    "GAME_NTFY_URL= (off): AWS not even asked" "$(cat "$T/log")" ""
lacks    "  nothing written"                  "$(envfile)" "GAME_NTFY_URL"
fresh
r=$(NTFY=https://ntfy.sh/topic-abc123 EXTRA="GAME_NTFY_URL=https://ntfy.sh/mine" run 'cw_adopt_ntfy')
check    "already set: left alone"            "$(cat "$T/log")" ""
fresh
r=$(run 'cw_adopt_ntfy; echo "rc=$?"')
contains "watchdog without notifications: nothing" "$r" "rc=0"
check    "  nothing written"                  "$(envfile)" ""
fresh
r=$(AWS_FAIL=1 run 'cw_adopt_ntfy; echo "rc=$?"')
contains "AWS not answering: carries on"      "$r" "rc=0"
check    "  nothing written"                  "$(envfile)" ""

echo "3. cg check without --fix: the two required settings, asked and saved"
fresh
r=$(run 'settings_prompts 0; echo "rc=$?"' 'tskey-auth-1\nme@example.com\n')
contains "auth key saved"                     "$(envfile)" "TAILSCALE_AUTH_KEY=tskey-auth-1"
contains "  alert email saved"                "$(envfile)" "EMAIL_ALERTS=me@example.com"
lacks    "  the auth key is not printed"      "$r" "tskey-auth-1"
lacks    "optional ones not asked"            "$r" "Enter to skip"
contains "  but warned about"                 "$r" "no TAILSCALE_API_KEY"
contains "  and it carries on"                "$r" "rc=0"

echo "4. cg check --fix: the optional ones too, and a skip is remembered"
fresh
r=$(run 'settings_prompts 1; echo "rc=$?"' 'tskey-auth-1\nme@example.com\ntskey-api-9\n\n\n\n')
contains "API token saved"                    "$(envfile)" "TAILSCALE_API_KEY=tskey-api-9"
lacks    "  and not printed"                  "$r" "tskey-api-9"
contains "  and used"                         "$r" "Tailscale API key set"
check    "ntfy skipped: saved as empty, so not asked again" "$(grep -c '^GAME_NTFY_URL=$' "$T/repo/.env")" "1"
contains "Enter on the disk size: the default, saved" "$(envfile)" "GAME_DISK_GB=50"
contains "Enter on the expiry: the default, saved"    "$(envfile)" "GAME_ARCHIVE_EXPIRY_DAYS=14"
contains "  the disk asked with its default shown"    "$r" "root disk GB [50]"
contains "  and the expiry"                           "$r" "after how many days [14]"
contains "  notifications off"                "$r" "notifications off"
fresh
r=$(EXTRA="TAILSCALE_AUTH_KEY=k EMAIL_ALERTS=e TAILSCALE_API_KEY= GAME_NTFY_URL= GAME_DISK_GB=50 GAME_ARCHIVE_EXPIRY_DAYS=14" run 'settings_prompts 1; echo "rc=$?"')
lacks    "everything mentioned: nothing asked" "$r" "paste"
lacks    "  nor the disk"                     "$r" "root disk GB ["
lacks    "  nor the ntfy question"            "$r" "ntfy topic or URL"
check    "  nothing written"                  "$(envfile)" ""

echo "5. --fix on a laptop whose watchdog already notifies"
fresh
r=$(NTFY=https://ntfy.sh/topic-abc123 EXTRA="TAILSCALE_AUTH_KEY=k EMAIL_ALERTS=e" run 'settings_prompts 1' '\n')
contains "the address is copied"              "$(envfile)" "GAME_NTFY_URL=https://ntfy.sh/topic-abc123"
lacks    "  so it is not asked for"           "$r" "ntfy topic or URL"
contains "  and notifications stay on"        "$r" "notifications on"

echo "6. a wrong ntfy value is not saved"
fresh
r=$(EXTRA="TAILSCALE_AUTH_KEY=k EMAIL_ALERTS=e TAILSCALE_API_KEY= GAME_DISK_GB=50 GAME_ARCHIVE_EXPIRY_DAYS=14" run 'settings_prompts 1' 'not a url!\n')
contains "said"                               "$r" "not a valid ntfy topic or URL"
lacks    "  not saved"                        "$(envfile)" "GAME_NTFY_URL"

echo "7. no auth key given: stops"
fresh
r=$(run 'settings_prompts 0; echo "rc=$?"' '\n')
contains "stops"                              "$r" "no auth key given"
contains "  after saying how to paste"        "$r" "nothing arrived - paste with Ctrl+Shift+V"
lacks    "  before going on"                  "$r" "rc=0"

echo "9. pasting: what the terminal adds is removed, and what arrived is confirmed"
fresh
r=$(run 'settings_prompts 0' '\e[200~tskey-auth-abc-DEF\e[201~\nme@example.com\n')
check    "bracketed-paste markers removed"    "$(grep '^TAILSCALE_AUTH_KEY=' "$T/repo/.env")" "TAILSCALE_AUTH_KEY=tskey-auth-abc-DEF"
contains "  a * per character, markers not shown" "$r" "$(printf '%.0s*' {1..18})"
lacks    "  and no more"                      "$r" "$(printf '%.0s*' {1..19})"
lacks    "  without printing it"              "$r" "abc-DEF"
fresh
run 'settings_prompts 0' '  tskey-auth-x  \nme@example.com\n' >/dev/null
check    "spaces around it removed"           "$(grep '^TAILSCALE_AUTH_KEY=' "$T/repo/.env")" "TAILSCALE_AUTH_KEY=tskey-auth-x"
fresh
r=$(run 'settings_prompts 0' 'hello\ntskey-auth-2\nme@example.com\n')
contains "a wrong paste is said"              "$r" "that is not a Tailscale auth key"
check    "  and asked again"                  "$(grep '^TAILSCALE_AUTH_KEY=' "$T/repo/.env")" "TAILSCALE_AUTH_KEY=tskey-auth-2"
fresh
r=$(run 'settings_prompts 0' '\ntskey-auth-3\nme@example.com\n')
contains "nothing pasted: how to paste"       "$r" "Ctrl+Shift+V"
check    "  and asked again"                  "$(grep '^TAILSCALE_AUTH_KEY=' "$T/repo/.env")" "TAILSCALE_AUTH_KEY=tskey-auth-3"
fresh
r=$(EXTRA="TAILSCALE_AUTH_KEY=k EMAIL_ALERTS=e GAME_NTFY_URL= GAME_DISK_GB=50 GAME_ARCHIVE_EXPIRY_DAYS=14" run 'settings_prompts 1' 'nope\nnope\nnope\n')
contains "a wrong API token three times: said" "$r" "no valid API token - not saved"
lacks    "  and not saved"                    "$(envfile)" "TAILSCALE_API_KEY"

echo "10. typing: backspace removes a character"
fresh
run 'settings_prompts 0' 'tskey-auth-abX\x7fc\nme@example.com\n' >/dev/null
check    "the deleted character is gone"      "$(grep '^TAILSCALE_AUTH_KEY=' "$T/repo/.env")" "TAILSCALE_AUTH_KEY=tskey-auth-abc"

echo "11. disk size and archive expiry: asked with defaults, checked, and reported"
BASE="TAILSCALE_AUTH_KEY=k EMAIL_ALERTS=e TAILSCALE_API_KEY= GAME_NTFY_URL="
fresh
r=$(EXTRA="$BASE GAME_ARCHIVE_EXPIRY_DAYS=14" run 'settings_prompts 1' '80\n')
contains "a disk size typed: saved"           "$(envfile)" "GAME_DISK_GB=80"
contains "  and reported"                     "$r" "root disk 80 GB"
fresh
r=$(EXTRA="$BASE GAME_ARCHIVE_EXPIRY_DAYS=14" run 'settings_prompts 1' 'abc\n10\n60\n')
contains "not a number, or under 30: said"    "$r" "a whole number, at least 30"
contains "  and asked again"                  "$(envfile)" "GAME_DISK_GB=60"
fresh
r=$(EXTRA="$BASE GAME_DISK_GB=50" run 'settings_prompts 1' '0\n')
contains "expiry 0: saved"                    "$(envfile)" "GAME_ARCHIVE_EXPIRY_DAYS=0"
contains "  and reported as kept forever"     "$r" "kept forever"
fresh
r=$(EXTRA="$BASE GAME_DISK_GB=50" run 'settings_prompts 1')
lacks    "no answer at all: nothing saved"    "$(envfile)" "GAME_ARCHIVE_EXPIRY_DAYS"
contains "  and said"                         "$r" "no expiry saved - the default, 14 days, is used"
fresh
r=$(EXTRA="TAILSCALE_AUTH_KEY=k EMAIL_ALERTS=e" run 'settings_prompts 0')
lacks    "without --fix: not asked"           "$r" "root disk GB ["
contains "  but the defaults are reported"    "$r" "root disk 50 GB (the default)"
contains "  both of them"                     "$r" "deleted after 14 days with no box"

echo "8. wired in"
check "setup asks through it"                 "$(grep -c '^settings_prompts "$FIX"' lib/setup)" "1"
check "cg init adopts before it deploys"      "$(sed -n '/^watchdog_ensure()/,/^}/p' cg | grep -c 'cw_adopt_ntfy')" "1"
check "cg watchdog install adopts too"        "$(sed -n '/^cmd_watchdog()/,/^}/p' cg | grep -c 'cw_adopt_ntfy')" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
