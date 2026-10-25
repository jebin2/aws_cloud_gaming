package costfacts

import (
	"context"
	"errors"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	budgetstypes "github.com/aws/aws-sdk-go-v2/service/budgets/types"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer"
	cetypes "github.com/aws/aws-sdk-go-v2/service/costexplorer/types"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/costdaily"
)

// The parts of each service client cost uses; the SDK clients satisfy them.
type (
	CloudWatchAPI interface {
		GetMetricStatistics(context.Context, *cloudwatch.GetMetricStatisticsInput, ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricStatisticsOutput, error)
	}
	CostExplorerAPI interface {
		GetCostAndUsage(context.Context, *costexplorer.GetCostAndUsageInput, ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error)
	}
	BudgetsAPI interface {
		DescribeBudget(context.Context, *budgets.DescribeBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeBudgetOutput, error)
	}
	FreeTierAPI interface {
		GetAccountPlanState(context.Context, *freetier.GetAccountPlanStateInput, ...func(*freetier.Options)) (*freetier.GetAccountPlanStateOutput, error)
	}
	S3API interface {
		HeadBucket(context.Context, *s3.HeadBucketInput, ...func(*s3.Options)) (*s3.HeadBucketOutput, error)
		ListObjectsV2(context.Context, *s3.ListObjectsV2Input, ...func(*s3.Options)) (*s3.ListObjectsV2Output, error)
	}
	STSAPI interface {
		GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error)
	}
)

// Gatherer reads the facts. Host is the box's name, which is also the value of
// the ownership tag.
type Gatherer struct {
	EC2        EC2API
	CloudWatch CloudWatchAPI
	CE         CostExplorerAPI // us-east-1, whatever the region
	Budgets    BudgetsAPI
	FreeTier   FreeTierAPI // us-east-1
	S3         S3API
	STS        STSAPI

	Host   string
	TagKey string
	Bucket string // the archive bucket, "" if none is known
	EnvID  string // GAME_INSTANCE_ID, which CloudWatch can still count after a destroy
	Now    func() time.Time
}

// Archive is the games kept in S3: the games only. steam/ also holds the 22 KB
// Steam login, which made an archive with no games in it read as "0.0 GB".
type Archive struct {
	Objects int64
	Bytes   int64
}

// ArchivePrefix is where the games are.
const ArchivePrefix = "steam/steamapps/"

// Facts is everything read, each saying whether it could be.
type Facts struct {
	Account   Known[string]
	Instance  Known[*Instance]
	Volumes   Known[[]Volume] // the box's attached disks and cg's leftovers
	Images    Known[[]Image]
	Snapshots Known[[]Snapshot] // the snapshots behind cg's images, and cg's loose ones
	EIPs      Known[int]
	KeyPair   Known[bool]
	SecGroup  Known[bool]
	Legacy    Known[*LegacyVolume]
	Budget    Known[*float64]
	Credits   Known[float64]
	Hours     Known[int]
	Archive   Known[Archive]
	Bucket    BucketStatus
	Month     Known[[]costdaily.Day]
	SpotPrice *float64 // set only for a spot box, and only if AWS said
}

// DiskGB is the size of every disk counted once.
func (f Facts) DiskGB() Known[float64] {
	if !f.Volumes.OK {
		return Known[float64]{}
	}
	var t float64
	seen := map[string]bool{}
	for _, v := range f.Volumes.V {
		if !seen[v.ID] {
			seen[v.ID] = true
			t += v.GB
		}
	}
	return ok(t)
}

// SnapshotGB is the size each snapshot was taken from, counted once: the most
// they can bill.
func (f Facts) SnapshotGB() Known[float64] {
	if !f.Snapshots.OK {
		return Known[float64]{}
	}
	var t float64
	seen := map[string]bool{}
	for _, s := range f.Snapshots.V {
		if !seen[s.ID] {
			seen[s.ID] = true
			t += s.GB
		}
	}
	return ok(t)
}

// Gather reads everything. An error that stops one fact leaves it unknown and
// the rest are still read; only an account that cannot be identified at all
// stops it, with AWS's own refusal.
func (g *Gatherer) Gather(ctx context.Context) (Facts, error) {
	if g.Now == nil {
		g.Now = time.Now
	}
	if g.TagKey == "" {
		g.TagKey = "cg:host"
	}
	var f Facts
	// AWS asked first, and its refusal said: a key AWS rejects must not end the
	// report silently at the first read.
	id, err := g.STS.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		return f, &AWSRefused{err}
	}
	f.Account = ok(aws.ToString(id.Account))

	f.Instance = g.instance(ctx)
	// Every volume and snapshot bills, attached or not - orphans are the classic
	// way to keep paying for a machine you think you deleted. cg's own: the box's
	// disks and cg's leftovers, cg's images and the snapshots behind them, and
	// cg's tagged snapshots.
	f.Volumes = g.collectVolumes(ctx, f.Instance)
	if imgs, err := g.images(ctx); err == nil {
		f.Images = ok(imgs)
		if loose, err := g.taggedSnapshots(ctx); err == nil {
			var all []Snapshot
			for _, im := range imgs {
				all = append(all, im.Snapshots...)
			}
			f.Snapshots = ok(append(all, loose...))
		}
	}
	f.EIPs = g.addresses(ctx)
	f.KeyPair = g.keyPair(ctx)
	f.SecGroup = g.securityGroup(ctx)
	f.Legacy = g.legacyGames(ctx)
	f.Budget = g.budget(ctx, f.Account.V)

	if f.Instance.OK && f.Instance.V != nil && f.Instance.V.Lifecycle == "spot" {
		f.SpotPrice = g.spotPrice(ctx, *f.Instance.V, g.Now().UTC())
	}
	f.Hours = g.hours(ctx, f.Instance)
	f.Credits = g.credits(ctx)
	f.Month = g.month(ctx)
	f.Bucket = g.bucketStatus(ctx)
	if f.Bucket.State == BucketReadable {
		f.Archive = g.archive(ctx)
	}
	return f, nil
}

// AWSRefused is AWS saying no before anything could be read.
type AWSRefused struct{ Err error }

func (e *AWSRefused) Error() string { return "AWS did not answer: " + e.Err.Error() }
func (e *AWSRefused) Unwrap() error { return e.Err }

func (g *Gatherer) collectVolumes(ctx context.Context, inst Known[*Instance]) Known[[]Volume] {
	var all []Volume
	if inst.OK && inst.V != nil {
		attached, err := g.volumes(ctx, []ec2types.Filter{filter("attachment.instance-id", inst.V.ID)})
		if err != nil {
			return Known[[]Volume]{}
		}
		all = attached
	} else if !inst.OK {
		return Known[[]Volume]{}
	}
	owned, err := g.ownedVolumes(ctx, true)
	if err != nil {
		return Known[[]Volume]{}
	}
	return ok(append(all, owned...))
}

func (g *Gatherer) budget(ctx context.Context, account string) Known[*float64] {
	r, err := g.Budgets.DescribeBudget(ctx, &budgets.DescribeBudgetInput{
		AccountId: aws.String(account), BudgetName: aws.String(g.Host + "-monthly")})
	if err != nil {
		var nf *budgetstypes.NotFoundException
		if errors.As(err, &nf) {
			return ok[*float64](nil)
		}
		return Known[*float64]{}
	}
	if r.Budget == nil || r.Budget.BudgetLimit == nil {
		return ok[*float64](nil)
	}
	return ok(parseFloat(aws.ToString(r.Budget.BudgetLimit.Amount)))
}

// hours counts the hourly CPU datapoints of the instance, which exist only for
// the hours it was up: runtime with none of the day's billing lag. A terminated
// instance keeps its metrics, so this still reports the month - but only the
// one instance, so across rebuilds it undercounts, which the report says.
func (g *Gatherer) hours(ctx context.Context, inst Known[*Instance]) Known[int] {
	id := g.EnvID
	if inst.OK && inst.V != nil {
		id = inst.V.ID
	}
	if id == "" {
		return ok(0)
	}
	now := g.Now().UTC()
	start := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	r, err := g.CloudWatch.GetMetricStatistics(ctx, &cloudwatch.GetMetricStatisticsInput{
		Namespace: aws.String("AWS/EC2"), MetricName: aws.String("CPUUtilization"),
		Dimensions: []cwtypes.Dimension{{Name: aws.String("InstanceId"), Value: aws.String(id)}},
		StartTime:  aws.Time(start), EndTime: aws.Time(now),
		Period: aws.Int32(3600), Statistics: []cwtypes.Statistic{cwtypes.StatisticAverage},
	})
	if err != nil {
		return Known[int]{}
	}
	return ok(len(r.Datapoints))
}

func (g *Gatherer) credits(ctx context.Context) Known[float64] {
	r, err := g.FreeTier.GetAccountPlanState(ctx, &freetier.GetAccountPlanStateInput{})
	if err != nil || r.AccountPlanRemainingCredits == nil {
		return Known[float64]{}
	}
	v := r.AccountPlanRemainingCredits.Amount
	return ok(v)
}

// month is the one Cost Explorer call, day by day: the table, the summary and
// the JSON are all drawn from it, because Cost Explorer bills $0.01 a request.
func (g *Gatherer) month(ctx context.Context) Known[[]costdaily.Day] {
	now := g.Now().UTC()
	start := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	end := now.AddDate(0, 0, 1)
	in := &costexplorer.GetCostAndUsageInput{
		TimePeriod: &cetypes.DateInterval{
			Start: aws.String(start.Format("2006-01-02")), End: aws.String(end.Format("2006-01-02"))},
		Granularity: cetypes.GranularityDaily,
		Metrics:     []string{"UnblendedCost", "UsageQuantity"},
		Filter: &cetypes.Expression{Dimensions: &cetypes.DimensionValues{
			Key: cetypes.DimensionRecordType, Values: []string{"Usage"}}},
		GroupBy: []cetypes.GroupDefinition{{Type: cetypes.GroupDefinitionTypeDimension, Key: aws.String("USAGE_TYPE")}},
	}
	days := []costdaily.Day{}
	for {
		r, err := g.CE.GetCostAndUsage(ctx, in)
		if err != nil {
			return Known[[]costdaily.Day]{}
		}
		for _, d := range r.ResultsByTime {
			day := costdaily.Day{G: []costdaily.Group{}}
			if d.TimePeriod != nil {
				day.D = aws.ToString(d.TimePeriod.Start)
			}
			for _, gr := range d.Groups {
				if len(gr.Keys) == 0 {
					continue
				}
				c := gr.Metrics["UnblendedCost"]
				q := gr.Metrics["UsageQuantity"]
				day.G = append(day.G, costdaily.Group{U: gr.Keys[0],
					C: costdaily.Money(num(aws.ToString(c.Amount))), Q: costdaily.Money(num(aws.ToString(q.Amount)))})
			}
			days = append(days, day)
		}
		if r.NextPageToken == nil || *r.NextPageToken == "" {
			return ok(days)
		}
		in.NextPageToken = r.NextPageToken
	}
}

func num(s string) float64 {
	if v := parseFloat(s); v != nil {
		return *v
	}
	return 0
}

// archive sums the games in the bucket. A listing that fails is unknown, not an
// archive of zero games.
func (g *Gatherer) archive(ctx context.Context) Known[Archive] {
	var a Archive
	var token *string
	for {
		r, err := g.S3.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
			Bucket: aws.String(g.Bucket), Prefix: aws.String(ArchivePrefix), ContinuationToken: token})
		if err != nil {
			return Known[Archive]{}
		}
		for _, o := range r.Contents {
			a.Objects++
			a.Bytes += aws.ToInt64(o.Size)
		}
		if !aws.ToBool(r.IsTruncated) {
			return ok(a)
		}
		token = r.NextContinuationToken
	}
}

// BucketState is whether the archive bucket could be read at all. A listing
// that fails prints nothing, which read as EMPTY - the reassurance the line
// exists to give, given when it was false.
type BucketState int

const (
	BucketUnset BucketState = iota
	BucketMissing
	BucketUnreadable
	BucketReadable
)

// BucketStatus is the state and, when unreadable, AWS's reason.
type BucketStatus struct {
	Name   string
	State  BucketState
	Reason string
}

func (g *Gatherer) bucketStatus(ctx context.Context) BucketStatus {
	b := BucketStatus{Name: g.Bucket}
	if g.Bucket == "" {
		return b
	}
	_, err := g.S3.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(g.Bucket)})
	switch {
	case err == nil:
		b.State = BucketReadable
	case code(err) == "NotFound" || code(err) == "NoSuchBucket" || code(err) == "404":
		b.State = BucketMissing
	default:
		b.State, b.Reason = BucketUnreadable, err.Error()
	}
	return b
}
