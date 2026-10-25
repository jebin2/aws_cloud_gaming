// Package machines is `cg machines`: what a region will actually rent you.
//
// The app needs an instance-type picker, and it must not hold a list of its
// own: every type, price and GPU name here comes from AWS, because a list typed
// into the renderer goes stale the first time a region gains a shape - and the
// whole reason this exists is a launch that failed for capacity on the only
// type the rig had ever used. Every call is free; nothing launches, changes or
// reserves anything.
package machines

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"

	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// EC2API is the part of EC2 the table reads; the SDK client satisfies it.
type EC2API interface {
	DescribeInstanceTypes(context.Context, *ec2.DescribeInstanceTypesInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error)
	DescribeInstanceTypeOfferings(context.Context, *ec2.DescribeInstanceTypeOfferingsInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypeOfferingsOutput, error)
	DescribeSpotPriceHistory(context.Context, *ec2.DescribeSpotPriceHistoryInput, ...func(*ec2.Options)) (*ec2.DescribeSpotPriceHistoryOutput, error)
}

// QuotasAPI is the vCPU quota.
type QuotasAPI interface {
	GetServiceQuota(context.Context, *servicequotas.GetServiceQuotaInput, ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error)
}

// Reader reads one region.
type Reader struct {
	EC2      EC2API
	Quotas   QuotasAPI
	Products pricing.Products // the Price List, for on-demand
	Region   string
	CacheDir string // XDG_CACHE_HOME/cg
	Now      func() time.Time
	// Override replaces the GPU type list with these (the tests, or a
	// deliberately short list).
	Override []string
}

// GPU is a type that can run this rig and how many vCPUs it has.
type GPU struct {
	Type  string
	VCPUs int
}

func (r *Reader) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// GPUTypes is every machine AWS offers in the region that can run this rig: an
// NVIDIA GPU made for graphics work, a whole one, on x86. Each of those is AWS's
// own description of the type - Manufacturer, Workloads, GpuPartitionSize - and
// not a list of names: the list this replaced (g4dn g5 g6 g6e gr6) had already
// missed g7e, AWS's newest.
//
//	graphics  compute-only GPUs (the p family) list no graphics workload
//	whole     a fractional GPU needs NVIDIA's vGPU driver, which the build
//	          does not install
//	x86       Steam and Proton; the Graviton g5g is ARM
//
// Kept for a day per region, so the table and the sweep do not ask twice.
func (r *Reader) GPUTypes(ctx context.Context) ([]GPU, error) {
	if len(r.Override) > 0 {
		var out []GPU
		for _, t := range r.Override {
			out = append(out, GPU{Type: t})
		}
		return out, nil
	}
	cache := filepath.Join(r.CacheDir, "gpu-types-"+r.Region)
	if st, err := os.Stat(cache); err == nil && r.now().Sub(st.ModTime()) < 24*time.Hour {
		if g := readCache(cache); len(g) > 0 {
			return g, nil
		}
	}
	got, err := r.fetchGPUTypes(ctx)
	if err != nil || len(got) == 0 {
		// A stale answer beats none.
		if g := readCache(cache); len(g) > 0 {
			return g, nil
		}
		return nil, err
	}
	var b strings.Builder
	for _, g := range got {
		fmt.Fprintf(&b, "%s %d\n", g.Type, g.VCPUs)
	}
	if os.MkdirAll(r.CacheDir, 0o755) == nil {
		_ = os.WriteFile(cache, []byte(b.String()), 0o644)
	}
	return got, nil
}

func readCache(path string) []GPU {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []GPU
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		p := strings.Fields(sc.Text())
		if len(p) >= 1 {
			n := 0
			if len(p) > 1 {
				n, _ = strconv.Atoi(p[1])
			}
			out = append(out, GPU{p[0], n})
		}
	}
	return out
}

func (r *Reader) fetchGPUTypes(ctx context.Context) ([]GPU, error) {
	seen := map[string]bool{}
	var out []GPU
	var token *string
	for {
		o, err := r.EC2.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{
			Filters:   []ec2types.Filter{{Name: aws.String("processor-info.supported-architecture"), Values: []string{"x86_64"}}},
			NextToken: token})
		if err != nil {
			return nil, err
		}
		for _, t := range o.InstanceTypes {
			if t.GpuInfo == nil || len(t.GpuInfo.Gpus) == 0 {
				continue
			}
			g := t.GpuInfo.Gpus[0]
			if aws.ToString(g.Manufacturer) != "NVIDIA" || !hasGraphics(g) || partition(g) < 1 {
				continue
			}
			name := string(t.InstanceType)
			if !seen[name] {
				seen[name] = true
				v := 0
				if t.VCpuInfo != nil {
					v = int(aws.ToInt32(t.VCpuInfo.DefaultVCpus))
				}
				out = append(out, GPU{name, v})
			}
		}
		if o.NextToken == nil || *o.NextToken == "" {
			break
		}
		token = o.NextToken
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Type < out[j].Type })
	return out, nil
}

func hasGraphics(g ec2types.GpuDeviceInfo) bool {
	for _, w := range g.Workloads {
		if w == "graphics" {
			return true
		}
	}
	return false
}

func partition(g ec2types.GpuDeviceInfo) float64 {
	if g.GpuPartitionSize == nil {
		return 1
	}
	return *g.GpuPartitionSize
}

// Shortlist is the smallest of each family: one row per kind of machine, for a
// scan across every region, where every size of every family would be hundreds
// of price lookups for rows that mostly cannot be rented.
func Shortlist(types []GPU) []string {
	best := map[string]GPU{}
	for _, g := range types {
		fam := strings.SplitN(g.Type, ".", 2)[0]
		if cur, ok := best[fam]; !ok || g.VCPUs < cur.VCPUs {
			best[fam] = g
		}
	}
	var out []string
	for _, g := range best {
		out = append(out, g.Type)
	}
	sort.Strings(out)
	return out
}

// Quota is the G/VT vCPU quotas, both purchase models. Either may be 0; an
// unreadable one is 0 too, and Unknown says so.
type Quota struct {
	OnDemand, Spot int
	Unknown        bool
}

// Quotas reads the two quotas.
func (r *Reader) Quotas_(ctx context.Context) Quota {
	var q Quota
	get := func(code string, into *int) {
		o, err := r.Quotas.GetServiceQuota(ctx, &servicequotas.GetServiceQuotaInput{ServiceCode: aws.String("ec2"), QuotaCode: aws.String(code)})
		if err != nil || o.Quota == nil || o.Quota.Value == nil {
			q.Unknown = true
			return
		}
		*into = int(math.Round(*o.Quota.Value))
	}
	get("L-DB2E81BA", &q.OnDemand)
	get("L-3819A6DF", &q.Spot)
	return q
}

// Spec is one shape's description.
type Spec struct {
	Type    string
	VCPUs   int
	MemMiB  int64
	GPU     string
	VRAMMiB int64
	StoreGB int64
	Count   int
}

func (r *Reader) specs(ctx context.Context, types []string) ([]Spec, error) {
	var out []Spec
	for i := 0; i < len(types); i += 100 { // the API takes a hundred at a time
		end := min(i+100, len(types))
		var in []ec2types.InstanceType
		for _, t := range types[i:end] {
			in = append(in, ec2types.InstanceType(t))
		}
		o, err := r.EC2.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{InstanceTypes: in})
		if err != nil {
			return nil, err
		}
		for _, t := range o.InstanceTypes {
			s := Spec{Type: string(t.InstanceType), Count: 1}
			if t.VCpuInfo != nil {
				s.VCPUs = int(aws.ToInt32(t.VCpuInfo.DefaultVCpus))
			}
			if t.MemoryInfo != nil {
				s.MemMiB = aws.ToInt64(t.MemoryInfo.SizeInMiB)
			}
			if t.GpuInfo != nil && len(t.GpuInfo.Gpus) > 0 {
				g := t.GpuInfo.Gpus[0]
				s.GPU = aws.ToString(g.Name)
				if g.MemoryInfo != nil {
					s.VRAMMiB = int64(aws.ToInt32(g.MemoryInfo.SizeInMiB))
				}
				if g.Count != nil {
					s.Count = int(*g.Count)
				}
			}
			if t.InstanceStorageInfo != nil {
				s.StoreGB = aws.ToInt64(t.InstanceStorageInfo.TotalSizeInGB)
			}
			out = append(out, s)
		}
	}
	return out, nil
}

// offerings is the zones each type is offered in.
func (r *Reader) offerings(ctx context.Context, types []string) (map[string][]string, error) {
	azs := map[string][]string{}
	var token *string
	for {
		o, err := r.EC2.DescribeInstanceTypeOfferings(ctx, &ec2.DescribeInstanceTypeOfferingsInput{
			LocationType: ec2types.LocationTypeAvailabilityZone,
			Filters:      []ec2types.Filter{{Name: aws.String("instance-type"), Values: types}},
			NextToken:    token})
		if err != nil {
			return nil, err
		}
		for _, x := range o.InstanceTypeOfferings {
			azs[string(x.InstanceType)] = append(azs[string(x.InstanceType)], aws.ToString(x.Location))
		}
		if o.NextToken == nil || *o.NextToken == "" {
			return azs, nil
		}
		token = o.NextToken
	}
}

// spotPrices is each type's current price in each zone. The history is newest
// first, so the first price seen for a zone is current.
func (r *Reader) spotPrices(ctx context.Context, types []string) (map[string]map[string]float64, map[string][]string, error) {
	out := map[string]map[string]float64{}
	order := map[string][]string{} // zones in the order first seen: a tie goes to the first
	in := &ec2.DescribeSpotPriceHistoryInput{ProductDescriptions: []string{"Linux/UNIX"},
		StartTime: aws.Time(r.now().Add(-3 * time.Hour))}
	for _, t := range types {
		in.InstanceTypes = append(in.InstanceTypes, ec2types.InstanceType(t))
	}
	for {
		o, err := r.EC2.DescribeSpotPriceHistory(ctx, in)
		if err != nil {
			return nil, nil, err
		}
		for _, p := range o.SpotPriceHistory {
			t, az := string(p.InstanceType), aws.ToString(p.AvailabilityZone)
			v, err := strconv.ParseFloat(aws.ToString(p.SpotPrice), 64)
			if err != nil {
				continue
			}
			if out[t] == nil {
				out[t] = map[string]float64{}
			}
			if _, seen := out[t][az]; !seen {
				out[t][az] = v
				order[t] = append(order[t], az)
			}
		}
		if o.NextToken == nil || *o.NextToken == "" {
			return out, order, nil
		}
		in.NextToken = o.NextToken
	}
}

// Machine is one row of the table. A price is the CHEAPEST current spot price
// across the zones that offer the type, with the zone named: zones differ by
// more than 2x, and nothing pins the AZ any more, so the cheap number alone
// would be a promise this cannot keep. The max is the other end of that range.
type Machine struct {
	Type            string             `json:"type"`
	VCPU            int                `json:"vcpu"`
	RAMGiB          float64            `json:"ram_gib"`
	GPU             *string            `json:"gpu"`
	GPUCount        int                `json:"gpu_count"`
	VRAMGiB         *float64           `json:"vram_gib"`
	StoreGB         *int64             `json:"store_gb"`
	AZs             []string           `json:"azs"`
	FitsOnDemand    bool               `json:"fits_ondemand"` // whether a quota covers it at all
	FitsSpot        bool               `json:"fits_spot"`
	USDHourOnDemand *float64           `json:"usd_hour_ondemand"`
	INRHourOnDemand *float64           `json:"inr_hour_ondemand"`
	USDHourSpot     *float64           `json:"usd_hour_spot"`
	INRHourSpot     *float64           `json:"inr_hour_spot"`
	SpotAZ          *string            `json:"spot_az"`
	SpotUSDByAZ     map[string]float64 `json:"spot_usd_by_az"`
	INRHourSpotMax  *float64           `json:"inr_hour_spot_max"`
	USDHourSpotMax  *float64           `json:"usd_hour_spot_max"`
	SpotAZMax       *string            `json:"spot_az_max"`
}

// Table is the whole thing, as one object.
type Table struct {
	Region     string  `json:"region"`
	Configured *string `json:"configured"`
	Spot       string  `json:"spot"`
	Quota      *struct {
		OnDemandVCPU int `json:"ondemand_vcpu"`
		SpotVCPU     int `json:"spot_vcpu"`
	} `json:"quota,omitempty"`
	QuotaUnknown bool      `json:"quota_unknown,omitempty"` // a quota AWS would not give is 0 above
	INRPerUSD    *float64  `json:"inr_per_usd"`
	Machines     []Machine `json:"machines"`
	Error        string    `json:"error,omitempty"`
}

// Build reads the region. configured is GAME_INSTANCE_TYPE, spot is GAME_SPOT
// as .env has it ("0" when silent).
func (r *Reader) Build(ctx context.Context, configured, spot string, inr *float64) Table {
	t := Table{Region: r.Region, Spot: spot, INRPerUSD: inr, Machines: []Machine{}}
	if configured != "" {
		t.Configured = &configured
	}
	q := r.Quotas_(ctx)
	gpus, _ := r.GPUTypes(ctx)
	var names []string
	for _, g := range gpus {
		names = append(names, g.Type)
	}
	var azs map[string][]string
	if len(names) > 0 {
		azs, _ = r.offerings(ctx, names)
	}
	if len(azs) == 0 {
		t.Error = "no GPU instance types are offered in this region, or EC2 could not be read"
		return t
	}
	t.Quota = &struct {
		OnDemandVCPU int `json:"ondemand_vcpu"`
		SpotVCPU     int `json:"spot_vcpu"`
	}{q.OnDemand, q.Spot}
	t.QuotaUnknown = q.Unknown
	var offered []string
	for ty := range azs {
		offered = append(offered, ty)
	}
	sort.Strings(offered)
	specs, _ := r.specs(ctx, offered)
	prices, zoneOrder, _ := r.spotPrices(ctx, offered)

	// On-demand prices: one Price List call per shape, and only for the shapes
	// whose vCPU count a quota could actually cover - the rest are listed as
	// out of reach and need no price.
	od := map[string]*float64{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, s := range specs {
		if s.VCPUs <= q.OnDemand || s.VCPUs <= q.Spot {
			wg.Add(1)
			go func(ty string) {
				defer wg.Done()
				p := pricing.OnDemandHourly(ctx, r.Products, ty, r.Region)
				mu.Lock()
				od[ty] = p
				mu.Unlock()
			}(s.Type)
		}
	}
	wg.Wait()

	money := func(usd float64) *float64 {
		if inr == nil {
			return nil
		}
		v := math.Round(usd**inr*100) / 100
		return &v
	}
	for _, s := range specs {
		m := Machine{Type: s.Type, VCPU: s.VCPUs, RAMGiB: round1(float64(s.MemMiB) / 1024), GPUCount: s.Count,
			AZs: sortedCopy(azs[s.Type]), FitsOnDemand: s.VCPUs <= q.OnDemand, FitsSpot: s.VCPUs <= q.Spot, SpotUSDByAZ: map[string]float64{}}
		if s.GPU != "" && s.GPU != "None" {
			g := s.GPU
			m.GPU = &g
		}
		if s.VRAMMiB > 0 {
			v := round1(float64(s.VRAMMiB) / 1024)
			m.VRAMGiB = &v
		}
		if s.StoreGB > 0 {
			v := s.StoreGB
			m.StoreGB = &v
		}
		if p := od[s.Type]; p != nil {
			m.USDHourOnDemand, m.INRHourOnDemand = p, money(*p)
		}
		if zp := prices[s.Type]; len(zp) > 0 {
			lo, hi := "", ""
			for _, az := range zoneOrder[s.Type] {
				p := zp[az]
				m.SpotUSDByAZ[az] = p
				if lo == "" || p < zp[lo] {
					lo = az
				}
				if hi == "" || p > zp[hi] {
					hi = az
				}
			}
			lp, hp := zp[lo], zp[hi]
			m.USDHourSpot, m.INRHourSpot, m.SpotAZ = &lp, money(lp), &lo
			m.USDHourSpotMax, m.INRHourSpotMax, m.SpotAZMax = &hp, money(hp), &hi
		}
		t.Machines = append(t.Machines, m)
	}
	// Cheapest usable first, by the purchase model actually configured; anything
	// no quota covers sinks to the bottom.
	spotOn := spot == "1"
	key := func(m Machine) (bool, float64, string) {
		usable := m.FitsOnDemand
		price := m.USDHourOnDemand
		if spotOn {
			usable, price = m.FitsSpot, m.USDHourSpot
		}
		p := 1e9
		if price != nil && *price != 0 {
			p = *price
		}
		return !usable, p, m.Type
	}
	sort.SliceStable(t.Machines, func(i, j int) bool {
		a1, a2, a3 := key(t.Machines[i])
		b1, b2, b3 := key(t.Machines[j])
		if a1 != b1 {
			return !a1
		}
		if a2 != b2 {
			return a2 < b2
		}
		return a3 < b3
	})
	return t
}

func round1(v float64) float64 { return math.Round(v*10) / 10 }

func sortedCopy(s []string) []string {
	out := append([]string{}, s...)
	sort.Strings(out)
	return out
}
