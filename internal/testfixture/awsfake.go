// Package testfixture holds fakes for the AWS clients, driven by a Scenario:
// one description of an account, so a test says what exists and every fake
// answers from it. Filters are honoured, so a test that forgets cg's tag finds
// another project's disk and fails - which is the point.
package testfixture

import (
	"context"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	budgetstypes "github.com/aws/aws-sdk-go-v2/service/budgets/types"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	logtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs/types"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer"
	cetypes "github.com/aws/aws-sdk-go-v2/service/costexplorer/types"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/eventbridge"
	ebtypes "github.com/aws/aws-sdk-go-v2/service/eventbridge/types"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	fttypes "github.com/aws/aws-sdk-go-v2/service/freetier/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	lambdatypes "github.com/aws/aws-sdk-go-v2/service/lambda/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"
	sqtypes "github.com/aws/aws-sdk-go-v2/service/servicequotas/types"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go"
)

// Instance is a box.
type Instance struct {
	ID, State, Type, Lifecycle, AZ, Name string
	PublicIP, RootVolume                 string
	Launched                             time.Time
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
	Key      string
	Size     int64
	Modified time.Time
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

	// For status.
	Plan                  string
	VCPUs, MemMiB, GPUMem int32
	GPU                   string
	QuotaOnDemand         float64
	QuotaSpot             float64
	Roles                 map[string]bool
	Notifications         int
	LogEvents             []LogEvent
	SpotRequest           string // the state of the spot request of the box
	SGID                  string
	Ingress               [][3]string // protocol, port, cidr
	KeyName               string
	Spent                 string
	ShutdownBehavior      string

	// For the watchdog.
	WD WatchdogState

	mu sync.Mutex // the watchdog reads concurrently
}

// WatchdogState is the deployed cloud watchdog.
type WatchdogState struct {
	Installed                  bool
	CodeSHA, State, Update     string
	Role, Description, Runtime string
	RuleState, Schedule        string
	Target                     string
	StateRuleState             string
	StateTarget                string
	Permission                 string
	PolicyJSON                 string
	NoLogGroup                 bool
}

// LogEvent is a line in the watchdog's log.
type LogEvent struct {
	At  time.Time
	Msg string
}

type apiError struct{ code, msg string }

func (e apiError) Error() string                 { return e.code + ": " + e.msg }
func (e apiError) ErrorCode() string             { return e.code }
func (e apiError) ErrorMessage() string          { return e.msg }
func (e apiError) ErrorFault() smithy.ErrorFault { return smithy.FaultClient }

func (s *Scenario) hit(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
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
		if i.PublicIP != "" {
			inst.PublicIpAddress = aws.String(i.PublicIP)
		}
		if !i.Launched.IsZero() {
			t := i.Launched
			inst.LaunchTime = &t
		}
		if i.RootVolume != "" {
			inst.BlockDeviceMappings = []ec2types.InstanceBlockDeviceMapping{{Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String(i.RootVolume)}}}
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
		if len(in.VolumeIds) > 0 {
			hit := false
			for _, id := range in.VolumeIds {
				hit = hit || id == v.ID
			}
			if !hit {
				continue
			}
		}
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
	return &ec2.DescribeKeyPairsOutput{KeyPairs: []ec2types.KeyPairInfo{{KeyName: aws.String(e.S.KeyName)}}}, nil
}

func (e EC2) DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error) {
	if err := e.S.hit("DescribeSecurityGroups"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeSecurityGroupsOutput{}
	if e.S.SecGroup {
		sg := ec2types.SecurityGroup{GroupId: aws.String(e.S.SGID)}
		for _, p := range e.S.Ingress {
			port, _ := strconv.Atoi(p[1])
			sg.IpPermissions = append(sg.IpPermissions, ec2types.IpPermission{IpProtocol: aws.String(p[0]), FromPort: aws.Int32(int32(port)),
				IpRanges: []ec2types.IpRange{{CidrIp: aws.String(p[2])}}})
		}
		out.SecurityGroups = []ec2types.SecurityGroup{sg}
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

func (e EC2) DescribeInstanceTypes(context.Context, *ec2.DescribeInstanceTypesInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error) {
	if err := e.S.hit("DescribeInstanceTypes"); err != nil {
		return nil, err
	}
	t := ec2types.InstanceTypeInfo{
		VCpuInfo:   &ec2types.VCpuInfo{DefaultVCpus: aws.Int32(e.S.VCPUs)},
		MemoryInfo: &ec2types.MemoryInfo{SizeInMiB: aws.Int64(int64(e.S.MemMiB))},
		GpuInfo: &ec2types.GpuInfo{Gpus: []ec2types.GpuDeviceInfo{{Name: aws.String(e.S.GPU), Count: aws.Int32(1),
			MemoryInfo: &ec2types.GpuDeviceMemoryInfo{SizeInMiB: aws.Int32(e.S.GPUMem)}}}},
	}
	return &ec2.DescribeInstanceTypesOutput{InstanceTypes: []ec2types.InstanceTypeInfo{t}}, nil
}

func (e EC2) DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error) {
	if err := e.S.hit("DescribeSpotInstanceRequests"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeSpotInstanceRequestsOutput{}
	if e.S.SpotRequest != "" {
		out.SpotInstanceRequests = []ec2types.SpotInstanceRequest{{State: ec2types.SpotInstanceState(e.S.SpotRequest)}}
	}
	return out, nil
}

func (e EC2) DescribeInstanceAttribute(context.Context, *ec2.DescribeInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceAttributeOutput, error) {
	if err := e.S.hit("DescribeInstanceAttribute"); err != nil {
		return nil, err
	}
	return &ec2.DescribeInstanceAttributeOutput{InstanceInitiatedShutdownBehavior: &ec2types.AttributeValue{Value: aws.String(e.S.ShutdownBehavior)}}, nil
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
	bud := &budgetstypes.Budget{BudgetLimit: &budgetstypes.Spend{Amount: aws.String(b.S.Budget), Unit: aws.String("USD")}}
	if b.S.Spent != "" {
		bud.CalculatedSpend = &budgetstypes.CalculatedSpend{ActualSpend: &budgetstypes.Spend{Amount: aws.String(b.S.Spent), Unit: aws.String("USD")}}
	}
	return &budgets.DescribeBudgetOutput{Budget: bud}, nil
}

func (b Budgets) DescribeNotificationsForBudget(context.Context, *budgets.DescribeNotificationsForBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeNotificationsForBudgetOutput, error) {
	if err := b.S.hit("DescribeNotificationsForBudget"); err != nil {
		return nil, err
	}
	return &budgets.DescribeNotificationsForBudgetOutput{Notifications: make([]budgetstypes.Notification, b.S.Notifications)}, nil
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
	out.AccountPlanType = fttypes.AccountPlanType(f.S.Plan)
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

// Quotas is the fake Service Quotas client.
type Quotas struct{ S *Scenario }

func (q Quotas) GetServiceQuota(_ context.Context, in *servicequotas.GetServiceQuotaInput, _ ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error) {
	if err := q.S.hit("GetServiceQuota"); err != nil {
		return nil, err
	}
	v := q.S.QuotaSpot
	if aws.ToString(in.QuotaCode) == "L-DB2E81BA" {
		v = q.S.QuotaOnDemand
	}
	return &servicequotas.GetServiceQuotaOutput{Quota: &sqtypes.ServiceQuota{Value: aws.Float64(v)}}, nil
}

// IAM is the fake IAM client.
type IAM struct{ S *Scenario }

func (i IAM) GetRole(_ context.Context, in *iam.GetRoleInput, _ ...func(*iam.Options)) (*iam.GetRoleOutput, error) {
	if err := i.S.hit("GetRole"); err != nil {
		return nil, err
	}
	if !i.S.Roles[aws.ToString(in.RoleName)] {
		return nil, apiError{"NoSuchEntity", "The role cannot be found"}
	}
	return &iam.GetRoleOutput{}, nil
}

// Logs is the fake CloudWatch Logs client.
type Logs struct{ S *Scenario }

func (l Logs) FilterLogEvents(_ context.Context, in *cloudwatchlogs.FilterLogEventsInput, _ ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.FilterLogEventsOutput, error) {
	if err := l.S.hit("FilterLogEvents"); err != nil {
		return nil, err
	}
	if l.S.WD.NoLogGroup {
		return nil, apiError{"ResourceNotFoundException", "The specified log group does not exist"}
	}
	pattern := strings.Trim(aws.ToString(in.FilterPattern), `"`)
	out := &cloudwatchlogs.FilterLogEventsOutput{}
	for _, e := range l.S.LogEvents {
		if !strings.Contains(e.Msg, pattern) || (in.StartTime != nil && e.At.UnixMilli() < *in.StartTime) {
			continue
		}
		out.Events = append(out.Events, logtypes.FilteredLogEvent{Message: aws.String(e.Msg), Timestamp: aws.Int64(e.At.UnixMilli())})
	}
	return out, nil
}

// Lambda is the fake Lambda client.
type Lambda struct{ S *Scenario }

func (l Lambda) GetFunctionConfiguration(context.Context, *lambda.GetFunctionConfigurationInput, ...func(*lambda.Options)) (*lambda.GetFunctionConfigurationOutput, error) {
	if err := l.S.hit("GetFunctionConfiguration"); err != nil {
		return nil, err
	}
	w := l.S.WD
	if !w.Installed {
		return nil, apiError{"ResourceNotFoundException", "Function not found"}
	}
	return &lambda.GetFunctionConfigurationOutput{CodeSha256: aws.String(w.CodeSHA), State: lambdatypes.State(w.State),
		LastUpdateStatus: lambdatypes.LastUpdateStatus(w.Update), Role: aws.String(w.Role), Description: aws.String(w.Description),
		Runtime: lambdatypes.Runtime(w.Runtime)}, nil
}

func (l Lambda) GetPolicy(context.Context, *lambda.GetPolicyInput, ...func(*lambda.Options)) (*lambda.GetPolicyOutput, error) {
	if err := l.S.hit("GetPolicy"); err != nil {
		return nil, err
	}
	return &lambda.GetPolicyOutput{Policy: aws.String(l.S.WD.Permission)}, nil
}

// Events is the fake EventBridge client.
type Events struct{ S *Scenario }

func (e Events) DescribeRule(_ context.Context, in *eventbridge.DescribeRuleInput, _ ...func(*eventbridge.Options)) (*eventbridge.DescribeRuleOutput, error) {
	if err := e.S.hit("DescribeRule"); err != nil {
		return nil, err
	}
	w := e.S.WD
	if strings.HasSuffix(aws.ToString(in.Name), "-state") {
		if w.StateRuleState == "" {
			return nil, apiError{"ResourceNotFoundException", "no rule"}
		}
		return &eventbridge.DescribeRuleOutput{State: ebtypes.RuleState(w.StateRuleState)}, nil
	}
	if w.RuleState == "" {
		return nil, apiError{"ResourceNotFoundException", "no rule"}
	}
	return &eventbridge.DescribeRuleOutput{State: ebtypes.RuleState(w.RuleState), ScheduleExpression: aws.String(w.Schedule)}, nil
}

func (e Events) ListTargetsByRule(_ context.Context, in *eventbridge.ListTargetsByRuleInput, _ ...func(*eventbridge.Options)) (*eventbridge.ListTargetsByRuleOutput, error) {
	if err := e.S.hit("ListTargetsByRule"); err != nil {
		return nil, err
	}
	arn := e.S.WD.Target
	if strings.HasSuffix(aws.ToString(in.Rule), "-state") {
		arn = e.S.WD.StateTarget
	}
	if arn == "" {
		return &eventbridge.ListTargetsByRuleOutput{}, nil
	}
	return &eventbridge.ListTargetsByRuleOutput{Targets: []ebtypes.Target{{Arn: aws.String(arn)}}}, nil
}

// RolePolicies is the fake IAM role-policy reader; IAM above has GetRole.
type RolePolicies struct{ S *Scenario }

func (r RolePolicies) GetRolePolicy(context.Context, *iam.GetRolePolicyInput, ...func(*iam.Options)) (*iam.GetRolePolicyOutput, error) {
	if err := r.S.hit("GetRolePolicy"); err != nil {
		return nil, err
	}
	return &iam.GetRolePolicyOutput{PolicyDocument: aws.String(url.QueryEscape(r.S.WD.PolicyJSON))}, nil
}
