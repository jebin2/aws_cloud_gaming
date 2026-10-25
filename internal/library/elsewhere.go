package library

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
)

// Place is a bucket of this rig's that is not the one in use.
type Place struct {
	Bucket      string   `json:"bucket"`
	Region      *string  `json:"region"`
	Error       *string  `json:"error"`
	Bytes       *int64   `json:"bytes"`
	GamesBytes  *int64   `json:"games_bytes"`
	USDMonth    *float64 `json:"usd_month"`
	XRegionUSD  *float64 `json:"xregion_usd_gb"` // what it costs to bring a game from here to where the machine is built
	Games       []Game   `json:"games"`
	Login       bool     `json:"login"`
	LoginDetail *Login   `json:"login_detail"`
}

// Elsewhere is `cg library elsewhere --json`: games saved somewhere cg is not
// looking.
//
// Every other read uses ONE bucket, the one .env names. A region move made a new
// one and left 162.8 GB of a game in the old region, billing with nothing
// pointing at it: Library said no games, a build offered none. AWS lists every
// bucket in the account in one call; cg keeps the ones it made for this account
// and host - never anything merely named like them. Region lookups are free;
// reading inside is a handful of LIST requests.
type Elsewhere struct {
	Error      *string  `json:"error"`
	Places     *[]Place `json:"places"`
	Region     string   `json:"region,omitempty"`
	INRPerUSD  *float64 `json:"inr_per_usd,omitempty"`
	ExpiryDays *int     `json:"expiry_days,omitempty"`
	LastSeen   *string  `json:"last_seen,omitempty"`
	MarksRead  *bool    `json:"marks_read,omitempty"`
	Bytes      *int64   `json:"bytes,omitempty"`
	USDMonth   *float64 `json:"usd_month,omitempty"`
}

// Prices says what a bucket costs in the region it is in: that region's own
// prices, not this one's.
type Prices func(ctx context.Context, region, key string) *float64

// ReadElsewhere scans the account.
func (l Library) ReadElsewhere(ctx context.Context, p Params, prices Prices, expiryDays int) Elsewhere {
	cur, _ := l.BucketName()
	names, err := l.S3.Buckets(ctx)
	if l.Account == "" || err != nil {
		msg := "could not list your buckets - AWS did not answer"
		return Elsewhere{Error: &msg}
	}
	marks := ReadMarks(ctx, p, l.Host)
	places := []Place{}
	for _, b := range names {
		if !strings.HasPrefix(b, "cg-library-") || b == cur {
			continue
		}
		r, err := l.S3.Location(ctx, b)
		if err != nil || r == "" {
			continue
		}
		if !Ours(b, r, l.Account, l.Host) {
			continue
		}
		places = append(places, l.place(ctx, b, r, marks, prices))
	}
	out := Elsewhere{Places: &places, Region: l.Region, INRPerUSD: l.INR, ExpiryDays: &expiryDays, MarksRead: ptr(marks != nil)}
	if marks != nil {
		out.LastSeen = marks.LastSeen
	}
	var total int64
	var usd float64
	unknown := false
	for _, pl := range places {
		if pl.Bytes == nil {
			continue
		}
		total += *pl.Bytes
		if pl.USDMonth == nil {
			unknown = true
		} else {
			usd += *pl.USDMonth
		}
	}
	out.Bytes = &total
	if !unknown {
		v := math.Round(usd*100) / 100
		out.USDMonth = &v
	}
	return out
}

func (l Library) place(ctx context.Context, b, region string, marks *Marks, prices Prices) Place {
	rp := region
	pl := Place{Bucket: b, Region: &rp, Games: []Game{}}
	s3 := prices(ctx, region, "CG_S3_USD_GB_MONTH")
	pl.XRegionUSD = prices(ctx, region, "CG_XREGION_USD_GB")
	// An empty prefix lists nothing and says nothing: that is an empty bucket.
	// Anything said as an error is a listing that failed, which is not.
	objs, err := l.S3.List(ctx, b, region, "steam/")
	if err != nil {
		msg := Reason(err, b)
		pl.Error = &msg
		return pl
	}
	var gamesB, loginB, otherB int64
	dirs := map[string]int64{}
	var dirOrder []string
	for _, o := range objs {
		switch {
		case strings.HasPrefix(o.Key, "steam/steamapps/"):
			gamesB += o.Size
			parts := strings.Split(o.Key, "/")
			if len(parts) > 4 && parts[2] == "common" {
				if _, seen := dirs[parts[3]]; !seen {
					dirOrder = append(dirOrder, parts[3])
				}
				dirs[parts[3]] += o.Size
			}
		case strings.HasPrefix(o.Key, "steam/account/"):
			loginB += o.Size
		default:
			otherB += o.Size
		}
	}
	apps, _ := l.Index(ctx, b, region)
	// The index names the games; without one, the folders they were saved in do.
	if len(apps) > 0 {
		for _, a := range apps {
			name := a.Name
			if name == "" {
				name = a.InstallDir
			}
			g := Game{AppID: nilIfEmpty(IDString(a.AppID)), Name: name, InstallDir: a.InstallDir, Bytes: a.Bytes, Pushed: a.Pushed, USDMonth: monthly(a.Bytes, s3)}
			if marks != nil {
				if v, ok := marks.Kept[b+"/"+IDString(a.AppID)]; ok {
					g.Kept = &v
				}
			}
			pl.Games = append(pl.Games, g)
		}
	} else {
		for _, d := range dirOrder {
			pl.Games = append(pl.Games, Game{Name: d, InstallDir: d, Bytes: dirs[d], USDMonth: monthly(dirs[d], s3)})
		}
	}
	sort.SliceStable(pl.Games, func(i, j int) bool { return pl.Games[i].Bytes > pl.Games[j].Bytes })
	total := gamesB + loginB + otherB
	pl.Bytes, pl.GamesBytes, pl.USDMonth = &total, &gamesB, monthly(total, s3)
	pl.Login = loginB > 0
	if pl.Login {
		d := l.AccountAt(ctx, b, region, nil)
		pl.LoginDetail = &d
	}
	return pl
}

// ShowElsewhere is the human view.
func ShowElsewhere(d Elsewhere, inr *float64) (string, bool) {
	if d.Error != nil {
		return "  " + *d.Error + "\n", false
	}
	var b strings.Builder
	var shown []Place
	for _, p := range *d.Places {
		if (p.Bytes != nil && *p.Bytes != 0) || p.Error != nil {
			shown = append(shown, p)
		}
	}
	if len(shown) == 0 {
		return "  nothing saved anywhere else - every game is in the archive cg uses\n", true
	}
	for _, p := range shown {
		region := "?"
		if p.Region != nil {
			region = *p.Region
		}
		if p.Error != nil {
			fmt.Fprintf(&b, "  %-14s could not be read: %s\n", region, *p.Error)
			continue
		}
		cost := ""
		if inr != nil && p.USDMonth != nil {
			cost = fmt.Sprintf("   INR %.0f a month", *p.USDMonth**inr)
		}
		fmt.Fprintf(&b, "  %-14s %6.1f GB%s   s3://%s\n", region, float64(*p.Bytes)/gib, cost, p.Bucket)
		for _, g := range p.Games {
			fmt.Fprintf(&b, "      %-10s %s\n", IDString(g.AppID), g.Name)
		}
		if p.Login {
			b.WriteString("      (and a Steam login)\n")
		}
	}
	b.WriteString("\n  cg does not use these. Bring one here: cg library move <appid> --from <bucket>\n")
	b.WriteString("  or stop paying for it:                 cg library forget <appid> --from <bucket>\n")
	return b.String(), true
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
