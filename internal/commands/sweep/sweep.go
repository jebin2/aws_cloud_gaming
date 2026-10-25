// Package sweep is `cg sweep`: which REGION will rent you a GPU - the question
// `cg machines` cannot answer. machines asks "what can this region rent me",
// which is the right question only once the region is settled. It is not: a week
// was spent retrying g6.xlarge in ap-south-2 on the assumption that spot
// capacity comes back, while AWS had an API all along that says it will not.
// get-spot-placement-scores scores a (region, type) pair 1-10 for the odds of
// actually getting capacity.
//
// So this sweeps every region AWS has and reports the three things that decide
// whether one is usable at all:
//
//	latency   measured, not assumed - a streamed game is unplayable past
//	          NVIDIA's stated 80ms whatever the GPU costs
//	capacity  the placement score, the only forward-looking number AWS publishes
//	quota     0 is the default for G instances in a region you have never asked
//	          about, and it reads as "unavailable" exactly like a shortage does,
//	          so the two must be told apart
//
// Every call is free. Nothing here launches, reserves, enables or changes
// anything.
package sweep

import (
	"context"
	"math"
	"sort"
	"strings"
	"sync"

	"github.com/jebin2/aws_cloud_gaming/internal/commands/machines"
)

// Region is a region and whether this account may use it.
type Region struct {
	Name  string
	OptIn string // opt-in-not-required | opted-in | not-opted-in
}

// Enabled: a region you have not opted into is still a candidate, it just costs
// an opt-in to reach, and hiding it would hide the only region with capacity.
func (r Region) Enabled() bool { return r.OptIn == "opt-in-not-required" || r.OptIn == "opted-in" }

// Spec is a shape's description, which does not vary by region.
type Spec struct {
	VCPU    int
	RAMGiB  float64
	GPU     *string
	VRAMGiB *float64
	StoreGB *int64
}

// Backend is everything the sweep asks of the world, so the sweep itself is a
// plain function of the answers.
type Backend interface {
	ListRegions(ctx context.Context) ([]Region, error)
	GPUTypes(ctx context.Context, region string) ([]machines.GPU, error)
	// PlacementWorks is whether get-spot-placement-scores exists in the region at all.
	PlacementWorks(ctx context.Context, from, instanceType string) bool
	// RTT is the median connect time in ms to the region's EC2 endpoint over the
	// samples, and false when no probe answered.
	RTT(ctx context.Context, region string, samples int) (float64, bool)
	Specs(ctx context.Context, from string, types []string) (map[string]Spec, error)
	Scores(ctx context.Context, from, instanceType string, regions []string) (map[string]int, error)
	City(ctx context.Context, from, region string) string
	Quota(ctx context.Context, region string) (ondemand, spot int, ok bool)
	Offers(ctx context.Context, region string, types []string) ([]string, error)
	// Spot is each type's cheapest and dearest current price in the region.
	Spot(ctx context.Context, region string, types []string) (lo, hi map[string]float64, err error)
	OnDemand(ctx context.Context, region, instanceType string) *float64
}

// Options are the knobs; the environment sets them (CG_SWEEP_*).
type Options struct {
	Configured string   // the region in use
	From       string   // CG_SWEEP_FROM: where the cross-region calls are made from
	Types      []string // CG_SWEEP_TYPES: replaces the shortlist
	Fallbacks  []string // CG_SWEEP_FALLBACKS
	MaxMS      float64  // CG_SWEEP_MAX_MS: NVIDIA's own requirement for GeForce NOW
	Samples    int      // CG_SWEEP_SAMPLES
	Parallel   int      // CG_SWEEP_PAR
	INRPerUSD  *float64
}

// Defaults for the options.
func (o *Options) defaults() {
	if o.MaxMS == 0 {
		o.MaxMS = 80
	}
	if o.Samples == 0 {
		o.Samples = 5
	}
	if o.Parallel == 0 {
		o.Parallel = 10
	}
	if len(o.Fallbacks) == 0 {
		o.Fallbacks = []string{"us-east-1", "eu-west-1", "ap-south-1", "ap-northeast-1"}
	}
}

// Machine is one type in one region.
type Machine struct {
	Type           string   `json:"type"`
	Score          *int     `json:"score"`
	GPU            *string  `json:"gpu"`
	VRAMGiB        *float64 `json:"vram_gib"`
	RAMGiB         *float64 `json:"ram_gib"`
	VCPU           *int     `json:"vcpu"`
	StoreGB        *int64   `json:"store_gb"`
	Offered        *bool    `json:"offered"`
	USDHourSpot    *float64 `json:"usd_hour_spot"`
	USDHourSpotMax *float64 `json:"usd_hour_spot_max"`
	INRHourSpotMax *float64 `json:"inr_hour_spot_max"`
	USDHourOD      *float64 `json:"usd_hour_ondemand"`
	INRHourSpot    *float64 `json:"inr_hour_spot"`
	INRHourOD      *float64 `json:"inr_hour_ondemand"`
	FitsSpot       *bool    `json:"fits_spot"`
	FitsOnDemand   *bool    `json:"fits_ondemand"`
}

// RegionRow is one region that is near enough.
type RegionRow struct {
	Region  string   `json:"region"`
	City    *string  `json:"city"`
	OptIn   string   `json:"optin"`
	Enabled bool     `json:"enabled"`
	RTTMS   *float64 `json:"rtt_ms"`
	Quota   *struct {
		OnDemandVCPU int `json:"ondemand_vcpu"`
		SpotVCPU     int `json:"spot_vcpu"`
	} `json:"quota"`
	BestScore *int      `json:"best_score"`
	Machines  []Machine `json:"machines"`
}

// Far is a region over the latency budget.
type Far struct {
	Region string  `json:"region"`
	OptIn  string  `json:"optin"`
	RTTMS  float64 `json:"rtt_ms"`
}

// Unreachable is a region that did not answer a latency probe.
type Unreachable struct {
	Region string `json:"region"`
	OptIn  string `json:"optin"`
}

// Result is the whole sweep as one object.
type Result struct {
	MaxMS       float64       `json:"max_ms"`
	Configured  string        `json:"configured"`
	Types       []string      `json:"types"`
	INRPerUSD   *float64      `json:"inr_per_usd"`
	Measured    bool          `json:"measured"`
	Regions     []RegionRow   `json:"regions"`
	TooFar      []Far         `json:"too_far"`
	Unreachable []Unreachable `json:"unreachable"`
	Error       string        `json:"error,omitempty"`
	// Set when it is stored.
	ScannedAt  *string `json:"scanned_at,omitempty"`
	Cached     *bool   `json:"cached,omitempty"`
	AgeSeconds *int64  `json:"age_seconds,omitempty"`
}

func empty(msg string) Result {
	return Result{Error: msg, Regions: []RegionRow{}, TooFar: []Far{}, Unreachable: []Unreachable{}, Types: []string{}}
}

// From is the region the cross-region calls are MADE from. Not the configured
// one: get-spot-placement-scores does not exist in every region - ap-south-2
// answers UnsupportedOperation - so asking from "wherever the box is" returned
// nothing for every region. It is probed once, and the probe is itself a
// placement-score call for one region, which is free.
func (o Options) from(ctx context.Context, b Backend) string {
	if o.From != "" {
		return o.From
	}
	cands := append([]string{o.Configured}, o.Fallbacks...)
	for _, c := range cands {
		if c == "" {
			continue
		}
		types, _ := b.GPUTypes(ctx, c)
		if len(types) == 0 {
			continue // any machine AWS offers there will do
		}
		if b.PlacementWorks(ctx, c, types[0].Type) {
			return c
		}
	}
	// Nothing answered. The configured region, so the caller still makes a call
	// and reports a real AWS error rather than silently scoring nothing.
	if o.Configured != "" {
		return o.Configured
	}
	return "us-east-1"
}

// shortlist is the smallest of each family AWS says can game, across the region
// the machine is built in and the one the sweep asks from.
func (o Options) shortlist(ctx context.Context, b Backend, from string) []string {
	if len(o.Types) > 0 {
		return o.Types
	}
	var all []machines.GPU
	for _, r := range []string{o.Configured, from} {
		if r == "" {
			continue
		}
		g, _ := b.GPUTypes(ctx, r)
		all = append(all, g...)
	}
	return machines.Shortlist(all)
}

func parallel(n int, items []string, fn func(string)) {
	if n < 1 {
		n = 1
	}
	sem := make(chan struct{}, n)
	var wg sync.WaitGroup
	for _, it := range items {
		wg.Add(1)
		sem <- struct{}{}
		go func(it string) {
			defer wg.Done()
			defer func() { <-sem }()
			fn(it)
		}(it)
	}
	wg.Wait()
}

func money(usd *float64, inr *float64) *float64 {
	if usd == nil || inr == nil {
		return nil
	}
	v := math.Round(*usd**inr*100) / 100
	return &v
}

func round1(v float64) float64 { return math.Round(v*10) / 10 }

// Scan runs the sweep.
func Scan(ctx context.Context, b Backend, o Options) Result {
	o.defaults()
	from := o.from(ctx, b)
	types := o.shortlist(ctx, b, from)
	if len(types) == 0 {
		return empty("AWS did not say which machines it offers - check your AWS credentials")
	}
	regions, err := b.ListRegions(ctx)
	if err != nil || len(regions) == 0 {
		return empty("could not list regions - check your AWS credentials")
	}
	sort.Slice(regions, func(i, j int) bool { return regions[i].Name < regions[j].Name })
	names := make([]string, len(regions))
	optin := map[string]string{}
	for i, r := range regions {
		names[i], optin[r.Name] = r.Name, r.OptIn
	}

	// Latency first, and in parallel: it is the cheapest filter and the harshest,
	// cutting 34 regions to a handful, so everything after it asks about far fewer.
	rtt := map[string]float64{}
	var mu sync.Mutex
	probe := func(samples int) func(string) {
		return func(r string) {
			if ms, ok := b.RTT(ctx, r, samples); ok {
				mu.Lock()
				rtt[r] = ms
				mu.Unlock()
			}
		}
	}
	parallel(o.Parallel, names, probe(o.Samples))
	// Did ANY probe answer? This is what decides whether a latency budget can be
	// applied: behind a firewall that blocks 443 outbound every probe fails, and
	// filtering on that would exclude every region and report that nowhere on
	// earth can stream.
	measured := len(rtt) > 0

	// The parallel pass is a coarse filter and nothing more: concurrent
	// handshakes share one uplink and inflate each other, so a region is kept if
	// it is within half again the budget, then measured again quietly.
	var near []string
	slack := o.MaxMS * 1.5
	for _, r := range names {
		ms, ok := rtt[r]
		switch {
		case !ok:
			if !measured {
				near = append(near, r)
			}
		case ms <= slack:
			near = append(near, r)
		}
	}
	if measured && len(near) > 0 {
		parallel(2, near, probe(o.Samples*3))
		var keep []string
		for _, r := range near {
			if ms, ok := rtt[r]; ok && ms <= o.MaxMS {
				keep = append(keep, r)
			}
		}
		near = keep
	}

	specs, _ := b.Specs(ctx, from, types)

	// Scores for the shortlist, one call per type rather than per region. A
	// region missing from the answer does NOT score 0: AWS returns nothing for a
	// region that does not offer the type.
	score := map[[2]string]int{}
	if len(near) > 0 {
		for _, t := range types {
			for i := 0; i < len(near); i += 10 { // the API caps the region list
				got, _ := b.Scores(ctx, from, t, near[i:min(i+10, len(near))])
				for r, s := range got {
					score[[2]string{r, t}] = s
				}
			}
		}
	}

	// Quotas, offerings and spot prices only work in a region that is enabled,
	// so their absence is "unreadable", not a zero. A 0 quota and an unreadable
	// quota lead to different actions - one is a request, the other an opt-in.
	type detail struct {
		city           *string
		quota          *[2]int
		offers         map[string]bool
		spotLo, spotHi map[string]float64
		od             map[string]float64
	}
	details := map[string]*detail{}
	var dmu sync.Mutex
	parallel(4, near, func(r string) {
		d := &detail{offers: map[string]bool{}, spotLo: map[string]float64{}, spotHi: map[string]float64{}, od: map[string]float64{}}
		if c := b.City(ctx, from, r); c != "" {
			d.city = &c
		}
		if regionOf(regions, r).Enabled() {
			if od, sp, ok := b.Quota(ctx, r); ok {
				d.quota = &[2]int{od, sp}
			} else {
				d.quota = &[2]int{0, 0} // the Bash read an unreadable quota as "0 0"
			}
			if offers, err := b.Offers(ctx, r, types); err == nil {
				for _, t := range offers {
					d.offers[t] = true
				}
			}
			if lo, hi, err := b.Spot(ctx, r, types); err == nil {
				d.spotLo, d.spotHi = lo, hi
			}
		}
		// On-demand prices come from the Price List, which answers for a region
		// whether or not it is enabled - the one number available before opting
		// in. Only types the region plausibly sells: a score or an offering.
		for _, t := range types {
			_, scored := score[[2]string{r, t}]
			if !scored && !d.offers[t] {
				continue
			}
			if p := b.OnDemand(ctx, r, t); p != nil {
				d.od[t] = *p
			}
		}
		dmu.Lock()
		details[r] = d
		dmu.Unlock()
	})

	res := Result{MaxMS: o.MaxMS, Configured: o.Configured, Types: types, INRPerUSD: o.INRPerUSD, Measured: measured,
		Regions: []RegionRow{}, TooFar: []Far{}, Unreachable: []Unreachable{}}
	nearSet := map[string]bool{}
	for _, r := range near {
		nearSet[r] = true
	}
	for _, r := range regions {
		ms, have := rtt[r.Name]
		if !have && measured {
			res.Unreachable = append(res.Unreachable, Unreachable{r.Name, r.OptIn})
			continue
		}
		if have && ms > o.MaxMS {
			res.TooFar = append(res.TooFar, Far{r.Name, r.OptIn, ms})
			continue
		}
		if !nearSet[r.Name] {
			continue
		}
		d := details[r.Name]
		row := RegionRow{Region: r.Name, City: d.city, OptIn: r.OptIn, Enabled: r.Enabled(), Machines: []Machine{}}
		if have {
			v := ms
			row.RTTMS = &v
		}
		if d.quota != nil {
			row.Quota = &struct {
				OnDemandVCPU int `json:"ondemand_vcpu"`
				SpotVCPU     int `json:"spot_vcpu"`
			}{d.quota[0], d.quota[1]}
		}
		for _, t := range types {
			sc, scored := score[[2]string{r.Name, t}]
			offered := d.offers[t]
			spLo, hasSpot := d.spotLo[t]
			odUSD, hasOD := d.od[t]
			// A type with no score, no offering and no price was never on sale here.
			if !scored && !offered && !hasOD && !hasSpot {
				continue
			}
			m := Machine{Type: t}
			if scored {
				v := sc
				m.Score = &v
			}
			if sp, ok := specs[t]; ok {
				v, ram := sp.VCPU, sp.RAMGiB
				m.GPU, m.VRAMGiB, m.RAMGiB, m.VCPU, m.StoreGB = sp.GPU, sp.VRAMGiB, &ram, &v, sp.StoreGB
			}
			if row.Enabled {
				v := offered
				m.Offered = &v
			}
			if hasSpot {
				lo, hi := spLo, d.spotHi[t]
				m.USDHourSpot, m.USDHourSpotMax = &lo, &hi
				m.INRHourSpot, m.INRHourSpotMax = money(&lo, o.INRPerUSD), money(&hi, o.INRPerUSD)
			}
			if hasOD {
				v := odUSD
				m.USDHourOD, m.INRHourOD = &v, money(&v, o.INRPerUSD)
			}
			if d.quota != nil {
				fs, fo := d.quota[1] >= 4, d.quota[0] >= 4
				m.FitsSpot, m.FitsOnDemand = &fs, &fo
			}
			row.Machines = append(row.Machines, m)
		}
		// Best first: a real score beats a cheap price, because price is what a
		// machine costs and score is whether you can have one at all.
		sort.SliceStable(row.Machines, func(i, j int) bool {
			a, c := row.Machines[i], row.Machines[j]
			if sa, sc := scoreOf(a), scoreOf(c); sa != sc {
				return sa > sc
			}
			if pa, pc := priceOf(a), priceOf(c); pa != pc {
				return pa < pc
			}
			return a.Type < c.Type
		})
		best := 0
		for _, m := range row.Machines {
			best = max(best, scoreOf(m))
		}
		if best > 0 {
			row.BestScore = &best
		}
		res.Regions = append(res.Regions, row)
	}
	// Usable first, then nearest: a region with capacity is the answer even when
	// a nearer one exists, and that is the entire finding this command exists to show.
	sort.SliceStable(res.Regions, func(i, j int) bool {
		a, c := res.Regions[i], res.Regions[j]
		if ba, bc := bestOf(a), bestOf(c); ba != bc {
			return ba > bc
		}
		return rttOf(a) < rttOf(c)
	})
	sort.SliceStable(res.TooFar, func(i, j int) bool { return res.TooFar[i].RTTMS < res.TooFar[j].RTTMS })
	return res
}

func regionOf(rs []Region, name string) Region {
	for _, r := range rs {
		if r.Name == name {
			return r
		}
	}
	return Region{Name: name}
}

func scoreOf(m Machine) int {
	if m.Score == nil {
		return 0
	}
	return *m.Score
}

func priceOf(m Machine) float64 {
	if m.INRHourOD == nil || *m.INRHourOD == 0 {
		return 1e9
	}
	return *m.INRHourOD
}

func bestOf(r RegionRow) int {
	if r.BestScore == nil {
		return 0
	}
	return *r.BestScore
}

func rttOf(r RegionRow) float64 {
	if r.RTTMS == nil {
		return 1e9
	}
	return *r.RTTMS
}

// Median is the median of the samples, the average of the two middle ones when
// there is an even number - the number a region is judged on, not a single
// probe that caught a 46ms outlier in a region whose median is 19ms.
func Median(v []float64) float64 {
	s := append([]float64{}, v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// RoundMS is the value as it is stored: one decimal.
func RoundMS(v float64) float64 { return round1(v) }

// Trim is a helper for the human view's city column.
func Trim(city string) string {
	for _, pre := range []string{"Asia Pacific (", "Europe (", "US East (", "US West (", "Canada (", "South America (", "Africa (", "Middle East (", "Israel ("} {
		if strings.HasPrefix(city, pre) {
			return strings.TrimRight(strings.TrimPrefix(city, pre), ")")
		}
	}
	return city
}
