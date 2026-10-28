package teardown

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/ssm"

	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

type region struct {
	name  string
	calls *[]string
	fail  map[string]bool
	spot  []string
}

func (r region) rec(s string) { *r.calls = append(*r.calls, r.name+": "+s) }
func (r region) DeregisterImage(_ context.Context, in *ec2.DeregisterImageInput, _ ...func(*ec2.Options)) (*ec2.DeregisterImageOutput, error) {
	if r.fail[*in.ImageId] {
		return nil, errors.New("AuthFailure")
	}
	r.rec("deregister " + *in.ImageId)
	return &ec2.DeregisterImageOutput{}, nil
}
func (r region) DeleteSnapshot(_ context.Context, in *ec2.DeleteSnapshotInput, _ ...func(*ec2.Options)) (*ec2.DeleteSnapshotOutput, error) {
	if r.fail[*in.SnapshotId] {
		return nil, errors.New("InUse")
	}
	r.rec("snapshot " + *in.SnapshotId)
	return &ec2.DeleteSnapshotOutput{}, nil
}
func (r region) DeleteVolume(_ context.Context, in *ec2.DeleteVolumeInput, _ ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error) {
	if r.fail[*in.VolumeId] {
		return nil, errors.New("VolumeInUse")
	}
	r.rec("volume " + *in.VolumeId)
	return &ec2.DeleteVolumeOutput{}, nil
}
func (r region) DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error) {
	var q []ec2types.SpotInstanceRequest
	for _, id := range r.spot {
		q = append(q, ec2types.SpotInstanceRequest{SpotInstanceRequestId: aws.String(id)})
	}
	return &ec2.DescribeSpotInstanceRequestsOutput{SpotInstanceRequests: q}, nil
}
func (r region) CancelSpotInstanceRequests(_ context.Context, in *ec2.CancelSpotInstanceRequestsInput, _ ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error) {
	r.rec("cancel " + strings.Join(in.SpotInstanceRequestIds, ","))
	return &ec2.CancelSpotInstanceRequestsOutput{}, nil
}
func (r region) TerminateInstances(_ context.Context, in *ec2.TerminateInstancesInput, _ ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error) {
	if r.fail[in.InstanceIds[0]] {
		return nil, errors.New("UnauthorizedOperation")
	}
	r.rec("terminate " + in.InstanceIds[0])
	return &ec2.TerminateInstancesOutput{}, nil
}

type ssmFake struct {
	calls *[]string
	fail  bool
}

func (s ssmFake) DeleteParameters(_ context.Context, in *ssm.DeleteParametersInput, _ ...func(*ssm.Options)) (*ssm.DeleteParametersOutput, error) {
	if s.fail {
		return nil, errors.New("x")
	}
	*s.calls = append(*s.calls, "ssm "+string(rune('0'+len(in.Names)/10))+string(rune('0'+len(in.Names)%10)))
	return &ssm.DeleteParametersOutput{}, nil
}

func rig() (Teardown, *[]string, *[]string, *[]string, map[string]bool) {
	var calls, said, failed []string
	fail := map[string]bool{}
	t := Teardown{
		EC2:  func(r string) RegionAPI { return region{name: r, calls: &calls, fail: fail, spot: []string{"sir-1"}} },
		SSM:  func(r string) SSMAPI { return ssmFake{calls: &calls} },
		Say:  func(s string) { said = append(said, s) },
		Log:  func(s string) { said = append(said, s) },
		Fail: func(s string) { failed = append(failed, s) },
		Wait: func(context.Context, string, string) bool { return true },
	}
	return t, &calls, &said, &failed, fail
}

func scan() storage.Everywhere {
	return storage.Everywhere{Found: []storage.Found{
		{Region: "ap-south-1", Volumes: []costfacts.Volume{{ID: "vol-1", GB: 160}},
			Images:    []costfacts.Image{{ID: "ami-1", Snapshots: []costfacts.Snapshot{{ID: "snap-a", GB: 50}}}},
			Snapshots: []costfacts.Snapshot{{ID: "snap-a", GB: 50}, {ID: "snap-loose", GB: 20}}},
		{Region: "us-east-1"}}}
}

func TestEverythingFoundGoesAndASnapshotBackingAnImageIsDeletedOnce(t *testing.T) {
	td, calls, said, failed, _ := rig()
	if !td.CleanEverywhere(context.Background(), scan()) || len(*failed) != 0 {
		t.Fatalf("%v", *failed)
	}
	if strings.Join(*calls, ",") != "ap-south-1: deregister ami-1,ap-south-1: snapshot snap-a,ap-south-1: volume vol-1,ap-south-1: snapshot snap-loose" {
		t.Errorf("an image first, its snapshots with it, then disks, then the loose snapshots: %v", *calls)
	}
	if !strings.Contains(strings.Join(*said, "|"), "deleting the disk vol-1 in ap-south-1 (160 GB)") {
		t.Error(*said)
	}
}

func TestARefusedDeleteIsSaidAndTheRestStillGo(t *testing.T) {
	td, calls, _, failed, fail := rig()
	fail["ami-1"], fail["vol-1"] = true, true
	if td.CleanEverywhere(context.Background(), scan()) {
		t.Fatal("something is still billing: not done")
	}
	if strings.Join(*failed, "|") != "could not deregister ami-1 in ap-south-1|could not delete the disk vol-1 in ap-south-1" {
		t.Errorf("%v", *failed)
	}
	if !strings.Contains(strings.Join(*calls, ","), "snapshot snap-loose") || strings.Contains(strings.Join(*calls, ","), "snapshot snap-a") {
		t.Errorf("the loose one still goes; the one behind a still-registered image does not: %v", *calls)
	}
	// A region AWS would not answer for is not known to be clean.
	td, _, _, failed, _ = rig()
	s := scan()
	s.Failed = []string{"eu-west-1", "ap-southeast-1"}
	if td.CleanEverywhere(context.Background(), s) || (*failed)[0] != "AWS would not say what is in: eu-west-1 ap-southeast-1" {
		t.Errorf("%v", *failed)
	}
}

func TestAMachineIsEndedWithItsSpotRequestCancelledFirst(t *testing.T) {
	td, calls, _, failed, fail := rig()
	if !td.EndMachine(context.Background(), "eu-west-1", "i-9") || strings.Join(*calls, ",") != "eu-west-1: cancel sir-1,eu-west-1: terminate i-9" {
		t.Errorf("a request left would launch another: %v", *calls)
	}
	fail["i-8"] = true
	if td.EndMachine(context.Background(), "eu-west-1", "i-8") || (*failed)[0] != "could not end i-8 in eu-west-1" {
		t.Errorf("%v", *failed)
	}
}

func TestSettingsGoTenAtATime(t *testing.T) {
	td, calls, _, _, _ := rig()
	var names []string
	for i := 0; i < 23; i++ {
		names = append(names, "/cloud-gaming/gamevps/kept/b/"+string(rune('a'+i)))
	}
	if !td.DeleteSettings(context.Background(), map[string][]string{"ap-south-2": names[:3], "ap-south-1": names}) {
		t.Fatal("failed")
	}
	if strings.Join(*calls, ",") != "ssm 10,ssm 10,ssm 03,ssm 03" {
		t.Errorf("ten is the most delete-parameters takes: %v", *calls)
	}
}

type iamFake struct{ calls []string }

func (i *iamFake) RemoveRoleFromInstanceProfile(context.Context, *iam.RemoveRoleFromInstanceProfileInput, ...func(*iam.Options)) (*iam.RemoveRoleFromInstanceProfileOutput, error) {
	i.calls = append(i.calls, "detach")
	return &iam.RemoveRoleFromInstanceProfileOutput{}, nil
}
func (i *iamFake) DeleteInstanceProfile(context.Context, *iam.DeleteInstanceProfileInput, ...func(*iam.Options)) (*iam.DeleteInstanceProfileOutput, error) {
	i.calls = append(i.calls, "profile")
	return &iam.DeleteInstanceProfileOutput{}, nil
}
func (i *iamFake) DeleteRolePolicy(context.Context, *iam.DeleteRolePolicyInput, ...func(*iam.Options)) (*iam.DeleteRolePolicyOutput, error) {
	i.calls = append(i.calls, "policy")
	return &iam.DeleteRolePolicyOutput{}, nil
}
func (i *iamFake) DeleteRole(context.Context, *iam.DeleteRoleInput, ...func(*iam.Options)) (*iam.DeleteRoleOutput, error) {
	i.calls = append(i.calls, "role")
	if len(i.calls) > 4 {
		return nil, errors.New("NoSuchEntity")
	}
	return &iam.DeleteRoleOutput{}, nil
}

func TestTheRoleGoesInTheOrderIAMAllows(t *testing.T) {
	td, _, said, _, _ := rig()
	i := &iamFake{}
	td.IAM = i
	td.RemoveRole(context.Background(), "gamevps")
	if strings.Join(i.calls, ",") != "detach,profile,policy,role" || (*said)[1] != "deleted role and instance profile gamevps-box" {
		t.Errorf("a role cannot go while it is in a profile or has a policy: %v %v", i.calls, *said)
	}
	td.RemoveRole(context.Background(), "gamevps")
	if (*said)[len(*said)-1] != "role gamevps-box was already gone" {
		t.Error(*said)
	}
}
