package status

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"github.com/jebin2/aws_cloud_gaming/internal/format"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

// LoginLine is the archived Steam login, on its own line because it is its own
// thing: a ~22 KB tarball that is what makes a rebuilt box come up already
// signed in. It was invisible on every screen while being counted as a game,
// which is how an archive with no games reported 22 KB of games. Unknown is its
// own answer: saying "none" because the listing failed is a lie.
func LoginLine(present Known[bool], bytes int64, pushed string) string {
	switch {
	case !present.OK:
		return "  steam login     unknown - the archive could not be listed\n"
	case present.V:
		size := ""
		if bytes > 0 {
			size = ", " + format.IEC(bytes)
		}
		s := fmt.Sprintf("  steam login     archived%s - a new box comes up signed in  (cg library account)\n", size)
		if pushed != "" {
			s += fmt.Sprintf("                  pushed %s\n", pushed)
		}
		return s
	}
	return "  steam login     none archived - a new box will ask you to sign in\n"
}

// RoleLines are the IAM roles cg made. Status used to show no IAM at all, and
// that is how a live access key survived `cg destroy --all` unnoticed: anything
// that can act on the account, or cost money, belongs in a status view.
func RoleLines(box, wd Known[bool], host string) string {
	role := func(k Known[bool], label, name, what string) string {
		switch {
		case !k.OK:
			return fmt.Sprintf("  %s ? (AWS could not be asked)\n", label)
		case k.V:
			return fmt.Sprintf("  %s %s  (%s)\n", label, name, what)
		}
		return fmt.Sprintf("  %s none - cg init creates it\n", label)
	}
	return role(box, "instance role  ", host+"-box", "lets the box read/write its library bucket") +
		role(wd, "watchdog role  ", watchdog.Name(host), "the cloud watchdog: ends only the "+host+" box")
}

// StrandedLines say a stopped spot box can never start again.
func StrandedLines(s *Stranded, r pricing.Rates) string {
	if s == nil {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "  STRANDED       this stopped spot box can never start again (request: %s)\n", s.Request)
	g := float64(s.GB)
	switch {
	case r.EBSGBMonth == nil:
		fmt.Fprintf(&b, "                 its %d GB root volume still bills, every month\n", s.GB)
	case r.INRPerUSD == nil:
		fmt.Fprintf(&b, "                 its %d GB root volume still bills $%.2f/mo\n", s.GB, g**r.EBSGBMonth)
	default:
		fmt.Fprintf(&b, "                 its %d GB root volume still bills $%.2f/mo (INR %.0f)\n", s.GB, g**r.EBSGBMonth, g**r.EBSGBMonth**r.INRPerUSD)
	}
	b.WriteString("                 reclaim it: cg destroy\n")
	return b.String()
}

// Extras are the facts `cg cost` borrows from the status report: what sits
// beside the archive.
type Extras struct {
	Login    Known[bool]
	Bytes    int64
	Pushed   string
	Decision string
	RoleBox  Known[bool]
	RoleWD   Known[bool]
	Stranded *Stranded
}

// Extras reads them for the box with this id ("" for none) and the archive
// bucket ("" for none).
func (g *Gatherer) Extras(ctx context.Context, instanceID, bucket string) Extras {
	var e Extras
	if bucket != "" {
		var last time.Time
		var token *string
		ok := true
		for {
			r, err := g.S3.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
				Bucket: aws.String(bucket), Prefix: aws.String("steam/account/"), ContinuationToken: token})
			if err != nil {
				ok = false
				break
			}
			for _, o := range r.Contents {
				e.Bytes += aws.ToInt64(o.Size)
				if o.LastModified != nil && o.LastModified.After(last) {
					last = *o.LastModified
				}
			}
			if !aws.ToBool(r.IsTruncated) {
				break
			}
			token = r.NextContinuationToken
		}
		if ok {
			e.Login = Known[bool]{V: e.Bytes > 0, OK: true}
		}
	}
	e.Decision = watchdog.ArchiveDecision(ctx, g.Logs, g.Host, g.ExpiryDays, g.Now())
	e.RoleBox = g.role(ctx, g.Host+"-box")
	e.RoleWD = g.role(ctx, watchdog.Name(g.Host))
	e.Stranded = g.StrandedFor(ctx, instanceID)
	return e
}

func ok2(n int) Known[int] { return Known[int]{V: n, OK: true} }

// StrandedFor is the stranded-spot note for the box with this id ("" for none).
func (g *Gatherer) StrandedFor(ctx context.Context, instanceID string) *Stranded {
	if instanceID == "" {
		return nil
	}
	r, err := g.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{instanceID}})
	if err != nil || len(r.Reservations) == 0 || len(r.Reservations[0].Instances) == 0 {
		return nil
	}
	i := r.Reservations[0].Instances[0]
	b := &Box{ID: instanceID, Lifecycle: "on-demand"}
	if i.State != nil {
		b.State = string(i.State.Name)
	}
	if i.InstanceLifecycle == "spot" {
		b.Lifecycle = "spot"
	}
	if len(i.BlockDeviceMappings) > 0 && i.BlockDeviceMappings[0].Ebs != nil {
		if v, err := g.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{
			VolumeIds: []string{aws.ToString(i.BlockDeviceMappings[0].Ebs.VolumeId)}}); err == nil && len(v.Volumes) > 0 {
			b.DiskGB = ok2(int(aws.ToInt32(v.Volumes[0].Size)))
		}
	}
	return g.stranded(ctx, b)
}
