#!/usr/bin/env bash
# What this region will actually rent you.
#
# The app needs an instance-type picker, and it must not hold a list of its own:
# every type, price and GPU name here comes from AWS, because a list typed into
# the renderer goes stale the first time a region gains a shape - and the whole
# reason this file exists is a launch that failed for capacity on the only type
# the rig had ever used.
#
# Every call below is free: describe-instance-type-offerings,
# describe-instance-types, describe-spot-price-history, service-quotas and the
# Pricing API cost nothing. Nothing here launches, changes or reserves anything.

# machines_gpu_types <region> - "<type> <vcpu>" for every machine AWS offers
# there that can run this rig: an NVIDIA GPU made for graphics work, a whole
# one, on x86. Each of those is AWS's own description of the type -
# Manufacturer, Workloads, GpuPartitionSize - and not a list of names: the list
# this replaced (g4dn g5 g6 g6e gr6) had already missed g7e, AWS's newest.
#   graphics  compute-only GPUs (the p family) list no graphics workload
#   whole     a fractional GPU (g6f, gr6f) needs NVIDIA's vGPU driver, which the
#             build does not install
#   x86       Steam and Proton; the Graviton g5g is ARM
# Free (describe-instance-types), and kept for a day per region, so the
# machines table and the sweep do not ask twice. CG_MACHINE_TYPES, a space
# separated list, replaces the answer - the tests, or a deliberate short list.
machines_gpu_types() {
  local region=$1 cache out
  if [[ -n ${CG_MACHINE_TYPES:-} ]]; then
    printf '%s\n' $CG_MACHINE_TYPES | awk '{print $1, 0}'; return 0
  fi
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/cg/gpu-types-$region"
  if [[ -s $cache ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < 86400 )); then
    cat "$cache"; return 0
  fi
  out=$(aws ec2 describe-instance-types --region "$region" \
          --filters Name=processor-info.supported-architecture,Values=x86_64 \
          --query 'InstanceTypes[?GpuInfo].{t:InstanceType,v:VCpuInfo.DefaultVCpus,g:GpuInfo.Gpus[0]}' \
          --output json 2>/dev/null | python3 -c '
import json, sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(1)
for r in rows:
    g = r.get("g") or {}
    if g.get("Manufacturer") != "NVIDIA": continue
    if "graphics" not in (g.get("Workloads") or []): continue
    if float(g.get("GpuPartitionSize") or 1) < 1: continue
    print(r["t"], r.get("v") or 0)' | sort -u) || out=""
  [[ -n $out ]] || { [[ -s $cache ]] && cat "$cache"; return 0; }
  mkdir -p "${cache%/*}" 2>/dev/null && printf '%s\n' "$out" > "$cache" 2>/dev/null
  printf '%s\n' "$out"
}

# machines_shortlist <region> - the smallest of each family: one row per kind of
# machine, for a scan across every region, where every size of every family
# would be hundreds of price lookups for rows that mostly cannot be rented.
machines_shortlist() {
  machines_gpu_types "$1" | awk '{split($1, p, "."); f = p[1]
    if (!(f in best) || $2 + 0 < v[f]) { best[f] = $1; v[f] = $2 + 0 } }
    END { for (f in best) print best[f] }' | sort
}

# The G/VT vCPU quotas, both purchase models. Either may be 0.
machines_quota() { # machines_quota <region> -> "<ondemand> <spot>"
  local r=$1 od sp
  od=$(aws service-quotas get-service-quota --region "$r" --service-code ec2 \
         --quota-code L-DB2E81BA --query 'Quota.Value' --output text 2>/dev/null) || od=0
  sp=$(aws service-quotas get-service-quota --region "$r" --service-code ec2 \
         --quota-code L-3819A6DF --query 'Quota.Value' --output text 2>/dev/null) || sp=0
  [[ $od == None || -z $od ]] && od=0
  [[ $sp == None || -z $sp ]] && sp=0
  printf '%.0f %.0f' "$od" "$sp"
}

# On-demand price per hour, read rather than assumed - same lookup lib/setup
# uses for the cost report. Prints nothing if the Pricing API has no answer,
# which is not fatal: the picker shows a type without a price rather than
# hiding it.
machines_ondemand_usd() { # machines_ondemand_usd <type> <region>
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$1" \
              "Type=TERM_MATCH,Field=regionCode,Value=$2" \
              "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
              "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
              "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
              "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --query 'PriceList[0]' --output text 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print([x["pricePerUnit"]["USD"] for t in d["terms"]["OnDemand"].values()
           for x in t["priceDimensions"].values()][0])
except Exception:
    pass' 2>/dev/null
}

# machines_json <region> - the whole table, as one object.
#
# A price is the CHEAPEST current spot price across the zones that offer the
# type, with the zone named: zones differ by more than 2x here, and nothing
# pins the AZ any more, so the cheap number alone would be a promise this
# cannot keep. `spot_usd_max` is the other end of that range.
machines_json() { # machines_json <region>
  local region=$1 quota od_q sp_q types configured
  quota=$(machines_quota "$region"); od_q=${quota% *}; sp_q=${quota#* }
  # The type in force is .env's, or the registry's default when .env is silent -
  # the same answer provision.sh would reach, read from lib/config.sh rather
  # than written down twice.
  configured="${GAME_INSTANCE_TYPE:-$(config_field GAME_INSTANCE_TYPE 3 2>/dev/null)}"

  # Offerings first: a type absent from the region must not appear at all. The
  # types asked about are the ones AWS says can game (machines_gpu_types).
  local gpu
  gpu=$(machines_gpu_types "$region" | awk '{print $1}' | paste -sd, -)
  types=""
  [[ -n $gpu ]] && types=$(aws ec2 describe-instance-type-offerings --region "$region" \
            --location-type availability-zone \
            --filters "Name=instance-type,Values=$gpu" \
            --query 'InstanceTypeOfferings[].[InstanceType,Location]' --output text 2>/dev/null) || types=""

  if [[ -z ${types//[[:space:]]/} ]]; then
    printf '{"region":"%s","configured":"%s","spot":"%s","error":"no GPU instance types are offered in this region, or EC2 could not be read","machines":[]}\n' \
      "$region" "$configured" "${GAME_SPOT:-0}"
    return 0
  fi

  # One describe-instance-types for every shape, and one spot price history
  # call for all of them, rather than a call per type.
  local uniq specs prices
  uniq=$(awk '{print $1}' <<<"$types" | sort -u)
  # shellcheck disable=SC2086
  specs=$(aws ec2 describe-instance-types --region "$region" --instance-types $uniq \
    --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB,GpuInfo.Gpus[0].Name,GpuInfo.Gpus[0].MemoryInfo.SizeInMiB,InstanceStorageInfo.TotalSizeInGB,GpuInfo.Gpus[0].Count]' \
    --output text 2>/dev/null) || specs=""
  # shellcheck disable=SC2086
  prices=$(aws ec2 describe-spot-price-history --region "$region" --instance-types $uniq \
    --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u -d '3 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --query 'SpotPriceHistory[].[InstanceType,AvailabilityZone,SpotPrice]' --output text 2>/dev/null) || prices=""

  # On-demand prices: one Pricing call per shape, and only for the shapes whose
  # vCPU count a quota could actually cover - the rest are listed as out of
  # reach and need no price.
  local od_list="" t vc
  while read -r t vc _; do
    [[ -z $t ]] && continue
    if (( vc <= od_q || vc <= sp_q )); then
      od_list+="$t $(machines_ondemand_usd "$t" "$region")"$'\n'
    fi
  done <<<"$specs"

  SPECS="$specs" OFFERS="$types" PRICES="$prices" ONDEMAND="$od_list" \
  REGION="$region" OD_Q="$od_q" SP_Q="$sp_q" \
  CONFIGURED="$configured" SPOT="${GAME_SPOT:-0}" INR="${CG_INR_PER_USD:-}" \
  python3 -c '
import json, os, collections

def rows(name, n):
    for line in os.environ.get(name, "").splitlines():
        p = line.split("\t") if "\t" in line else line.split()
        if len(p) >= n:
            yield p

azs = collections.defaultdict(set)
for t, az in ((p[0], p[1]) for p in rows("OFFERS", 2)):
    azs[t].add(az)

spot = collections.defaultdict(dict)   # type -> az -> newest price
for p in rows("PRICES", 3):
    t, az, price = p[0], p[1], float(p[2])
    # The history is newest first, so the first price seen for a zone is current.
    spot[t].setdefault(az, price)

od = {p[0]: float(p[1]) for p in rows("ONDEMAND", 2)}

# A dollar of AWS charges in rupees, GST included (lib/rates.sh). Unknown, the
# rupee figures are null and the app says so; the dollars still stand.
try:
    inr = float(os.environ["INR"])
except (KeyError, ValueError):
    inr = None
# To the paisa: the app adds the address and the disk to these, and a price
# rounded to the rupee first was up to 50 paise out before it showed paise.
money = lambda usd: None if usd is None or inr is None else round(usd * inr, 2)
od_q, sp_q = int(os.environ["OD_Q"]), int(os.environ["SP_Q"])

machines = []
for p in rows("SPECS", 6):
    t, vcpu, mib, gpu, vram, store = p[0], int(p[1]), int(p[2]), p[3], p[4], p[5]
    count = int(p[6]) if len(p) > 6 and p[6] not in ("None", "") else 1
    cheap = min(spot[t].items(), key=lambda kv: kv[1]) if spot.get(t) else None
    dear  = max(spot[t].items(), key=lambda kv: kv[1]) if spot.get(t) else None
    m = {
        "type": t,
        "vcpu": vcpu,
        "ram_gib": round(mib / 1024.0, 1),
        "gpu": None if gpu in ("None", "") else gpu,
        "gpu_count": count,
        "vram_gib": None if vram in ("None", "") else round(int(vram) / 1024.0, 1),
        "store_gb": None if store in ("None", "") else int(store),
        "azs": sorted(azs.get(t, [])),
        # Whether a quota covers it at all. A type that fits neither is still
        # listed - saying why it cannot be chosen beats leaving a gap.
        "fits_ondemand": vcpu <= od_q,
        "fits_spot": vcpu <= sp_q,
        "usd_hour_ondemand": od.get(t),
        "inr_hour_ondemand": money(od.get(t)),
        "usd_hour_spot": cheap[1] if cheap else None,
        "inr_hour_spot": money(cheap[1]) if cheap else None,
        "spot_az": cheap[0] if cheap else None,
        # Every zone, priced: nothing pins the zone, so a running machine is
        # priced by the zone it is in, not by the cheapest one.
        "spot_usd_by_az": dict(sorted(spot[t].items())) if spot.get(t) else {},
        "inr_hour_spot_max": money(dear[1]) if dear else None,
        "usd_hour_spot_max": dear[1] if dear else None,
        "spot_az_max": dear[0] if dear else None,
    }
    machines.append(m)

# Cheapest usable first, by the purchase model actually configured; anything no
# quota covers sinks to the bottom.
spot_on = os.environ.get("SPOT", "0") == "1"
def key(m):
    usable = m["fits_spot"] if spot_on else m["fits_ondemand"]
    price = (m["usd_hour_spot"] if spot_on else m["usd_hour_ondemand"]) or 1e9
    return (not usable, price, m["type"])
machines.sort(key=key)

print(json.dumps({
    "region": os.environ["REGION"],
    "configured": os.environ["CONFIGURED"] or None,
    "spot": os.environ["SPOT"],
    "quota": {"ondemand_vcpu": od_q, "spot_vcpu": sp_q},
    "inr_per_usd": inr,
    "machines": machines,
}))
'
}

# The same table for a person, not a program.
machines_show() { # machines_show <region> [--all]
  # ALL belongs to the python on the RIGHT of the pipe. As a prefix on
  # machines_json it was set for the producer and never reached the formatter,
  # so --all silently did nothing.
  machines_json "$1" | ALL="${2:-}" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
if d.get("error"):
    print("  " + d["error"]); raise SystemExit(0)
spot_on = d["spot"] == "1"
print("  region %s - quota %d vCPU on demand, %d spot" %
      (d["region"], d["quota"]["ondemand_vcpu"], d["quota"]["spot_vcpu"]))
print("  prices are per hour; spot is the cheapest zone right now, and nothing pins the zone")
print()
print("  %-14s %-5s %-9s %-8s %-7s %-8s %s" %
      ("TYPE", "VCPU", "GPU", "VRAM", "RAM", "DISK", "SPOT / ON DEMAND"))
def inr(v):
    return "INR %-6.2f" % v if v is not None else "    -     "

# Only the shapes a quota actually covers, unless asked for everything: this
# region offers 17 and two are reachable, and a list where 15 rows say "no
# quota covers this" is a list nobody reads.
show_all = os.environ.get("ALL", "") in ("--all", "all", "1")
usable = [m for m in d["machines"] if m["fits_spot"] or m["fits_ondemand"]]
rest = len(d["machines"]) - len(usable)
for m in (d["machines"] if show_all else usable):
    note = ""
    if not m["fits_spot"] and not m["fits_ondemand"]:
        note = "  (no quota covers %d vCPU)" % m["vcpu"]
    elif spot_on and not m["fits_spot"]:
        note = "  (spot quota does not cover it)"
    elif not spot_on and not m["fits_ondemand"]:
        note = "  (on-demand quota does not cover it)"
    print("  %s%-13s %-5d %-9s %-8s %-7s %-8s %s/ %s%s" % (
        "*" if m["type"] == d["configured"] else " ",
        m["type"], m["vcpu"], m["gpu"] or "-",
        ("%g GB" % m["vram_gib"]) if m["vram_gib"] else "-",
        "%g GB" % m["ram_gib"],
        ("%d GB" % m["store_gb"]) if m["store_gb"] else "none",
        inr(m["inr_hour_spot"]), inr(m["inr_hour_ondemand"]), note))
if rest and not show_all:
    print()
    print("  %d larger shapes exist here that no quota covers: cg machines --all" % rest)
print()
print("  * is the one in use. Change it with: cg config set GAME_INSTANCE_TYPE <type>")
print("  a type with no spot price has no spot market in this region")
'
}
