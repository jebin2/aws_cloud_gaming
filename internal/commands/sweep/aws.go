package sweep

import (
	"context"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/machines"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// AWS is the real Backend.
type AWS struct {
	Home     string // the region the account-level calls are made from
	Get      config.Lookup
	Products pricing.Products

	mu      sync.Mutex
	readers map[string]*machines.Reader
	clients map[string]*ec2.Client
}

func (a *AWS) ec2(ctx context.Context, region string) (*ec2.Client, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if c, ok := a.clients[region]; ok {
		return c, nil
	}
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	if a.clients == nil {
		a.clients = map[string]*ec2.Client{}
	}
	c := ec2.NewFromConfig(cfg)
	a.clients[region] = c
	return c, nil
}

func (a *AWS) reader(ctx context.Context, region string) (*machines.Reader, error) {
	a.mu.Lock()
	if r, ok := a.readers[region]; ok {
		a.mu.Unlock()
		return r, nil
	}
	a.mu.Unlock()
	r, err := machines.NewReader(ctx, region, a.Get, a.Products)
	if err != nil {
		return nil, err
	}
	a.mu.Lock()
	if a.readers == nil {
		a.readers = map[string]*machines.Reader{}
	}
	a.readers[region] = r
	a.mu.Unlock()
	return r, nil
}

// ListRegions lists every region, including ones not enabled: a region you have
// not opted into is still a candidate.
func (a *AWS) ListRegions(ctx context.Context) ([]Region, error) {
	c, err := a.ec2(ctx, a.Home)
	if err != nil {
		return nil, err
	}
	o, err := c.DescribeRegions(ctx, &ec2.DescribeRegionsInput{AllRegions: aws.Bool(true)})
	if err != nil {
		return nil, err
	}
	var out []Region
	for _, r := range o.Regions {
		out = append(out, Region{aws.ToString(r.RegionName), aws.ToString(r.OptInStatus)})
	}
	return out, nil
}

func (a *AWS) GPUTypes(ctx context.Context, region string) ([]machines.GPU, error) {
	r, err := a.reader(ctx, region)
	if err != nil {
		return nil, err
	}
	return r.GPUTypes(ctx)
}

func (a *AWS) PlacementWorks(ctx context.Context, from, itype string) bool {
	c, err := a.ec2(ctx, from)
	if err != nil {
		return false
	}
	_, err = c.GetSpotPlacementScores(ctx, &ec2.GetSpotPlacementScoresInput{
		InstanceTypes: []string{itype}, TargetCapacity: aws.Int32(1), RegionNames: []string{from}})
	return err == nil
}

// RTT is the median TCP connect time to the region's EC2 endpoint. The name
// lookup is done first and left out of the time: it is the round trip that
// matters, and it excludes the request, so it tracks the network rather than
// the API. The median of several, not one sample - a single probe caught a 46ms
// outlier in a region whose median is 19ms.
func (a *AWS) RTT(ctx context.Context, region string, samples int) (float64, bool) {
	host := "ec2." + region + ".amazonaws.com"
	var ms []float64
	for i := 0; i < samples; i++ {
		if ctx.Err() != nil {
			break
		}
		cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
		ips, err := net.DefaultResolver.LookupHost(cctx, host)
		if err != nil || len(ips) == 0 {
			cancel()
			continue
		}
		start := time.Now()
		conn, err := (&net.Dialer{}).DialContext(cctx, "tcp", net.JoinHostPort(ips[0], "443"))
		d := time.Since(start)
		cancel()
		if err != nil {
			continue
		}
		conn.Close()
		if d > 0 {
			ms = append(ms, float64(d.Microseconds())/1000)
		}
	}
	if len(ms) == 0 {
		return 0, false
	}
	return RoundMS(Median(ms)), true
}

func (a *AWS) Specs(ctx context.Context, from string, types []string) (map[string]Spec, error) {
	c, err := a.ec2(ctx, from)
	if err != nil {
		return nil, err
	}
	var in []ec2types.InstanceType
	for _, t := range types {
		in = append(in, ec2types.InstanceType(t))
	}
	o, err := c.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{InstanceTypes: in})
	if err != nil {
		return nil, err
	}
	out := map[string]Spec{}
	for _, t := range o.InstanceTypes {
		s := Spec{}
		if t.VCpuInfo != nil {
			s.VCPU = int(aws.ToInt32(t.VCpuInfo.DefaultVCpus))
		}
		if t.MemoryInfo != nil {
			s.RAMGiB = RoundMS(float64(aws.ToInt64(t.MemoryInfo.SizeInMiB)) / 1024)
		}
		if t.GpuInfo != nil && len(t.GpuInfo.Gpus) > 0 {
			g := t.GpuInfo.Gpus[0]
			if n := aws.ToString(g.Name); n != "" {
				s.GPU = &n
			}
			if g.MemoryInfo != nil && g.MemoryInfo.SizeInMiB != nil {
				v := RoundMS(float64(*g.MemoryInfo.SizeInMiB) / 1024)
				s.VRAMGiB = &v
			}
		}
		// The fast local disk games go on, as AWS sizes it (GB).
		if t.InstanceStorageInfo != nil && t.InstanceStorageInfo.TotalSizeInGB != nil {
			v := *t.InstanceStorageInfo.TotalSizeInGB
			s.StoreGB = &v
		}
		out[string(t.InstanceType)] = s
	}
	return out, nil
}

func (a *AWS) Scores(ctx context.Context, from, itype string, regions []string) (map[string]int, error) {
	c, err := a.ec2(ctx, from)
	if err != nil {
		return nil, err
	}
	o, err := c.GetSpotPlacementScores(ctx, &ec2.GetSpotPlacementScoresInput{
		InstanceTypes: []string{itype}, TargetCapacity: aws.Int32(1), RegionNames: regions})
	if err != nil {
		return nil, err
	}
	out := map[string]int{}
	for _, s := range o.SpotPlacementScores {
		out[aws.ToString(s.Region)] = int(aws.ToInt32(s.Score))
	}
	return out, nil
}

// City is the human name of a region. Cosmetic, and allowed to fail: the
// recursive form of this path pages over thousands of parameters and times out,
// so it is asked one region at a time and only for the shortlist.
func (a *AWS) City(ctx context.Context, from, region string) string {
	cfg, err := awscfg.New(ctx, from)
	if err != nil {
		return ""
	}
	o, err := ssm.NewFromConfig(cfg).GetParameter(ctx, &ssm.GetParameterInput{
		Name: aws.String("/aws/service/global-infrastructure/regions/" + region + "/longName")})
	if err != nil || o.Parameter == nil {
		return ""
	}
	return aws.ToString(o.Parameter.Value)
}

func (a *AWS) Quota(ctx context.Context, region string) (int, int, bool) {
	r, err := a.reader(ctx, region)
	if err != nil {
		return 0, 0, false
	}
	q := r.Quotas_(ctx)
	return q.OnDemand, q.Spot, !q.Unknown
}

func (a *AWS) Offers(ctx context.Context, region string, types []string) ([]string, error) {
	c, err := a.ec2(ctx, region)
	if err != nil {
		return nil, err
	}
	var out []string
	var token *string
	for {
		o, err := c.DescribeInstanceTypeOfferings(ctx, &ec2.DescribeInstanceTypeOfferingsInput{
			LocationType: ec2types.LocationTypeRegion,
			Filters:      []ec2types.Filter{{Name: aws.String("instance-type"), Values: types}}, NextToken: token})
		if err != nil {
			return nil, err
		}
		for _, x := range o.InstanceTypeOfferings {
			out = append(out, string(x.InstanceType))
		}
		if o.NextToken == nil || *o.NextToken == "" {
			return out, nil
		}
		token = o.NextToken
	}
}

func (a *AWS) Spot(ctx context.Context, region string, types []string) (map[string]float64, map[string]float64, error) {
	c, err := a.ec2(ctx, region)
	if err != nil {
		return nil, nil, err
	}
	in := &ec2.DescribeSpotPriceHistoryInput{ProductDescriptions: []string{"Linux/UNIX"}, StartTime: aws.Time(time.Now().Add(-3 * time.Hour))}
	for _, t := range types {
		in.InstanceTypes = append(in.InstanceTypes, ec2types.InstanceType(t))
	}
	lo, hi := map[string]float64{}, map[string]float64{}
	for {
		o, err := c.DescribeSpotPriceHistory(ctx, in)
		if err != nil {
			return nil, nil, err
		}
		for _, p := range o.SpotPriceHistory {
			v, err := strconv.ParseFloat(aws.ToString(p.SpotPrice), 64)
			if err != nil {
				continue
			}
			t := string(p.InstanceType)
			if cur, ok := lo[t]; !ok || v < cur {
				lo[t] = v
			}
			if cur, ok := hi[t]; !ok || v > cur {
				hi[t] = v
			}
		}
		if o.NextToken == nil || *o.NextToken == "" {
			return lo, hi, nil
		}
		in.NextToken = o.NextToken
	}
}

func (a *AWS) OnDemand(ctx context.Context, region, itype string) *float64 {
	return pricing.OnDemandHourly(ctx, a.Products, itype, region)
}
