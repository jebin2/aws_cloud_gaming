// Package teardown is taking away everything of cg's that is not the box: its
// disks, images and snapshots in every region, machines in other regions, the
// instance role, the settings it keeps in SSM. Every step carries on past a
// failure and says what is left: something that stays behind still bills, so the
// whole fails - never "done" over something still billing.
package teardown

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/ssm"

	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

// RegionAPI is EC2 in one region.
type RegionAPI interface {
	DeregisterImage(context.Context, *ec2.DeregisterImageInput, ...func(*ec2.Options)) (*ec2.DeregisterImageOutput, error)
	DeleteSnapshot(context.Context, *ec2.DeleteSnapshotInput, ...func(*ec2.Options)) (*ec2.DeleteSnapshotOutput, error)
	DeleteVolume(context.Context, *ec2.DeleteVolumeInput, ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error)
	DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error)
	CancelSpotInstanceRequests(context.Context, *ec2.CancelSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error)
	TerminateInstances(context.Context, *ec2.TerminateInstancesInput, ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error)
}

// SSMAPI deletes parameters.
type SSMAPI interface {
	DeleteParameters(context.Context, *ssm.DeleteParametersInput, ...func(*ssm.Options)) (*ssm.DeleteParametersOutput, error)
}

// IAMAPI removes the instance role.
type IAMAPI interface {
	RemoveRoleFromInstanceProfile(context.Context, *iam.RemoveRoleFromInstanceProfileInput, ...func(*iam.Options)) (*iam.RemoveRoleFromInstanceProfileOutput, error)
	DeleteInstanceProfile(context.Context, *iam.DeleteInstanceProfileInput, ...func(*iam.Options)) (*iam.DeleteInstanceProfileOutput, error)
	DeleteRolePolicy(context.Context, *iam.DeleteRolePolicyInput, ...func(*iam.Options)) (*iam.DeleteRolePolicyOutput, error)
	DeleteRole(context.Context, *iam.DeleteRoleInput, ...func(*iam.Options)) (*iam.DeleteRoleOutput, error)
}

// Teardown carries things out in regions.
type Teardown struct {
	EC2  func(region string) RegionAPI
	SSM  func(region string) SSMAPI
	IAM  IAMAPI
	Say  func(string)
	Log  func(string)
	Fail func(string)
	// Wait waits for an instance to be terminated.
	Wait func(ctx context.Context, region, id string) bool
}

// CleanEverywhere deletes what the scan found: each image and every snapshot behind
// it, each disk, each loose snapshot. A delete AWS refuses is said, and the whole
// fails. A region AWS would not answer for is a failure too: what it holds is not
// known to be gone.
func (t Teardown) CleanEverywhere(ctx context.Context, found storage.Everywhere) (ok bool) {
	ok = true
	if len(found.Failed) > 0 {
		t.Fail("AWS would not say what is in: " + strings.Join(found.Failed, " "))
		ok = false
	}
	// Every snapshot behind an image goes with it; the rest are loose.
	for _, f := range found.Found {
		c := t.EC2(f.Region)
		backing := map[string]bool{}
		for _, im := range f.Images {
			for _, s := range im.Snapshots {
				backing[s.ID] = true
			}
		}
		for _, im := range f.Images {
			t.Say(fmt.Sprintf("deregistering the image %s in %s", im.ID, f.Region))
			if _, err := c.DeregisterImage(ctx, &ec2.DeregisterImageInput{ImageId: aws.String(im.ID)}); err != nil {
				t.Fail(fmt.Sprintf("could not deregister %s in %s", im.ID, f.Region))
				ok = false
				continue
			}
			for _, s := range im.Snapshots {
				if _, err := c.DeleteSnapshot(ctx, &ec2.DeleteSnapshotInput{SnapshotId: aws.String(s.ID)}); err != nil {
					t.Fail(fmt.Sprintf("could not delete the snapshot %s in %s", s.ID, f.Region))
					ok = false
				}
			}
		}
		for _, v := range f.Volumes {
			t.Say(fmt.Sprintf("deleting the disk %s in %s (%g GB)", v.ID, f.Region, v.GB))
			if _, err := c.DeleteVolume(ctx, &ec2.DeleteVolumeInput{VolumeId: aws.String(v.ID)}); err != nil {
				t.Fail(fmt.Sprintf("could not delete the disk %s in %s", v.ID, f.Region))
				ok = false
			}
		}
		for _, s := range f.Snapshots {
			if backing[s.ID] {
				continue
			}
			t.Say(fmt.Sprintf("deleting the snapshot %s in %s (%g GB)", s.ID, f.Region, s.GB))
			if _, err := c.DeleteSnapshot(ctx, &ec2.DeleteSnapshotInput{SnapshotId: aws.String(s.ID)}); err != nil {
				t.Fail(fmt.Sprintf("could not delete the snapshot %s in %s", s.ID, f.Region))
				ok = false
			}
		}
	}
	return ok
}

// EndMachine ends a machine in a region: a spot request cancelled first, so it
// cannot launch another, then the machine ended - its disk goes with it.
func (t Teardown) EndMachine(ctx context.Context, region, id string) bool {
	t.Say(fmt.Sprintf("ending the machine %s in %s", id, region))
	c := t.EC2(region)
	if o, err := c.DescribeSpotInstanceRequests(ctx, &ec2.DescribeSpotInstanceRequestsInput{Filters: []ec2types.Filter{{Name: aws.String("instance-id"), Values: []string{id}}}}); err == nil {
		var reqs []string
		for _, r := range o.SpotInstanceRequests {
			reqs = append(reqs, aws.ToString(r.SpotInstanceRequestId))
		}
		if len(reqs) > 0 {
			_, _ = c.CancelSpotInstanceRequests(ctx, &ec2.CancelSpotInstanceRequestsInput{SpotInstanceRequestIds: reqs})
		}
	}
	if _, err := c.TerminateInstances(ctx, &ec2.TerminateInstancesInput{InstanceIds: []string{id}}); err != nil || (t.Wait != nil && !t.Wait(ctx, region, id)) {
		t.Fail(fmt.Sprintf("could not end %s in %s", id, region))
		return false
	}
	return true
}

// DeleteSettings deletes cg's SSM parameters, ten names a call (the most
// delete-parameters takes), in every region they were found in.
func (t Teardown) DeleteSettings(ctx context.Context, byRegion map[string][]string) bool {
	ok := true
	var regions []string
	for r := range byRegion {
		regions = append(regions, r)
	}
	sort.Strings(regions)
	for _, r := range regions {
		t.Say("deleting cg's settings in " + r)
		names := byRegion[r]
		for i := 0; i < len(names); i += 10 {
			end := min(i+10, len(names))
			if _, err := t.SSM(r).DeleteParameters(ctx, &ssm.DeleteParametersInput{Names: names[i:end]}); err != nil {
				t.Fail("could not delete settings in " + r)
				ok = false
			}
		}
	}
	return ok
}

// RemoveRole removes the box's instance role and profile. Order matters: a role
// cannot be deleted while it is in an instance profile or has an inline policy
// attached. The cost is nothing, but "--all" that leaves IAM objects behind is not
// --all.
func (t Teardown) RemoveRole(ctx context.Context, host string) {
	prof := host + "-box"
	t.Say("removing the instance role " + prof)
	_, _ = t.IAM.RemoveRoleFromInstanceProfile(ctx, &iam.RemoveRoleFromInstanceProfileInput{InstanceProfileName: aws.String(prof), RoleName: aws.String(prof)})
	_, _ = t.IAM.DeleteInstanceProfile(ctx, &iam.DeleteInstanceProfileInput{InstanceProfileName: aws.String(prof)})
	_, _ = t.IAM.DeleteRolePolicy(ctx, &iam.DeleteRolePolicyInput{RoleName: aws.String(prof), PolicyName: aws.String("library-rw")})
	if _, err := t.IAM.DeleteRole(ctx, &iam.DeleteRoleInput{RoleName: aws.String(prof)}); err == nil {
		t.Log("deleted role and instance profile " + prof)
	} else {
		t.Log("role " + prof + " was already gone")
	}
}
