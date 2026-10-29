// Package box is the AWS machine: what EC2 says about it, and a shell on it over
// the tailnet. Everything that starts it, stops it, saves it or takes it away is
// built on this.
package box

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// EC2 is what the box's lifecycle uses.
type EC2 interface {
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
	DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error)
	StartInstances(context.Context, *ec2.StartInstancesInput, ...func(*ec2.Options)) (*ec2.StartInstancesOutput, error)
	StopInstances(context.Context, *ec2.StopInstancesInput, ...func(*ec2.Options)) (*ec2.StopInstancesOutput, error)
	TerminateInstances(context.Context, *ec2.TerminateInstancesInput, ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error)
	CancelSpotInstanceRequests(context.Context, *ec2.CancelSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error)
	CreateImage(context.Context, *ec2.CreateImageInput, ...func(*ec2.Options)) (*ec2.CreateImageOutput, error)
	DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
	DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error)
}

// Box is one machine of cg's.
type Box struct {
	EC2 EC2
	ID  string // the instance id; "" when there is none
	// Host is the AWS resource name; Node is the tailnet name, which can differ
	// when a stale node held the hostname.
	Host, Node string
	Key        string // the .pem
	R          local.Runner
	Sleep      func(time.Duration)
	Log        func(string)
	TagKey     string
}

func (b Box) sleep(d time.Duration) {
	if b.Sleep != nil {
		b.Sleep(d)
		return
	}
	time.Sleep(d)
}

// State is the instance's state name. "none" when there is no instance in .env.
func (b Box) State(ctx context.Context) (string, error) {
	if b.ID == "" {
		return "none", nil
	}
	o, err := b.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{b.ID}})
	if err != nil {
		return "", err
	}
	if len(o.Reservations) == 0 || len(o.Reservations[0].Instances) == 0 || o.Reservations[0].Instances[0].State == nil {
		return "", fmt.Errorf("InvalidInstanceID.NotFound: %s", b.ID)
	}
	return string(o.Reservations[0].Instances[0].State.Name), nil
}

// Lifecycle is "spot" or "" (on demand), and "none" when it cannot be read.
func (b Box) Lifecycle(ctx context.Context) string {
	o, err := b.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{b.ID}})
	if err != nil || len(o.Reservations) == 0 || len(o.Reservations[0].Instances) == 0 {
		return "none"
	}
	return string(o.Reservations[0].Instances[0].InstanceLifecycle)
}

// SpotRequest is the id and state of the spot request behind the instance:
// "", "unknown" when it cannot be read.
func (b Box) SpotRequest(ctx context.Context) (id, state string) {
	o, err := b.EC2.DescribeSpotInstanceRequests(ctx, &ec2.DescribeSpotInstanceRequestsInput{
		Filters: []ec2types.Filter{{Name: aws.String("instance-id"), Values: []string{b.ID}}}})
	if err != nil {
		return "", "unknown"
	}
	if len(o.SpotInstanceRequests) == 0 {
		return "", "None"
	}
	r := o.SpotInstanceRequests[0]
	return aws.ToString(r.SpotInstanceRequestId), string(r.State)
}

// Start starts a stopped instance.
func (b Box) Start(ctx context.Context) error {
	_, err := b.EC2.StartInstances(ctx, &ec2.StartInstancesInput{InstanceIds: []string{b.ID}})
	return err
}

// Stop stops it.
func (b Box) Stop(ctx context.Context) error {
	_, err := b.EC2.StopInstances(ctx, &ec2.StopInstancesInput{InstanceIds: []string{b.ID}})
	return err
}

// WaitState waits for the instance to reach a state: a line per change plus a
// heartbeat, rather than one per poll - timestamped lines are the point, but not
// 200 of them.
func (b Box) WaitState(ctx context.Context, want string, timeout time.Duration) bool {
	last, beat := "", time.Duration(0)
	for waited := time.Duration(0); waited < timeout; waited += 3 * time.Second {
		if ctx.Err() != nil {
			b.Log("interrupted")
			return false
		}
		now, err := b.State(ctx)
		if err != nil {
			now = "?"
		}
		switch {
		case now != last:
			b.Log(now)
			last, beat = now, waited
		case waited-beat >= 10*time.Second:
			b.Log(fmt.Sprintf("still %s (%ds)", now, int(waited/time.Second)))
			beat = waited
		}
		if now == want {
			b.Log(fmt.Sprintf("%s after %ds", now, int(waited/time.Second)))
			return true
		}
		b.sleep(3 * time.Second)
	}
	b.Log(fmt.Sprintf("TIMEOUT after %ds, last state: %s", int(timeout/time.Second), last))
	return false
}

// Volume reads the size of the instance's root disk, in GB; "?" when it cannot be read.
func (b Box) RootVolumeGB(ctx context.Context) string {
	o, err := b.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{b.ID}})
	if err != nil || len(o.Reservations) == 0 || len(o.Reservations[0].Instances) == 0 {
		return "?"
	}
	in := o.Reservations[0].Instances[0]
	if len(in.BlockDeviceMappings) == 0 || in.BlockDeviceMappings[0].Ebs == nil {
		return "?"
	}
	v, err := b.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{VolumeIds: []string{aws.ToString(in.BlockDeviceMappings[0].Ebs.VolumeId)}})
	if err != nil || len(v.Volumes) == 0 {
		return "?"
	}
	return fmt.Sprint(aws.ToInt32(v.Volumes[0].Size))
}

// CreateImage saves the instance as an image, tagged so it can be found again,
// and returns its id.
func (b Box) CreateImage(ctx context.Context, name string) (string, error) {
	tag := b.TagKey
	if tag == "" {
		tag = "cg:host"
	}
	o, err := b.EC2.CreateImage(ctx, &ec2.CreateImageInput{InstanceId: aws.String(b.ID), Name: aws.String(name), Description: aws.String("cloud_gaming saved desktop"),
		TagSpecifications: []ec2types.TagSpecification{
			{ResourceType: ec2types.ResourceTypeImage, Tags: []ec2types.Tag{{Key: aws.String("Name"), Value: aws.String(b.Host + "-image")}, {Key: aws.String(tag), Value: aws.String(b.Host)}}},
			{ResourceType: ec2types.ResourceTypeSnapshot, Tags: []ec2types.Tag{{Key: aws.String(tag), Value: aws.String(b.Host)}}},
		}})
	if err != nil {
		return "", err
	}
	return aws.ToString(o.ImageId), nil
}

// WaitImage waits for an image to be available.
func (b Box) WaitImage(ctx context.Context, ami string, timeout time.Duration) bool {
	last, beat := "", time.Duration(0)
	for waited := time.Duration(0); waited < timeout; waited += 5 * time.Second {
		if ctx.Err() != nil {
			b.Log("interrupted")
			return false
		}
		now := "?"
		if o, err := b.EC2.DescribeImages(ctx, &ec2.DescribeImagesInput{ImageIds: []string{ami}}); err == nil && len(o.Images) > 0 {
			now = string(o.Images[0].State)
		}
		switch {
		case now != last:
			b.Log(now)
			last, beat = now, waited
		case waited-beat >= 15*time.Second:
			b.Log(fmt.Sprintf("still %s (%ds)", now, int(waited/time.Second)))
			beat = waited
		}
		if now == "available" {
			b.Log(fmt.Sprintf("available after %ds", int(waited/time.Second)))
			return true
		}
		if now == "failed" {
			b.Log("image creation FAILED")
			return false
		}
		b.sleep(5 * time.Second)
	}
	b.Log(fmt.Sprintf("TIMEOUT after %ds, last state: %s", int(timeout/time.Second), last))
	return false
}

// IP is the box's tailnet address, if it is on the tailnet.
func (b Box) IP(ctx context.Context) (string, bool) {
	out, err := b.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"ip", "-4", b.Node}})
	ip := strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0])
	return ip, err == nil && ip != ""
}

func (b Box) sshArgs(ip string, timeout string, command string) []string {
	return []string{"-i", b.Key, "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=" + timeout, "-o", "BatchMode=yes", "ubuntu@" + ip, command}
}

// SSH runs a command on the box and returns what it printed. Standard input only
// when given: otherwise ssh reads cg's own, where the app's answers arrive.
func (b Box) SSH(ctx context.Context, command string, stdin io.Reader) ([]byte, error) {
	ip, ok := b.IP(ctx)
	if !ok {
		return nil, fmt.Errorf("'%s' is not on the tailnet", b.Node)
	}
	return b.R.Run(ctx, local.Cmd{Name: "ssh", Args: b.sshArgs(ip, "10", command), Stdin: stdin})
}

// Stream runs a command on the box with its output (error included) passed to w
// as it arrives. The exit status is the command's.
func (b Box) Stream(ctx context.Context, w io.Writer, command string) error {
	ip, ok := b.IP(ctx)
	if !ok {
		return fmt.Errorf("'%s' is not on the tailnet", b.Node)
	}
	args := append([]string{"-c", `exec "$@" 2>&1`, "sh", "ssh"}, b.sshArgs(ip, "10", command)...)
	return b.R.Stream(ctx, w, "sh", args...)
}
