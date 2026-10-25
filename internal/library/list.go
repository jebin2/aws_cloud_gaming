package library

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/format"
)

// Disk is the game disk the NEXT build gets: the configured type's, measured
// once one has run, less the space kept free for Steam.
type Disk struct {
	Type      string
	GB        *int
	Measured  bool
	ReserveGB *int
}

// Listing is `cg library list --json`: the index and the orphan scan, as data.
// When the index could not be read it is still data - a program reading this
// must be able to tell the difference between "no games" and "I could not look".
type Listing struct {
	Bucket        *string  `json:"bucket"`
	Error         string   `json:"error,omitempty"`
	Games         *[]Game  `json:"games"`
	TotalBytes    *int64   `json:"total_bytes"`
	USDMonth      *float64 `json:"usd_month"`
	OrphanBytes   *int64   `json:"orphan_bytes"`
	OrphanUSD     *float64 `json:"orphan_usd_month"`
	Login         *Login   `json:"login"`
	DiskType      *string  `json:"disk_type"`
	DiskGB        *int     `json:"disk_gb"`
	DiskMeasured  *bool    `json:"disk_measured"`
	ReserveGB     *int     `json:"reserve_gb"`
	SelectableGB  *int     `json:"selectable_gb"`
	USDPerGBMonth *float64 `json:"usd_per_gb_month"`
	Region        *string  `json:"region"`
	INRPerUSD     *float64 `json:"inr_per_usd"`
	ExpiryDays    *int     `json:"expiry_days"`
	LastSeen      *string  `json:"last_seen"`
	MarksRead     *bool    `json:"marks_read"`
}

// MarshalJSON: when the index could not be read the answer is the error and what
// is known of the bucket - games, total, price and login are null, which is not
// the same as none.
func (l Listing) MarshalJSON() ([]byte, error) {
	type plain Listing
	if l.Error != "" {
		return json.Marshal(map[string]any{"bucket": l.Bucket, "error": l.Error, "games": nil,
			"total_bytes": nil, "usd_month": nil, "login": nil})
	}
	return json.Marshal(plain(l))
}

// List reads the archive in use.
func (l Library) List(ctx context.Context, p Params, disk Disk, expiryDays int) Listing {
	b, ok := l.BucketName()
	if !ok {
		return Listing{Error: "could not work out the archive bucket - AWS did not answer"}
	}
	region := l.regionOf(ctx, b)
	apps, err := l.Index(ctx, b, region)
	bp := b
	if err != nil {
		return Listing{Bucket: &bp, Error: err.Error()}
	}
	objs, _ := l.S3.List(ctx, b, region, "steam/steamapps/")
	marks := ReadMarks(ctx, p, l.Host)
	login := l.AccountAt(ctx, b, region, nil)
	gs := games(apps, b, marks, l.S3USD)
	var total int64
	for _, g := range gs {
		total += g.Bytes
	}
	out := Listing{Bucket: &bp, Games: &gs, TotalBytes: &total, USDMonth: monthly(total, l.S3USD), Login: &login}
	var ob int64
	for _, o := range Orphans(objs, apps) {
		ob += o.Bytes
	}
	if ob > 0 {
		out.OrphanBytes, out.OrphanUSD = &ob, monthly(ob, l.S3USD)
	}
	if disk.Type != "" {
		t := disk.Type
		out.DiskType = &t
	}
	out.DiskGB, out.ReserveGB = disk.GB, disk.ReserveGB
	m := disk.Measured
	out.DiskMeasured = &m
	if disk.GB != nil {
		sel := max(0, *disk.GB-derefInt(disk.ReserveGB))
		out.SelectableGB = &sel
	}
	out.USDPerGBMonth, out.Region, out.INRPerUSD = l.S3USD, &l.Region, l.INR
	out.ExpiryDays = &expiryDays
	out.MarksRead = ptr(marks != nil)
	if marks != nil {
		out.LastSeen = marks.LastSeen
	}
	return out
}

func derefInt(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}

func (l Library) regionOf(ctx context.Context, b string) string {
	if r, err := l.S3.Location(ctx, b); err == nil && r != "" {
		return r
	}
	return l.Region
}

// Human is `cg library list` for a person: every sentence is said only about
// what was actually established. Before anything is said about what is IN the
// archive, it is established that it can be read at all.
func (l Library) Human(ctx context.Context, p Params, disk Disk) (text string, ok bool) {
	b, bok := l.BucketName()
	if !bok {
		return "  could not work out the archive bucket - AWS did not answer\n", false
	}
	region := l.regionOf(ctx, b)
	apps, err := l.Index(ctx, b, region)
	if err != nil {
		return fmt.Sprintf("cannot read the archive: %s\n  s3://%s was not readable, so nothing here is known -\n  this is NOT the same as the archive being empty.\n", err, b), false
	}
	var w strings.Builder
	objs, _ := l.S3.List(ctx, b, region, "steam/steamapps/")
	// An index.json is written only by the per-app push. A box built before that
	// mirrors fine but writes no index, so "the archive is empty" would be a lie
	// told about the thing that was looked for rather than the thing that is there.
	if len(objs) > 0 {
		if _, herr := l.S3.Head(ctx, b, region, "steam/index.json"); herr != nil {
			var sz int64
			for _, o := range objs {
				sz += o.Size
			}
			fmt.Fprintf(&w, "  archive holds %d objects, %s\n", len(objs), format.IEC(sz))
			w.WriteString("  but no per-game index yet - this box predates per-game archiving.\n")
			w.WriteString("  The next push from a rebuilt box writes one and this lists per game.\n")
			seen := map[string]bool{}
			var names []string
			for _, o := range objs {
				parts := strings.Split(o.Key, "/")
				if len(parts) > 4 && parts[2] == "common" && !seen[parts[3]] {
					seen[parts[3]] = true
					names = append(names, parts[3])
				}
			}
			sort.Strings(names)
			for _, n := range names {
				fmt.Fprintf(&w, "  - %s\n", n)
			}
			return w.String(), true
		}
	}
	if len(apps) == 0 {
		w.WriteString("  the archive is empty\n")
	} else {
		fmt.Fprintf(&w, "  %-10s %-32s %9s  %s\n", "APPID", "GAME", "SIZE", "ARCHIVED")
		var tot int64
		for _, a := range apps {
			tot += a.Bytes
			name := a.Name
			if name == "" {
				name = "?"
			}
			pushed := a.Pushed
			if pushed == "" {
				pushed = "?"
			}
			if len(pushed) > 16 {
				pushed = pushed[:16]
			}
			fmt.Fprintf(&w, "  %-10s %-32s %6.1f GB  %s\n", IDString(a.AppID), clip(name, 32), float64(a.Bytes)/gib, strings.Replace(pushed, "T", " ", 1))
		}
		g := float64(tot) / gib
		cost := ""
		if l.S3USD != nil {
			cost = fmt.Sprintf("   $%.2f/month", g**l.S3USD)
			if l.INR != nil {
				cost += fmt.Sprintf(" (INR %.0f)", g**l.S3USD**l.INR)
			}
		}
		fmt.Fprintf(&w, "  %-10s %-32s %6.1f GB%s\n", "", "total", g, cost)
		w.WriteString("\n")
		t := disk.Type
		if t == "" {
			t = "the machine"
		}
		if disk.GB != nil {
			sel := max(0, *disk.GB-derefInt(disk.ReserveGB))
			note := ""
			if !disk.Measured {
				note = "; AWS figure, not yet measured"
			}
			fmt.Fprintf(&w, "  %d GB fits on a %s at once (%d GB selectable, %d GB kept free%s)\n", *disk.GB, t, sel, derefInt(disk.ReserveGB), note)
			if g > float64(sel) {
				w.WriteString("  the archive is larger than that - cg init asks which to restore\n")
			}
		} else {
			fmt.Fprintf(&w, "  how much a %s holds could not be read - the box restores what fits\n", t)
		}
	}
	if or := Orphans(objs, apps); len(or) > 0 {
		var t int64
		for _, o := range or {
			t += o.Bytes
		}
		if t > 0 && l.S3USD != nil {
			fmt.Fprintf(&w, "\n  plus %.1f GB of ORPHANED objects from an unfinished push\n  costing $%.2f/month and unusable - remove them: cg library clean\n",
				float64(t)/gib, float64(t)/gib**l.S3USD)
		}
	}
	return w.String(), true
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
