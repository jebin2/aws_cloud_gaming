// Package status is `cg status`: what exists in the account and on this
// computer, and whether every safeguard is on. One round of queries fills the
// facts; the report and --json both render from them, so an app reading the
// JSON is reading exactly what the report shows and the two cannot drift.
//
// A probe that fails is a fact, not a failure: it is unknown, never empty. A
// key AWS rejects must not end this report at the first read, and it must not
// print "none" and "0" for an account nobody looked at.
package status

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	budgetstypes "github.com/aws/aws-sdk-go-v2/service/budgets/types"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go"

	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
	"github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

// Known is a value and whether it could be read; the same type cost uses.
type Known[T any] = costfacts.Known[T]

func ok[T any](v T) Known[T] { return Known[T]{V: v, OK: true} }

// The AWS clients, as far as status uses them; the SDK clients satisfy them.
type (
	EC2API interface {
		DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
		DescribeInstanceTypes(context.Context, *ec2.DescribeInstanceTypesInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error)
		DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error)
		DescribeSnapshots(context.Context, *ec2.DescribeSnapshotsInput, ...func(*ec2.Options)) (*ec2.DescribeSnapshotsOutput, error)
		DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
		DescribeAddresses(context.Context, *ec2.DescribeAddressesInput, ...func(*ec2.Options)) (*ec2.DescribeAddressesOutput, error)
		DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error)
		DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error)
		DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error)
	}
	QuotasAPI interface {
		GetServiceQuota(context.Context, *servicequotas.GetServiceQuotaInput, ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error)
	}
	BudgetsAPI interface {
		DescribeBudget(context.Context, *budgets.DescribeBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeBudgetOutput, error)
		DescribeNotificationsForBudget(context.Context, *budgets.DescribeNotificationsForBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeNotificationsForBudgetOutput, error)
	}
	FreeTierAPI interface {
		GetAccountPlanState(context.Context, *freetier.GetAccountPlanStateInput, ...func(*freetier.Options)) (*freetier.GetAccountPlanStateOutput, error)
	}
	S3API interface {
		ListObjectsV2(context.Context, *s3.ListObjectsV2Input, ...func(*s3.Options)) (*s3.ListObjectsV2Output, error)
	}
	STSAPI interface {
		GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error)
	}
	IAMAPI interface {
		GetRole(context.Context, *iam.GetRoleInput, ...func(*iam.Options)) (*iam.GetRoleOutput, error)
	}
	LogsAPI = watchdog.LogsAPI
)

// Gatherer reads the facts.
type Gatherer struct {
	EC2      EC2API
	Quotas   QuotasAPI // in the working region
	Budgets  BudgetsAPI
	FreeTier FreeTierAPI
	S3       S3API
	STS      STSAPI
	IAM      IAMAPI
	Logs     LogsAPI
	Runner   local.Runner
	Probe    session.Probe

	Host, Node, Region, Type string
	Bucket                   string
	EnvInstanceID            string
	Home                     string // for ~/.ssh
	CacheDir                 string // XDG_CACHE_HOME/cg
	LockFile                 string
	ExpiryDays               int
	Now                      func() time.Time

	AuthKey bool // a Tailscale auth key is set in .env; never its value
}

// Box is the machine.
type Box struct {
	ID, State, Type, PublicIP, Lifecycle, AZ string
	Launched                                 time.Time
	DiskGB                                   Known[int]
	Built                                    bool
	Ready                                    Known[bool] // unknown when it could not be asked
}

// Archive is the games in S3 and the Steam login beside them.
type Archive struct {
	Bucket  string
	Err     string // why the listing failed; the archive is then unknown
	Objects int64
	Bytes   int64
	USD     *float64
	Login   struct {
		Present Known[bool]
		Bytes   int64
		Pushed  string
	}
}

// Facts is everything status reports.
type Facts struct {
	AccountID    string // "" when no account could be identified
	Plan         string // "?" when AWS would not say
	Credits      string
	ErrorCause   string // "no-key" or "rejected"; empty when AWS answered
	ErrorMessage string

	Spec struct {
		VCPUs        Known[int]
		MemoryMiB    Known[int]
		GPU          string
		GPUMemoryMiB Known[int]
	}
	QuotaOnDemand, QuotaSpot Known[float64]

	Box       Known[*Box]
	Volumes   Known[float64] // every volume in the region, GB
	Snapshots Known[int]
	SnapGB    Known[float64]
	Images    Known[int]
	EIPs      Known[int]
	KeyPair   Known[string] // "none" or the name
	SecGroup  Known[string] // "none" or the id
	Inbound   []string      // "udp/41641 from 0.0.0.0/0"
	Legacy    Known[*struct {
		ID, AZ string
		GB     float64
	}]
	Archive    Archive
	Decision   string
	ExpiryDays int

	BudgetLimit, BudgetSpent Known[float64]
	BudgetExists             Known[bool]
	BudgetAlerts             Known[int]

	RoleBox, RoleWatchdog Known[bool]
	Stranded              *Stranded // a stopped spot box that can never start again

	Session                      Known[session.Lock]
	authKey                      bool // a Tailscale auth key is set in .env
	Tailscale, Moonlight, SSHKey bool
	Node                         struct {
		Name, IP string
		Online   bool
		Found    bool
	}
}

func code(err error) string {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		return ae.ErrorCode()
	}
	return ""
}

func f(name string, values ...string) ec2types.Filter {
	return ec2types.Filter{Name: aws.String(name), Values: values}
}

// Gather reads everything. Nothing stops it: each fact that cannot be read is
// unknown and the rest are still read.
func (g *Gatherer) Gather(ctx context.Context) Facts {
	if g.Now == nil {
		g.Now = time.Now
	}
	var out Facts
	out.ExpiryDays = g.ExpiryDays
	out.authKey = g.AuthKey

	id, err := g.STS.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		out.AccountID = ""
		out.ErrorCause, out.ErrorMessage = "rejected", "AWS rejected this access key."
		if strings.Contains(err.Error(), "failed to refresh cached credentials") || strings.Contains(err.Error(), "NoCredentialProviders") {
			out.ErrorCause, out.ErrorMessage = "no-key", "No AWS access key was found on this computer."
		}
	} else {
		out.AccountID = aws.ToString(id.Account)
	}
	out.Plan, out.Credits = "?", "?"
	if p, err := g.FreeTier.GetAccountPlanState(ctx, &freetier.GetAccountPlanStateInput{}); err == nil {
		out.Plan = string(p.AccountPlanType)
		if p.AccountPlanRemainingCredits != nil {
			out.Credits = strconv.FormatFloat(p.AccountPlanRemainingCredits.Amount, 'f', -1, 64)
		}
	}

	// One call answers the quota question and describes the machine the Build
	// screen shows - vCPU, memory, GPU - so nothing about the type is hardcoded.
	if r, err := g.EC2.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{
		InstanceTypes: []ec2types.InstanceType{ec2types.InstanceType(g.Type)}}); err == nil && len(r.InstanceTypes) > 0 {
		t := r.InstanceTypes[0]
		if t.VCpuInfo != nil && t.VCpuInfo.DefaultVCpus != nil {
			out.Spec.VCPUs = ok(int(*t.VCpuInfo.DefaultVCpus))
		}
		if t.MemoryInfo != nil && t.MemoryInfo.SizeInMiB != nil {
			out.Spec.MemoryMiB = ok(int(*t.MemoryInfo.SizeInMiB))
		}
		if t.GpuInfo != nil && len(t.GpuInfo.Gpus) > 0 {
			out.Spec.GPU = aws.ToString(t.GpuInfo.Gpus[0].Name)
			if m := t.GpuInfo.Gpus[0].MemoryInfo; m != nil && m.SizeInMiB != nil {
				out.Spec.GPUMemoryMiB = ok(int(*m.SizeInMiB))
			}
		}
	}
	out.QuotaOnDemand = g.quota(ctx, "L-DB2E81BA")
	out.QuotaSpot = g.quota(ctx, "L-3819A6DF")

	out.Box = g.box(ctx)
	out.Volumes = g.volumesGB(ctx)
	out.Snapshots, out.SnapGB = g.snapshots(ctx)
	out.Images = g.images(ctx)
	if r, err := g.EC2.DescribeAddresses(ctx, &ec2.DescribeAddressesInput{}); err == nil {
		out.EIPs = ok(len(r.Addresses))
	}
	out.KeyPair = g.keyPair(ctx)
	out.SecGroup, out.Inbound = g.securityGroup(ctx)
	out.Legacy = g.legacy(ctx)
	out.Archive = g.archive(ctx)
	out.Decision = watchdog.ArchiveDecision(ctx, g.Logs, g.Host, g.ExpiryDays, g.Now())
	g.budget(ctx, out.AccountID, &out)
	out.RoleBox = g.role(ctx, g.Host+"-box")
	out.RoleWatchdog = g.role(ctx, watchdog.Name(g.Host))
	if in := out.Box.V; out.Box.OK && in != nil {
		out.Stranded = g.stranded(ctx, in)
	}

	if l, held := session.Running(g.LockFile, g.Probe); held {
		out.Session = ok(l)
	}
	g.localFacts(ctx, &out)
	if out.Box.OK && out.Box.V != nil && out.Box.V.State == "running" {
		g.ready(ctx, out.Box.V, out.Node.Found && out.Node.Online, out.Node.IP)
	}
	return out
}

func (g *Gatherer) quota(ctx context.Context, quotaCode string) Known[float64] {
	r, err := g.Quotas.GetServiceQuota(ctx, &servicequotas.GetServiceQuotaInput{
		ServiceCode: aws.String("ec2"), QuotaCode: aws.String(quotaCode)})
	if err != nil || r.Quota == nil || r.Quota.Value == nil {
		return Known[float64]{}
	}
	return ok(*r.Quota.Value)
}

// box finds the machine by its Name tag rather than trusting .env.
func (g *Gatherer) box(ctx context.Context) Known[*Box] {
	r, err := g.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{Filters: []ec2types.Filter{
		f("tag:Name", g.Host), f("instance-state-name", "pending", "running", "stopping", "stopped")}})
	if err != nil {
		return Known[*Box]{}
	}
	for _, res := range r.Reservations {
		for _, i := range res.Instances {
			b := &Box{ID: aws.ToString(i.InstanceId), Type: string(i.InstanceType), PublicIP: aws.ToString(i.PublicIpAddress),
				Lifecycle: "on-demand"}
			if i.State != nil {
				b.State = string(i.State.Name)
			}
			if i.LaunchTime != nil {
				b.Launched = *i.LaunchTime
			}
			if i.InstanceLifecycle == ec2types.InstanceLifecycleTypeSpot {
				b.Lifecycle = "spot"
			}
			if i.Placement != nil {
				b.AZ = aws.ToString(i.Placement.AvailabilityZone)
			}
			if len(i.BlockDeviceMappings) > 0 && i.BlockDeviceMappings[0].Ebs != nil {
				if v, err := g.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{
					VolumeIds: []string{aws.ToString(i.BlockDeviceMappings[0].Ebs.VolumeId)}}); err == nil && len(v.Volumes) > 0 {
					b.DiskGB = ok(int(aws.ToInt32(v.Volumes[0].Size)))
				}
			}
			b.Built = exists(filepath.Join(g.CacheDir, "built-"+b.ID))
			return ok(b)
		}
	}
	return ok[*Box](nil)
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func (g *Gatherer) volumesGB(ctx context.Context) Known[float64] {
	var total float64
	var token *string
	for {
		r, err := g.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{NextToken: token})
		if err != nil {
			return Known[float64]{}
		}
		for _, v := range r.Volumes {
			total += float64(aws.ToInt32(v.Size))
		}
		if r.NextToken == nil || *r.NextToken == "" {
			return ok(total)
		}
		token = r.NextToken
	}
}

// snapshots counts every snapshot the account owns, and the size each was taken
// FROM - what a full snapshot would bill. Incremental ones bill less, so this is
// the most they can cost, said as such.
func (g *Gatherer) snapshots(ctx context.Context) (Known[int], Known[float64]) {
	var n int
	var gb float64
	var token *string
	for {
		r, err := g.EC2.DescribeSnapshots(ctx, &ec2.DescribeSnapshotsInput{OwnerIds: []string{"self"}, NextToken: token})
		if err != nil {
			return Known[int]{}, Known[float64]{}
		}
		for _, s := range r.Snapshots {
			n++
			gb += float64(aws.ToInt32(s.VolumeSize))
		}
		if r.NextToken == nil || *r.NextToken == "" {
			return ok(n), ok(gb)
		}
		token = r.NextToken
	}
}

func (g *Gatherer) images(ctx context.Context) Known[int] {
	var n int
	var token *string
	for {
		r, err := g.EC2.DescribeImages(ctx, &ec2.DescribeImagesInput{Owners: []string{"self"}, NextToken: token})
		if err != nil {
			return Known[int]{}
		}
		n += len(r.Images)
		if r.NextToken == nil || *r.NextToken == "" {
			return ok(n)
		}
		token = r.NextToken
	}
}

func (g *Gatherer) keyPair(ctx context.Context) Known[string] {
	r, err := g.EC2.DescribeKeyPairs(ctx, &ec2.DescribeKeyPairsInput{KeyNames: []string{g.Host}})
	switch {
	case err == nil && len(r.KeyPairs) > 0:
		return ok(aws.ToString(r.KeyPairs[0].KeyName))
	case err == nil, code(err) == "InvalidKeyPair.NotFound":
		return ok("none")
	}
	return Known[string]{}
}

func (g *Gatherer) securityGroup(ctx context.Context) (Known[string], []string) {
	r, err := g.EC2.DescribeSecurityGroups(ctx, &ec2.DescribeSecurityGroupsInput{
		Filters: []ec2types.Filter{f("group-name", g.Host+"-sg")}})
	if err != nil {
		return Known[string]{}, nil
	}
	if len(r.SecurityGroups) == 0 {
		return ok("none"), nil
	}
	sg := r.SecurityGroups[0]
	var in []string
	for _, p := range sg.IpPermissions {
		cidr := ""
		if len(p.IpRanges) > 0 {
			cidr = aws.ToString(p.IpRanges[0].CidrIp)
		}
		if proto := aws.ToString(p.IpProtocol); proto != "" {
			in = append(in, fmt.Sprintf("%s/%d from %s", proto, aws.ToInt32(p.FromPort), cidr))
		}
	}
	return ok(aws.ToString(sg.GroupId)), in
}

func (g *Gatherer) legacy(ctx context.Context) Known[*struct {
	ID, AZ string
	GB     float64
}] {
	type lv = struct {
		ID, AZ string
		GB     float64
	}
	r, err := g.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{Filters: []ec2types.Filter{f("tag:Name", g.Host+"-games")}})
	if err != nil {
		return Known[*lv]{}
	}
	if len(r.Volumes) == 0 {
		return ok[*lv](nil)
	}
	v := r.Volumes[0]
	return ok(&lv{aws.ToString(v.VolumeId), aws.ToString(v.AvailabilityZone), float64(aws.ToInt32(v.Size))})
}

// archive lists the bucket once and partitions it by prefix. The archived Steam
// LOGIN lives under steam/account/ and the games under steam/steamapps/;
// summing the whole steam/ prefix counted 22 KB of login as archived games.
func (g *Gatherer) archive(ctx context.Context) Archive {
	a := Archive{Bucket: g.Bucket}
	if g.Bucket == "" {
		return a
	}
	var lastLogin time.Time
	var token *string
	for {
		r, err := g.S3.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
			Bucket: aws.String(g.Bucket), Prefix: aws.String("steam/"), ContinuationToken: token})
		if err != nil {
			// A failed listing is not an empty archive: unknown, and the login with it.
			a.Err = firstLine(err.Error())
			return a
		}
		for _, o := range r.Contents {
			key := aws.ToString(o.Key)
			switch {
			case strings.HasPrefix(key, "steam/steamapps/"):
				a.Objects++
				a.Bytes += aws.ToInt64(o.Size)
			case strings.HasPrefix(key, "steam/account/"):
				a.Login.Bytes += aws.ToInt64(o.Size)
				if o.LastModified != nil && o.LastModified.After(lastLogin) {
					lastLogin = *o.LastModified
				}
			}
		}
		if !aws.ToBool(r.IsTruncated) {
			break
		}
		token = r.NextContinuationToken
	}
	a.Login.Present = ok(a.Login.Bytes > 0)
	if !lastLogin.IsZero() {
		a.Login.Pushed = lastLogin.UTC().Format("2006-01-02T15:04:05")
	}
	return a
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}

func (g *Gatherer) budget(ctx context.Context, account string, out *Facts) {
	if account == "" {
		return
	}
	name := g.Host + "-monthly"
	r, err := g.Budgets.DescribeBudget(ctx, &budgets.DescribeBudgetInput{AccountId: aws.String(account), BudgetName: aws.String(name)})
	if err != nil {
		var nf *budgetstypes.NotFoundException
		if errors.As(err, &nf) {
			out.BudgetExists = ok(false)
		}
	} else if r.Budget != nil && r.Budget.BudgetLimit != nil {
		out.BudgetExists = ok(true)
		if v, err := strconv.ParseFloat(aws.ToString(r.Budget.BudgetLimit.Amount), 64); err == nil {
			out.BudgetLimit = ok(v)
		}
		// AWS Budgets populates CalculatedSpend up to 24h AFTER a budget is
		// created, and `cg init` recreates this budget on every build.
		out.BudgetSpent = ok(0.0)
		if r.Budget.CalculatedSpend != nil && r.Budget.CalculatedSpend.ActualSpend != nil {
			if v, err := strconv.ParseFloat(aws.ToString(r.Budget.CalculatedSpend.ActualSpend.Amount), 64); err == nil {
				out.BudgetSpent = ok(v)
			}
		}
	}
	if n, err := g.Budgets.DescribeNotificationsForBudget(ctx, &budgets.DescribeNotificationsForBudgetInput{
		AccountId: aws.String(account), BudgetName: aws.String(name)}); err == nil {
		out.BudgetAlerts = ok(len(n.Notifications))
	}
}

func (g *Gatherer) role(ctx context.Context, name string) Known[bool] {
	_, err := g.IAM.GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String(name)})
	switch {
	case err == nil:
		return ok(true)
	case code(err) == "NoSuchEntity":
		return ok(false)
	}
	return Known[bool]{}
}

// stranded explains a stopped spot box that can never start again. Every cost
// guard leaves exactly this state: the on-host `shutdown -h` and the external
// guards' ec2:stop cannot terminate instead - a persistent spot request
// relaunches the moment its instance dies - so stop is right, and this is the
// leak it leaves. Nothing reported it; `cg status` said "stopped", which reads
// as normal and recoverable.
func (g *Gatherer) stranded(ctx context.Context, b *Box) *Stranded {
	if b.State != "stopped" || b.Lifecycle != "spot" {
		return nil
	}
	state := "unknown"
	if r, err := g.EC2.DescribeSpotInstanceRequests(ctx, &ec2.DescribeSpotInstanceRequestsInput{
		Filters: []ec2types.Filter{f("instance-id", b.ID)}}); err == nil && len(r.SpotInstanceRequests) > 0 {
		state = string(r.SpotInstanceRequests[0].State)
	}
	if state == "active" {
		return nil
	}
	gb := 0
	if b.DiskGB.OK {
		gb = b.DiskGB.V // the real volume size, not GAME_DISK_GB
	}
	return &Stranded{Request: state, GB: gb}
}

// Stranded is the note's facts: the spot request's state and the root volume
// that keeps billing.
type Stranded struct {
	Request string
	GB      int
}
