#!/usr/bin/env bash
# Layer 3: the cloud watchdog. Sourced by cg - not run directly.
#
# lambda/cloud_watchdog.py, run every 5 minutes by an EventBridge rule, on an
# IAM role that can end only the instance tagged $TS_HOST - no access key exists
# for it, and nothing outside AWS has to stay up for it to run.
#
# Every piece is free at this scale: ~8,640 invocations a month against 1M, a
# few MB of logs against 5 GB, and EventBridge schedules cost nothing.
#
# Nothing here is fatal to `cg init`. A missing guard must not stop a build;
# it says so, and the other layers still apply.

CW_NAME="${TS_HOST}-cloud-watchdog"
CW_LOGS="/aws/lambda/$CW_NAME"
CW_SRC="lambda/cloud_watchdog.py"
CW_RUNTIME="python3.13"
CW_POLICY_NAME="idle-guard"

cw_aws() { aws --region "$REGION" "$@"; }

cw_int() { [[ ${1:-} =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf '%s' "$2"; }

# Days with no box before the game archive is deleted: 14 unless set, 0 turns it
# off, and any other number is used as written.
cw_expiry_days() {
  cw_int "${GAME_ARCHIVE_EXPIRY_DAYS:-}" 14
}

# The archive bucket, named exactly as lib/library-aws.sh names it.
cw_bucket() { # cw_bucket <account>
  if [[ -n ${GAME_S3_BUCKET:-} ]]; then printf '%s' "$GAME_S3_BUCKET"
  else printf 'cg-library-%s' "$(printf '%s' "$1-$TS_HOST" | sha256sum | cut -c1-12)"; fi
}

# Floors, not just defaults. A stuck limit under the shutdown push's 30 minutes
# would force a box down while it is still mirroring its games.
cw_env() { # cw_env <account>
  local idle stuck
  idle=$(cw_int "${GAME_WATCHDOG_IDLE_MIN:-}" 30); (( idle < 10 )) && idle=10
  stuck=$(cw_int "${GAME_WATCHDOG_STUCK_MIN:-}" 60); (( stuck < 40 )) && stuck=40
  # CG_NTFY_URL only when set: an unset notification URL is simply absent.
  local ntfy; ntfy=$(cg_ntfy_url)
  printf 'Variables={CG_TS_HOST=%s,CG_IDLE_MINUTES=%s,CG_BOOT_GRACE_MINUTES=20,CG_STUCK_MINUTES=%s,CG_BUCKET=%s,CG_ARCHIVE_EXPIRY_DAYS=%s%s}' \
    "$TS_HOST" "$idle" "$stuck" "$(cw_bucket "$1")" "$(cw_expiry_days)" "${ntfy:+,CG_NTFY_URL=$ntfy}"
}

# Describe and read metrics anywhere; stop, terminate and tag ONLY the instance
# tagged with this host name, and tag it only with the one key the watchdog
# uses; write only its own log group. It cannot launch anything, read the game
# archive beyond expiring it, or touch IAM.
#
# Archive expiry adds CloudTrail lookups and list/tag/delete on the ONE archive
# bucket - and only while expiry is on. With GAME_ARCHIVE_EXPIRY_DAYS=0 the role
# cannot delete a single game.
cw_policy() { # cw_policy <account>
  local b extra=""
  b=$(cw_bucket "$1")
  if (( $(cw_expiry_days) > 0 )); then
    extra=$(cat <<JSON
,
 {"Sid":"ArchiveExpiryLookups","Effect":"Allow","Action":"cloudtrail:LookupEvents","Resource":"*"},
 {"Sid":"ArchiveExpiryBucket","Effect":"Allow",
  "Action":["s3:ListBucket","s3:ListBucketMultipartUploads","s3:GetBucketTagging","s3:PutBucketTagging","s3:DeleteBucket"],
  "Resource":"arn:aws:s3:::$b"},
 {"Sid":"ArchiveExpiryObjects","Effect":"Allow","Action":["s3:DeleteObject","s3:AbortMultipartUpload"],
  "Resource":"arn:aws:s3:::$b/*"}
JSON
)
  fi
  cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Look","Effect":"Allow",
  "Action":["ec2:DescribeInstances","cloudwatch:GetMetricStatistics"],"Resource":"*"},
 {"Sid":"EndOnlyTheTaggedBox","Effect":"Allow",
  "Action":["ec2:StopInstances","ec2:TerminateInstances"],
  "Resource":"arn:aws:ec2:$REGION:$1:instance/*",
  "Condition":{"StringEquals":{"ec2:ResourceTag/Name":"$TS_HOST"}}},
 {"Sid":"MarkWhenFirstSeenGoingDown","Effect":"Allow","Action":"ec2:CreateTags",
  "Resource":"arn:aws:ec2:$REGION:$1:instance/*",
  "Condition":{"StringEquals":{"ec2:ResourceTag/Name":"$TS_HOST"},
               "ForAllValues:StringEquals":{"aws:TagKeys":["cg-going-down-since"]}}},
 {"Sid":"OwnLogs","Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:$REGION:$1:log-group:$CW_LOGS:*"}$extra
]}
JSON
}

# The deployment package, byte-identical on every run: fixed timestamp, stored
# rather than deflated (zlib versions compress differently). That is what lets
# "is the deployed code current" be one comparison against Lambda's CodeSha256.
cw_zip() { # cw_zip <out.zip>  -> prints the base64 SHA-256 Lambda reports
  python3 - "$CW_SRC" "$1" <<'PY'
import sys, zipfile, hashlib, base64
src, out = sys.argv[1:3]
info = zipfile.ZipInfo("cloud_watchdog.py", (1980, 1, 1, 0, 0, 0))
info.external_attr = 0o644 << 16
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    z.writestr(info, open(src, "rb").read())
print(base64.b64encode(hashlib.sha256(open(out, "rb").read()).digest()).decode())
PY
}

# Everything about the function that is not its code, as one short hash kept in
# its description - so drift in any of it reads as "not current".
cw_fp() { # cw_fp <role-arn>
  local acct; acct=$(sed -nE 's/^arn:aws:iam::([0-9]+):role\/.*/\1/p' <<<"$1")
  printf '%s|%s|%s|300|128|%s\n' "$CW_RUNTIME" "cloud_watchdog.handler" "$1" "$(cw_env "$acct")" \
    | sha256sum | cut -c1-12
}

cw_policy_matches() { # cw_policy_matches <file-with-current-json> <account>
  python3 -c 'import json,sys
try: sys.exit(0 if json.load(open(sys.argv[1])) == json.loads(sys.argv[2]) else 1)
except Exception: sys.exit(1)' "$1" "$(cw_policy "$2")"
}

# One parallel round of read-only calls: is every piece there and as this repo
# would make it? Sets CW_DRIFT to what is not, and CW_LAST_* to the last
# decision logged in the past hour.
CW_DRIFT="" CW_LAST_MS="" CW_LAST_MSG="" CW_ARCH_MS="" CW_ARCH_MSG=""
cw_current() {
  local d; d=$(mktemp -d)
  cw_aws lambda get-function-configuration --function-name "$CW_NAME" \
    --query '[CodeSha256,State,LastUpdateStatus,Role,Description]' --output text > "$d/fn" 2>/dev/null &
  cw_aws events describe-rule --name "$CW_NAME" \
    --query '[State,ScheduleExpression]' --output text > "$d/rule" 2>/dev/null &
  cw_aws events list-targets-by-rule --rule "$CW_NAME" \
    --query 'Targets[0].Arn' --output text > "$d/target" 2>/dev/null &
  cw_aws lambda get-policy --function-name "$CW_NAME" \
    --query Policy --output text > "$d/perm" 2>/dev/null &
  aws iam get-role-policy --role-name "$CW_NAME" --policy-name "$CW_POLICY_NAME" \
    --query PolicyDocument --output json > "$d/policy" 2>/dev/null &
  { cw_aws logs filter-log-events --log-group-name "$CW_LOGS" \
      --start-time "$(( ($(date +%s) - 3600) * 1000 ))" --filter-pattern '"cg-watchdog:"' \
      --query 'events[-1].[timestamp,message]' --output text > "$d/last" 2>/dev/null \
      || echo NOGROUP > "$d/last"; } &
  cw_archive_query > "$d/archive" 2>/dev/null &
  local sha; sha=$(cw_zip "$d/fn.zip")
  wait

  local fsha fstate fupd frole fdesc acct
  IFS=$'\t' read -r fsha fstate fupd frole fdesc < "$d/fn" || true
  acct=$(sed -nE 's/^arn:aws:iam::([0-9]+):role\/.*/\1/p' <<<"${frole:-}")
  local drift=()
  if [[ -z ${fsha:-} || -z $acct ]]; then
    drift+=("no function")
  else
    [[ $fsha == "$sha" ]] || drift+=("code changed")
    [[ ${fdesc:-} == *"cfg=$(cw_fp "$frole")"* ]] || drift+=("settings changed")
    [[ $fstate == Active && $fupd == Successful ]] || drift+=("function $fstate/$fupd")
    [[ $(cat "$d/rule") == $'ENABLED\trate(5 minutes)' ]] || drift+=("schedule not enabled")
    [[ $(cat "$d/target") == "arn:aws:lambda:$REGION:$acct:function:$CW_NAME" ]] || drift+=("schedule has no target")
    grep -qF "arn:aws:events:$REGION:$acct:rule/$CW_NAME" "$d/perm" 2>/dev/null || drift+=("schedule cannot invoke it")
    cw_policy_matches "$d/policy" "$acct" || drift+=("role policy changed")
    [[ $(cat "$d/last") != NOGROUP ]] || drift+=("no log group")
  fi
  CW_DRIFT=$(IFS=,; printf '%s' "${drift[*]}"); CW_DRIFT=${CW_DRIFT//,/, }
  CW_LAST_MS="" CW_LAST_MSG=""
  if [[ $(cat "$d/last") != NOGROUP && $(cat "$d/last") != None* ]]; then
    IFS=$'\t' read -r CW_LAST_MS CW_LAST_MSG < "$d/last" || true
    CW_LAST_MSG=${CW_LAST_MSG#cg-watchdog: }
  fi
  cw_archive_parse "$(cat "$d/archive" 2>/dev/null)"
  rm -rf "$d"
  [[ -z $CW_DRIFT ]]
}

cw_age() { # cw_age <epoch-ms> -> "42s" / "7 min"
  local age=$(( $(date +%s) - ${1:-0} / 1000 ))
  (( age < 90 )) && printf '%ss' "$age" || printf '%s min' "$(( age / 60 ))"
}

# Called on the fast path, where nothing is redeployed and no new check runs:
# show what the schedule last decided, and flag a schedule that is not firing.
cw_report_last() {
  if [[ -z $CW_LAST_MS ]]; then
    log "cloud watchdog: up to date, but it has logged nothing in the last hour - check: cg watchdog status"
    return 0
  fi
  log "cloud watchdog: up to date - last check $(cw_age "$CW_LAST_MS") ago: $CW_LAST_MSG"
  (( $(date +%s) - CW_LAST_MS / 1000 > 900 )) \
    && log "  ^ nothing for $(( ($(date +%s) - CW_LAST_MS / 1000) / 60 )) min but it runs every 5 - it is not running. Check: cg watchdog status"
  cw_blind_note "$CW_LAST_MSG"
  log "game archive: $(cw_archive_text)"
  return 0
}

# What the archive check last decided, from the Lambda's own log - so what init
# and status say is exactly what the check will do, not a second opinion.
cw_archive_query() {
  cw_aws logs filter-log-events --log-group-name "$CW_LOGS" \
    --start-time "$(( ($(date +%s) - 7200) * 1000 ))" --filter-pattern '"cg-watchdog: archive"' \
    --query 'events[-1].[timestamp,message]' --output text
}

cw_archive_parse() { # cw_archive_parse "<ms>\t<message>"
  local ms msg
  CW_ARCH_MS="" CW_ARCH_MSG=""
  IFS=$'\t' read -r ms msg <<<"${1:-}"
  if [[ ${ms:-} =~ ^[0-9]+$ && ${msg:-} == "cg-watchdog: archive:"* ]]; then
    CW_ARCH_MS=$ms CW_ARCH_MSG=${msg#cg-watchdog: archive: }
  fi
  return 0
}

# One line: off, the latest decision and its age, or not checked yet.
cw_archive_text() {
  local days; days=$(cw_expiry_days)
  if (( days == 0 )); then
    printf 'kept forever (GAME_ARCHIVE_EXPIRY_DAYS=0)'
  elif [[ -n $CW_ARCH_MS ]]; then
    printf '%s  (checked %s ago)' "$CW_ARCH_MSG" "$(cw_age "$CW_ARCH_MS")"
  else
    printf 'deleted after %s days with no box - not checked yet (hourly)' "$days"
  fi
}

# For reports that did not run cw_current: fetch, then describe.
cw_archive_line() {
  (( $(cw_expiry_days) == 0 )) || cw_archive_parse "$(cw_archive_query 2>/dev/null)"
  cw_archive_text
}

cw_blind_note() {
  [[ $1 == *"CANNOT QUERY AWS"* || $1 == *DENIED* || $1 == *FAILED* ]] \
    && log "  ^ it cannot act on your account - fix this or layer 3 is decoration"
  return 0
}

cw_install() {
  local acct role_arn d sha fp cur cur_sha cur_desc fn_arn rule_arn out i
  acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || { log "cannot reach AWS - the cloud watchdog was not installed"; return 1; }
  role_arn="arn:aws:iam::$acct:role/$CW_NAME"

  if ! aws iam get-role --role-name "$CW_NAME" >/dev/null 2>&1; then
    log "creating the role $CW_NAME"
    aws iam create-role --role-name "$CW_NAME" \
      --description "cloud_gaming layer 3: end the idle $TS_HOST instance" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      >/dev/null 2>&1 || { log "could not create the role $CW_NAME (needs iam:CreateRole)"; return 1; }
  fi
  # put-role-policy overwrites, so this also repairs a policy edited by hand.
  aws iam put-role-policy --role-name "$CW_NAME" --policy-name "$CW_POLICY_NAME" \
    --policy-document "$(cw_policy "$acct")" >/dev/null 2>&1 \
    || { log "could not attach the policy to $CW_NAME"; return 1; }

  # Created here rather than by Lambda, so it gets a retention: Lambda's own
  # log groups keep everything forever.
  cw_aws logs create-log-group --log-group-name "$CW_LOGS" >/dev/null 2>&1 || true
  cw_aws logs put-retention-policy --log-group-name "$CW_LOGS" --retention-in-days 14 >/dev/null 2>&1 \
    || log "could not set the log retention (not fatal)"

  d=$(mktemp -d)
  sha=$(cw_zip "$d/fn.zip"); fp=$(cw_fp "$role_arn")
  if cur=$(cw_aws lambda get-function-configuration --function-name "$CW_NAME" \
             --query '[CodeSha256,Description]' --output text 2>/dev/null); then
    IFS=$'\t' read -r cur_sha cur_desc <<<"$cur"
    if [[ $cur_sha != "$sha" ]]; then
      log "updating the function code"
      cw_aws lambda update-function-code --function-name "$CW_NAME" \
        --zip-file "fileb://$d/fn.zip" >/dev/null 2>&1 \
        || { log "could not update $CW_NAME"; rm -rf "$d"; return 1; }
      # A configuration update while the code update is in progress is refused
      # with ResourceConflictException.
      cw_aws lambda wait function-updated-v2 --function-name "$CW_NAME" 2>/dev/null || true
    fi
    if [[ ${cur_desc:-} != *"cfg=$fp"* ]]; then
      log "updating the function settings"
      cw_aws lambda update-function-configuration --function-name "$CW_NAME" \
        --runtime "$CW_RUNTIME" --handler cloud_watchdog.handler --role "$role_arn" \
        --timeout 300 --memory-size 128 --environment "$(cw_env "$acct")" \
        --description "cloud_gaming layer 3 idle watchdog cfg=$fp" >/dev/null 2>&1 \
        || { log "could not update the settings of $CW_NAME"; rm -rf "$d"; return 1; }
      cw_aws lambda wait function-updated-v2 --function-name "$CW_NAME" 2>/dev/null || true
    fi
  else
    log "creating the function $CW_NAME"
    # A role created seconds ago is not yet assumable by Lambda, which refuses
    # with InvalidParameterValueException. That is propagation, not failure.
    for i in $(seq 1 12); do
      if out=$(cw_aws lambda create-function --function-name "$CW_NAME" \
            --runtime "$CW_RUNTIME" --handler cloud_watchdog.handler --role "$role_arn" \
            --timeout 300 --memory-size 128 --environment "$(cw_env "$acct")" \
            --description "cloud_gaming layer 3 idle watchdog cfg=$fp" \
            --zip-file "fileb://$d/fn.zip" 2>&1 >/dev/null); then
        break
      fi
      if [[ $out == *InvalidParameterValue* ]] && (( i < 12 )); then sleep "${CG_CW_RETRY_SLEEP:-5}"; continue; fi
      log "could not create $CW_NAME: ${out//$'\n'/ }"; rm -rf "$d"; return 1
    done
    cw_aws lambda wait function-active-v2 --function-name "$CW_NAME" 2>/dev/null || true
  fi
  rm -rf "$d"

  fn_arn="arn:aws:lambda:$REGION:$acct:function:$CW_NAME"
  rule_arn=$(cw_aws events put-rule --name "$CW_NAME" --schedule-expression 'rate(5 minutes)' \
      --state ENABLED --description "Runs the cloud_gaming idle watchdog" \
      --query RuleArn --output text 2>/dev/null) \
    || { log "could not create the schedule $CW_NAME"; return 1; }
  [[ $(cw_aws events put-targets --rule "$CW_NAME" --targets "Id=watchdog,Arn=$fn_arn" \
        --query FailedEntryCount --output text 2>/dev/null) == 0 ]] \
    || { log "could not point the schedule at $CW_NAME"; return 1; }
  if ! cw_aws lambda get-policy --function-name "$CW_NAME" --query Policy --output text 2>/dev/null \
       | grep -qF "$rule_arn"; then
    cw_aws lambda remove-permission --function-name "$CW_NAME" --statement-id cg-schedule >/dev/null 2>&1 || true
    cw_aws lambda add-permission --function-name "$CW_NAME" --statement-id cg-schedule \
      --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn "$rule_arn" \
      >/dev/null 2>&1 || { log "could not let the schedule invoke $CW_NAME"; return 1; }
  fi
  log "armed: $CW_NAME runs every 5 minutes"
  return 0
}

# "Installed" is not evidence. Run it once as a DRY RUN and report what it
# decided: it reads the account with its own role, and for a running box proves
# it may end it, without doing so. It keeps no state, so this costs nothing
# towards ending a box.
cw_prove() {
  local d out err b64 lines i
  d=$(mktemp -d)
  for i in 1 2 3; do
    if ! out=$(cw_aws lambda invoke --function-name "$CW_NAME" --cli-binary-format raw-in-base64-out \
          --payload '{"dry_run":true}' --log-type Tail --query '[FunctionError,LogResult]' \
          --output text "$d/resp" 2>&1); then
      log "cloud watchdog: could not run a check: ${out//$'\n'/ }"; rm -rf "$d"; return 0
    fi
    IFS=$'\t' read -r err b64 <<<"$out"
    lines=$(base64 -d <<<"${b64:-}" 2>/dev/null | grep -o 'cg-watchdog: .*' | sed 's/^cg-watchdog: //' || true)
    # A role created moments ago can be refused by EC2 for a few seconds.
    [[ ${err:-None} == None && $lines != *"CANNOT QUERY AWS"* ]] && break
    (( i < 3 )) && sleep "${CG_CW_RETRY_SLEEP:-10}"
  done
  rm -rf "$d"
  if [[ -z $lines ]]; then
    log "cloud watchdog: the check logged nothing - see: cg watchdog logs"
  else
    while IFS= read -r i; do [[ -n $i ]] && log "cloud watchdog: $i"; done <<<"$lines"
  fi
  [[ ${err:-None} != None ]] && log "  ^ the check FAILED ($err) - see: cg watchdog logs"
  cw_blind_note "$lines"
  return 0
}

cw_exists() {
  cw_aws lambda get-function-configuration --function-name "$CW_NAME" >/dev/null 2>&1 \
    || aws iam get-role --role-name "$CW_NAME" >/dev/null 2>&1
}

# The schedule first, so nothing invokes a half-removed function. Every part is
# attempted whatever happened to the one before, and the outcome is said on
# every path - including "there was nothing".
cw_remove() {
  local any=0
  cw_aws events remove-targets --rule "$CW_NAME" --ids watchdog >/dev/null 2>&1 && any=1
  cw_aws events delete-rule --name "$CW_NAME" >/dev/null 2>&1 && { any=1; log "deleted the schedule $CW_NAME"; }
  cw_aws lambda delete-function --function-name "$CW_NAME" >/dev/null 2>&1 && { any=1; log "deleted the function $CW_NAME"; }
  cw_aws logs delete-log-group --log-group-name "$CW_LOGS" >/dev/null 2>&1 && { any=1; log "deleted its logs"; }
  aws iam delete-role-policy --role-name "$CW_NAME" --policy-name "$CW_POLICY_NAME" >/dev/null 2>&1 && any=1
  aws iam delete-role --role-name "$CW_NAME" >/dev/null 2>&1 && { any=1; log "deleted the role $CW_NAME"; }
  (( any )) || log "cloud watchdog: nothing to remove"
  return 0
}

cw_status() {
  local fn rule
  fn=$(cw_aws lambda get-function-configuration --function-name "$CW_NAME" \
         --query '[State,Runtime]' --output text 2>/dev/null | tr '\t' ' ') || fn=""
  rule=$(cw_aws events describe-rule --name "$CW_NAME" --query State --output text 2>/dev/null) || rule=""
  # Not "${fn:+a}${fn:-b}": the second half expands to $fn itself when it is
  # set, and printed every value twice.
  if [[ -n $fn ]]; then printf '  function  %s  %s\n' "$CW_NAME" "$fn"
  else printf '  function  not installed - cg init creates it\n'; fi
  if [[ -n $rule ]]; then printf '  schedule  every 5 minutes, %s\n' "$rule"
  else printf '  schedule  none\n'; fi
  printf '  can end   only the instance tagged %s\n' "$TS_HOST"
  printf '  archive   %s\n' "$(cw_archive_line)"
  echo "  recent decisions:"
  local ev ms msg n=0
  ev=$(cw_aws logs filter-log-events --log-group-name "$CW_LOGS" \
         --start-time "$(( ($(date +%s) - 3600) * 1000 ))" --filter-pattern '"cg-watchdog:"' \
         --query 'events[-8:].[timestamp,message]' --output text 2>/dev/null) || ev=""
  while IFS=$'\t' read -r ms msg; do
    [[ $ms =~ ^[0-9]+$ ]] || continue
    printf '    %s %s\n' "$(date -d "@$(( ms / 1000 ))" '+%Y-%m-%d %H:%M:%S')" "${msg#cg-watchdog: }"
    n=$((n+1))
  done <<<"$ev"
  (( n )) || echo "    (none in the last hour)"
}

cw_logs() {
  local args=(logs tail "$CW_LOGS" --since 3h --format short --filter-pattern '"cg-watchdog:"')
  (( ${WATCH:-0} )) && args+=(--follow)
  cw_aws "${args[@]}"
}

# cg watcher's row: is the schedule firing, and what did it last decide.
cw_watcher_lines() {
  local rule
  rule=$(cw_aws events describe-rule --name "$CW_NAME" --query State --output text 2>/dev/null) || rule=""
  log_as "$([[ $rule == ENABLED ]] && echo ok || echo warn)" \
    "cloud watchdog    ${rule:-not installed}  (Lambda $CW_NAME, every 5 min)"
  local last ms msg
  last=$(cw_aws logs filter-log-events --log-group-name "$CW_LOGS" \
           --start-time "$(( ($(date +%s) - 3600) * 1000 ))" --filter-pattern '"cg-watchdog:"' \
           --query 'events[-1].[timestamp,message]' --output text 2>/dev/null) || last=""
  IFS=$'\t' read -r ms msg <<<"$last"
  if [[ ${ms:-} =~ ^[0-9]+$ ]]; then
    log "  last            $(cw_age "$ms") ago: ${msg#cg-watchdog: }"
    [[ $msg == *"CANNOT QUERY AWS"* || $msg == *DENIED* || $msg == *FAILED* ]] \
      && log_as fail "  ^ it cannot act on your account, so layer 3 is decoration"
  elif [[ $rule == ENABLED ]]; then
    log_as warn "  ^ nothing logged in the last hour, but it runs every 5 min"
  fi
  return 0
}
