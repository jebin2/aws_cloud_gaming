// Package inventory is everything of cg's in this AWS account that a disconnect
// would delete, read live, with what each bills a month. An unknown price is
// null, never 0; "error" says AWS could not be asked, and then nothing else in
// it can be trusted.
package inventory

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"sync"

	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

// Machine is a box in some region.
type Machine struct{ ID, State, Type string }

// Cloud is the part of AWS the inventory asks beyond S3 and storage; the real
// one is in aws.go.
type Cloud interface {
	Account(ctx context.Context) (string, error)
	Regions(ctx context.Context) ([]string, error)
	// Machines are the boxes cg launched in a region, in any state that still
	// bills or can come back.
	Machines(ctx context.Context, region string) ([]Machine, error)
	// Watchdog says whether the function is in the region. The watchdog is per
	// region too (its role is global, and shared): one a region move left behind
	// kept that role in use, and so in the account.
	Watchdog(ctx context.Context, region string) bool
	Role(ctx context.Context) bool
	Budget(ctx context.Context, account string) bool
	// Settings are cg's names in SSM in a region: the watchdog's marks and each
	// game's keep timer - free, but cg's.
	Settings(ctx context.Context, region string) []string
}

// Inventory reads one rig.
type Inventory struct {
	Cloud  Cloud
	Lib    library.Library
	Params library.Params
	Prices library.Prices
	Scan   func(ctx context.Context, regions []string) storage.Everywhere
	Rates  pricing.Rates
	Here   string
	Expiry int
}

// Item is one thing that exists.
type Item struct {
	Kind     string        `json:"kind"`
	Label    string        `json:"label"`
	ID       string        `json:"id,omitempty"`
	Region   string        `json:"region,omitempty"`
	Bucket   string        `json:"bucket,omitempty"`
	Games    *int          `json:"games,omitempty"`
	Regions  []string      `json:"regions,omitempty"`
	Detail   string        `json:"detail"`
	USDMonth *float64      `json:"usd_month"`
	Bills    bool          `json:"bills"`
	Hourly   *bool         `json:"hourly,omitempty"`
	Names    []SettingName `json:"names,omitempty"`
}

// SettingName is one SSM parameter.
type SettingName struct {
	Region string `json:"region"`
	Name   string `json:"name"`
}

// Result is `cg aws inventory --json`.
type Result struct {
	Error     *string  `json:"error"`
	Region    string   `json:"region"`
	Items     []Item   `json:"items"`
	Hourly    bool     `json:"hourly"`
	USDMonth  *float64 `json:"usd_month"`
	INRPerUSD *float64 `json:"inr_per_usd"`
}

const gib = 1073741824.0

func month(gb float64, rate *float64) *float64 {
	if rate == nil {
		return nil
	}
	v := math.Round(gb**rate*100) / 100
	return &v
}

func zero() *float64 { v := 0.0; return &v }

// Read takes the inventory. Listing is free.
func (inv Inventory) Read(ctx context.Context) Result {
	res := Result{Region: inv.Here, Items: []Item{}, INRPerUSD: inv.Rates.INRPerUSD}
	acct, err := inv.Cloud.Account(ctx)
	if err != nil || acct == "" {
		msg := "AWS could not be asked what is there"
		res.Error = &msg
		return res
	}
	var errs []string
	regions, err := inv.Cloud.Regions(ctx)
	if err != nil || len(regions) == 0 {
		regions = []string{inv.Here}
	}
	sort.Strings(regions)

	// Machines cg launched, in every region, not only the one set here: a laptop
	// whose settings say one region does not see a machine another launched in
	// the next, and that one bills just the same.
	type perRegion struct {
		machines []Machine
		merr     error
		wd       bool
	}
	got := make([]perRegion, len(regions))
	var wg sync.WaitGroup
	for i, r := range regions {
		wg.Add(1)
		go func(i int, r string) {
			defer wg.Done()
			got[i].machines, got[i].merr = inv.Cloud.Machines(ctx, r)
			got[i].wd = inv.Cloud.Watchdog(ctx, r)
		}(i, r)
	}
	// The saved games cg uses, and every other region's.
	var el library.Elsewhere
	var st storage.Everywhere
	wg.Add(2)
	go func() { defer wg.Done(); el = inv.Lib.ReadElsewhere(ctx, inv.Params, inv.Prices, inv.Expiry) }()
	go func() { defer wg.Done(); st = inv.Scan(ctx, regions) }()
	wg.Wait()

	var watchdogs []string
	for i, r := range regions {
		if got[i].wd {
			watchdogs = append(watchdogs, r)
		}
		if got[i].merr != nil {
			if r == inv.Here {
				errs = append(errs, "machines")
			}
			continue
		}
		for _, m := range got[i].machines {
			where := ""
			if r != inv.Here {
				where = " in " + r
			}
			hourly := m.State == "pending" || m.State == "running"
			res.Items = append(res.Items, Item{Kind: "machine", Label: "Machine", ID: m.ID, Region: r,
				Detail: fmt.Sprintf("%s, %s%s", m.Type, m.State, where), Bills: true, Hourly: &hourly})
		}
	}

	if b, ok := inv.Lib.BucketName(); ok {
		region := inv.Here
		if loc, err := inv.Lib.S3.Location(ctx, b); err == nil && loc != "" {
			region = loc
		}
		if objs, err := inv.Lib.S3.List(ctx, b, region, ""); err == nil {
			var size int64
			login := false
			for _, o := range objs {
				size += o.Size
				login = login || strings.HasPrefix(o.Key, "steam/account/")
			}
			apps, _ := inv.Lib.Index(ctx, b, region)
			n := len(apps)
			ls := ""
			if login {
				ls = " and the saved Steam login"
			}
			plural := "s"
			if n == 1 {
				plural = ""
			}
			res.Items = append(res.Items, Item{Kind: "games", Label: "Saved games", Region: region, Bucket: b, Games: &n,
				Detail: fmt.Sprintf("%d game%s, %.1f GB%s", n, plural, float64(size)/gib, ls), USDMonth: month(float64(size)/gib, inv.Rates.S3GBMonth), Bills: true})
		}
	}
	if el.Error != nil || el.Places == nil {
		errs = append(errs, "elsewhere")
	} else {
		for _, p := range *el.Places {
			if p.Error != nil {
				errs = append(errs, "elsewhere")
				continue
			}
			n := len(p.Games)
			plural := "s"
			if n == 1 {
				plural = ""
			}
			login := ""
			if p.Login {
				login = " and a saved Steam login"
			}
			bytes := int64(0)
			if p.Bytes != nil {
				bytes = *p.Bytes
			}
			region := ""
			if p.Region != nil {
				region = *p.Region
			}
			res.Items = append(res.Items, Item{Kind: "games", Label: "Saved games elsewhere", Region: region, Bucket: p.Bucket, Games: &n,
				Detail: fmt.Sprintf("%d game%s, %.1f GB in %s%s", n, plural, float64(bytes)/gib, region, login), USDMonth: p.USDMonth, Bills: true})
		}
	}

	// Disks, disk images and snapshots left over, which bill by the GB with
	// nothing attached - cg's only, and in every region: a region move left them
	// where only the current one was looked at.
	if len(st.Failed) > 0 {
		errs = append(errs, "volumes")
	} else {
		where := func(regs map[string]bool) string {
			var rs []string
			for r := range regs {
				if r != inv.Here {
					rs = append(rs, r)
				}
			}
			sort.Strings(rs)
			if len(rs) == 0 {
				return ""
			}
			return " - in " + strings.Join(rs, ", ")
		}
		var vols, imgs, snaps int
		var vgb, igb, sgb float64
		vr, ir, sr := map[string]bool{}, map[string]bool{}, map[string]bool{}
		for _, f := range st.Found {
			for _, v := range f.Volumes {
				vols++
				vgb += v.GB
				vr[f.Region] = true
			}
			for _, im := range f.Images {
				imgs++
				for _, s := range im.Snapshots {
					igb += s.GB
				}
				ir[f.Region] = true
			}
			for _, s := range f.Snapshots {
				snaps++
				sgb += s.GB
				sr[f.Region] = true
			}
		}
		if vols > 0 {
			res.Items = append(res.Items, Item{Kind: "disks", Label: "Leftover disks", Detail: fmt.Sprintf("%d, %d GB%s", vols, int(vgb), where(vr)),
				USDMonth: month(vgb, inv.Rates.EBSGBMonth), Bills: true})
		}
		if imgs > 0 {
			res.Items = append(res.Items, Item{Kind: "images", Label: "Disk images", Detail: fmt.Sprintf("%d, with their snapshots%s", imgs, where(ir)),
				USDMonth: month(igb, inv.Rates.SnapshotGBMonth), Bills: true})
		}
		if snaps > 0 {
			res.Items = append(res.Items, Item{Kind: "snapshots", Label: "Disk snapshots", Detail: fmt.Sprintf("%d, %d GB%s", snaps, int(sgb), where(sr)),
				USDMonth: month(sgb, inv.Rates.SnapshotGBMonth), Bills: true})
		}
	}

	if inv.Cloud.Role(ctx) || len(watchdogs) > 0 {
		detail := "function, schedule, role, logs (the role)"
		if len(watchdogs) > 0 {
			detail = "function, schedule, role, logs in " + strings.Join(watchdogs, ", ")
		}
		res.Items = append(res.Items, Item{Kind: "watchdog", Label: "Cloud watchdog", Regions: watchdogs, Detail: detail, USDMonth: zero()})
	}
	if inv.Cloud.Budget(ctx, acct) {
		res.Items = append(res.Items, Item{Kind: "budget", Label: "Budget alert", USDMonth: zero()})
	}

	// Its settings in SSM: in this region and every region that has saved games.
	setRegions := map[string]bool{inv.Here: true}
	if el.Places != nil {
		for _, p := range *el.Places {
			if p.Region != nil && *p.Region != "" {
				setRegions[*p.Region] = true
			}
		}
	}
	var srs []string
	for r := range setRegions {
		srs = append(srs, r)
	}
	sort.Strings(srs)
	var names []SettingName
	for _, r := range srs {
		for _, n := range inv.Cloud.Settings(ctx, r) {
			names = append(names, SettingName{r, n})
		}
	}
	if len(names) > 0 {
		plural := "s"
		if len(names) == 1 {
			plural = ""
		}
		res.Items = append(res.Items, Item{Kind: "settings", Label: "Game timers", Detail: fmt.Sprintf("%d setting%s in SSM", len(names), plural),
			USDMonth: zero(), Names: names})
	}

	// The total is unknown if any one of its parts is.
	var total float64
	known := 0
	for _, it := range res.Items {
		if it.USDMonth != nil {
			total += *it.USDMonth
			known++
		}
		if it.Hourly != nil && *it.Hourly {
			res.Hourly = true
		}
	}
	if known == len(res.Items) {
		v := math.Round(total*100) / 100
		res.USDMonth = &v
	}
	if len(errs) > 0 {
		set := map[string]bool{}
		var uniq []string
		for _, e := range errs {
			if !set[e] {
				set[e] = true
				uniq = append(uniq, e)
			}
		}
		sort.Strings(uniq)
		msg := "AWS could not be asked: " + strings.Join(uniq, ", ")
		res.Error = &msg
	}
	return res
}

// Show is the plan for a person.
func Show(r Result) string {
	var b strings.Builder
	if r.Error != nil {
		fmt.Fprintf(&b, "  %s\n", *r.Error)
	}
	for _, i := range r.Items {
		fmt.Fprintf(&b, "  %-22s %s\n", i.Label, i.Detail)
	}
	if len(r.Items) == 0 {
		b.WriteString("  nothing of cg is left in AWS\n")
	}
	return b.String()
}
