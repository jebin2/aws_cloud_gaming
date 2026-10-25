// Package testfixture holds fakes for the AWS clients, driven by a Scenario:
// one description of an account, so a test says what exists and every fake
// answers from it. Filters are honoured, so a test that forgets cg's tag finds
// another project's disk and fails - which is the point.
package testfixture

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	budgetstypes "github.com/aws/aws-sdk-go-v2/service/budgets/types"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer"
	cetypes "github.com/aws/aws-sdk-go-v2/service/costexplorer/types"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	fttypes "github.com/aws/aws-sdk-go-v2/service/freetier/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go"
)

// Instance is a box.
type Instance struct {
	ID, State, Type, Lifecycle, AZ, Name string
}

// Volume is a disk with its tags.
type Volume struct {
	ID, State, AZ, Instance string
	GB                      int32
	Created                 time.Time
	Tags                    map[string]string
}

// Image is a saved image and the snapshots behind it.
type Image struct {
	ID        string
	Tags      map[string]string
	Snapshots map[string]int32 // snapshot id -> size
}

// Snapshot is a loose snapshot.
type Snapshot struct {
	ID   string
	GB   int32
	Tags map[string]string
}

// Object is an S3 object.
type Object struct {
	Key  string
	Size int64
}

// Day is one day of Cost Explorer's answer: usage type -> {cost, qty}.
type Day struct {
	Date  string
	Usage map[string][2]string
}

// Scenario is an account.
type Scenario struct {
	Account    string
	Instances  []Instance
	Volumes    []Volume
	Images     []Image
	Snapshots  []Snapshot
	Addresses  int
	KeyPair    bool
	SecGroup   bool
	SpotPrice  string // "" = AWS gives none
	CPUHours   int
	Credits    float64
	NoCredits  bool
	Budget     string // "" = none exists
	Bucket     string
	BucketGone bool // head-bucket says it does not exist
	Denied     bool // head-bucket is refused
	Objects    []Object
	Month      []Day
	Fail       map[string]bool // API names that fail: "DescribeVolumes", "GetCostAndUsage", ...
	Calls      map[string]int
}

type apiError struct{ code, msg string }

func (e apiError) Error() string                 { return e.code + ": " + e.msg }
func (e apiError) ErrorCode() string             { return e.code }
func (e apiError) ErrorMessage() string          { return e.msg }
func (e apiError) ErrorFault() smithy.ErrorFault { return smithy.FaultClient }

func (s *Scenario) hit(name string) error {
	if s.Calls == nil {
		s.Calls = map[string]int{}
	}
	s.Calls[name]++
	if s.Fail[name] {
		return apiError{"InternalError", name + " failed"}
	}
	return nil
}

// match applies EC2-style filters to a tag map and a few named attributes.
func match(filters []ec2types.Filter, attr map[string]string, tags map[string]string) bool {
	for _, f := range filters {
		name := aws.ToString(f.Name)
		var have string
		if strings.HasPrefix(name, "tag:") {
			have = tags[strings.TrimPrefix(name, "tag:")]
		} else {
			have = attr[name]
		}
		hit := false
		for _, v := range f.Values {
			if v == have {
				hit = true
			}
		}
		if !hit {
			return false
		}
	}
	return true
}

// EC2 is the fake EC2 client.
type EC2 struct{ S *Scenario }

func (e EC2) DescribeInstances(_ context.Context, in *ec2.DescribeInstancesInput, _ ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	if err := e.S.hit("DescribeInstances"); err != nil {
		return nil, err
	}
	var out ec2.DescribeInstancesOutput
	for _, i := range e.S.Instances {
		if !match(in.Filters, map[string]string{"instance-state-name": i.State}, map[string]string{"Name": i.Name}) {
			continue
		}
		inst := ec2types.Instance{InstanceId: aws.String(i.ID), InstanceType: ec2types.InstanceType(i.Type),
			State:     &ec2types.InstanceState{Name: ec2types.InstanceStateName(i.State)},
			Placement: &ec2types.Placement{AvailabilityZone: aws.String(i.AZ)}}
		if i.Lifecycle != "" {
			inst.InstanceLifecycle = ec2types.InstanceLifecycleType(i.Lifecycle)
		}
		out.Reservations = append(out.Reservations, ec2types.Reservation{Instances: []ec2types.Instance{inst}})
	}
	return &out, nil
}

func (e EC2) DescribeVolumes(_ context.Context, in *ec2.DescribeVolumesInput, _ ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	if err := e.S.hit("DescribeVolumes"); err != nil {
		return nil, err
	}
	var out ec2.DescribeVolumesOutput
	for _, v := range e.S.Volumes {
		attr := map[string]string{"status": v.State, "attachment.instance-id": v.Instance}
		if !match(in.Filters, attr, v.Tags) {
			continue
		}
		created := v.Created
		out.Volumes = append(out.Volumes, ec2types.Volume{VolumeId: aws.String(v.ID), Size: aws.Int32(v.GB),
			AvailabilityZone: aws.String(v.AZ), CreateTime: &created})
	}
	return &out, nil
}

func (e EC2) DescribeImages(_ context.Context, in *ec2.DescribeImagesInput, _ ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error) {
	if err := e.S.hit("DescribeImages"); err != nil {
		return nil, err
	}
	var out ec2.DescribeImagesOutput
	for _, im := range e.S.Images {
		if !match(in.Filters, nil, im.Tags) {
			continue
		}
		img := ec2types.Image{ImageId: aws.String(im.ID)}
		for id, gb := range im.Snapshots {
			img.BlockDeviceMappings = append(img.BlockDeviceMappings, ec2types.BlockDeviceMapping{
				Ebs: &ec2types.EbsBlockDevice{SnapshotId: aws.String(id), VolumeSize: aws.Int32(gb)}})
		}
		out.Images = append(out.Images, img)
	}
	return &out, nil
}

func (e EC2) DescribeSnapshots(_ context.Context, in *ec2.DescribeSnapshotsInput, _ ...func(*ec2.Options)) (*ec2.DescribeSnapshotsOutput, error) {
	if err := e.S.hit("DescribeSnapshots"); err != nil {
		return nil, err
	}
	var out ec2.DescribeSnapshotsOutput
	for _, s := range e.S.Snapshots {
		if match(in.Filters, nil, s.Tags) {
			out.Snapshots = append(out.Snapshots, ec2types.Snapshot{SnapshotId: aws.String(s.ID), VolumeSize: aws.Int32(s.GB)})
		}
	}
	return &out, nil
}

func (e EC2) DescribeAddresses(context.Context, *ec2.DescribeAddressesInput, ...func(*ec2.Options)) (*ec2.DescribeAddressesOutput, error) {
	if err := e.S.hit("DescribeAddresses"); err != nil {
		return nil, err
	}
	return &ec2.DescribeAddressesOutput{Addresses: make([]ec2types.Address, e.S.Addresses)}, nil
}

func (e EC2) DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error) {
	if err := e.S.hit("DescribeKeyPairs"); err != nil {
		return nil, err
	}
	if !e.S.KeyPair {
		return nil, apiError{"InvalidKeyPair.NotFound", "no such key pair"}
	}
	return &ec2.DescribeKeyPairsOutput{KeyPairs: []ec2types.KeyPairInfo{{}}}, nil
}

func (e EC2) DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error) {
	if err := e.S.hit("DescribeSecurityGroups"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeSecurityGroupsOutput{}
	if e.S.SecGroup {
		out.SecurityGroups = []ec2types.SecurityGroup{{}}
	}
	return out, nil
}

func (e EC2) DescribeSpotPriceHistory(context.Context, *ec2.DescribeSpotPriceHistoryInput, ...func(*ec2.Options)) (*ec2.DescribeSpotPriceHistoryOutput, error) {
	if err := e.S.hit("DescribeSpotPriceHistory"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeSpotPriceHistoryOutput{}
	if e.S.SpotPrice != "" {
		out.SpotPriceHistory = []ec2types.SpotPrice{{SpotPrice: aws.String(e.S.SpotPrice)}}
	}
	return out, nil
}

// CloudWatch is the fake CloudWatch client.
type CloudWatch struct{ S *Scenario }

func (c CloudWatch) GetMetricStatistics(context.Context, *cloudwatch.GetMetricStatisticsInput, ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricStatisticsOutput, error) {
	if err := c.S.hit("GetMetricStatistics"); err != nil {
		return nil, err
	}
	return &cloudwatch.GetMetricStatisticsOutput{Datapoints: make([]cwtypes.Datapoint, c.S.CPUHours)}, nil
}

// CE is the fake Cost Explorer client.
type CE struct{ S *Scenario }

func (c CE) GetCostAndUsage(_ context.Context, _ *costexplorer.GetCostAndUsageInput, _ ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error) {
	if err := c.S.hit("GetCostAndUsage"); err != nil {
		return nil, err
	}
	out := &costexplorer.GetCostAndUsageOutput{}
	for _, d := range c.S.Month {
		r := cetypes.ResultByTime{TimePeriod: &cetypes.DateInterval{Start: aws.String(d.Date)}}
		for u, cq := range d.Usage {
			r.Groups = append(r.Groups, cetypes.Group{Keys: []string{u}, Metrics: map[string]cetypes.MetricValue{
				"UnblendedCost": {Amount: aws.String(cq[0])}, "UsageQuantity": {Amount: aws.String(cq[1])}}})
		}
		out.ResultsByTime = append(out.ResultsByTime, r)
	}
	return out, nil
}

// Budgets is the fake Budgets client.
type Budgets struct{ S *Scenario }

func (b Budgets) DescribeBudget(context.Context, *budgets.DescribeBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeBudgetOutput, error) {
	if err := b.S.hit("DescribeBudget"); err != nil {
		return nil, err
	}
	if b.S.Budget == "" {
		return nil, &budgetstypes.NotFoundException{Message: aws.String("no budget")}
	}
	return &budgets.DescribeBudgetOutput{Budget: &budgetstypes.Budget{
		BudgetLimit: &budgetstypes.Spend{Amount: aws.String(b.S.Budget), Unit: aws.String("USD")}}}, nil
}

// FreeTier is the fake Free Tier client.
type FreeTier struct{ S *Scenario }

func (f FreeTier) GetAccountPlanState(context.Context, *freetier.GetAccountPlanStateInput, ...func(*freetier.Options)) (*freetier.GetAccountPlanStateOutput, error) {
	if err := f.S.hit("GetAccountPlanState"); err != nil {
		return nil, err
	}
	out := &freetier.GetAccountPlanStateOutput{}
	if !f.S.NoCredits {
		out.AccountPlanRemainingCredits = &fttypes.MonetaryAmount{Amount: f.S.Credits}
	}
	return out, nil
}

// S3 is the fake S3 client.
type S3 struct{ S *Scenario }

func (s S3) HeadBucket(context.Context, *s3.HeadBucketInput, ...func(*s3.Options)) (*s3.HeadBucketOutput, error) {
	if err := s.S.hit("HeadBucket"); err != nil {
		return nil, err
	}
	switch {
	case s.S.BucketGone:
		return nil, apiError{"NotFound", "Not Found"}
	case s.S.Denied:
		return nil, apiError{"Forbidden", "Forbidden"}
	}
	return &s3.HeadBucketOutput{}, nil
}

func (s S3) ListObjectsV2(_ context.Context, in *s3.ListObjectsV2Input, _ ...func(*s3.Options)) (*s3.ListObjectsV2Output, error) {
	if err := s.S.hit("ListObjectsV2"); err != nil {
		return nil, err
	}
	out := &s3.ListObjectsV2Output{}
	for _, o := range s.S.Objects {
		if strings.HasPrefix(o.Key, aws.ToString(in.Prefix)) {
			out.Contents = append(out.Contents, s3object(o))
		}
	}
	return out, nil
}

// STS is the fake STS client.
type STS struct{ S *Scenario }

func (s STS) GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error) {
	if err := s.S.hit("GetCallerIdentity"); err != nil {
		return nil, errors.New("The security token included in the request is invalid")
	}
	return &sts.GetCallerIdentityOutput{Account: aws.String(s.S.Account)}, nil
}
