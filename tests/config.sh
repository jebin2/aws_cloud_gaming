#!/usr/bin/env bash
# `cg config`: the .env settings as one registry, with the rules in one place.
#
# The app must never write .env itself - it asks cg, so a disk that cannot be
# shrunk, an expiry of 0 meaning "keep forever" and a token that must look like
# a token are enforced once, here, rather than in a renderer.
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

mkdir -p "$T/repo" "$T/home"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
printf 'GAME_DISK_GB=80\nGAME_NTFY_URL=https://ntfy.sh/topic-abc\n' > "$T/repo/.env"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/home/aws"; chmod +x "$T/home/aws"

cg_() { ( cd "$T/repo" && env -i PATH="$T/home:$PATH" HOME="$T/home" CG_COLOR=never \
            bash ./cg "$@" 2>&1 ); }
envfile() { cat "$T/repo/.env"; }
jq_() { python3 -c 'import json,sys
rows = {r["key"]: r for r in json.load(sys.stdin)}
r = rows[sys.argv[1]]
print(json.dumps(r[sys.argv[2]]))' "$1" "$2"; }

echo "1. the registry, as data"
j=$(cg_ config --json)
check    "valid JSON"                    "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' <<<"$j")" "14"
check    "a set value is reported"       "$(jq_ GAME_DISK_GB value <<<"$j")" '"80"'
check    "  with its default"            "$(jq_ GAME_DISK_GB default <<<"$j")" '"50"'
check    "  and its minimum"             "$(jq_ GAME_DISK_GB rule <<<"$j")" '"30"'
check    "an unset one falls back"       "$(jq_ GAME_ARCHIVE_EXPIRY_DAYS effective <<<"$j")" '"14"'
check    "  and is marked unset"         "$(jq_ GAME_ARCHIVE_EXPIRY_DAYS is_set <<<"$j")" "false"

echo "2. secrets are never handed out"
check    "the ntfy topic is set"         "$(jq_ GAME_NTFY_URL is_set <<<"$j")" "true"
check    "  but its value is withheld"   "$(jq_ GAME_NTFY_URL value <<<"$j")" "null"
check    "  and it is marked secret"     "$(jq_ GAME_NTFY_URL secret <<<"$j")" "true"
lacks    "the topic never appears"       "$j" "topic-abc"
check    "the API token is secret too"   "$(jq_ TAILSCALE_API_KEY secret <<<"$j")" "true"

echo "3. set, with the rules enforced"
out=$(cg_ config set GAME_DISK_GB 120)
contains "a valid number is taken"       "$(envfile)" "GAME_DISK_GB=120"
contains "  and it says when it applies" "$out" "applies to the next cg init"
out=$(cg_ config set GAME_DISK_GB 12)
contains "under the minimum is refused"  "$out" "must be at least 30"
contains "  keeping the old value"       "$(envfile)" "GAME_DISK_GB=120"
out=$(cg_ config set GAME_DISK_GB fifty)
contains "not a number is refused"       "$out" "must be a whole number"
out=$(cg_ config set GAME_ARCHIVE_EXPIRY_DAYS 0)
contains "0 days is allowed - keep forever" "$(envfile)" "GAME_ARCHIVE_EXPIRY_DAYS=0"
out=$(cg_ config set GAME_SPOT maybe)
contains "a choice is checked"           "$out" "must be one of: auto, 1, 0"
out=$(cg_ config set GAME_NOT_A_SETTING 1)
contains "an unknown key is refused"     "$out" "unknown setting"
out=$(cg_ config set TAILSCALE_API_KEY not-a-token)
contains "a token must look like one"    "$out" "does not look like a Tailscale token"
out=$(cg_ config set EMAIL_ALERTS nope)
contains "an address must look like one" "$out" "does not look like an email"

echo "4. setting a secret says nothing about it"
out=$(cg_ config set TAILSCALE_API_KEY tskey-api-abc123)
contains "it confirms"                   "$out" "TAILSCALE_API_KEY = set"
lacks    "  without echoing the token"   "$out" "tskey-api-abc123"
contains "  and it is written"           "$(envfile)" "TAILSCALE_API_KEY=tskey-api-abc123"
out=$(cg_ config set GAME_NTFY_URL "")
contains "clearing one is allowed"       "$out" "GAME_NTFY_URL = cleared"
contains "  remembered as off"           "$(envfile)" "GAME_NTFY_URL="
out=$(cg_ config set GAME_NTFY_URL "not a url!")
contains "a bad address is refused"      "$out" "not a valid ntfy topic or URL"

echo "4b. get: the one deliberate way to see a secret"
check    "it prints the value, alone"    "$(cg_ config get TAILSCALE_API_KEY)" "tskey-api-abc123"
check    "  a plain setting too"         "$(cg_ config get GAME_DISK_GB)" "120"
contains "an unknown key is refused"     "$(cg_ config get GAME_NOPE)" "unknown setting"

echo "5. the human view"
out=$(cg_ config)
contains "a table of settings"           "$out" "SETTING"
contains "  values"                      "$out" "GAME_DISK_GB"
contains "  notes"                       "$out" "Cannot be shrunk later"
contains "  secrets as set or not"       "$out" "not set"
lacks    "  and never a secret's value"  "$out" "tskey-api-abc123"

echo "6. wired in"
check "cg dispatches config"             "$(grep -c '^  config)' cg)" "1"
check "  and help mentions it"           "$(grep -c 'cg config \[set|get <k>\]' cg)" "1"
check "the registry is pipe separated, not tabs" "$(grep -c 'a tab is IFS' lib/config.sh)" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
