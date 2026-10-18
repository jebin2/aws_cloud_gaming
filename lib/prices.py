#!/usr/bin/env python3
# prices.py <region> - AWS's own prices for one region, as KEY=value lines.
#
# Every rate cg prints or hands the app comes from here: the Price List API,
# asked directly, so a price AWS changes is the price shown the next day. None
# is written down in the code - a table typed in once was how disk copies came
# to be priced at the archive tier, a quarter of what AWS charges for them.
#
# Free: the Price List API costs nothing. lib/rates.sh caches the answer for a
# day per region, so this runs at most once a day for each place.
#
# Exit 1, printing nothing, unless every price was found: a half-read table is
# not cached, and an unknown price stays unknown rather than becoming a guess.
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor


def products(service, *filters):
    args = ["aws", "pricing", "get-products", "--region", "us-east-1",
            "--service-code", service, "--output", "json",
            # One --filters, all of them after it: given twice, the CLI keeps
            # only the last, and every region came back with us-east-1's prices.
            "--filters", *(f"Type=TERM_MATCH,Field={f},Value={v}" for f, v in filters)]
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=60).stdout
        return [json.loads(p) for p in json.loads(out).get("PriceList", [])]
    except Exception:
        return []


def first_tier(items):
    """(usagetype, USD) of the lowest paid tier - the price the first GB pays.
    Free tiers are not in the price list; a tier that starts at 0 is the first."""
    best = None
    for d in items:
        ut = d.get("product", {}).get("attributes", {}).get("usagetype", "")
        for term in d.get("terms", {}).get("OnDemand", {}).values():
            for dim in term.get("priceDimensions", {}).values():
                try:
                    usd = float(dim["pricePerUnit"]["USD"])
                    begin = float(dim.get("beginRange") or 0)
                except (KeyError, TypeError, ValueError):
                    continue
                if usd <= 0:
                    continue
                if best is None or begin < best[0]:
                    best = (begin, ut, usd)
    return (best[1], best[2]) if best else (None, None)


def main():
    region = sys.argv[1] if len(sys.argv) > 1 else ""
    if not region:
        return 1
    # The gp3 disk first: its usage type carries the region's billing prefix
    # ("APS5-" for Hyderabad), which names every other price exactly.
    ut, ebs = first_tier(products("AmazonEC2", ("regionCode", region),
                                  ("productFamily", "Storage"), ("volumeApiName", "gp3")))
    if not ut or "EBS:" not in ut:
        return 1
    p = ut.split("EBS:")[0]
    asks = {
        "CG_SNAPSHOT_USD_GB_MONTH": ("AmazonEC2", p + "EBS:SnapshotUsage"),
        "CG_S3_USD_GB_MONTH":       ("AmazonS3", p + "TimedStorage-ByteHrs"),
        "CG_IPV4_USD_HOUR":         ("AmazonVPC", p + "PublicIPv4:InUseAddress"),
        "CG_EGRESS_USD_GB":         ("AWSDataTransfer", p + "DataTransfer-Out-Bytes"),
        "CG_XREGION_USD_GB":        ("AWSDataTransfer", p + "AWS-Out-Bytes"),
        # Cost Explorer is billed in us-east-1 whatever the region.
        "CG_CE_CALL_USD":           ("AWSCostExplorer", "USE1-APIRequest"),
    }
    def ask(a):
        service, usage = a
        usd = first_tier(products(service, ("usagetype", usage)))[1]
        # us-east-1 bills its disks with no prefix but its addresses and
        # transfers as "USE1-": the one region that is not consistent.
        if usd is None and not p and not usage.startswith("USE1-"):
            usd = first_tier(products(service, ("usagetype", "USE1-" + usage)))[1]
        return usd
    with ThreadPoolExecutor(len(asks)) as pool:
        got = dict(zip(asks, pool.map(ask, asks.values())))
    got["CG_EBS_USD_GB_MONTH"] = ebs
    if any(v is None for v in got.values()):
        return 1
    for k in sorted(got):
        print(f"{k}={got[k]:.6g}")
    return 0


sys.exit(main())
