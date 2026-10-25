package cost

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

// OtherRegions is what cg has in OTHER regions, which the report of this one
// never looked at: saved games a region move left behind, and cg's disks,
// images and snapshots - each with its monthly cost where it is known.
//
// A read that failed is said, never "nothing of cg's": the Bash treated an error
// answer from the library scan as an empty one and still printed that false
// reassurance, and read a failed region list as "none".
func OtherRegions(el library.Elsewhere, st storage.Everywhere, here string, r pricing.Rates) string {
	const gib = 1073741824.0
	cost := func(gb float64, rate *float64) string {
		if rate == nil {
			return ""
		}
		return fmt.Sprintf("  ($%.2f/mo)", gb**rate)
	}
	var out []string
	if el.Places != nil {
		for _, p := range *el.Places {
			if p.Bytes == nil && p.Error == nil {
				continue
			}
			gb := 0.0
			if p.Bytes != nil {
				gb = float64(*p.Bytes) / gib
			}
			c := ""
			if p.USDMonth != nil {
				c = fmt.Sprintf("  ($%.2f/mo)", *p.USDMonth)
			}
			region := ""
			if p.Region != nil {
				region = *p.Region
			}
			out = append(out, fmt.Sprintf("  saved games     %.1f GB in %s%s", gb, region, c))
		}
	}
	type row struct {
		label string
		id    string
		gb    float64
		reg   string
		rate  *float64
	}
	var rows []row
	for _, f := range st.Found {
		if f.Region == here {
			continue
		}
		for _, v := range f.Volumes {
			rows = append(rows, row{"disk", v.ID, v.GB, f.Region, r.EBSGBMonth})
		}
		for _, im := range f.Images {
			var gb float64
			for _, s := range im.Snapshots {
				gb += s.GB
			}
			rows = append(rows, row{"image", im.ID, gb, f.Region, r.SnapshotGBMonth})
		}
		for _, s := range f.Snapshots {
			rows = append(rows, row{"snapshot", s.ID, s.GB, f.Region, r.SnapshotGBMonth})
		}
	}
	order := map[string]int{"disk": 0, "image": 1, "snapshot": 2}
	sort.SliceStable(rows, func(i, j int) bool { return order[rows[i].label] < order[rows[j].label] })
	for _, x := range rows {
		out = append(out, fmt.Sprintf("  %-15s %s, %d GB in %s%s", x.label, x.id, int(x.gb), x.reg, cost(x.gb, x.rate)))
	}
	var b strings.Builder
	b.WriteString("other regions:\n")
	switch {
	case len(out) > 0:
		b.WriteString(strings.Join(out, "\n") + "\n  removed by: cg aws disconnect\n")
	case el.Error != nil || len(st.Failed) > 0:
		why := ""
		if len(st.Failed) > 0 {
			why = " - " + strings.Join(st.Failed, ", ")
		}
		if el.Error != nil && why == "" {
			why = " - " + *el.Error
		}
		fmt.Fprintf(&b, "  could not be read%s\n", why)
	default:
		b.WriteString("  nothing of cg's\n")
	}
	// Whatever was found, a region AWS would not answer for is still unknown.
	if len(out) > 0 && len(st.Failed) > 0 {
		fmt.Fprintf(&b, "  could not be read: %s\n", strings.Join(st.Failed, ", "))
	}
	return b.String()
}
