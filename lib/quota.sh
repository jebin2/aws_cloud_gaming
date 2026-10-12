#!/usr/bin/env bash
# The G-instance quota: what you have, what a build needs, and how to ask.
#
# A new AWS account gets 0 vCPU of GPU instances. The request is free and the
# API takes it, but the first answer is an automatic refusal - "service quotas
# are put in place to help you gradually ramp up activity" - and what gets it
# approved is the APPEAL on that same case, with a specific use case in it.
# That is a human conversation, and the Support API needs a Business plan, so
# cg cannot have it for you. What it can do is ask, track the answer, and write
# the appeal out of facts this rig already knows.
#
# Two quotas, not one. They are separate limits and a build needs whichever
# purchase model it is using.
QUOTA_OD=L-DB2E81BA      # Running On-Demand G and VT instances
QUOTA_SPOT=L-3819A6DF    # All G and VT Spot Instance Requests

quota_code() { [[ ${1:-} == spot ]] && printf '%s' "$QUOTA_SPOT" || printf '%s' "$QUOTA_OD"; }
quota_label() { [[ ${1:-} == spot ]] && printf 'G and VT spot' || printf 'G and VT on demand'; }

# quota_value <region> <code> - the applied value, or empty when it cannot be read.
quota_value() {
  aws service-quotas get-service-quota --service-code ec2 --quota-code "$2" \
    --region "$1" --query 'Quota.Value' --output text 2>/dev/null \
    | sed -n 's/\.0$//p;t;p' | head -1
}

# quota_request_state <region> <code> - status|desired|created|case, tab separated,
# for the most recent request. Empty when there has never been one.
quota_request_state() {
  aws service-quotas list-requested-service-quota-change-history-by-quota \
    --service-code ec2 --quota-code "$2" --region "$1" \
    --query 'RequestedQuotas | sort_by(@, &Created) | [-1].[Status,DesiredValue,Created,CaseId]' \
    --output text 2>/dev/null | grep -v '^None' | head -1 || true
  return 0
}

# How many vCPUs one box of the configured type needs. The ask is exactly that
# and never more - the appeal that worked said so in as many words.
quota_type() {
  printf '%s' "${TYPE:-${GAME_INSTANCE_TYPE:-$(config_field GAME_INSTANCE_TYPE 3 2>/dev/null)}}"
}

quota_vcpus_needed() {
  local v
  v=$(aws ec2 describe-instance-types --region "${REGION:?}" --instance-types "$(quota_type)" \
        --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null) || v=""
  [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '4'
}

quota_json() {
  local need; need=$(quota_vcpus_needed) || need=4
  local kind out=""
  for kind in ondemand spot; do
    local code val st
    code=$(quota_code "$kind")
    val=$(quota_value "$REGION" "$code") || val=""
    st=$(quota_request_state "$REGION" "$code") || st=""
    out+="$kind"$'\t'"$code"$'\t'"${val:-}"$'\t'"$st"$'\n'
  done
  printf '%s' "$out" | REGION="$REGION" TYPE="$(quota_type)" NEED="$need" python3 -I -c '
import json, os, sys
need = int(os.environ["NEED"])
rows = {}
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    f = (line.split("\t") + [""] * 6)[:6]
    kind, code, val = f[0], f[1], f[2]
    status, desired, created, case = f[3], f[4], f[5], ""
    # The history query returns four columns of its own; when there has never
    # been a request they are simply absent.
    parts = line.split("\t")
    hist = parts[3:] if len(parts) > 3 else []
    def num(x):
        try: return float(x)
        except Exception: return None
    rows[kind] = {
        "code": code,
        "value": num(val),
        # Enough is enough: a quota that already covers one box is not a problem
        # to solve, and asking again is refused as a duplicate.
        "enough": (num(val) or 0) >= need,
        "request": None if not hist or not hist[0] or hist[0] == "None" else {
            "status": hist[0],
            "desired": num(hist[1]) if len(hist) > 1 else None,
            "created": hist[2] if len(hist) > 2 else None,
            "case_id": hist[3] if len(hist) > 3 and hist[3] != "None" else None,
        },
    }
print(json.dumps({"region": os.environ["REGION"], "instance_type": os.environ["TYPE"],
                  "vcpus_needed": need, "ondemand": rows.get("ondemand"),
                  "spot": rows.get("spot")}, indent=2))'
}

quota_show() {
  local j; j=$(quota_json) || return 1
  say "gpu quota in $REGION"
  printf '%s' "$j" | python3 -I -c '
import json, sys, datetime
d = json.load(sys.stdin)
need = d["vcpus_needed"]
for kind, label in (("ondemand", "on demand"), ("spot", "spot     ")):
    q = d.get(kind) or {}
    val = q.get("value")
    have = "unknown" if val is None else "%g vCPU" % val
    mark = "ok" if q.get("enough") else "fail"
    print("%s\t%s\t%s" % (mark, label, have))
    r = q.get("request")
    if r:
        when = (r.get("created") or "")[:10]
        print("info\t  last asked\t%s for %s vCPU, %s%s" % (
            when, "%g" % (r.get("desired") or 0), r.get("status", "?").lower().replace("_", " "),
            ", case %s" % r["case_id"] if r.get("case_id") else ""))
' | while IFS=$'\t' read -r mark a b; do
      log_as "$mark" "$(printf '%-12s %s' "$a" "$b")"
    done
  printf '%s' "$j" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
short = [k for k in ("ondemand", "spot") if not (d.get(k) or {}).get("enough")]
if short:
    print("  ask for %s:  cg quota request %s" % (" and ".join(short), short[0]))
    print("  the first answer is usually no; the appeal is what works: cg quota appeal %s" % short[0])
'
}

# quota_request <ondemand|spot> - ask AWS for exactly what one box needs.
quota_request() {
  local kind=${1:-ondemand} code need val st
  [[ $kind == ondemand || $kind == spot ]] || die "usage: cg quota request [ondemand|spot]"
  code=$(quota_code "$kind")
  need=$(quota_vcpus_needed)
  val=$(quota_value "$REGION" "$code") || val=""
  if [[ -n $val ]] && (( ${val%.*} >= need )); then
    log_as ok "$(quota_label "$kind") in $REGION is already $val vCPU - nothing to ask for"
    return 0
  fi
  st=$(quota_request_state "$REGION" "$code") || st=""
  case ${st%%$'\t'*} in
    PENDING|CASE_OPENED)
      log_as warn "a request for this quota is already open - AWS refuses duplicates"
      log "  $(printf '%s' "$st" | awk -F'\t' '{print "asked " substr($3,1,10) " for " $2 " vCPU, " tolower($1)}')"
      log "  its case: https://console.aws.amazon.com/support/home#/case/?displayId=$(printf '%s' "$st" | awk -F'\t' '{print $4}')"
      return 0 ;;
  esac
  say "asking for $need vCPU of $(quota_label "$kind") in $REGION"
  local out id
  out=$(aws service-quotas request-service-quota-increase --service-code ec2 \
          --quota-code "$code" --desired-value "$need" --region "$REGION" \
          --query 'RequestedQuota.[Id,CaseId,Status]' --output text 2>&1) || {
    log_as fail "AWS refused the request: $(printf '%s' "$out" | tr '\n' ' ' | sed -E 's/  +/ /g' | cut -c1-300)"
    return 1
  }
  id=$(awk '{print $1}' <<<"$out")
  local case_id; case_id=$(awk '{print $2}' <<<"$out")
  [[ $case_id == None ]] && case_id=""
  log_as ok "asked AWS for $need vCPU. request $id"
  [[ -n $case_id ]] && log "  case $case_id - https://console.aws.amazon.com/support/home#/case/?displayId=$case_id"
  log "  The first answer is usually an automatic refusal - that is normal, and"
  log "  the appeal on the same case is what gets approved."
  log "  Write it with:  cg quota appeal $kind"
}

# quota_appeal <ondemand|spot> - the case text, from this rig's own facts.
#
# Every number in it is measured here rather than invented: the appeal that
# worked was specific and checkable, and the agent escalated it for that reason.
quota_appeal() {
  local kind=${1:-ondemand} need city rtt
  need=$(quota_vcpus_needed)
  # The sweep remembers what this laptop measured; without one, the line is
  # left out rather than guessed at.
  if cg_cache_read "${CG_SWEEP_CACHE:-sweep.json}" >/dev/null 2>&1; then
    read -r city rtt < <(cg_cache_read "${CG_SWEEP_CACHE:-sweep.json}" 2>/dev/null \
      | REGION="$REGION" python3 -I -c '
import json, os, sys
try:    d = json.load(sys.stdin)
except Exception: raise SystemExit
for r in d.get("regions", []):
    if r.get("region") == os.environ["REGION"]:
        print((r.get("city") or "").replace(" ", "_"), r.get("rtt_ms") or "")
        break') || true
  fi
  cat <<TXT
Requesting an appeal with detailed use case.

WORKLOAD
Low-latency remote desktop and game streaming for personal use, using
Sunshine (host) and Moonlight (client) over a private Tailscale network.
The GPU is required for NVENC hardware video encoding - encoding a 1080p60
stream in real time. Software encoding is not viable: it adds 30-40ms of
latency and saturates all vCPUs, which defeats the purpose.

INSTANCE AND SIZE
A single $(quota_type) (${need} vCPU). I am requesting exactly ${need} vCPUs - the
minimum for one instance. I will never run more than one at a time.

USAGE PATTERN
The instance is started on demand for a session and stopped immediately
afterwards. It is not a persistent workload.

COST CONTROLS ALREADY IN PLACE
- An AWS Budget at ${GAME_BUDGET_INR:-5000} INR/month, created before the first launch
- A cloud watchdog (Lambda, every 5 minutes) that stops the instance after
  ${GAME_WATCHDOG_IDLE_MIN:-30} minutes with no stream traffic
- An on-instance watchdog that shuts the box down from inside
- A forced shutdown after ${GAME_WATCHDOG_STUCK_MIN:-180} minutes, whatever the traffic says

REGION
${REGION}${city:+ (${city//_/ })}${rtt:+ is ${rtt}ms from me}. Latency is the whole
constraint for interactive streaming: anything above about 40ms is unusable,
which rules out most regions from my location.

This is not for cryptocurrency mining, ML training, or resale of compute.
TXT
}
