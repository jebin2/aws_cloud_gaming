package provision

import (
	"context"
	"encoding/base64"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"

	"github.com/jebin2/aws_cloud_gaming/internal/sshkey"
)

// EC2 is what making and launching the box uses.
type EC2 interface {
	sshkey.KeyAdmin
	DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
	DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error)
	CreateSecurityGroup(context.Context, *ec2.CreateSecurityGroupInput, ...func(*ec2.Options)) (*ec2.CreateSecurityGroupOutput, error)
	AuthorizeSecurityGroupIngress(context.Context, *ec2.AuthorizeSecurityGroupIngressInput, ...func(*ec2.Options)) (*ec2.AuthorizeSecurityGroupIngressOutput, error)
	CreateTags(context.Context, *ec2.CreateTagsInput, ...func(*ec2.Options)) (*ec2.CreateTagsOutput, error)
	RunInstances(context.Context, *ec2.RunInstancesInput, ...func(*ec2.Options)) (*ec2.RunInstancesOutput, error)
	DescribeIamInstanceProfileAssociations(context.Context, *ec2.DescribeIamInstanceProfileAssociationsInput, ...func(*ec2.Options)) (*ec2.DescribeIamInstanceProfileAssociationsOutput, error)
	AssociateIamInstanceProfile(context.Context, *ec2.AssociateIamInstanceProfileInput, ...func(*ec2.Options)) (*ec2.AssociateIamInstanceProfileOutput, error)
	DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error)
}

// SSM reads the current Ubuntu image.
type SSM interface {
	GetParameter(context.Context, *ssm.GetParameterInput, ...func(*ssm.Options)) (*ssm.GetParameterOutput, error)
}

// Params is everything a launch is decided by.
type Params struct {
	Host, Region, Type string
	DiskGB             int
	Spot               bool
	TagKey             string
	// Joining the tailnet, and what the build restores.
	AuthKey, Apps, Login, ReserveGB string
	// The bucket the library lives in, and where it is.
	Bucket, BucketRegion string
	NtfyURL              string
	KeyFile              string
	// Prices for the cross-region notice (nil: unknown).
	XRegionUSD, INR *float64
}

// Provisioner makes the box.
type Provisioner struct {
	EC2   EC2
	SSM   SSM
	Up    Uploader
	Src   fs.FS // the repo's embedded files: lib/bootstrap.d and host
	Out   func(string)
	Now   func() time.Time
	Sleep func(time.Duration)
	// WaitRunning waits for an instance to be running; nil does not wait.
	WaitRunning func(ctx context.Context, id string) error
}

// Result is what the launch settled.
type Result struct {
	InstanceID string
	Reused     bool
	Restored   bool
}

// LaunchError carries what to say when run-instances refused.
type LaunchError struct{ Report []string }

func (e *LaunchError) Error() string {
	return "could not launch the instance - see the launch error above"
}

func (p Provisioner) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

func (p Provisioner) sleep(d time.Duration) {
	if p.Sleep != nil {
		p.Sleep(d)
		return
	}
	time.Sleep(d)
}

func (p Provisioner) tag(a Params) string {
	if a.TagKey != "" {
		return a.TagKey
	}
	return "cg:host"
}

// Existing is the instance already there for this host, if one is: running,
// pending, stopping or stopped.
func (p Provisioner) Existing(ctx context.Context, host string) (string, error) {
	o, err := p.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{Filters: []ec2types.Filter{
		{Name: aws.String("tag:Name"), Values: []string{host}},
		{Name: aws.String("instance-state-name"), Values: []string{"pending", "running", "stopping", "stopped"}}}})
	if err != nil {
		return "", err
	}
	for _, r := range o.Reservations {
		for _, i := range r.Instances {
			return aws.ToString(i.InstanceId), nil
		}
	}
	return "", nil
}

// Run makes sure there is exactly one box, and launches one only when there is
// none: re-running reuses an existing instance rather than launching a second.
func (p Provisioner) Run(ctx context.Context, a Params) (Result, error) {
	out := p.Out
	var res Result
	id, err := p.Existing(ctx, a.Host)
	if err != nil {
		return res, fmt.Errorf("could not look for an existing instance: %s", firstLine(err))
	}
	if id != "" {
		out("reusing existing instance " + id)
		res.InstanceID, res.Reused = id, true
	} else {
		id, restored, err := p.launch(ctx, a)
		if err != nil {
			return res, err
		}
		res.InstanceID, res.Restored = id, restored
	}
	p.repairProfile(ctx, a, res.InstanceID)

	// The old EBS game volume is deliberately NOT attached any more: nothing mounts
	// it, and attaching it would re-pin the AZ for no benefit. It is not deleted
	// either - deleting storage that might hold the only copy of something is not a
	// thing to do silently. `cg games --volume` shows what it still costs.
	if o, err := p.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{Filters: []ec2types.Filter{{Name: aws.String("tag:Name"), Values: []string{a.Host + "-games"}}}}); err == nil && len(o.Volumes) > 0 {
		v := aws.ToString(o.Volumes[0].VolumeId)
		out(fmt.Sprintf("==> note: the old EBS game volume %s still exists and still bills", v))
		out("    it is no longer used or attached - reclaim it with: cg games --volume --delete")
	}
	return res, nil
}

// image is a saved image from `cg destroy`, which already has driver, desktop,
// Sunshine and Tailscale on it, so restoring skips bootstrap entirely - minutes,
// not ~20. The newest one.
func (p Provisioner) image(ctx context.Context, host string) string {
	o, err := p.EC2.DescribeImages(ctx, &ec2.DescribeImagesInput{Owners: []string{"self"}, Filters: []ec2types.Filter{
		{Name: aws.String("tag:Name"), Values: []string{host + "-image"}}, {Name: aws.String("state"), Values: []string{"available"}}}})
	if err != nil || len(o.Images) == 0 {
		return ""
	}
	im := o.Images
	sort.Slice(im, func(i, j int) bool { return aws.ToString(im[i].CreationDate) > aws.ToString(im[j].CreationDate) })
	return aws.ToString(im[0].ImageId)
}

func (p Provisioner) securityGroup(ctx context.Context, a Params) (string, error) {
	name := a.Host + "-sg"
	var sg string
	if o, err := p.EC2.DescribeSecurityGroups(ctx, &ec2.DescribeSecurityGroupsInput{GroupNames: []string{name}}); err == nil && len(o.SecurityGroups) > 0 {
		sg = aws.ToString(o.SecurityGroups[0].GroupId)
	}
	if sg == "" {
		// The only inbound rule is Tailscale's UDP port. Without it, Tailscale
		// cannot negotiate a direct path and silently falls back to a DERP relay -
		// which still works, but adds tens of ms and makes streaming feel sluggish.
		// The port is safe to expose: Tailscale traffic is end-to-end encrypted and
		// unauthenticated peers get nowhere. No SSH, no Sunshine ports.
		p.Out("==> creating security group (tailscale UDP only)")
		o, err := p.EC2.CreateSecurityGroup(ctx, &ec2.CreateSecurityGroupInput{GroupName: aws.String(name),
			Description:       aws.String("cloud gaming host; reachable over Tailscale only"),
			TagSpecifications: []ec2types.TagSpecification{{ResourceType: ec2types.ResourceTypeSecurityGroup, Tags: []ec2types.Tag{{Key: aws.String(p.tag(a)), Value: aws.String(a.Host)}}}}})
		if err != nil {
			return "", fmt.Errorf("could not create the security group: %s", firstLine(err))
		}
		sg = aws.ToString(o.GroupId)
		if _, err := p.EC2.AuthorizeSecurityGroupIngress(ctx, &ec2.AuthorizeSecurityGroupIngressInput{GroupId: aws.String(sg), IpPermissions: []ec2types.IpPermission{{
			IpProtocol: aws.String("udp"), FromPort: aws.Int32(41641), ToPort: aws.Int32(41641),
			IpRanges: []ec2types.IpRange{{CidrIp: aws.String("0.0.0.0/0"), Description: aws.String("tailscale direct path")}}}}}); err != nil {
			return "", fmt.Errorf("could not open the tailscale port: %s", firstLine(err))
		}
	}
	// cg's tag on it, made before the tag existed or not - never fatal.
	_, _ = p.EC2.CreateTags(ctx, &ec2.CreateTagsInput{Resources: []string{sg}, Tags: []ec2types.Tag{{Key: aws.String(p.tag(a)), Value: aws.String(a.Host)}}})
	p.Out("    " + sg)
	return sg, nil
}

func (p Provisioner) launch(ctx context.Context, a Params) (id string, restored bool, err error) {
	out := p.Out
	ami := p.image(ctx, a.Host)
	if ami != "" {
		restored = true
		out("==> restoring from saved image " + ami)
	} else {
		out("==> resolving latest Ubuntu 24.04 AMI")
		o, err := p.SSM.GetParameter(ctx, &ssm.GetParameterInput{Name: aws.String("/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id")})
		if err != nil || o.Parameter == nil {
			return "", false, fmt.Errorf("could not find the Ubuntu image: %v", err)
		}
		ami = aws.ToString(o.Parameter.Value)
		out("    " + ami)
	}

	// Reused only if this laptop holds its private key; replaced otherwise.
	if err := sshkey.Ensure(ctx, p.EC2, a.Host, a.KeyFile, p.tag(a), out, p.now); err != nil {
		return "", false, fmt.Errorf("could not set up the ssh key pair: %s", firstLine(err))
	}
	sg, err := p.securityGroup(ctx, a)
	if err != nil {
		return "", false, err
	}

	// A restored image is already built; re-running bootstrap would reinstall over a
	// working system and re-join Tailscale as a duplicate node.
	var ud []byte
	if restored {
		out("==> skipping bootstrap (image is already built)")
	} else {
		out("==> rendering user-data")
		u, err := p.userData(ctx, a)
		if err != nil {
			return "", false, err
		}
		ud = u.Gzipped
		out(fmt.Sprintf("    assembled %d modules", u.Modules))
		out(fmt.Sprintf("    %d bytes -> %d gzipped (limit %d)", len(u.Raw), len(u.Gzipped), UserDataLimit))
	}

	// ONE-TIME spot, not persistent, and terminate rather than stop.
	//
	// The old design was persistent + InstanceInterruptionBehavior=stop, because the
	// games lived on the instance store and terminating meant losing them. That
	// constraint is gone - they are in S3 - and the old design had two costs: a
	// persistent request RELAUNCHES the moment its instance is terminated, so
	// nothing may terminate the box without cancelling the request first (and no
	// cost guard can do that); and stopping a spot instance disables its request
	// permanently, leaving a box that can never start again while its root volume
	// keeps billing. A one-time request never relaunches, which makes terminate
	// safe, which lets the guards actually remove the thing they are guarding
	// against. Nothing is lost: a stop wipes the instance store anyway, and the S3
	// mirror is what preserves the games in either case.
	shutdown := ec2types.ShutdownBehaviorStop
	in := &ec2.RunInstancesInput{
		ImageId: aws.String(ami), InstanceType: ec2types.InstanceType(a.Type), KeyName: aws.String(a.Host), SecurityGroupIds: []string{sg},
		IamInstanceProfile: &ec2types.IamInstanceProfileSpecification{Name: aws.String(a.Host + "-box")},
		MinCount:           aws.Int32(1), MaxCount: aws.Int32(1),
		BlockDeviceMappings: []ec2types.BlockDeviceMapping{{DeviceName: aws.String("/dev/sda1"), Ebs: &ec2types.EbsBlockDevice{VolumeSize: aws.Int32(int32(a.DiskGB)), VolumeType: ec2types.VolumeTypeGp3, DeleteOnTermination: aws.Bool(true)}}},
		TagSpecifications: []ec2types.TagSpecification{
			{ResourceType: ec2types.ResourceTypeInstance, Tags: []ec2types.Tag{{Key: aws.String("Name"), Value: aws.String(a.Host)}, {Key: aws.String(p.tag(a)), Value: aws.String(a.Host)}}},
			{ResourceType: ec2types.ResourceTypeVolume, Tags: []ec2types.Tag{{Key: aws.String("Name"), Value: aws.String(a.Host)}, {Key: aws.String(p.tag(a)), Value: aws.String(a.Host)}}}},
	}
	if ud != nil {
		in.UserData = aws.String(base64.StdEncoding.EncodeToString(ud))
	}
	if a.Spot {
		in.InstanceMarketOptions = &ec2types.InstanceMarketOptionsRequest{MarketType: ec2types.MarketTypeSpot, SpotOptions: &ec2types.SpotMarketOptions{SpotInstanceType: ec2types.SpotInstanceTypeOneTime}}
		// So the on-host watchdog's `shutdown -h` removes the box rather than
		// stranding it. Safe only because nothing can relaunch a one-time request.
		shutdown = ec2types.ShutdownBehaviorTerminate
		out(fmt.Sprintf("==> launching %s (spot, one-time - shutdown means terminate)", a.Type))
	} else {
		out("==> launching " + a.Type)
	}
	// shutdown-behaviour is set at launch, not after: the watchdog issues
	// `shutdown -h`, and the window matters. On demand it must mean "stop", so a
	// misfiring watchdog parks the box instead of deleting it. On one-time spot it
	// must mean "terminate", because a stopped spot instance can never start again.
	in.InstanceInitiatedShutdownBehavior = shutdown

	// A freshly created instance profile is not immediately usable by run-instances
	// - IAM is eventually consistent, and the first call after creating one fails
	// with "Invalid IAM Instance Profile name" for a few seconds. Retried here
	// rather than left as an init that fails once and works when you run it again,
	// which is the kind of thing that gets diagnosed as flakiness instead of
	// propagation.
	var lastErr error
	for attempt := 1; attempt <= 6; attempt++ {
		o, err := p.EC2.RunInstances(ctx, in)
		if err == nil && len(o.Instances) > 0 {
			id = aws.ToString(o.Instances[0].InstanceId)
			out("    " + id)
			return id, restored, nil
		}
		lastErr = err
		if err != nil && strings.Contains(err.Error(), "Invalid IAM Instance Profile") {
			out(fmt.Sprintf("    instance profile %s not visible yet (attempt %d) - waiting", a.Host+"-box", attempt))
			p.sleep(5 * time.Second)
			continue
		}
		break
	}
	f := LaunchFailure{Type: a.Type, Region: a.Region, Spot: a.Spot, KeyName: a.Host, KeyFile: a.KeyFile, Profile: a.Host + "-box"}
	if lastErr != nil {
		f.Code, f.Message = ErrorParts(lastErr)
	}
	if f.Code == "MaxSpotInstanceCountExceeded" {
		f.Holders, f.HoldersKnown = SpotHolders(ctx, p.EC2)
	}
	return "", false, &LaunchError{Report: f.Report()}
}

// userData uploads the host bundle and renders the build around its address.
// host/ goes to S3 and the box fetches it, rather than riding along inside
// user-data as base64. A presigned GET, valid two hours, so the box needs no
// credentials at the point in the build where it has none.
func (p Provisioner) userData(ctx context.Context, a Params) (UserData, error) {
	bundle, err := HostBundle(p.Src, a.NtfyURL)
	if err != nil {
		return UserData{}, fmt.Errorf("could not bundle host/: %s", firstLine(err))
	}
	// The BUCKET's region, not the box's. They are the same until GAME_REGION moves,
	// and then they are not: `aws s3 cp` hides this by following S3's redirect;
	// `presign` cannot, and a URL signed for the wrong region is a 400 that kills
	// user-data before tailscale exists.
	region := a.BucketRegion
	if region == "" {
		region = a.Region
	}
	if err := p.Up.Put(ctx, a.Bucket, region, "boot/host.tgz", bundle); err != nil {
		return UserData{}, fmt.Errorf("could not upload host/ to s3://%s/boot/host.tgz", a.Bucket)
	}
	url, err := p.Up.Presign(ctx, a.Bucket, region, "boot/host.tgz", 2*time.Hour)
	if err != nil || !strings.HasPrefix(url, "https://") {
		return UserData{}, fmt.Errorf("could not presign the host bundle")
	}
	if region != a.Region {
		// One listing, charged as LIST requests: cents per ten thousand objects. An
		// EMPTY archive is the case this message exists for, and it must not kill
		// the build.
		size := int64(-1)
		if objs, err := p.Up.List(ctx, a.Bucket, region, "steam/steamapps/"); err == nil {
			size = 0
			for _, o := range objs {
				size += o.Size
			}
		}
		for _, l := range CrossRegion(region, a.Region, size, a.XRegionUSD, a.INR) {
			p.Out(l)
		}
	}
	// Assembled by render - the same build a machine of yours gets - as the AWS box:
	// user ubuntu on Ubuntu, with its own steps switched on.
	apps, login, reserve := a.Apps, a.Login, a.ReserveGB
	if apps == "" {
		apps = "all"
	}
	if login == "" {
		login = "use"
	}
	u, err := Assemble(p.Src, map[string]string{"TS_AUTHKEY": a.AuthKey, "TS_HOST": a.Host, "HOST_TGZ_URL": url, "S3_BUCKET": a.Bucket,
		"CG_APPS": apps, "CG_LOGIN": login, "CG_RESERVE_GB": reserve, "CG_TARGET": "aws", "CG_USER": "ubuntu", "CG_FAMILY": "ubuntu"})
	if err != nil {
		return u, fmt.Errorf("could not render user-data: %s", firstLine(err))
	}
	return u, nil
}

// repairProfile attaches the instance role to a reused instance that has none. A
// box launched before the library moved to S3 has no instance profile, and without
// one the restore and the push both fail with a permission error 10 minutes into a
// download. Attaching it to a running instance is allowed, so repair it here rather
// than requiring a rebuild.
func (p Provisioner) repairProfile(ctx context.Context, a Params, id string) {
	o, err := p.EC2.DescribeIamInstanceProfileAssociations(ctx, &ec2.DescribeIamInstanceProfileAssociationsInput{Filters: []ec2types.Filter{
		{Name: aws.String("instance-id"), Values: []string{id}}, {Name: aws.String("state"), Values: []string{"associated", "associating"}}}})
	if err == nil && len(o.IamInstanceProfileAssociations) > 0 {
		return
	}
	prof := a.Host + "-box"
	p.Out(fmt.Sprintf("==> attaching instance profile %s to %s", prof, id))
	if p.WaitRunning != nil {
		_ = p.WaitRunning(ctx, id)
	}
	if _, err := p.EC2.AssociateIamInstanceProfile(ctx, &ec2.AssociateIamInstanceProfileInput{InstanceId: aws.String(id), IamInstanceProfile: &ec2types.IamInstanceProfileSpecification{Name: aws.String(prof)}}); err != nil {
		p.Out("    could not attach it - the box will not reach S3 (needs iam:PassRole)")
	}
}
