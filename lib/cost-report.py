#!/usr/bin/env python3
# Renders `cg cost`'s "billed so far" section from one Cost Explorer answer on
# stdin: the usage-type table, the spot-against-on-demand comparison, and the
# egress allowance (which it also caches for `cg status`, because each Cost
# Explorer call costs $0.01 and status must not make one).
#
# Lifted out of lib/setup unchanged so that `cg cost --daily` can render the
# same summary from the same single call - see lib/cost-daily.py.

import json,sys
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
    print("  %-32s%9.2f %8.2f %7.0f" % (u,q,c,c*88))
print("  " + "-"*57)
print("  %-32s%9s %8.2f %7.0f" % ("TOTAL","",tot,tot*88))
if sp_h or od_h:
    print("")
    if od_h: print("  %5.1f h on demand  $%6.2f (INR %5.0f)   $%.3f/hr" % (od_h, od_c, od_c*88, od_c/od_h))
    if sp_h: print("  %5.1f h on spot    $%6.2f (INR %5.0f)   $%.3f/hr" % (sp_h, sp_c, sp_c*88, sp_c/sp_h))
    # Compare against the rate actually paid where there is one, rather than a
    # hardcoded guess.
    rate = (sp_c/sp_h) if sp_h else 0.23
    if od_h:
        save = od_c - od_h*rate
        print("  those on-demand hours would have been $%.2f (INR %.0f) on spot - %.0f%% less"
              % (od_h*rate, od_h*rate*88, 100*save/od_c if od_c else 0))

# Streaming is data transfer out. Free to 100 GB/month, then $0.1093/GB - which
# at a 20 Mbps stream (~9 GB/hour) is ~$0.98/hour, rivalling the instance.
FREE=100.0
left=max(0.0, FREE-out_gb)
# Cache it. Cost Explorer is the only source for MONTHLY egress - the box knows
# only its own boot - and each CE call costs $0.01, so `cg status` cannot ask
# for itself: at 20 runs a day that is INR 530/month, more than the S3 bill.
# Writing down what this command already paid for lets status show the real
# number for free, stamped with its age so it is never mistaken for live.
try:
    import os, time
    os.makedirs(".cg-cache", exist_ok=True)
    with open(".cg-cache/egress", "w") as f:
        f.write("%d %.3f %.0f\n" % (time.time(), out_gb, FREE))
except Exception:
    pass
print("")
print("  egress (streaming) %.1f GB of %.0f GB free - %.0f GB left" % (out_gb, FREE, left))
if left > 0:
    print("    ~%.1f more hours of streaming at 20 Mbps before it costs anything" % (left/9.0))
    print("    after that: $0.1093/GB, about $0.98 (INR 86) per streaming hour")
else:
    print("    FREE ALLOWANCE USED - streaming now costs ~$0.98 (INR 86) per hour at 20 Mbps")
    print("    lowering the Moonlight bitrate cuts this proportionally")
