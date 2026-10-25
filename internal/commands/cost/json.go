package cost

import (
	"encoding/json"
	"math"
	"strconv"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/costdaily"
	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
)

type obj = map[string]any

func nf(v *float64) any {
	if v == nil {
		return nil
	}
	return *v
}

func nk[T any](k costfacts.Known[T]) any {
	if !k.OK {
		return nil
	}
	return k.V
}

func round(x float64, n int) float64 {
	v, _ := strconv.ParseFloat(strconv.FormatFloat(x, 'f', n, 64), 64)
	return v
}

// monthly is qty of something billed by the month, in dollars: 0 for none, nil
// when there is some but its price is unknown.
func monthly(qty costfacts.Known[float64], price *float64) *float64 {
	if !qty.OK {
		return nil
	}
	if qty.V == 0 {
		z := 0.0
		return &z
	}
	if price == nil {
		return nil
	}
	v := qty.V * *price
	return &v
}

func r2(v *float64, n int) any {
	if v == nil {
		return nil
	}
	return round(*v, n)
}

// JSON is `cg cost --json`: the resources that still bill, plus everything the
// one Cost Explorer call knows. Same call, same price. Keys sort, and an
// unreadable fact is null - never 0 or false.
func (in Inputs) JSON() ([]byte, error) {
	f, r := in.Facts, in.Rates
	cr := costdaily.Rates{INRPerUSD: r.INRPerUSD, TaxPct: r.TaxPct, FreeGB: &r.EgressFreeGB}
	var month any = obj{}
	var sum costdaily.Summary
	haveMonth := f.Month.OK
	if haveMonth {
		sum = costdaily.Summarize(f.Month.V, cr)
		month = sum
	}
	var inst any
	if i := in.instance(); i != nil {
		inst = obj{"id": i.ID, "state": i.State}
	}
	disk, snap := f.DiskGB(), f.SnapshotGB()
	images := any(nil)
	if f.Images.OK {
		images = len(f.Images.V)
	}
	eips := any(nil)
	if f.EIPs.OK {
		eips = f.EIPs.V
	}
	var budget *float64
	if f.Budget.OK {
		budget = f.Budget.V
	}

	// The archive: the games only. No bucket is 0 objects; a bucket that could
	// not be listed is unknown.
	arch := obj{"bucket": nil, "objects": 0.0, "bytes": nil, "usd_month": nil, "decision": nil}
	var archiveUSD costfacts.Known[float64]
	archiveUSD = costfacts.Known[float64]{V: 0, OK: true}
	if in.Facts.Bucket.Name != "" {
		arch["bucket"] = in.Facts.Bucket.Name
		if f.Archive.OK {
			arch["objects"] = float64(f.Archive.V.Objects)
			if f.Archive.V.Bytes > 0 {
				arch["bytes"] = float64(f.Archive.V.Bytes)
			}
			gb := costfacts.Known[float64]{V: float64(f.Archive.V.Bytes) / 1073741824, OK: true}
			if u := monthly(gb, r.S3GBMonth); u != nil {
				archiveUSD = costfacts.Known[float64]{V: *u, OK: true}
				if f.Archive.V.Bytes > 0 {
					arch["usd_month"] = round(*u, 2)
				}
			} else {
				archiveUSD = costfacts.Known[float64]{}
			}
		} else {
			arch["objects"], archiveUSD = nil, costfacts.Known[float64]{}
		}
	}

	// What still bills with no box at all: the archive, plus any volume or
	// snapshot left behind, plus any Elastic IP - an address bills by the hour
	// whether or not anything uses it. One number, worked out once, here.
	now := in.Now.UTC()
	monthDays := time.Date(now.Year(), now.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day()
	monthHours := float64(monthDays * 24)
	var addr *float64
	if f.EIPs.OK {
		addr = monthly(costfacts.Known[float64]{V: float64(f.EIPs.V) * monthHours, OK: true}, r.IPv4Hour)
	}
	parts := []*float64{nil, monthly(disk, r.EBSGBMonth), monthly(snap, r.SnapshotGBMonth), addr}
	if archiveUSD.OK {
		parts[0] = &archiveUSD.V
	}
	var standby *float64
	complete := true
	var total float64
	for _, p := range parts {
		if p == nil {
			complete = false
			break
		}
		total += *p
	}
	if complete {
		standby = &total
	}

	// Storage as the BILL sees it, beside storage as cg sees it. cg only knows
	// the bucket in .env; a region move left games in another one, billing,
	// while this said the archive was empty. The most recent whole day that
	// billed any S3 is the rate: today is partial, and Cost Explorer lags, so
	// the largest of the last three such days.
	var billed *float64
	if haveMonth {
		today := now.Format("2006-01-02")
		var s3 []float64
		for _, d := range sum.Days {
			if d.Date < today && d.S3 > 0 {
				s3 = append(s3, d.S3)
			}
		}
		if n := len(s3); n > 0 {
			recent := s3[max(0, n-3):]
			hi := recent[0]
			for _, v := range recent {
				hi = math.Max(hi, v)
			}
			v := round(hi*30, 2)
			billed = &v
		}
	}
	var known, unknown any
	if archiveUSD.OK {
		known = round(archiveUSD.V, 2)
		if billed != nil {
			unknown = round(math.Max(0, *billed-archiveUSD.V), 2)
		}
	}
	var stdDay any
	if standby != nil {
		stdDay = round(*standby/float64(monthDays), 4)
	}
	var ssd = func(i int) any { return r2(parts[i], 2) }

	out := obj{
		"host": in.Host, "region": in.Region, "month": month,
		"credits_usd": nk(f.Credits),
		"resources": obj{
			"instance": inst, "volumes_gb": nk(disk), "snapshots_gb": nk(snap), "images": images,
			"key_pair": nk(f.KeyPair), "security_group": nk(f.SecGroup), "budget_usd": nf(budget),
			"elastic_ips": eips,
		},
		"archive": arch,
		"rates": obj{
			"s3_gb_month": nf(r.S3GBMonth), "ebs_gb_month": nf(r.EBSGBMonth), "snapshot_gb_month": nf(r.SnapshotGBMonth),
			"egress_gb": nf(r.EgressGB), "egress_free_gb": r.EgressFreeGB, "ce_call_usd": nf(r.CECallUSD),
			"ipv4_hour": nf(r.IPv4Hour), "inr_per_usd": nf(r.INRPerUSD), "fx_inr_per_usd": nf(r.FXINRPerUSD),
			"tax_pct": r.TaxPct,
		},
		"storage": obj{"billed_usd_month": nf(billed), "known_usd_month": known, "unknown_usd_month": unknown},
		"standby": obj{
			"usd_month": r2(standby, 2), "usd_day": stdDay,
			"archive_usd_month": ssd(0), "volumes_usd_month": ssd(1),
			"snapshots_usd_month": ssd(2), "addresses_usd_month": ssd(3),
		},
	}
	return json.MarshalIndent(out, "", "  ")
}
