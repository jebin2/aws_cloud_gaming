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
import calendar
import json
import os
import re
import sys

# The rate lib/rates.sh settled on, so this total and every other rupee figure
# agree: a dollar of AWS charges in rupees, GST included. A fixed 88 here put
# the month at Rs 265 while the rows under it, at today's 94.95, added up to
# more. None when no rate could be found - the rupee column then says so.
try:
    INR = float(os.environ["CG_INR_PER_USD"])
except (KeyError, ValueError):
    INR = None
try:
    TAX = float(os.environ.get("CG_TAX_PCT") or 0)
except ValueError:
    TAX = 0.0
# AWS's free allowance for data out to the internet - lib/rates.sh.
try:
    FREE_GB = float(os.environ["CG_EGRESS_FREE_GB"])
except (KeyError, ValueError):
    FREE_GB = None
COLS = ["compute", "s3", "disk", "egress", "api", "other"]


# A region prefix: AWS writes it in capitals - APS5-, USE1-, EU-. Cutting at the
# first dash instead took "DataTransfer-" off DataTransfer-Out-Bytes and
# "TimedStorage-" off TimedStorage-ByteHrs, wherever AWS gave no prefix, and
# egress and S3 storage landed in "other".
REGION_PREFIX = re.compile(r"^[A-Z]{2,4}[0-9]{0,2}-")


def strip_region(usage_type):
    return REGION_PREFIX.sub("", usage_type, count=1)


def bucket(usage_type):
    """Which column a usage type belongs in, its region prefix stripped first."""
    u = strip_region(usage_type)
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


def project(days, month_total):
    """Where the month is heading if the rest of it looks like the part that has
    already happened.

    The window asked of Cost Explorer starts on the 1st and ends tomorrow, so
    the answer carries one entry per day elapsed, today included. Today is not
    over and the bill runs about a day behind, so the pace is the days before
    today: dividing the month by every day including today read low all month.
    On the 1st there is no whole day yet, and no pace.

    The window's own first date says which month it is, and therefore how many
    days it has; the app used to work this out in the renderer, which meant the
    terminal could not say it at all.
    """
    if not days or month_total <= 0:
        return {"days_elapsed": len(days), "days_in_month": None,
                "projected_usd": None, "projected_inr": None}
    elapsed = len(days)
    whole = days[:-1]
    if not whole:
        return {"days_elapsed": elapsed, "days_in_month": None,
                "projected_usd": None, "projected_inr": None}
    try:
        year, mon = (int(x) for x in str(days[0].get("d", "")).split("-")[:2])
        in_month = calendar.monthrange(year, mon)[1]
    except (TypeError, ValueError):
        return {"days_elapsed": elapsed, "days_in_month": None,
                "projected_usd": None, "projected_inr": None}
    # What the whole days ran at, for every day of the month. Today's partial
    # charges are not in the pace; the days to come, today included, are.
    done = sum(float(g["c"]) for d in whole for g in (d.get("g") or []))
    usd = done / len(whole) * in_month
    return {"days_elapsed": elapsed, "days_in_month": in_month,
            "projected_usd": round(usd, 4),
            "projected_inr": round(usd * INR) if INR else None}


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

    def inr(usd):
        return "%8s" % ("?" if INR is None else "%.0f" % (usd * INR))

    for d, hours, cols, total in rows:
        print("  %-11s %5s" % (d, "-" if hours <= 0 else "%.1f" % hours)
              + "".join(cell(cols[c]) for c in COLS)
              + "%9.2f" % total + inr(total))
    print("  " + "-" * (len(head) - 2))
    month_total = sum(month.values())
    print("  %-11s %5.1f" % ("TOTAL", month_hours)
          + "".join(cell(month[c]) for c in COLS)
          + "%9.2f" % month_total + inr(month_total))
    rate = ("INR unknown - no exchange rate could be read" if INR is None
            else "INR at %.2f a dollar%s" % (INR, " (%g%% GST included)" % TAX if TAX else ""))
    if empty:
        print("  %d day(s) with nothing billed are not shown. USD before tax, and %s."
              % (empty, rate))
    else:
        print("  USD before tax, and %s." % rate)
    pr = project(days, month_total)
    if pr["projected_inr"] is not None and pr["days_elapsed"] < pr["days_in_month"]:
        print("  On this pace: %.2f USD / %d INR by the end of the month"
              " (%d of its %d days so far)."
              % (pr["projected_usd"], pr["projected_inr"],
                 pr["days_elapsed"], pr["days_in_month"]))


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
            u = strip_region(g["u"])
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
        "total_usd": month, "total_inr": round(month * INR) if INR is not None else None,
        # The same arithmetic the window used to do for itself.
        **project(days, month),
        "hours": {k: round(v, 2) for k, v in hours.items()},
        "usd_per_hour": rates,
        "egress": {"gb_used": round(out_gb, 2), "gb_free": FREE_GB,
                   "gb_left": round(max(0.0, FREE_GB - out_gb), 2) if FREE_GB is not None else None},
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
        print("billed day by day (the whole AWS account, every region - lags a day):")
        table(days)


main()
