#!/usr/bin/env python3
# `cg cost --daily`: one row per day, one column per kind of charge.
#
# Reads Cost Explorer's answer on stdin - daily granularity, grouped by usage
# type. With --aggregate it prints the same data in the monthly shape instead,
# so lib/cost-report.py renders its summary from the SAME answer: Cost Explorer
# bills $0.01 per request, so --daily must not cost a second call.
#
# Days with nothing billed are left out and counted at the end: an idle month is
# mostly empty days, and printing thirty "0.00" rows hides the days that matter.
import json
import sys

INR = 88
COLS = ["compute", "s3", "disk", "egress", "api", "other"]


def bucket(usage_type):
    """Which column a usage type belongs in. The region prefix (APS5-) is
    stripped first, as the monthly table does."""
    u = usage_type.split("-", 1)[-1]
    if u.startswith(("BoxUsage", "SpotUsage")):        return "compute"
    if u.startswith("DataTransfer-Out-Bytes"):         return "egress"
    if u.startswith(("TimedStorage", "Requests-Tier")): return "s3"
    if "VolumeUsage" in u or "SnapshotUsage" in u:     return "disk"
    if u.startswith("APIRequest"):                     return "api"
    return "other"


def load():
    try:
        days = json.load(sys.stdin)
    except Exception:
        return None
    if not isinstance(days, list):
        return None
    return days


def aggregate(days):
    """The monthly shape: one entry per usage type, summed over the month."""
    totals = {}
    for day in days:
        for g in day.get("g") or []:
            t = totals.setdefault(g["u"], {"u": g["u"], "c": 0.0, "q": 0.0})
            t["c"] += float(g["c"])
            t["q"] += float(g["q"])
    out = [{"u": t["u"], "c": "%.10f" % t["c"], "q": "%.6f" % t["q"]} for t in totals.values()]
    json.dump(out, sys.stdout)


def table(days):
    rows, empty, month = [], 0, dict.fromkeys(COLS, 0.0)
    month_hours = 0.0
    for day in days:
        cols = dict.fromkeys(COLS, 0.0)
        hours = 0.0
        for g in day.get("g") or []:
            c = float(g["c"])
            cols[bucket(g["u"])] += c
            if bucket(g["u"]) == "compute":
                hours += float(g["q"])
        total = sum(cols.values())
        if total <= 0.0005 and hours <= 0:
            empty += 1
            continue
        for k in COLS:
            month[k] += cols[k]
        month_hours += hours
        rows.append((day["d"], hours, cols, total))

    if not rows:
        print("  nothing billed yet this month")
        return

    head = "  %-11s %5s" % ("DATE", "HRS") + "".join("%9s" % c.upper() for c in COLS) + "%9s%8s" % ("TOTAL", "INR")
    print(head)

    def cell(v):
        return "%9s" % ("-" if v <= 0.0005 else "%.2f" % v)

    for d, hours, cols, total in rows:
        print("  %-11s %5s" % (d, "-" if hours <= 0 else "%.1f" % hours)
              + "".join(cell(cols[c]) for c in COLS)
              + "%9.2f%8.0f" % (total, total * INR))
    print("  " + "-" * (len(head) - 2))
    month_total = sum(month.values())
    print("  %-11s %5.1f" % ("TOTAL", month_hours)
          + "".join(cell(month[c]) for c in COLS)
          + "%9.2f%8.0f" % (month_total, month_total * INR))
    if empty:
        print("  %d day(s) with nothing billed are not shown. USD, and INR at %d."
              % (empty, INR))
    else:
        print("  USD, and INR at %d." % INR)


def as_json(days):
    """Everything the CE answer holds, as data: per day, per usage type, and the
    two summaries the report draws (hours by purchase model, egress allowance)."""
    rows, usage = [], {}
    hours = {"on_demand": 0.0, "spot": 0.0}
    cost = {"on_demand": 0.0, "spot": 0.0}
    out_gb = 0.0
    for day in days:
        cols = dict.fromkeys(COLS, 0.0)
        day_hours = 0.0
        for g in day.get("g") or []:
            c, q = float(g["c"]), float(g["q"])
            u = g["u"].split("-", 1)[-1]
            cols[bucket(g["u"])] += c
            t = usage.setdefault(u, {"type": u, "qty": 0.0, "usd": 0.0})
            t["qty"] += q; t["usd"] += c
            if u.startswith("SpotUsage"):       hours["spot"] += q; cost["spot"] += c; day_hours += q
            elif u.startswith("BoxUsage"):      hours["on_demand"] += q; cost["on_demand"] += c; day_hours += q
            elif u.startswith("DataTransfer-Out-Bytes"): out_gb += q
        total = sum(cols.values())
        if total <= 0.0005 and day_hours <= 0:
            continue
        rows.append({"date": day["d"], "hours": round(day_hours, 2),
                     **{k: round(v, 4) for k, v in cols.items()},
                     "total": round(total, 4)})
    month = round(sum(r["total"] for r in rows), 4)
    rates = {k: round(cost[k] / hours[k], 4) if hours[k] else None for k in hours}
    return {
        "days": rows,
        "usage": sorted(({"type": u["type"], "qty": round(u["qty"], 4), "usd": round(u["usd"], 4)}
                         for u in usage.values()), key=lambda x: -x["usd"]),
        "total_usd": month, "total_inr": round(month * INR),
        "hours": {k: round(v, 2) for k, v in hours.items()},
        "usd_per_hour": rates,
        "egress": {"gb_used": round(out_gb, 2), "gb_free": 100.0,
                   "gb_left": round(max(0.0, 100.0 - out_gb), 2)},
        "inr_per_usd": INR,
    }


def main():
    days = load()
    if days is None:
        if "--json" in sys.argv:    print("{}")
        elif "--aggregate" in sys.argv: print("[]")
        else: print("  (Cost Explorer unavailable)")
        return
    if "--json" in sys.argv:
        print(json.dumps(as_json(days), indent=2))
    elif "--aggregate" in sys.argv:
        aggregate(days)
    else:
        print("billed day by day (lags a day, like the totals below):")
        table(days)


main()
