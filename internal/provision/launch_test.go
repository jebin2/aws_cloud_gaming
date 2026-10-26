package provision

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
	"github.com/aws/smithy-go"
)

type cloud struct {
	existing    string
	images      []ec2types.Image
	sg          string
	keyExists   bool
	volume      string
	assoc       bool
	launchErrs  []error // returned in order before success
	run         *ec2.RunInstancesInput
	runs        int
	calls       []string
	holders     []ec2types.Instance
	keyMaterial string
	assocErr    error
}

func (c *cloud) DescribeInstances(_ context.Context, in *ec2.DescribeInstancesInput, _ ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	for _, f := range in.Filters {
		if aws.ToString(f.Name) == "instance-lifecycle" {
			return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: c.holders}}}, nil
		}
	}
	if c.existing == "" {
		return &ec2.DescribeInstancesOutput{}, nil
	}
	return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: []ec2types.Instance{{InstanceId: aws.String(c.existing)}}}}}, nil
}
func (c *cloud) DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error) {
	if !c.keyExists {
		return nil, &smithy.GenericAPIError{Code: "InvalidKeyPair.NotFound"}
	}
	return &ec2.DescribeKeyPairsOutput{KeyPairs: []ec2types.KeyPairInfo{{KeyFingerprint: aws.String("ab:cd")}}}, nil
}
func (c *cloud) DeleteKeyPair(context.Context, *ec2.DeleteKeyPairInput, ...func(*ec2.Options)) (*ec2.DeleteKeyPairOutput, error) {
	return &ec2.DeleteKeyPairOutput{}, nil
}
func (c *cloud) CreateKeyPair(context.Context, *ec2.CreateKeyPairInput, ...func(*ec2.Options)) (*ec2.CreateKeyPairOutput, error) {
	c.calls = append(c.calls, "create-key")
	return &ec2.CreateKeyPairOutput{KeyMaterial: aws.String(c.keyMaterial)}, nil
}
func (c *cloud) DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error) {
	return &ec2.DescribeImagesOutput{Images: c.images}, nil
}
func (c *cloud) DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error) {
	if c.sg == "" {
		return nil, errors.New("InvalidGroup.NotFound")
	}
	return &ec2.DescribeSecurityGroupsOutput{SecurityGroups: []ec2types.SecurityGroup{{GroupId: aws.String(c.sg)}}}, nil
}
func (c *cloud) CreateSecurityGroup(context.Context, *ec2.CreateSecurityGroupInput, ...func(*ec2.Options)) (*ec2.CreateSecurityGroupOutput, error) {
	c.calls = append(c.calls, "create-sg")
	c.sg = "sg-new"
	return &ec2.CreateSecurityGroupOutput{GroupId: aws.String("sg-new")}, nil
}
func (c *cloud) AuthorizeSecurityGroupIngress(_ context.Context, in *ec2.AuthorizeSecurityGroupIngressInput, _ ...func(*ec2.Options)) (*ec2.AuthorizeSecurityGroupIngressOutput, error) {
	p := in.IpPermissions[0]
	c.calls = append(c.calls, "ingress "+aws.ToString(p.IpProtocol)+" "+itoa(aws.ToInt32(p.FromPort))+" "+aws.ToString(p.IpRanges[0].CidrIp))
	return &ec2.AuthorizeSecurityGroupIngressOutput{}, nil
}
func itoa(n int32) string { return strconv.Itoa(int(n)) }
func (c *cloud) CreateTags(context.Context, *ec2.CreateTagsInput, ...func(*ec2.Options)) (*ec2.CreateTagsOutput, error) {
	return &ec2.CreateTagsOutput{}, nil
}
func (c *cloud) RunInstances(_ context.Context, in *ec2.RunInstancesInput, _ ...func(*ec2.Options)) (*ec2.RunInstancesOutput, error) {
	c.runs++
	c.run = in
	if len(c.launchErrs) > 0 {
		err := c.launchErrs[0]
		c.launchErrs = c.launchErrs[1:]
		return nil, err
	}
	return &ec2.RunInstancesOutput{Instances: []ec2types.Instance{{InstanceId: aws.String("i-new")}}}, nil
}
func (c *cloud) DescribeIamInstanceProfileAssociations(context.Context, *ec2.DescribeIamInstanceProfileAssociationsInput, ...func(*ec2.Options)) (*ec2.DescribeIamInstanceProfileAssociationsOutput, error) {
	if c.assoc {
		return &ec2.DescribeIamInstanceProfileAssociationsOutput{IamInstanceProfileAssociations: []ec2types.IamInstanceProfileAssociation{{}}}, nil
	}
	return &ec2.DescribeIamInstanceProfileAssociationsOutput{}, nil
}
func (c *cloud) AssociateIamInstanceProfile(context.Context, *ec2.AssociateIamInstanceProfileInput, ...func(*ec2.Options)) (*ec2.AssociateIamInstanceProfileOutput, error) {
	c.calls = append(c.calls, "associate")
	return &ec2.AssociateIamInstanceProfileOutput{}, c.assocErr
}
func (c *cloud) DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	if c.volume == "" {
		return &ec2.DescribeVolumesOutput{}, nil
	}
	return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{{VolumeId: aws.String(c.volume)}}}, nil
}

type ssmFake struct{}

func (ssmFake) GetParameter(context.Context, *ssm.GetParameterInput, ...func(*ssm.Options)) (*ssm.GetParameterOutput, error) {
	return &ssm.GetParameterOutput{Parameter: &ssmtypes.Parameter{Value: aws.String("ami-ubuntu")}}, nil
}

type upFake struct {
	put  map[string][]byte
	size int64
	err  error
}

func (u *upFake) Put(_ context.Context, b, r, k string, body []byte) error {
	if u.err != nil {
		return u.err
	}
	if u.put == nil {
		u.put = map[string][]byte{}
	}
	u.put[b+"@"+r+"/"+k] = body
	return nil
}
func (u *upFake) Presign(_ context.Context, b, r, k string, valid time.Duration) (string, error) {
	return "https://" + b + ".s3." + r + ".amazonaws.com/" + k + "?X-Amz-Expires=" + valid.String() + "&X-Amz-Signature=abc", nil
}
func (u *upFake) List(context.Context, string, string, string) ([]Object, error) {
	return []Object{{Size: u.size}}, nil
}

func rig(t *testing.T) (Provisioner, *cloud, *upFake, *[]string, Params) {
	c := &cloud{keyMaterial: "PRIVATE", assoc: true}
	up := &upFake{}
	var out []string
	var slept time.Duration
	_ = slept
	root := os.DirFS("../..")
	p := Provisioner{EC2: c, SSM: ssmFake{}, Up: up, Src: root, Out: func(s string) { out = append(out, s) },
		Now: func() time.Time { return time.Date(2026, 10, 25, 9, 8, 7, 0, time.UTC) }, Sleep: func(time.Duration) {}}
	a := Params{Host: "gamevps", Region: "ap-south-1", Type: "g6.xlarge", DiskGB: 50, Spot: false, AuthKey: "tskey-auth-xxxxxxxxxxxxxxxx",
		Bucket: "cg-bucket-1", BucketRegion: "ap-south-1", KeyFile: filepath.Join(t.TempDir(), "gamevps.pem"), ReserveGB: "20"}
	return p, c, up, &out, a
}

func TestAFreshOnDemandLaunch(t *testing.T) {
	p, c, up, out, a := rig(t)
	res, err := p.Run(context.Background(), a)
	if err != nil || res.InstanceID != "i-new" || res.Reused || res.Restored {
		t.Fatalf("%+v %v\n%s", res, err, strings.Join(*out, "\n"))
	}
	in := c.run
	if aws.ToString(in.ImageId) != "ami-ubuntu" || in.InstanceType != "g6.xlarge" || in.InstanceInitiatedShutdownBehavior != ec2types.ShutdownBehaviorStop || in.InstanceMarketOptions != nil {
		t.Errorf("on demand: shutdown must mean stop, no market options: %+v", in)
	}
	if aws.ToString(in.IamInstanceProfile.Name) != "gamevps-box" || aws.ToInt32(in.BlockDeviceMappings[0].Ebs.VolumeSize) != 50 || !aws.ToBool(in.BlockDeviceMappings[0].Ebs.DeleteOnTermination) {
		t.Errorf("%+v", in)
	}
	if in.Placement != nil {
		t.Error("no AZ pinning: the library is in S3, and any zone improves the odds")
	}
	tags := map[string]string{}
	for _, ts := range in.TagSpecifications {
		for _, tg := range ts.Tags {
			tags[string(ts.ResourceType)+":"+aws.ToString(tg.Key)] = aws.ToString(tg.Value)
		}
	}
	if tags["instance:Name"] != "gamevps" || tags["instance:cg:host"] != "gamevps" || tags["volume:cg:host"] != "gamevps" {
		t.Errorf("%v", tags)
	}
	// The user-data is the gzip of the assembled build, base64 as the API wants it.
	raw, _ := base64.StdEncoding.DecodeString(aws.ToString(in.UserData))
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	script, _ := io.ReadAll(gz)
	if !strings.Contains(string(script), "tskey-auth-xxxxxxxxxxxxxxxx") || strings.Contains(string(script), "__") && strings.Contains(string(script), "__TS_") || len(raw) >= UserDataLimit {
		t.Errorf("user-data: %d bytes", len(raw))
	}
	// The host bundle went to S3 in the bucket's region, and the build fetches it by a presigned URL.
	if len(up.put) != 1 || up.put["cg-bucket-1@ap-south-1/boot/host.tgz"] == nil || !strings.Contains(string(script), "https://cg-bucket-1.s3.ap-south-1.amazonaws.com/boot/host.tgz?X-Amz-Expires=2h0m0s&X-Amz-Signature=abc") {
		t.Errorf("%v", up.put)
	}
	if strings.Join(c.calls, ",") != "create-key,create-sg,ingress udp 41641 0.0.0.0/0" {
		t.Errorf("%v", c.calls)
	}
	if b, _ := os.ReadFile(a.KeyFile); string(b) != "PRIVATE" {
		t.Error("the private key is written once, here")
	}
}

func TestSpotMeansOneTimeAndTerminate(t *testing.T) {
	p, c, _, out, a := rig(t)
	a.Spot = true
	if _, err := p.Run(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	m := c.run.InstanceMarketOptions
	if m.MarketType != ec2types.MarketTypeSpot || m.SpotOptions.SpotInstanceType != ec2types.SpotInstanceTypeOneTime || c.run.InstanceInitiatedShutdownBehavior != ec2types.ShutdownBehaviorTerminate {
		t.Errorf("a persistent request relaunches the moment it is terminated, and a stopped spot box can never start: %+v", m)
	}
	if !strings.Contains(strings.Join(*out, "\n"), "==> launching g6.xlarge (spot, one-time - shutdown means terminate)") {
		t.Error(*out)
	}
}

func TestARerunReusesTheBoxAndLaunchesNothing(t *testing.T) {
	p, c, up, out, a := rig(t)
	c.existing = "i-0old"
	res, err := p.Run(context.Background(), a)
	if err != nil || res.InstanceID != "i-0old" || !res.Reused || c.runs != 0 || len(up.put) != 0 {
		t.Fatalf("%+v %v runs=%d", res, err, c.runs)
	}
	if (*out)[0] != "reusing existing instance i-0old" {
		t.Error(*out)
	}
	// A reused box with no instance role gets one.
	p, c, _, out, a = rig(t)
	c.existing, c.assoc = "i-0old", false
	if _, err := p.Run(context.Background(), a); err != nil || strings.Join(c.calls, ",") != "associate" || !strings.Contains(strings.Join(*out, "\n"), "==> attaching instance profile gamevps-box to i-0old") {
		t.Errorf("%v %v", err, c.calls)
	}
	c.assocErr = errors.New("UnauthorizedOperation")
	*out = nil
	_, _ = p.Run(context.Background(), a)
	if !strings.Contains(strings.Join(*out, "\n"), "could not attach it - the box will not reach S3 (needs iam:PassRole)") {
		t.Error(*out)
	}
}

func TestASavedImageSkipsTheBuild(t *testing.T) {
	p, c, up, out, a := rig(t)
	c.images = []ec2types.Image{{ImageId: aws.String("ami-old"), CreationDate: aws.String("2026-01-01T00:00:00Z")}, {ImageId: aws.String("ami-newer"), CreationDate: aws.String("2026-09-01T00:00:00Z")}}
	res, err := p.Run(context.Background(), a)
	if err != nil || !res.Restored || aws.ToString(c.run.ImageId) != "ami-newer" || c.run.UserData != nil || len(up.put) != 0 {
		t.Fatalf("%+v %v %+v", res, err, c.run)
	}
	if !strings.Contains(strings.Join(*out, "\n"), "==> restoring from saved image ami-newer") || !strings.Contains(strings.Join(*out, "\n"), "==> skipping bootstrap (image is already built)") {
		t.Error(*out)
	}
}

func TestAnInstanceProfileThatIsNotVisibleYetIsRetried(t *testing.T) {
	p, c, _, out, a := rig(t)
	c.launchErrs = []error{errors.New("Invalid IAM Instance Profile name"), errors.New("InvalidParameterValue: Invalid IAM Instance Profile name")}
	res, err := p.Run(context.Background(), a)
	if err != nil || res.InstanceID != "i-new" || c.runs != 3 {
		t.Fatalf("%v runs=%d", err, c.runs)
	}
	if !strings.Contains(strings.Join(*out, "\n"), "instance profile gamevps-box not visible yet (attempt 2) - waiting") {
		t.Error(*out)
	}
	// Six tries and no more.
	p, c, _, _, a = rig(t)
	c.launchErrs = make([]error, 10)
	for i := range c.launchErrs {
		c.launchErrs[i] = errors.New("Invalid IAM Instance Profile name")
	}
	_, err = p.Run(context.Background(), a)
	var le *LaunchError
	if !errors.As(err, &le) || c.runs != 6 {
		t.Errorf("%v runs=%d", err, c.runs)
	}
}

func TestARefusedLaunchSaysWhyAndNamesWhatHoldsTheAllowance(t *testing.T) {
	p, c, _, _, a := rig(t)
	a.Spot = true
	c.launchErrs = []error{&smithy.GenericAPIError{Code: "InsufficientInstanceCapacity", Message: "We currently do not have sufficient g6.xlarge capacity."}}
	_, err := p.Run(context.Background(), a)
	var le *LaunchError
	if !errors.As(err, &le) || !strings.HasPrefix(le.Report[0], "!! AWS has no spare g6.xlarge at the spot price in ap-south-1") || !strings.Contains(strings.Join(le.Report, "\n"), "AWS said: We currently do not have sufficient") {
		t.Fatalf("%v", err)
	}
	if c.runs != 1 {
		t.Error("a capacity refusal is not retried")
	}
	p, c, _, _, a = rig(t)
	a.Spot = true
	c.holders = []ec2types.Instance{{InstanceId: aws.String("i-held"), InstanceType: "g6.xlarge", State: &ec2types.InstanceState{Name: "running"}}}
	c.launchErrs = []error{&smithy.GenericAPIError{Code: "MaxSpotInstanceCountExceeded", Message: "Max spot instance count exceeded"}}
	_, err = p.Run(context.Background(), a)
	if !errors.As(err, &le) || !strings.Contains(le.Report[0], "still there and holds your spot allowance: i-held (running)") {
		t.Errorf("%v", le)
	}
}

func TestTheOldGamesVolumeIsMentionedNotTouched(t *testing.T) {
	p, c, _, out, a := rig(t)
	c.volume = "vol-legacy"
	if _, err := p.Run(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	g := strings.Join(*out, "\n")
	if !strings.Contains(g, "==> note: the old EBS game volume vol-legacy still exists and still bills") || !strings.Contains(g, "cg games --volume --delete") {
		t.Error(g)
	}
}

func TestACrossRegionBucketIsSaidAndPresignedForItsOwnRegion(t *testing.T) {
	p, _, up, out, a := rig(t)
	a.BucketRegion = "ap-south-2"
	up.size = 10 << 30
	price, inr := 0.086, 95.0
	a.XRegionUSD, a.INR = &price, &inr
	if _, err := p.Run(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	if up.put["cg-bucket-1@ap-south-2/boot/host.tgz"] == nil {
		t.Errorf("signed for the wrong region is a 400 that kills user-data before tailscale exists: %v", up.put)
	}
	if !strings.Contains(strings.Join(*out, "\n"), "!! the archive is in ap-south-2 but the box is in ap-south-1") {
		t.Error(*out)
	}
	// A bundle that cannot be uploaded stops before anything is launched.
	p, c, up, _, a := rig(t)
	up.err = errors.New("AccessDenied")
	_, err := p.Run(context.Background(), a)
	if err == nil || !strings.Contains(err.Error(), "could not upload host/ to s3://cg-bucket-1/boot/host.tgz") || c.runs != 0 {
		t.Errorf("%v runs=%d", err, c.runs)
	}
}
