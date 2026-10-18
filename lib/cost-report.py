#!/usr/bin/env python3
# Renders `cg cost`'s "billed so far" section from one Cost Explorer answer on
# stdin: the usage-type table, the spot-against-on-demand comparison, and the
# egress allowance (which it also caches for `cg status`, because each Cost
# Explorer call costs $0.01 and status must not make one).
#
# Lifted out of lib/setup unchanged so that `cg cost --daily` can render the
# same summary from the same single call - see lib/cost-daily.py.

import json,os,sys
# Every rate is lib/rates.sh's, which read it from AWS - never a number typed in
# here. INR is a dollar of AWS charges in rupees, GST included.
def env(k):
    try: return float(os.environ[k])
    except (KeyError, ValueError): return None
INR=env("CG_INR_PER_USD"); EGRESS=env("CG_EGRESS_USD_GB"); FREE=env("CG_EGRESS_FREE_GB")
KBPS=env("GAME_BITRATE_KBPS") or 20000
def inr(usd, w=7): return ("%*s" % (w, "?")) if INR is None else ("%*.0f" % (w, usd*INR))
try: g=json.load(sys.stdin)
except Exception: print("  (Cost Explorer unavailable)"); sys.exit()
# Egress is the charge that rivals compute and it is INVISIBLE here until it
# starts costing money: the first 100 GB/month is free, so it books at $0.00
# and any "hide the small rows" filter drops the very line worth watching.
# Pull it out before filtering.
out_gb=sum(float(x["q"]) for x in g if "DataTransfer-Out-Bytes" in x["u"])
g=[x for x in g if float(x["c"])>0.004]
g.sort(key=lambda x:-float(x["c"]))
if not g and not out_gb: print("  nothing billed yet this month"); sys.exit()
print("  %-32s%9s %8s %7s" % ("USAGE TYPE","QTY","USD","INR"))
# Spot and on-demand hours are counted SEPARATELY. This used to keep one
# boolean - `spot = spot or "SpotUsage" in u` - so a single spot hour labelled
# the entire month "(spot)". It hid the thing most worth seeing: 10.96 of 15
# hours were on-demand at 4x the price, 87% of the bill, while the summary line
# read "15.0 instance-hours this month (spot)".
tot=0.0; sp_h=sp_c=od_h=od_c=0.0
for x in g:
    c=float(x["c"]); q=float(x["q"]); tot+=c
    u=x["u"].split("-",1)[-1]          # strip the region prefix
    if "SpotUsage" in u:  sp_h+=q; sp_c+=c
    elif "BoxUsage" in u: od_h+=q; od_c+=c
    print("  %-32s%9.2f %8.2f %s" % (u,q,c,inr(c)))
print("  " + "-"*57)
print("  %-32s%9s %8.2f %s" % ("TOTAL","",tot,inr(tot)))
if sp_h or od_h:
    print("")
    if od_h: print("  %5.1f h on demand  $%6.2f (INR %s)   $%.3f/hr" % (od_h, od_c, inr(od_c,5), od_c/od_h))
    if sp_h: print("  %5.1f h on spot    $%6.2f (INR %s)   $%.3f/hr" % (sp_h, sp_c, inr(sp_c,5), sp_c/sp_h))
    # Compare against the spot rate actually paid this month. With no spot
    # hour there is nothing to compare with, and no guess is made.
    rate = (sp_c/sp_h) if sp_h else None
    if od_h and rate:
        save = od_c - od_h*rate
        print("  those on-demand hours would have been $%.2f (INR %s) on spot - %.0f%% less"
              % (od_h*rate, inr(od_h*rate,0), 100*save/od_c if od_c else 0))

# Streaming is data transfer out. Free up to AWS's allowance each month, then
# AWS's per-GB price - which at a 20 Mbps stream (~9 GB an hour) rivals the
# machine itself. The hour is worked out at the bitrate actually set.
gb_hour=KBPS*3600/8/1e6
left=max(0.0, FREE-out_gb) if FREE is not None else None
# Cache it. Cost Explorer is the only source for MONTHLY egress - the box knows
# only its own boot - and each CE call costs $0.01, so `cg status` cannot ask
# for itself: at 20 runs a day that is INR 530/month, more than the S3 bill.
# Writing down what this command already paid for lets status show the real
# number for free, stamped with its age so it is never mistaken for live.
try:
    import time
    os.makedirs(".cg-cache", exist_ok=True)
    with open(".cg-cache/egress", "w") as f:
        f.write("%d %.3f %.0f\n" % (time.time(), out_gb, FREE if FREE is not None else 0))
except Exception:
    pass
print("")
mbps = "%g Mbps" % (KBPS/1000)
hour = ("$%.2f (INR %s) an hour" % (gb_hour*EGRESS, inr(gb_hour*EGRESS, 0))) if EGRESS is not None else "an unknown amount an hour"
if left is None:
    print("  egress (streaming) %.1f GB - the free allowance is not known" % out_gb)
else:
    print("  egress (streaming) %.1f GB of %.0f GB free - %.0f GB left" % (out_gb, FREE, left))
if left is None or left > 0:
    if left is not None:
        print("    ~%.1f more hours of streaming at %s before it costs anything" % (left/gb_hour, mbps))
    print("    after that: %s, about %s" % ("$%g/GB" % EGRESS if EGRESS is not None else "AWS's per-GB price", hour))
else:
    print("    FREE ALLOWANCE USED - streaming now costs about %s at %s" % (hour, mbps))
    print("    lowering the Moonlight bitrate cuts this proportionally")
