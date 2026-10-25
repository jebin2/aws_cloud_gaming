package machines

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// Show is the same table for a person, not a program. Only the shapes a quota
// actually covers are listed unless all is asked for: a region offers 17 and two
// are reachable, and a list where 15 rows say "no quota covers this" is a list
// nobody reads.
func Show(t Table, all bool) string {
	if t.Error != "" {
		return "  " + t.Error + "\n"
	}
	var b strings.Builder
	spotOn := t.Spot == "1"
	fmt.Fprintf(&b, "  region %s - quota %d vCPU on demand, %d spot\n", t.Region, t.Quota.OnDemandVCPU, t.Quota.SpotVCPU)
	b.WriteString("  prices are per hour; spot is the cheapest zone right now, and nothing pins the zone\n\n")
	fmt.Fprintf(&b, "  %-14s %-5s %-9s %-8s %-7s %-8s %s\n", "TYPE", "VCPU", "GPU", "VRAM", "RAM", "DISK", "SPOT / ON DEMAND")
	inr := func(v *float64) string {
		if v == nil {
			return "    -     "
		}
		return fmt.Sprintf("INR %-6.2f", *v)
	}
	var usable []Machine
	for _, m := range t.Machines {
		if m.FitsSpot || m.FitsOnDemand {
			usable = append(usable, m)
		}
	}
	rows := usable
	if all {
		rows = t.Machines
	}
	configured := ""
	if t.Configured != nil {
		configured = *t.Configured
	}
	for _, m := range rows {
		note := ""
		switch {
		case !m.FitsSpot && !m.FitsOnDemand:
			note = fmt.Sprintf("  (no quota covers %d vCPU)", m.VCPU)
		case spotOn && !m.FitsSpot:
			note = "  (spot quota does not cover it)"
		case !spotOn && !m.FitsOnDemand:
			note = "  (on-demand quota does not cover it)"
		}
		star := " "
		if m.Type == configured {
			star = "*"
		}
		gpu, vram, disk := "-", "-", "none"
		if m.GPU != nil {
			gpu = *m.GPU
		}
		if m.VRAMGiB != nil && *m.VRAMGiB != 0 {
			vram = fmt.Sprintf("%g GB", *m.VRAMGiB)
		}
		if m.StoreGB != nil && *m.StoreGB != 0 {
			disk = fmt.Sprintf("%d GB", *m.StoreGB)
		}
		fmt.Fprintf(&b, "  %s%-13s %-5d %-9s %-8s %-7s %-8s %s/ %s%s\n", star, m.Type, m.VCPU, gpu, vram,
			fmt.Sprintf("%g GB", m.RAMGiB), disk, inr(m.INRHourSpot), inr(m.INRHourOnDemand), note)
	}
	if rest := len(t.Machines) - len(usable); rest > 0 && !all {
		fmt.Fprintf(&b, "\n  %d larger shapes exist here that no quota covers: cg machines --all\n", rest)
	}
	b.WriteString("\n  * is the one in use. Change it with: cg config set GAME_INSTANCE_TYPE <type>\n")
	b.WriteString("  a type with no spot price has no spot market in this region\n")
	return b.String()
}

// JSON is `cg machines --json`.
func JSON(t Table) ([]byte, error) { return json.Marshal(t) }

var regionShape = regexp.MustCompile(`^[a-z]{2}(-[a-z]+)+-[0-9]$`)

// IsRegion is whether an argument names a region. An explicit region used to be
// swallowed as if it were the --all flag, so `cg machines ap-south-1 --all`
// reported the CURRENT region and dropped --all.
func IsRegion(s string) bool { return regionShape.MatchString(s) }
