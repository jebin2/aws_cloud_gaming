package machines

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"
	sqtypes "github.com/aws/aws-sdk-go-v2/service/servicequotas/types"
)

type shape struct {
	name       string
	vcpu       int32
	mem        int64
	manuf, gpu string
	workloads  []string
	partition  *float64
	vram       int32
	store      int64
	offeredIn  []string
	spot       map[string]string // az -> price, newest first in the order given
	spotOrder  []string
}

type fakeEC2 struct {
	shapes        []shape
	calls         map[string]int
	failOfferings bool
}

func (f *fakeEC2) DescribeInstanceTypes(_ context.Context, in *ec2.DescribeInstanceTypesInput, _ ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error) {
	f.calls["types"]++
	want := map[string]bool{}
	for _, t := range in.InstanceTypes {
		want[string(t)] = true
	}
	out := &ec2.DescribeInstanceTypesOutput{}
	for _, s := range f.shapes {
		if len(want) > 0 && !want[s.name] {
			continue
		}
		g := ec2types.GpuDeviceInfo{Manufacturer: aws.String(s.manuf), Name: aws.String(s.gpu), Count: aws.Int32(1),
			Workloads: s.workloads, GpuPartitionSize: s.partition, MemoryInfo: &ec2types.GpuDeviceMemoryInfo{SizeInMiB: aws.Int32(s.vram)}}
		ti := ec2types.InstanceTypeInfo{InstanceType: ec2types.InstanceType(s.name),
			VCpuInfo: &ec2types.VCpuInfo{DefaultVCpus: aws.Int32(s.vcpu)}, MemoryInfo: &ec2types.MemoryInfo{SizeInMiB: aws.Int64(s.mem)},
			GpuInfo: &ec2types.GpuInfo{Gpus: []ec2types.GpuDeviceInfo{g}}}
		if s.store > 0 {
			ti.InstanceStorageInfo = &ec2types.InstanceStorageInfo{TotalSizeInGB: aws.Int64(s.store)}
		}
		out.InstanceTypes = append(out.InstanceTypes, ti)
	}
	return out, nil
}

func (f *fakeEC2) DescribeInstanceTypeOfferings(_ context.Context, in *ec2.DescribeInstanceTypeOfferingsInput, _ ...func(*ec2.Options)) (*ec2.DescribeInstanceTypeOfferingsOutput, error) {
	f.calls["offerings"]++
	if f.failOfferings {
		return nil, errors.New("denied")
	}
	want := map[string]bool{}
	for _, v := range in.Filters[0].Values {
		want[v] = true
	}
	out := &ec2.DescribeInstanceTypeOfferingsOutput{}
	for _, s := range f.shapes {
		if !want[s.name] {
			continue
		}
		for _, az := range s.offeredIn {
			out.InstanceTypeOfferings = append(out.InstanceTypeOfferings, ec2types.InstanceTypeOffering{
				InstanceType: ec2types.InstanceType(s.name), Location: aws.String(az)})
		}
	}
	return out, nil
}

func (f *fakeEC2) DescribeSpotPriceHistory(_ context.Context, _ *ec2.DescribeSpotPriceHistoryInput, _ ...func(*ec2.Options)) (*ec2.DescribeSpotPriceHistoryOutput, error) {
	f.calls["spot"]++
	out := &ec2.DescribeSpotPriceHistoryOutput{}
	for _, s := range f.shapes {
		for _, az := range s.spotOrder {
			out.SpotPriceHistory = append(out.SpotPriceHistory, ec2types.SpotPrice{InstanceType: ec2types.InstanceType(s.name),
				AvailabilityZone: aws.String(az), SpotPrice: aws.String(s.spot[az])})
		}
	}
	return out, nil
}

type fakeQuotas struct {
	od, sp float64
	fail   bool
}

func (q fakeQuotas) GetServiceQuota(_ context.Context, in *servicequotas.GetServiceQuotaInput, _ ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error) {
	if q.fail {
		return nil, errors.New("denied")
	}
	v := q.sp
	if aws.ToString(in.QuotaCode) == "L-DB2E81BA" {
		v = q.od
	}
	return &servicequotas.GetServiceQuotaOutput{Quota: &sqtypes.ServiceQuota{Value: aws.Float64(v)}}, nil
}

type fakeProducts struct{ price map[string]string }

func (f fakeProducts) Products(_ context.Context, _ string, filters [][2]string) ([]string, error) {
	for _, flt := range filters {
		if flt[0] == "instanceType" {
			if p, ok := f.price[flt[1]]; ok {
				return []string{`{"terms":{"OnDemand":{"x":{"priceDimensions":{"y":{"pricePerUnit":{"USD":"` + p + `"}}}}}}}`}, nil
			}
		}
	}
	return nil, nil
}

func fl(v float64) *float64 { return &v }

func shapes() []shape {
	g := []string{"graphics", "compute"}
	return []shape{
		{name: "g4dn.xlarge", vcpu: 4, mem: 16384, manuf: "NVIDIA", gpu: "T4", workloads: g, vram: 16384, store: 125,
			offeredIn: []string{"az-a", "az-b"}, spot: map[string]string{"az-a": "0.30", "az-b": "0.30"}, spotOrder: []string{"az-b", "az-a"}},
		{name: "g6.xlarge", vcpu: 4, mem: 16384, manuf: "NVIDIA", gpu: "L4", workloads: g, vram: 22888, store: 250,
			offeredIn: []string{"az-a"}, spot: map[string]string{"az-a": "0.65"}, spotOrder: []string{"az-a"}},
		{name: "g6.12xlarge", vcpu: 48, mem: 196608, manuf: "NVIDIA", gpu: "L4", workloads: g, vram: 22888, offeredIn: []string{"az-a"}},
		{name: "p4d.24xlarge", vcpu: 96, mem: 1, manuf: "NVIDIA", gpu: "A100", workloads: []string{"compute"}, vram: 1, offeredIn: []string{"az-a"}},
		{name: "g6f.large", vcpu: 2, mem: 1, manuf: "NVIDIA", gpu: "L4", workloads: g, partition: fl(0.5), vram: 1, offeredIn: []string{"az-a"}},
		{name: "g4ad.xlarge", vcpu: 4, mem: 1, manuf: "AMD", gpu: "Radeon", workloads: g, vram: 1, offeredIn: []string{"az-a"}},
	}
}

func reader(t *testing.T, f *fakeEC2, q fakeQuotas) *Reader {
	return &Reader{EC2: f, Quotas: q, Products: fakeProducts{map[string]string{"g4dn.xlarge": "0.60", "g6.xlarge": "1.20"}},
		Region: "ap-south-1", CacheDir: t.TempDir(), Now: func() time.Time { return time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC) }}
}

func TestOnlyMachinesThatCanRunThisRigAreOffered(t *testing.T) {
	f := &fakeEC2{shapes: shapes(), calls: map[string]int{}}
	got, err := reader(t, f, fakeQuotas{}).GPUTypes(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, g := range got {
		names = append(names, g.Type)
	}
	// NVIDIA, a graphics workload, a whole GPU: not the p family, not a fraction, not AMD.
	if strings.Join(names, ",") != "g4dn.xlarge,g6.12xlarge,g6.xlarge" {
		t.Errorf("types: %v", names)
	}
}

func TestGPUTypesAreKeptADay(t *testing.T) {
	f := &fakeEC2{shapes: shapes(), calls: map[string]int{}}
	r := reader(t, f, fakeQuotas{})
	_, _ = r.GPUTypes(context.Background())
	_, _ = r.GPUTypes(context.Background())
	if f.calls["types"] != 1 {
		t.Errorf("asked %d times", f.calls["types"])
	}
	// A stale answer beats none when AWS cannot be asked.
	old := time.Now().Add(-48 * time.Hour)
	_ = os.Chtimes(filepath.Join(r.CacheDir, "gpu-types-ap-south-1"), old, old)
	r.Now = time.Now
	f.shapes = nil
	if got, _ := r.GPUTypes(context.Background()); len(got) != 3 {
		t.Errorf("stale: %v", got)
	}
}

func TestShortlistIsTheSmallestOfEachFamily(t *testing.T) {
	got := Shortlist([]GPU{{"g6.xlarge", 4}, {"g6.2xlarge", 8}, {"g6.12xlarge", 48}, {"g4dn.xlarge", 4}, {"g4dn.12xlarge", 48}})
	if strings.Join(got, ",") != "g4dn.xlarge,g6.xlarge" {
		t.Errorf("%v", got)
	}
}

func TestTheTable(t *testing.T) {
	f := &fakeEC2{shapes: shapes(), calls: map[string]int{}}
	r := reader(t, f, fakeQuotas{od: 4, sp: 4})
	tb := r.Build(context.Background(), "g4dn.xlarge", "1", fl(100))
	if tb.Error != "" || tb.Quota.OnDemandVCPU != 4 || tb.QuotaUnknown {
		t.Fatalf("%+v", tb)
	}
	if len(tb.Machines) != 3 {
		t.Fatalf("machines: %d", len(tb.Machines))
	}
	// Cheapest usable first by the purchase model in use (spot); what no quota covers sinks.
	var order []string
	for _, m := range tb.Machines {
		order = append(order, m.Type)
	}
	if strings.Join(order, ",") != "g4dn.xlarge,g6.xlarge,g6.12xlarge" {
		t.Errorf("order: %v", order)
	}
	m := tb.Machines[0]
	if *m.USDHourSpot != 0.30 || *m.INRHourSpot != 30 || *m.USDHourOnDemand != 0.60 || *m.INRHourOnDemand != 60 {
		t.Errorf("%+v", m)
	}
	// A tie goes to the zone AWS listed first, and the max is the other end.
	if *m.SpotAZ != "az-b" || *m.SpotAZMax != "az-b" {
		t.Errorf("tie: %s %s", *m.SpotAZ, *m.SpotAZMax)
	}
	if !m.FitsSpot || !m.FitsOnDemand || tb.Machines[2].FitsSpot || tb.Machines[2].USDHourOnDemand != nil {
		t.Errorf("a shape no quota covers needs no price: %+v", tb.Machines[2])
	}
	if *m.VRAMGiB != 16 || m.RAMGiB != 16 || *m.StoreGB != 125 || m.GPU == nil || *m.GPU != "T4" {
		t.Errorf("%+v", m)
	}
}

func TestOnDemandOrdersByOnDemandPriceWhenSpotIsOff(t *testing.T) {
	f := &fakeEC2{shapes: shapes(), calls: map[string]int{}}
	tb := reader(t, f, fakeQuotas{od: 4, sp: 0}).Build(context.Background(), "g6.xlarge", "0", nil)
	if tb.Machines[0].Type != "g4dn.xlarge" || tb.Machines[0].INRHourOnDemand != nil {
		t.Errorf("%+v", tb.Machines[0])
	}
	if tb.Machines[0].FitsSpot {
		t.Error("no spot quota")
	}
}

func TestAnUnreadableQuotaIsSaidAndAnEmptyRegionIsAnError(t *testing.T) {
	f := &fakeEC2{shapes: shapes(), calls: map[string]int{}}
	tb := reader(t, f, fakeQuotas{fail: true}).Build(context.Background(), "", "0", nil)
	if !tb.QuotaUnknown || tb.Quota.OnDemandVCPU != 0 || tb.Configured != nil {
		t.Errorf("%+v", tb)
	}
	f = &fakeEC2{shapes: shapes(), calls: map[string]int{}, failOfferings: true}
	tb = reader(t, f, fakeQuotas{}).Build(context.Background(), "g6.xlarge", "0", nil)
	b, _ := JSON(tb)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if m["error"] == nil || len(m["machines"].([]any)) != 0 || m["quota"] != nil {
		t.Errorf("%s", b)
	}
	if got := Show(tb, false); !strings.Contains(got, "no GPU instance types are offered in this region") {
		t.Errorf("%s", got)
	}
}

func TestShow(t *testing.T) {
	f := &fakeEC2{shapes: shapes(), calls: map[string]int{}}
	tb := reader(t, f, fakeQuotas{od: 4, sp: 4}).Build(context.Background(), "g4dn.xlarge", "1", fl(100))
	text := Show(tb, false)
	for _, want := range []string{"region ap-south-1 - quota 4 vCPU on demand, 4 spot", "*g4dn.xlarge   4     T4        16 GB    16 GB   125 GB   INR 30.00 / INR 60.00",
		"1 larger shapes exist here that no quota covers: cg machines --all", "* is the one in use."} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "g6.12xlarge") {
		t.Error("an unreachable shape listed without --all")
	}
	if all := Show(tb, true); !strings.Contains(all, "g6.12xlarge") || !strings.Contains(all, "(no quota covers 48 vCPU)") || strings.Contains(all, "larger shapes exist") {
		t.Errorf("--all:\n%s", all)
	}
}

func TestIsRegion(t *testing.T) {
	if !IsRegion("ap-south-1") || !IsRegion("us-gov-west-1") || IsRegion("--all") || IsRegion("all") || IsRegion("ap-south") {
		t.Error("region shape")
	}
}
