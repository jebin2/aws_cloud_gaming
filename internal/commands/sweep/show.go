package sweep

import (
	"fmt"
	"strings"
)

// Show is the same sweep for a person.
func Show(d Result, all bool) string {
	if d.Error != "" {
		return "  " + d.Error + "\n"
	}
	var b strings.Builder
	b.WriteString("  every AWS region, scored for whether it can actually run this rig\n")
	if d.Measured {
		fmt.Fprintf(&b, "  latency is measured now, median of several probes; the budget is %gms\n", d.MaxMS)
	} else {
		b.WriteString("  latency could NOT be measured - every probe failed - so\n")
		b.WriteString("  no region was excluded and the list below is not ordered by distance\n")
	}
	b.WriteString("  capacity is AWS own spot placement score, 1-10: 1 means do not bother\n\n")

	if len(d.Regions) == 0 {
		fmt.Fprintf(&b, "  no region is within %gms - nothing here can stream\n", d.MaxMS)
	} else {
		fmt.Fprintf(&b, "  %-16s %-11s %-7s %-13s %-6s %-9s %s\n", "REGION", "CITY", "LATENCY", "TYPE", "SCORE", "QUOTA", "SPOT / ON DEMAND")
		for _, r := range d.Regions {
			city := ""
			if r.City != nil {
				city = Trim(*r.City)
			}
			ms := "-"
			if r.RTTMS != nil {
				ms = fmt.Sprintf("%.0f ms", *r.RTTMS)
			}
			mark := " "
			if r.Region == d.Configured {
				mark = "*"
			}
			if len(r.Machines) == 0 {
				fmt.Fprintf(&b, "  %s%-15s %-11s %-7s %s\n", mark, r.Region, clip(city, 11), ms, "no GPU machine of a usable size is sold here")
				continue
			}
			for i, m := range r.Machines {
				var q string
				switch {
				case !r.Enabled:
					q = "opt-in"
				case m.FitsSpot == nil:
					q = "?"
				default:
					od, sp := "0", "0"
					if *m.FitsOnDemand {
						od = "ok"
					}
					if *m.FitsSpot {
						sp = "ok"
					}
					q = od + "/" + sp
				}
				inr := func(v *float64) string {
					if v == nil {
						return "-"
					}
					return fmt.Sprintf("INR %.2f", *v)
				}
				score := "-"
				if m.Score != nil {
					score = fmt.Sprint(*m.Score)
				}
				first := func(s string) string {
					if i == 0 {
						return s
					}
					return ""
				}
				mk := " "
				if i == 0 {
					mk = mark
				}
				fmt.Fprintf(&b, "  %s%-15s %-11s %-7s %-13s %-6s %-9s %s\n", mk, first(r.Region), first(clip(city, 11)), first(ms),
					m.Type, score, q, inr(m.INRHourSpot)+" / "+inr(m.INRHourOD))
			}
		}
		b.WriteString("\n  QUOTA is on demand/spot: ok means 4 vCPU is covered, 0 means ask for it,\n")
		b.WriteString("  opt-in means the region is not enabled so the quota cannot be read yet.\n")
	}
	switch {
	case len(d.TooFar) > 0 && all:
		fmt.Fprintf(&b, "\n  too far to stream (over %gms):\n", d.MaxMS)
		for _, r := range d.TooFar {
			fmt.Fprintf(&b, "    %-16s %5.0f ms\n", r.Region, r.RTTMS)
		}
	case len(d.TooFar) > 0:
		fmt.Fprintf(&b, "\n  %d more regions are over %gms and were skipped: cg sweep --all\n", len(d.TooFar), d.MaxMS)
	}
	if len(d.Unreachable) > 0 {
		fmt.Fprintf(&b, "  %d regions did not answer a latency probe\n", len(d.Unreachable))
	}
	b.WriteString("\n  * is the region in use. Change it with: cg config set GAME_REGION <region>\n")
	return b.String()
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
