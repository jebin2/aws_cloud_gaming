#!/usr/bin/env bash
# Which REGION will rent you a GPU - the question lib/machines.sh cannot answer.
#
# machines.sh asks "what can this region rent me", which is the right question
# only once the region is settled. It is not: a week was spent retrying
# g6.xlarge in ap-south-2 on the assumption that spot capacity comes back,
# while AWS had an API all along that says it will not. get-spot-placement-scores
# scores a (region, type) pair 1-10 for the odds of actually getting capacity,
# and ap-south-2 scored 1 for every type the rig can use while ap-south-1 scored
# 9 for g4dn.xlarge. One free call would have moved the box in an afternoon.
#
# So this sweeps every region AWS has and reports the three things that decide
# whether one is usable at all:
#
#   latency   measured, not assumed - a streamed game is unplayable past
#             NVIDIA's stated 80ms whatever the GPU costs
#   capacity  the placement score, which is the only forward-looking number
#             AWS publishes; price and quota say nothing about availability
#   quota     0 is the default for G instances in a region you have never
#             asked about, and it reads as "unavailable" exactly like a
#             shortage does, so the two must be told apart
#
# Every call is free: describe-regions, get-spot-placement-scores,
# describe-instance-type-offerings, describe-spot-price-history, service-quotas
# and the Pricing API all cost nothing, and the latency probe opens a TCP
# connection to a public endpoint without touching an AWS API at all. Nothing
# here launches, reserves, enables or changes anything.

# The 4-vCPU shapes, because a 4-vCPU quota cannot reach anything larger and a
# sweep of every size would be 200 price lookups for rows nobody can rent.
CG_SWEEP_TYPES="${CG_SWEEP_TYPES:-g4dn.xlarge g5.xlarge g6.xlarge g6e.xlarge}"
# NVIDIA's own requirement for GeForce NOW, and the number the research
# converges on: past this a stream is not worth launching.
CG_SWEEP_MAX_MS="${CG_SWEEP_MAX_MS:-80}"
CG_SWEEP_SAMPLES="${CG_SWEEP_SAMPLES:-5}"
CG_SWEEP_PAR="${CG_SWEEP_PAR:-10}"

# The region the cross-region calls are MADE from.
#
# Not the configured one. get-spot-placement-scores does not exist in every
# region - ap-south-2, which is where this rig lives, answers
# UnsupportedOperation - so asking from "wherever the box is" returned nothing
# for every region and the whole sweep reported a dash in the column it was
# written to produce. The source region is therefore PROBED once and cached,
# and the probe is itself a placement-score call for one region, which is free.
CG_SWEEP_FALLBACKS="${CG_SWEEP_FALLBACKS:-us-east-1 eu-west-1 ap-south-1 ap-northeast-1}"
_SWEEP_SRC=""
sweep_from() {
  if [[ -n ${CG_SWEEP_FROM:-} ]]; then printf '%s' "$CG_SWEEP_FROM"; return 0; fi
  if [[ -n $_SWEEP_SRC ]]; then printf '%s' "$_SWEEP_SRC"; return 0; fi
  local c
  for c in "${REGION:-${GAME_REGION:-}}" $CG_SWEEP_FALLBACKS; do
    [[ -n $c ]] || continue
    if aws ec2 get-spot-placement-scores --region "$c" \
         --instance-types g4dn.xlarge --target-capacity 1 --region-names "$c" \
         --query 'SpotPlacementScores' --output text >/dev/null 2>&1; then
      _SWEEP_SRC=$c; printf '%s' "$c"; return 0
    fi
  done
  # Nothing answered. Print the configured region so the caller still makes a
  # call and reports a real AWS error rather than silently scoring nothing.
  printf '%s' "${REGION:-${GAME_REGION:-us-east-1}}"
}

# sweep_rtt_ms <region> - median TLS connect time in ms, or nothing.
#
# The median of several, not one sample: a single probe caught a 46ms outlier in
# a region whose median is 19ms, and picking a region on that would have been
# picking on noise. time_connect is the TCP+TLS handshake, which is the round
# trip and excludes the request, so it tracks the network rather than the API.
sweep_rtt_ms() { # sweep_rtt_ms <region>
  command -v curl >/dev/null || return 0
  local r=$1 i t out=""
  for (( i = 0; i < CG_SWEEP_SAMPLES; i++ )); do
    t=$(curl -sS --max-time 8 -o /dev/null -w '%{time_connect}' \
          "https://ec2.$r.amazonaws.com" 2>/dev/null) || continue
    [[ -n $t && $t != 0.000000 ]] && out+="$t"$'\n'
  done
  [[ -n $out ]] || return 0
  printf '%s' "$out" | python3 -c '
import sys, statistics
v = [float(x) * 1000 for x in sys.stdin if x.strip()]
if v: print("%.1f" % statistics.median(v))'
}

# sweep_regions - "<region> <optin>" for every region, including ones not
# enabled: a region you have not opted into is still a candidate, it just costs
# an opt-in to reach, and hiding it would hide the only region with capacity.
sweep_regions() {
  aws ec2 describe-regions --all-regions \
    --query 'sort_by(Regions,&RegionName)[].[RegionName,OptInStatus]' \
    --output text 2>/dev/null || true
}

# sweep_scores <type> <region>... - "<region> <score>" per region that has one.
#
# A region missing from the answer does NOT score 0 - AWS simply returns nothing
# for a region that does not offer the type, and reporting that as 0 would read
# as "no capacity" for a machine that was never on sale there. The caller keeps
# the difference.
sweep_scores() { # sweep_scores <type> <region>...
  local type=$1; shift
  local -a chunk=()
  # The API caps the region list, so ask in batches rather than one call that
  # fails whole.
  while (( $# )); do
    chunk+=("$1"); shift
    if (( ${#chunk[@]} == 10 || $# == 0 )); then
      aws ec2 get-spot-placement-scores --region "$(sweep_from)" \
        --instance-types "$type" --target-capacity 1 \
        --region-names "${chunk[@]}" \
        --query 'SpotPlacementScores[].[Region,Score]' --output text 2>/dev/null || true
      chunk=()
    fi
  done
}

# sweep_city <region> - the human name, or nothing. Cosmetic, and allowed to
# fail: the recursive form of this path pages over thousands of parameters and
# times out, so it is asked one region at a time and only for the shortlist.
sweep_city() { # sweep_city <region>
  aws ssm get-parameter --region "$(sweep_from)" \
    --name "/aws/service/global-infrastructure/regions/$1/longName" \
    --query 'Parameter.Value' --output text 2>/dev/null || true
}

# sweep_json - the whole sweep, as one object.
sweep_json() {
  local work rc=0; work=$(mktemp -d) || return 1

  sweep_regions > "$work/regions"
  if [[ ! -s $work/regions ]]; then
    rm -rf "$work"
    printf '{"error":"could not list regions - check your AWS credentials","regions":[]}\n'
    return 0
  fi

  # Latency first, and in parallel: it is the cheapest filter and the harshest,
  # cutting 34 regions to a handful, so everything after it asks about far fewer.
  mkdir -p "$work/rtt"
  local probe="$work/probe.sh"
  if command -v curl >/dev/null; then
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
source "$CG_SWEEP_LIB" 2>/dev/null || exit 0
sweep_rtt_ms "$1" > "$CG_SWEEP_OUT/$1"
PROBE
    chmod +x "$probe"
    awk '{print $1}' "$work/regions" \
      | CG_SWEEP_LIB="${BASH_SOURCE[0]}" CG_SWEEP_OUT="$work/rtt" \
        CG_SWEEP_SAMPLES="$CG_SWEEP_SAMPLES" \
        xargs -P "$CG_SWEEP_PAR" -I{} env "$probe" {} 2>/dev/null || true
  fi

  # Did ANY probe answer? This, not `command -v curl`, is what decides whether a
  # latency budget can be applied. curl being installed says nothing: behind a
  # firewall that blocks 443 outbound every probe fails, and filtering on that
  # would exclude all 34 regions and report that nowhere on earth can stream.
  local measured=0
  if compgen -G "$work/rtt/*" >/dev/null 2>&1; then
    grep -lq . "$work"/rtt/* 2>/dev/null && measured=1
  fi

  # The shortlist. The parallel pass above is a coarse filter and nothing more:
  # concurrent handshakes share one uplink and inflate each other, so a region
  # is kept if it is within HALF AGAIN the budget, then measured again quietly.
  local near=() r rtt slack
  slack=$(python3 -c "print($CG_SWEEP_MAX_MS * 1.5)")
  while read -r r _; do
    rtt=$(cat "$work/rtt/$r" 2>/dev/null || true)
    if [[ -z $rtt ]]; then
      (( measured )) || near+=("$r")
    elif python3 -c "import sys; sys.exit(0 if $rtt <= $slack else 1)"; then
      near+=("$r")
    fi
  done < "$work/regions"

  # The quiet pass: few regions, more samples, two at a time. This is the number
  # the budget is actually applied to, and the one the report prints.
  if (( measured )) && (( ${#near[@]} )); then
    printf '%s\n' "${near[@]}" \
      | CG_SWEEP_LIB="${BASH_SOURCE[0]}" CG_SWEEP_OUT="$work/rtt" \
        CG_SWEEP_SAMPLES="$(( CG_SWEEP_SAMPLES * 3 ))" \
        xargs -P 2 -I{} env "$probe" {} 2>/dev/null || true
    local keep=()
    for r in "${near[@]}"; do
      rtt=$(cat "$work/rtt/$r" 2>/dev/null || true)
      [[ -n $rtt ]] || continue
      python3 -c "import sys; sys.exit(0 if $rtt <= $CG_SWEEP_MAX_MS else 1)" && keep+=("$r")
    done
    near=("${keep[@]}")
  fi

  # GPU, VRAM and RAM for the table. A type's specs do not vary by region, so
  # ONE call from the source region covers every row - including rows in regions
  # that are not enabled, where describe-instance-types cannot be called at all.
  # shellcheck disable=SC2086
  aws ec2 describe-instance-types --region "$(sweep_from)" --instance-types $CG_SWEEP_TYPES \
    --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB,GpuInfo.Gpus[0].Name,GpuInfo.Gpus[0].MemoryInfo.SizeInMiB]' \
    --output text 2>/dev/null > "$work/specs" || : > "$work/specs"

  # Scores for the shortlist, one call per type rather than per region.
  : > "$work/scores"
  if (( ${#near[@]} )); then
    local t
    for t in $CG_SWEEP_TYPES; do
      sweep_scores "$t" "${near[@]}" | awk -v t="$t" '{print t, $1, $2}' >> "$work/scores"
    done
  fi

  # Quotas, offerings and spot prices only work in a region that is enabled, so
  # they are asked per region and their absence is recorded as "unreadable"
  # rather than as a zero. A 0 quota and an unreadable quota lead to different
  # actions - one is a request, the other an opt-in - so they must not collapse.
  : > "$work/detail"
  local optin enabled
  for r in "${near[@]}"; do
    optin=$(awk -v r="$r" '$1 == r { print $2 }' "$work/regions")
    enabled=0; [[ $optin == opt-in-not-required || $optin == opted-in ]] && enabled=1
    printf 'city\t%s\t%s\n' "$r" "$(sweep_city "$r")" >> "$work/detail"
    printf 'optin\t%s\t%s\t%s\n' "$r" "$optin" "$enabled" >> "$work/detail"
    if (( enabled )); then
      local q
      q=$(machines_quota "$r" 2>/dev/null || echo "0 0")
      printf 'quota\t%s\t%s\t%s\n' "$r" "${q% *}" "${q#* }" >> "$work/detail"
      aws ec2 describe-instance-type-offerings --region "$r" --location-type region \
        --filters "Name=instance-type,Values=$(tr ' ' ',' <<<"$CG_SWEEP_TYPES")" \
        --query 'InstanceTypeOfferings[].InstanceType' --output text 2>/dev/null \
        | tr '\t' '\n' | sed '/^$/d' | awk -v r="$r" '{print "offers\t" r "\t" $1}' >> "$work/detail" || true
      # shellcheck disable=SC2086
      aws ec2 describe-spot-price-history --region "$r" --instance-types $CG_SWEEP_TYPES \
        --product-descriptions "Linux/UNIX" \
        --start-time "$(date -u -d '3 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --query 'SpotPriceHistory[].[InstanceType,SpotPrice]' --output text 2>/dev/null \
        | sort -k1,1 -k2,2g \
        | awk -v r="$r" '{ if (!lo[$1]) lo[$1]=$2; hi[$1]=$2 }
                         END { for (t in lo) print "spot\t" r "\t" t "\t" lo[t] "\t" hi[t] }' \
        >> "$work/detail" || true
    fi
    # On-demand prices come from the Pricing API, which answers for a region
    # whether or not it is enabled - the one number available before opting in,
    # and so the only way to cost a region you cannot yet query.
    local t price
    for t in $CG_SWEEP_TYPES; do
      # Only types the region plausibly sells: a score or an offering. Pricing
      # every type in every region was 28 calls for rows that do not exist.
      grep -q "^$t $r " "$work/scores" 2>/dev/null \
        || grep -qF "offers$(printf '\t')$r$(printf '\t')$t" "$work/detail" 2>/dev/null || continue
      price=$(machines_ondemand_usd "$t" "$r" 2>/dev/null || true)
      [[ -n $price ]] && printf 'ondemand\t%s\t%s\t%s\n' "$r" "$t" "$price" >> "$work/detail"
    done
  done

  REGIONS_F="$work/regions" RTT_D="$work/rtt" SCORES_F="$work/scores" \
  DETAIL_F="$work/detail" SPECS_F="$work/specs" \
  MAXMS="$CG_SWEEP_MAX_MS" TYPES="$CG_SWEEP_TYPES" \
  CONFIGURED="${GAME_REGION:-$REGION}" INR="${CG_INR_PER_USD:-88}" \
  MEASURED="$measured" \
  python3 -c '
import json, os, collections

maxms = float(os.environ["MAXMS"])
inr   = float(os.environ["INR"])
types = os.environ["TYPES"].split()

optin = {}
for line in open(os.environ["REGIONS_F"]):
    p = line.split()
    if len(p) >= 2: optin[p[0]] = p[1]

rtt = {}
d = os.environ["RTT_D"]
for r in optin:
    try:
        v = open(os.path.join(d, r)).read().strip()
        if v: rtt[r] = float(v)
    except OSError:
        pass

score = {}
try:
    for line in open(os.environ["SCORES_F"]):
        p = line.split()
        if len(p) >= 3: score[(p[1], p[0])] = int(p[2])
except OSError:
    pass

city, enabled, quota = {}, {}, {}
offers = collections.defaultdict(set)
spot, spot_max, od = {}, {}, {}
for line in open(os.environ["DETAIL_F"]):
    p = line.rstrip("\n").split("\t")
    k = p[0]
    if   k == "city"  and len(p) >= 3: city[p[1]] = p[2] or None
    elif k == "optin" and len(p) >= 4: enabled[p[1]] = p[3] == "1"
    elif k == "quota" and len(p) >= 4: quota[p[1]] = (int(float(p[2])), int(float(p[3])))
    elif k == "offers" and len(p) >= 3: offers[p[1]].add(p[2])
    elif k == "spot"  and len(p) >= 4:
        spot[(p[1], p[2])] = float(p[3])
        if len(p) >= 5: spot_max[(p[1], p[2])] = float(p[4])
    elif k == "ondemand" and len(p) >= 4: od[(p[1], p[2])] = float(p[3])

specs = {}
try:
    for line in open(os.environ["SPECS_F"]):
        p = line.split("\t") if "\t" in line else line.split()
        if len(p) >= 5:
            specs[p[0]] = {
                "vcpu": int(p[1]),
                "ram_gib": round(int(p[2]) / 1024, 1),
                "gpu": None if p[3] in ("None", "") else p[3],
                "vram_gib": None if p[4] in ("None", "") else round(int(p[4]) / 1024, 1),
            }
except OSError:
    pass

def money(v):
    return None if v is None else round(v * inr)

regions, far, unknown = [], [], []
for r, o in optin.items():
    ms = rtt.get(r)
    if ms is None and os.environ["MEASURED"] == "1":
        unknown.append({"region": r, "optin": o}); continue
    if ms is not None and ms > maxms:
        far.append({"region": r, "optin": o, "rtt_ms": ms}); continue

    en = enabled.get(r, False)
    q  = quota.get(r)
    machines = []
    for t in types:
        sc = score.get((r, t))
        offered = t in offers.get(r, set())
        has_price = (r, t) in od or (r, t) in spot
        # A type with no score, no offering and no price was never on sale here.
        if sc is None and not offered and not has_price:
            continue
        sp_usd, od_usd = spot.get((r, t)), od.get((r, t))
        sp_max = spot_max.get((r, t))
        sp = specs.get(t, {})
        machines.append({
            "type": t,
            "score": sc,
            "gpu": sp.get("gpu"),
            "vram_gib": sp.get("vram_gib"),
            "ram_gib": sp.get("ram_gib"),
            "vcpu": sp.get("vcpu"),
            "offered": offered if en else None,
            "usd_hour_spot": sp_usd,
            "usd_hour_spot_max": sp_max,
            "inr_hour_spot_max": money(sp_max),
            "usd_hour_ondemand": od_usd,
            "inr_hour_spot": money(sp_usd),
            "inr_hour_ondemand": money(od_usd),
            "fits_spot": (q[1] >= 4) if q else None,
            "fits_ondemand": (q[0] >= 4) if q else None,
        })
    # Best first: a real score beats a cheap price, because price is what a
    # machine costs and score is whether you can have one at all.
    machines.sort(key=lambda m: (-(m["score"] or 0), m["inr_hour_ondemand"] or 1e9, m["type"]))
    best = max((m["score"] or 0) for m in machines) if machines else 0
    regions.append({
        "region": r, "city": city.get(r), "optin": o, "enabled": en,
        "rtt_ms": ms,
        "quota": ({"ondemand_vcpu": q[0], "spot_vcpu": q[1]} if q else None),
        "best_score": best or None,
        "machines": machines,
    })

# Usable first, then nearest: a region with capacity is the answer even when a
# nearer one exists, and that is the entire finding this command exists to show.
regions.sort(key=lambda x: (-(x["best_score"] or 0), x["rtt_ms"] if x["rtt_ms"] is not None else 1e9))
far.sort(key=lambda x: x["rtt_ms"])

print(json.dumps({
    "max_ms": maxms,
    "configured": os.environ["CONFIGURED"],
    "types": types,
    "inr_per_usd": inr,
    "measured": os.environ["MEASURED"] == "1",
    "regions": regions,
    "too_far": far,
    "unreachable": unknown,
}))
' || rc=$?
  rm -rf "$work"
  return $rc
}

CG_SWEEP_CACHE="${CG_SWEEP_CACHE:-sweep.json}"

# sweep_fresh - a real sweep, and remember it. The cache is a convenience only:
# every reader below works when it is missing, and nothing waits on the write.
sweep_fresh() {
  local out; out=$(sweep_json) || return $?
  [[ -n $out ]] || return 1
  # The timestamp belongs IN the document, so a reader knows how old the answer
  # is without asking the filesystem - the app shows it, and a stale score is
  # worse than no score if nobody can tell.
  # cached/age_seconds are set here too, so a fresh answer and a remembered one
  # are the same shape - the app renders one function, not two.
  out=$(AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
d["scanned_at"] = os.environ["AT"]
d["cached"] = True
d["age_seconds"] = 0
print(json.dumps(d))' <<<"$out") || return 1
  printf '%s\n' "$out" | cg_cache_write "$CG_SWEEP_CACHE"
  printf '%s\n' "$out"
}

# sweep_cached - the last sweep, with how old it is, or an empty answer saying
# there has not been one. Never scans: this is what an opening screen calls.
sweep_cached() {
  local out age
  if out=$(cg_cache_read "$CG_SWEEP_CACHE"); then
    age=$(cg_cache_age "$CG_SWEEP_CACHE" 2>/dev/null || echo "")
    AGE="$age" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({"cached": False, "regions": [], "too_far": [], "unreachable": [],
                      "error": "the remembered scan could not be read"})); raise SystemExit(0)
d["cached"] = True
a = os.environ.get("AGE") or ""
d["age_seconds"] = int(a) if a.isdigit() else None
print(json.dumps(d))' <<<"$out" && return 0
  fi
  printf '{"cached":false,"regions":[],"too_far":[],"unreachable":[],"scanned_at":null,"age_seconds":null}\n'
}

# sweep_show [--all] - the same sweep for a person.
sweep_show() { # sweep_show [--all]
  sweep_fresh | ALL="${1:-}" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
if d.get("error"):
    print("  " + d["error"]); raise SystemExit(0)
show_all = os.environ.get("ALL", "") in ("--all", "all", "1")

print("  every AWS region, scored for whether it can actually run this rig")
if d["measured"]:
    print("  latency is measured now, median of several probes; the budget is %gms"
          % d["max_ms"])
else:
    print("  latency could NOT be measured - no curl, or every probe failed - so")
    print("  no region was excluded and the list below is not ordered by distance")
print("  capacity is AWS own spot placement score, 1-10: 1 means do not bother")
print()

if not d["regions"]:
    print("  no region is within %gms - nothing here can stream" % d["max_ms"])
else:
    print("  %-16s %-11s %-7s %-13s %-6s %-9s %s" %
          ("REGION", "CITY", "LATENCY", "TYPE", "SCORE", "QUOTA", "SPOT / ON DEMAND"))
    for r in d["regions"]:
        city = (r["city"] or "")
        for pre in ("Asia Pacific (", "Europe (", "US East (", "US West (",
                    "Canada (", "South America (", "Africa (", "Middle East (", "Israel ("):
            if city.startswith(pre): city = city[len(pre):].rstrip(")")
        ms = "%.0f ms" % r["rtt_ms"] if r["rtt_ms"] is not None else "-"
        mark = "*" if r["region"] == d["configured"] else " "
        if not r["machines"]:
            print("  %s%-15s %-11s %-7s %s" % (mark, r["region"], city[:11], ms,
                  "no GPU machine of a usable size is sold here"))
            continue
        for i, m in enumerate(r["machines"]):
            if not r["enabled"]:
                q = "opt-in"
            elif m["fits_spot"] is None:
                q = "?"
            else:
                q = "%s/%s" % ("ok" if m["fits_ondemand"] else "0",
                               "ok" if m["fits_spot"] else "0")
            price = "%s / %s" % (
                ("INR %d" % m["inr_hour_spot"]) if m["inr_hour_spot"] is not None else "-",
                ("INR %d" % m["inr_hour_ondemand"]) if m["inr_hour_ondemand"] is not None else "-")
            print("  %s%-15s %-11s %-7s %-13s %-6s %-9s %s" % (
                mark if i == 0 else " ",
                r["region"] if i == 0 else "", city[:11] if i == 0 else "",
                ms if i == 0 else "",
                m["type"], str(m["score"]) if m["score"] is not None else "-", q, price))
    print()
    print("  QUOTA is on demand/spot: ok means 4 vCPU is covered, 0 means ask for it,")
    print("  opt-in means the region is not enabled so the quota cannot be read yet.")

far = d["too_far"]
if far and show_all:
    print()
    print("  too far to stream (over %gms):" % d["max_ms"])
    for r in far:
        print("    %-16s %5.0f ms" % (r["region"], r["rtt_ms"]))
elif far:
    print()
    print("  %d more regions are over %gms and were skipped: cg sweep --all"
          % (len(far), d["max_ms"]))
if d["unreachable"]:
    print("  %d regions did not answer a latency probe" % len(d["unreachable"]))
print()
print("  * is the region in use. Change it with: cg config set GAME_REGION <region>")
'
}

# regions_json - the enabled regions, and nothing else.
#
# Separate from the sweep on purpose: the app needs a region picker the moment
# it opens, and the sweep takes minutes. This is ONE describe-regions call, and
# it lists only regions already enabled because those are the ones a dropdown
# can switch to without an opt-in that this app has no business performing.
regions_json() {
  aws ec2 describe-regions \
    --query 'sort_by(Regions,&RegionName)[].[RegionName,OptInStatus]' \
    --output text 2>/dev/null \
  | CONFIGURED="${GAME_REGION:-$REGION}" python3 -c '
import json, os, sys
rows = [l.split() for l in sys.stdin if l.strip()]
regions = [{"region": p[0], "optin": p[1] if len(p) > 1 else None} for p in rows]
cfg = os.environ["CONFIGURED"]
# The configured region must be in the list even if describe-regions could not
# be read: a picker that silently drops the current value looks like the setting
# was lost, and the first thing anyone does then is set it again by hand.
if cfg and not any(r["region"] == cfg for r in regions):
    regions.append({"region": cfg, "optin": None})
# Sorted here rather than trusting the query to have done it: a dropdown whose
# order depends on what the API happened to return is a dropdown that reorders
# itself under the cursor.
regions.sort(key=lambda r: r["region"])
print(json.dumps({"configured": cfg, "regions": regions}))
'
}

regions_show() {
  regions_json | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d["regions"]:
    print("  could not list regions - check your AWS credentials"); raise SystemExit(0)
for r in d["regions"]:
    print("  %s%s" % ("*" if r["region"] == d["configured"] else " ", r["region"]))
print()
print("  * is the region in use. Only enabled regions are listed.")
print("  What each one can actually rent you: cg sweep")
'
}
