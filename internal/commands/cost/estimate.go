// Package cost is `cg cost`: what has been billed, what has not been billed
// yet, and what still bills with no machine at all. Every figure is built from
// facts that say whether they could be read; an unknown price or an unreadable
// fact is "?" or null, never zero.
package cost

import (
	"fmt"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// Estimate is the part of the month Cost Explorer has not caught up with (it
// lags about a day): this instance's runtime, the disks it and cg leave
// behind, and the snapshots. Egress is counted by the bill, not here.
type Estimate struct {
	Hours      costfacts.Known[int]
	Kind       string   // "on demand" or "spot, price now"
	HourlyRate *float64 // the machine, per hour; nil when AWS would not say
	DiskGB     costfacts.Known[float64]
	DiskGBMon  costfacts.Known[float64] // GB-months accrued so far this month
	SnapGB     costfacts.Known[float64]
	NoInstance bool
	Day        int // day of the month
	MonthDays  int
}

// Lines are the money of the estimate; a nil is unknown.
type Lines struct {
	Compute, Storage, Snapshots, Total *float64
}

func mul(a, b *float64) *float64 {
	if a == nil || b == nil {
		return nil
	}
	v := *a * *b
	return &v
}

func f(v float64) *float64 { return &v }

// Compute works the estimate out. Compute is hours at the machine's price plus
// the public IPv4 address's, billed by the hour beside it.
func Compute(e Estimate, r pricing.Rates) Lines {
	var l Lines
	if e.Hours.OK && e.HourlyRate != nil && r.IPv4Hour != nil {
		l.Compute = f(float64(e.Hours.V) * (*e.HourlyRate + *r.IPv4Hour))
	}
	switch {
	case e.DiskGB.OK && e.DiskGB.V == 0:
		l.Storage = f(0)
	case e.DiskGBMon.OK:
		l.Storage = mul(f(e.DiskGBMon.V), r.EBSGBMonth)
	}
	switch {
	case e.SnapGB.OK && e.SnapGB.V == 0:
		l.Snapshots = f(0)
	case e.SnapGB.OK:
		l.Snapshots = mul(f(e.SnapGB.V*float64(e.Day)/float64(e.MonthDays)), r.SnapshotGBMonth)
	}
	if l.Compute != nil && l.Storage != nil && l.Snapshots != nil {
		l.Total = f(*l.Compute + *l.Storage + *l.Snapshots)
	}
	return l
}

// GBMonths is how much of a month's disk has accrued: each disk from when it
// was made, not from the first. One made yesterday was charged as if it had
// existed all month.
func GBMonths(vols []costfacts.Volume, now time.Time) float64 {
	start := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	end := start.AddDate(0, 1, 0)
	var t float64
	for _, v := range vols {
		from := v.Created
		if from.Before(start) {
			from = start
		}
		if d := now.Sub(from); d > 0 {
			t += v.GB * d.Seconds() / end.Sub(start).Seconds()
		}
	}
	return t
}

func usd(v *float64) string {
	if v == nil {
		return "      ?"
	}
	return fmt.Sprintf("$%6.2f", *v)
}

func rupees(v *float64, r pricing.Rates) string {
	if v == nil || r.INRPerUSD == nil {
		return "INR     ?"
	}
	return fmt.Sprintf("INR %5.0f", *v**r.INRPerUSD)
}

// Render is the "not yet billed" block. A price AWS could not be asked for
// prints as "?", never as $0.00: an unknown is not free.
func (e Estimate) Render(r pricing.Rates) string {
	l := Compute(e, r)
	var b strings.Builder
	b.WriteString("not yet billed (Cost Explorer lags about a day):\n")
	hours := "      ?"
	if e.Hours.OK {
		hours = fmt.Sprintf("%6.1f", float64(e.Hours.V))
	}
	fmt.Fprintf(&b, "  compute   %s hrs  %s  (%s)  THIS instance only, %s, with its IPv4\n", hours, usd(l.Compute), rupees(l.Compute, r), e.Kind)
	gb := "     ?"
	if e.DiskGB.OK {
		gb = fmt.Sprintf("%6d", int(e.DiskGB.V))
	}
	fmt.Fprintf(&b, "  storage   %s GB   %s  (%s)  month so far, accrues while stopped\n", gb, usd(l.Storage), rupees(l.Storage, r))
	if !e.SnapGB.OK || e.SnapGB.V > 0 {
		sg := "     ?"
		if e.SnapGB.OK {
			sg = fmt.Sprintf("%6d", int(e.SnapGB.V))
		}
		fmt.Fprintf(&b, "  snapshots %s GB   %s  (%s)  at most - AWS bills only the changed blocks\n", sg, usd(l.Snapshots), rupees(l.Snapshots, r))
	}
	b.WriteString("  ---------------------------------------\n")
	fmt.Fprintf(&b, "  estimate              %s  (%s)\n", usd(l.Total), rupees(l.Total, r))
	b.WriteString("  (egress is counted under 'billed so far' below, not in this estimate)\n")
	if e.NoInstance {
		b.WriteString("  NOTE: no instance exists, so runtime from any earlier one this month is\n")
		b.WriteString("  not counted above. 'billed so far' below is the figure to trust.\n")
	}
	return b.String()
}
