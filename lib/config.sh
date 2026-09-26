#!/usr/bin/env bash
# The settings in .env: what they are, what they may be, and who applies them.
#
# One registry, read by `cg config` and by the app. A screen that wants to change
# a setting asks cg to do it, so the rules - a disk that cannot be shrunk, an
# expiry of 0 meaning "keep forever", a token that must look like a token - live
# here and not in a renderer.
#
# Fields, pipe separated: key, kind, default, rule, note. Not tabs: a tab is IFS
# whitespace, so bash's `read` collapses two in a row and every later column
# slides one to the left - an empty default silently became the note.
#   kind   number | text | choice | secret | ntfy | email
#   rule   number: the minimum. choice: the allowed values, comma separated.
CONFIG_ROWS() {
  cat <<'ROWS'
GAME_DISK_GB|number|50|30|Root disk in GB. Cannot be shrunk later; applies to the next build.
GAME_ARCHIVE_EXPIRY_DAYS|number|14|0|Days with no box before the cloud watchdog deletes the archive. 0 keeps it forever.
GAME_INSTANCE_TYPE|text|g6.xlarge||The EC2 instance type. Its GPU quota must cover it.
GAME_REGION|text|ap-south-2||The AWS region everything lives in.
GAME_SPOT|choice|auto|auto,1,0|Purchase model: spot, on demand, or spot whenever the quota allows.
GAME_BUDGET_INR|number|5000|100|Monthly budget. It emails you; it stops nothing.
GAME_WATCHDOG_IDLE_MIN|number|30|10|Minutes of quiet before the cloud watchdog ends the box.
GAME_WATCHDOG_STUCK_MIN|number|60|40|Minutes before a stuck shutdown is forced. Never inside the push's 30.
GAME_NTFY_URL|ntfy|||Phone notifications: an ntfy topic or full URL. Empty turns them off.
TAILSCALE_API_KEY|secret|||Tailscale API token. Prunes old nodes and turns off key expiry. Empty goes without.
EMAIL_ALERTS|email|||Where budget alerts are sent. Comma separated for several.
GAME_RES|text|||Moonlight resolution, e.g. 1920x1080. Empty leaves Moonlight's own setting.
GAME_FPS|number|60|24|Moonlight frame rate.
GAME_BITRATE_KBPS|number|20000|500|Moonlight bitrate. Lower it to cut streaming egress proportionally.
ROWS
}

config_field() { # config_field <key> <1-5>
  CONFIG_ROWS | awk -F'|' -v k="$1" -v f="$2" '$1 == k { print $f; exit }'
}

# config_validate <key> <value> - prints the reason it is refused, or nothing.
config_validate() {
  local key=$1 value=$2 kind rule
  kind=$(config_field "$key" 2); rule=$(config_field "$key" 4)
  [[ -n $kind ]] || { echo "unknown setting '$key'"; return; }
  [[ $value == *$'\n'* ]] && { echo "a setting cannot contain a newline"; return; }
  case $kind in
    number)
      [[ $value =~ ^[0-9]+$ ]] || { echo "must be a whole number"; return; }
      (( 10#$value >= ${rule:-0} )) || { echo "must be at least ${rule:-0}"; return; } ;;
    choice)
      [[ ,$rule, == *,$value,* ]] || { echo "must be one of: ${rule//,/, }"; return; } ;;
    secret)
      [[ -z $value || $value =~ ^tskey-[A-Za-z0-9-]+$ ]] || { echo "does not look like a Tailscale token"; return; } ;;
    ntfy)
      [[ -z $value || -n $(GAME_NTFY_URL="$value" cg_ntfy_url) ]] \
        || { echo "not a valid ntfy topic or URL"; return; } ;;
    email)
      [[ $value == *@*.* ]] || { echo "does not look like an email address"; return; } ;;
    text)
      [[ -n $value ]] || { echo "cannot be empty"; return; } ;;
  esac
}

# config_json - every setting, its value and whether it is set. A secret's value
# is never printed: an app shows "set", and may replace it, never read it.
config_json() {
  CONFIG_ROWS | python3 -c '
import json, os, sys
out = []
for line in sys.stdin:
    if not line.strip(): continue
    key, kind, default, rule, note = (line.rstrip("\n").split("|") + [""] * 5)[:5]
    raw = os.environ.get(key)
    secret = kind in ("secret", "ntfy")
    out.append({
        "key": key, "kind": kind, "note": note,
        "default": default or None,
        "rule": rule or None,
        "secret": secret,
        "is_set": raw is not None and raw != "",
        "mentioned": raw is not None,
        "value": None if secret else (raw if raw not in (None, "") else None),
        "effective": None if secret else (raw if raw not in (None, "") else (default or None)),
    })
print(json.dumps(out, indent=2))'
}

# config_set <key> <value> - validated, then written to .env by env_set.
config_set() {
  local key=$1 value=${2-} why
  why=$(config_validate "$key" "$value")
  [[ -z $why ]] || die "$key: $why"
  env_set "$key" "$value" || die "could not write .env"
  export "$key=$value"
  local shown=$value
  [[ $(config_field "$key" 2) == secret || $(config_field "$key" 2) == ntfy ]] \
    && shown=$([[ -n $value ]] && echo "set" || echo "cleared")
  log_as ok "$key = $shown"
  case $key in
    GAME_DISK_GB|GAME_INSTANCE_TYPE|GAME_REGION|GAME_SPOT)
      log_as info "applies to the next cg init" ;;
    GAME_ARCHIVE_EXPIRY_DAYS|GAME_WATCHDOG_IDLE_MIN|GAME_WATCHDOG_STUCK_MIN|GAME_NTFY_URL)
      log_as info "applies when the cloud watchdog is next deployed: cg watchdog install" ;;
    GAME_BUDGET_INR|EMAIL_ALERTS)
      log_as info "applies at the next cg init, which rewrites the budget" ;;
  esac
}

# config_get <key> - the value, raw, for someone who asked to see it. Secrets are
# hidden everywhere else; this is the deliberate exception, and it prints nothing
# but the value so it can be piped.
config_get() {
  local key=$1
  [[ -n $(config_field "$key" 2) ]] || die "unknown setting '$key'"
  printf '%s\n' "${!key-}"
}

config_show() { # the human view
  local key kind default rule note value
  printf '  %-28s %-12s %s\n' "SETTING" "VALUE" "NOTE"
  while IFS='|' read -r key kind default rule note; do
    [[ -n $key ]] || continue
    value=${!key-}
    if [[ $kind == secret || $kind == ntfy ]]; then
      value=$([[ -n $value ]] && echo set || echo "not set")
    elif [[ -z $value ]]; then
      value="${default:-–}$([[ -n $default ]] && echo ' (default)')"
    fi
    printf '  %-28s %-12s %s\n' "$key" "$value" "$note"
  done < <(CONFIG_ROWS)
}
