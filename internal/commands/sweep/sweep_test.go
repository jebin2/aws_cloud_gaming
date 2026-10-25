package sweep

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/commands/machines"
)

type fake struct {
	regions   []Region
	rtt       map[string]float64        // absent: no reply
	placement map[string]bool           // regions where the call exists
	scores    map[string]map[string]int // type -> region -> score
	quota     map[string][2]int
	quotaFail map[string]bool
	offers    map[string][]string
	spot      map[string][2]float64 // "region/type"
	od        map[string]float64    // "region/type"
	gpu       map[string][]machines.GPU
	rttCalls  map[string][]int
	mu        sync.Mutex
}

func ptr(v float64) *float64 { return &v }

func (f *fake) ListRegions(context.Context) ([]Region, error) { return f.regions, nil }
func (f *fake) GPUTypes(_ context.Context, r string) ([]machines.GPU, error) {
	if g, ok := f.gpu[r]; ok {
		return g, nil
	}
	return f.gpu["*"], nil
}
func (f *fake) PlacementWorks(_ context.Context, from, _ string) bool { return f.placement[from] }
func (f *fake) RTT(_ context.Context, r string, samples int) (float64, bool) {
	f.mu.Lock()
	if f.rttCalls == nil {
		f.rttCalls = map[string][]int{}
	}
	f.rttCalls[r] = append(f.rttCalls[r], samples)
	f.mu.Unlock()
	v, ok := f.rtt[r]
	return v, ok
}
func (f *fake) Specs(_ context.Context, _ string, types []string) (map[string]Spec, error) {
	out := map[string]Spec{}
	for _, t := range types {
		gpu := "T4"
		v, store := 16.0, int64(125)
		out[t] = Spec{VCPU: 4, RAMGiB: 16, GPU: &gpu, VRAMGiB: &v, StoreGB: &store}
	}
	return out, nil
}
func (f *fake) Scores(_ context.Context, _ string, t string, regions []string) (map[string]int, error) {
	out := map[string]int{}
	for _, r := range regions {
		if s, ok := f.scores[t][r]; ok {
			out[r] = s
		}
	}
	return out, nil
}
func (f *fake) City(_ context.Context, _ string, r string) string { return "Asia Pacific (" + r + ")" }
func (f *fake) Quota(_ context.Context, r string) (int, int, bool) {
	if f.quotaFail[r] {
		return 0, 0, false
	}
	q := f.quota[r]
	return q[0], q[1], true
}
func (f *fake) Offers(_ context.Context, r string, _ []string) ([]string, error) {
	return f.offers[r], nil
}
func (f *fake) Spot(_ context.Context, r string, types []string) (map[string]float64, map[string]float64, error) {
	lo, hi := map[string]float64{}, map[string]float64{}
	for _, t := range types {
		if p, ok := f.spot[r+"/"+t]; ok {
			lo[t], hi[t] = p[0], p[1]
		}
	}
	return lo, hi, nil
}
func (f *fake) OnDemand(_ context.Context, r, t string) *float64 {
	if p, ok := f.od[r+"/"+t]; ok {
		return &p
	}
	return nil
}

func world() *fake {
	return &fake{
		regions: []Region{{"us-east-1", "opt-in-not-required"}, {"ap-south-1", "opt-in-not-required"}, {"ap-south-2", "opt-in-not-required"},
			{"af-south-1", "not-opted-in"}, {"sa-east-1", "opt-in-not-required"}, {"eu-west-1", "opt-in-not-required"}},
		rtt:       map[string]float64{"ap-south-1": 19.3, "ap-south-2": 25, "af-south-1": 60, "sa-east-1": 300, "eu-west-1": 100},
		placement: map[string]bool{"ap-south-1": true},
		gpu:       map[string][]machines.GPU{"*": {{Type: "g4dn.xlarge", VCPUs: 4}, {Type: "g4dn.12xlarge", VCPUs: 48}, {Type: "g6.xlarge", VCPUs: 4}}},
		scores: map[string]map[string]int{
			"g4dn.xlarge": {"ap-south-1": 9, "af-south-1": 3},
			"g6.xlarge":   {"ap-south-1": 4, "ap-south-2": 1},
		},
		quota:  map[string][2]int{"ap-south-1": {4, 4}, "ap-south-2": {0, 8}},
		offers: map[string][]string{"ap-south-1": {"g4dn.xlarge", "g6.xlarge"}, "ap-south-2": {"g6.xlarge"}},
		spot:   map[string][2]float64{"ap-south-1/g4dn.xlarge": {0.2, 0.5}},
		od:     map[string]float64{"ap-south-1/g4dn.xlarge": 0.6, "ap-south-1/g6.xlarge": 1.2, "ap-south-2/g6.xlarge": 1.3, "af-south-1/g4dn.xlarge": 0.8},
	}
}

func scan(t *testing.T, f *fake, mutate func(*Options)) Result {
	o := Options{Configured: "ap-south-2", MaxMS: 80, Samples: 5, INRPerUSD: ptr(100)}
	if mutate != nil {
		mutate(&o)
	}
	return Scan(context.Background(), f, o)
}

func TestTheShortlistIsTheSmallestOfEachFamily(t *testing.T) {
	r := scan(t, world(), nil)
	if strings.Join(r.Types, ",") != "g4dn.xlarge,g6.xlarge" {
		t.Errorf("%v", r.Types)
	}
	r = scan(t, world(), func(o *Options) { o.Types = []string{"g6.xlarge"} })
	if strings.Join(r.Types, ",") != "g6.xlarge" {
		t.Errorf("CG_SWEEP_TYPES wins: %v", r.Types)
	}
}

// Latency is applied first and is the harshest filter.
func TestLatencyDecidesWhoIsNearEnough(t *testing.T) {
	f := world()
	r := scan(t, f, nil)
	var near []string
	for _, x := range r.Regions {
		near = append(near, x.Region)
	}
	// 60 ms is within the budget, 100 is over, 300 is far; us-east-1 never answered. Capacity orders them: a region with a score of 3 beats a nearer one with 1.
	if strings.Join(near, ",") != "ap-south-1,af-south-1,ap-south-2" {
		t.Errorf("near: %v", near)
	}
	if len(r.TooFar) != 2 || r.TooFar[0].Region != "eu-west-1" || r.TooFar[1].Region != "sa-east-1" {
		t.Errorf("too far, nearest first: %+v", r.TooFar)
	}
	if len(r.Unreachable) != 1 || r.Unreachable[0].Region != "us-east-1" || !r.Measured {
		t.Errorf("unreachable: %+v", r.Unreachable)
	}
	// The coarse pass uses the plain sample count; the near ones are measured again, three times as hard.
	if got := f.rttCalls["ap-south-1"]; len(got) != 2 || got[0] != 5 || got[1] != 15 {
		t.Errorf("probes: %v", got)
	}
	if got := f.rttCalls["sa-east-1"]; len(got) != 1 {
		t.Errorf("a far region is not measured again: %v", got)
	}
}

// Behind a firewall every probe fails; filtering on that would exclude every
// region and report that nowhere on earth can stream.
func TestNoProbeAnsweredMeansNothingIsExcluded(t *testing.T) {
	f := world()
	f.rtt = nil
	r := scan(t, f, nil)
	if r.Measured || len(r.Regions) != 6 || len(r.TooFar) != 0 || len(r.Unreachable) != 0 {
		t.Errorf("measured=%v regions=%d far=%d unreachable=%d", r.Measured, len(r.Regions), len(r.TooFar), len(r.Unreachable))
	}
	if txt := Show(r, false); !strings.Contains(txt, "latency could NOT be measured") {
		t.Errorf("%s", txt)
	}
}

func TestCapacityBeatsPriceAndNearness(t *testing.T) {
	r := scan(t, world(), nil)
	if r.Regions[0].Region != "ap-south-1" || *r.Regions[0].BestScore != 9 {
		t.Errorf("a region with capacity is the answer: %+v", r.Regions[0])
	}
	m := r.Regions[0].Machines
	if m[0].Type != "g4dn.xlarge" || *m[0].Score != 9 || m[1].Type != "g6.xlarge" {
		t.Errorf("best score first: %v %v", m[0].Type, m[1].Type)
	}
	if *m[0].INRHourSpot != 20 || *m[0].INRHourSpotMax != 50 || *m[0].INRHourOD != 60 || *m[0].USDHourOD != 0.6 {
		t.Errorf("%+v", m[0])
	}
	if *m[0].FitsOnDemand != true || *m[0].FitsSpot != true || *m[0].Offered != true {
		t.Errorf("%+v", m[0])
	}
	if *r.Regions[0].RTTMS != 19.3 || *r.Regions[0].City != "Asia Pacific (ap-south-1)" {
		t.Errorf("%+v", r.Regions[0])
	}
}

// A 0 quota and an unreadable quota lead to different actions - one is a request,
// the other an opt-in - so they must not collapse; and a region not opted into
// cannot be asked at all.
func TestAQuotaOfZeroIsNotAnOptIn(t *testing.T) {
	r := scan(t, world(), nil)
	var af, as2 RegionRow
	for _, x := range r.Regions {
		if x.Region == "af-south-1" {
			af = x
		}
		if x.Region == "ap-south-2" {
			as2 = x
		}
	}
	if af.Enabled || af.Quota != nil || af.Machines[0].FitsSpot != nil || af.Machines[0].Offered != nil {
		t.Errorf("not opted in: nothing can be read: %+v", af)
	}
	if af.Machines[0].INRHourOD == nil {
		t.Error("but the Price List answers before opting in")
	}
	if as2.Quota.OnDemandVCPU != 0 || *as2.Machines[0].FitsOnDemand != false || *as2.Machines[0].FitsSpot != true {
		t.Errorf("a zero quota is a request: %+v", as2)
	}
	txt := Show(r, false)
	if !strings.Contains(txt, "opt-in") || !strings.Contains(txt, "0/ok") || !strings.Contains(txt, "ok/ok") {
		t.Errorf("%s", txt)
	}
}

func TestATypeNeverOnSaleIsNotListed(t *testing.T) {
	r := scan(t, world(), nil)
	for _, x := range r.Regions {
		if x.Region == "ap-south-2" {
			for _, m := range x.Machines {
				if m.Type == "g4dn.xlarge" {
					t.Error("g4dn is not sold in ap-south-2: no score, no offering, no price")
				}
			}
		}
	}
}

// ap-south-2 answers UnsupportedOperation for placement scores, so the source
// region is probed.
func TestTheCallsAreMadeFromARegionWhereTheyExist(t *testing.T) {
	f := world()
	opts := Options{Configured: "ap-south-2", Fallbacks: []string{"us-east-1", "ap-south-1"}}
	if got := opts.from(context.Background(), f); got != "ap-south-1" {
		t.Errorf("from %s", got)
	}
	opts.From = "eu-west-1"
	if opts.from(context.Background(), f) != "eu-west-1" {
		t.Error("CG_SWEEP_FROM wins")
	}
	f.placement = nil
	opts.From = ""
	if got := opts.from(context.Background(), f); got != "ap-south-2" {
		t.Errorf("nothing answered: the configured region, so a real AWS error is reported: %s", got)
	}
}

func TestErrors(t *testing.T) {
	f := world()
	f.gpu = map[string][]machines.GPU{}
	if r := scan(t, f, nil); !strings.Contains(r.Error, "AWS did not say which machines it offers") || len(r.Regions) != 0 {
		t.Errorf("%+v", r)
	}
	f = world()
	f.regions = nil
	if r := scan(t, f, nil); !strings.Contains(r.Error, "could not list regions") {
		t.Errorf("%+v", r)
	}
	if txt := Show(scan(t, f, nil), false); !strings.Contains(txt, "could not list regions") {
		t.Errorf("%s", txt)
	}
}

func TestShow(t *testing.T) {
	txt := Show(scan(t, world(), nil), false)
	for _, want := range []string{"the budget is 80ms", "REGION", "ap-south-1", "19 ms", "2 more regions are over 80ms and were skipped: cg sweep --all",
		"1 regions did not answer a latency probe", "no GPU machine"[:0], "* is the region in use."} {
		if !strings.Contains(txt, want) {
			t.Errorf("lacks %q:\n%s", want, txt)
		}
	}
	// The configured region is starred; the long name is trimmed.
	if !strings.Contains(txt, "*ap-south-2") || !strings.Contains(txt, "ap-south-1)"[:0]) {
		t.Errorf("%s", txt)
	}
	all := Show(scan(t, world(), nil), true)
	if !strings.Contains(all, "too far to stream (over 80ms):") || !strings.Contains(all, "sa-east-1") {
		t.Errorf("--all:\n%s", all)
	}
}

func TestMedianAndTrim(t *testing.T) {
	if Median([]float64{30, 10, 20}) != 20 || Median([]float64{10, 20, 30, 40}) != 25 {
		t.Error("median")
	}
	if Trim("Asia Pacific (Mumbai)") != "Mumbai" || Trim("US East (N. Virginia)") != "N. Virginia" || Trim("Somewhere") != "Somewhere" {
		t.Error("trim")
	}
}

func TestStoreRemembersAndReports(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	s := Store{Dir: dir, Name: "sweep.json", Now: func() time.Time { return now }}
	// Never scanned: the empty answer, with no error.
	if c := s.Cached(); c["cached"] != false || c["error"] != nil || c["scanned_at"] != nil {
		t.Errorf("%v", c)
	}
	saved := s.Save(scan(t, world(), nil))
	if saved.ScannedAt == nil || *saved.ScannedAt != "2026-10-25T12:00:00Z" || *saved.Cached != true || *saved.AgeSeconds != 0 {
		t.Errorf("%+v", saved)
	}
	later := Store{Dir: dir, Name: "sweep.json", Now: func() time.Time { return now.Add(3 * time.Hour) }}
	_ = os.Chtimes(filepath.Join(dir, "sweep.json"), now, now)
	c := later.Cached()
	if c["cached"] != true || c["age_seconds"] != int64(10800) {
		t.Errorf("an old cache is returned with its age, not discarded: %v", c["age_seconds"])
	}
	// Readable but not JSON: the empty answer with an error, not a failure.
	_ = os.WriteFile(filepath.Join(dir, "sweep.json"), []byte("not json"), 0o644)
	if c := later.Cached(); c["cached"] != false || c["error"] != "the remembered scan could not be read" {
		t.Errorf("%v", c)
	}
}
