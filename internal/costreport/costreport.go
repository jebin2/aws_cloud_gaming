// Package costreport renders `cg cost`'s "billed so far" section from the
// month's usage types: the table, the spot-against-on-demand comparison and the
// egress allowance. It is the Go form of lib/cost-report.py.
//
// Two rules it keeps from the Python, and one it fixes:
//
//   - egress is the charge that rivals compute and is invisible until it costs
//     money (the first 100 GB a month is free), so it is pulled out before the
//     small rows are dropped;
//   - spot and on-demand hours are counted separately, never one boolean;
//   - fixed: the total is everything billed, and a month whose only charges are
//     under half a cent shows that total instead of "nothing billed yet".
package costreport

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/costdaily"
)

// Settings are the prices and the stream bitrate. A nil is unknown and prints
// as unknown, never as a number typed in here.
type Settings struct {
	INRPerUSD *float64 // a dollar of AWS charges in rupees, GST included
	EgressUSD *float64 // AWS's price per GB out
	FreeGB    *float64 // the free allowance each month
	KBPS      float64  // the stream bitrate; 0 means the default
}

const defaultKBPS = 20000

// Cache is told how much data went out this month, because Cost Explorer is the
// only source for it and each call costs $0.01: `cg status` shows the cached
// figure instead of asking for itself.
type Cache func(outGB float64, freeGB *float64)

func (s Settings) inr(usd float64, w int) string {
	if s.INRPerUSD == nil {
		return fmt.Sprintf("%*s", w, "?")
	}
	return fmt.Sprintf("%*.0f", w, usd**s.INRPerUSD)
}

// Render is the report for one month. cache may be nil.
func Render(usage []costdaily.Usage, s Settings, cache Cache) string {
	kbps := s.KBPS
	if kbps == 0 {
		kbps = defaultKBPS
	}
	var outGB, whole float64
	for _, x := range usage {
		if strings.Contains(x.U, "DataTransfer-Out-Bytes") {
			outGB += x.Q
		}
		whole += x.C
	}
	var shown []costdaily.Usage
	for _, x := range usage {
		if x.C > 0.004 {
			shown = append(shown, x)
		}
	}
	sort.SliceStable(shown, func(i, j int) bool { return shown[i].C > shown[j].C })

	if len(shown) == 0 && outGB == 0 && whole <= 0 {
		return "  nothing billed yet this month\n"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "  %-32s%9s %8s %7s\n", "USAGE TYPE", "QTY", "USD", "INR")
	var spH, spC, odH, odC float64
	for _, x := range shown {
		u := costdaily.StripRegion(x.U)
		switch {
		case strings.Contains(u, "SpotUsage"):
			spH += x.Q
			spC += x.C
		case strings.Contains(u, "BoxUsage"):
			odH += x.Q
			odC += x.C
		}
		fmt.Fprintf(&b, "  %-32s%9.2f %8.2f %s\n", u, x.Q, x.C, s.inr(x.C, 7))
	}
	if len(shown) == 0 {
		b.WriteString("  (every charge is under half a cent)\n")
	}
	b.WriteString("  " + strings.Repeat("-", 57) + "\n")
	fmt.Fprintf(&b, "  %-32s%9s %8.2f %s\n", "TOTAL", "", whole, s.inr(whole, 7))

	if spH != 0 || odH != 0 {
		b.WriteString("\n")
		if odH != 0 {
			fmt.Fprintf(&b, "  %5.1f h on demand  $%6.2f (INR %s)   $%.3f/hr\n", odH, odC, s.inr(odC, 5), odC/odH)
		}
		if spH != 0 {
			fmt.Fprintf(&b, "  %5.1f h on spot    $%6.2f (INR %s)   $%.3f/hr\n", spH, spC, s.inr(spC, 5), spC/spH)
		}
		// Compared against the spot rate actually paid this month. With no spot
		// hour there is nothing to compare with, and no guess is made.
		if spH != 0 && odH != 0 {
			if rate := spC / spH; rate != 0 {
				save := odC - odH*rate
				pct := 0.0
				if odC != 0 {
					pct = 100 * save / odC
				}
				fmt.Fprintf(&b, "  those on-demand hours would have been $%.2f (INR %s) on spot - %.0f%% less\n",
					odH*rate, s.inr(odH*rate, 0), pct)
			}
		}
	}

	// Streaming is data transfer out: free up to the allowance each month, then
	// AWS's per-GB price, which at a 20 Mbps stream rivals the machine itself.
	gbHour := kbps * 3600 / 8 / 1e6
	var left *float64
	if s.FreeGB != nil {
		l := *s.FreeGB - outGB
		if l < 0 {
			l = 0
		}
		left = &l
	}
	if cache != nil {
		cache(outGB, s.FreeGB)
	}
	b.WriteString("\n")
	mbps := fmt.Sprintf("%g Mbps", kbps/1000)
	hour := "an unknown amount an hour"
	if s.EgressUSD != nil {
		hour = fmt.Sprintf("$%.2f (INR %s) an hour", gbHour**s.EgressUSD, s.inr(gbHour**s.EgressUSD, 0))
	}
	if left == nil {
		fmt.Fprintf(&b, "  egress (streaming) %.1f GB - the free allowance is not known\n", outGB)
	} else {
		fmt.Fprintf(&b, "  egress (streaming) %.1f GB of %.0f GB free - %.0f GB left\n", outGB, *s.FreeGB, *left)
	}
	if left == nil || *left > 0 {
		if left != nil {
			fmt.Fprintf(&b, "    ~%.1f more hours of streaming at %s before it costs anything\n", *left/gbHour, mbps)
		}
		price := "AWS's per-GB price"
		if s.EgressUSD != nil {
			price = fmt.Sprintf("$%g/GB", *s.EgressUSD)
		}
		fmt.Fprintf(&b, "    after that: %s, about %s\n", price, hour)
	} else {
		fmt.Fprintf(&b, "    FREE ALLOWANCE USED - streaming now costs about %s at %s\n", hour, mbps)
		b.WriteString("    lowering the Moonlight bitrate cuts this proportionally\n")
	}
	return b.String()
}
