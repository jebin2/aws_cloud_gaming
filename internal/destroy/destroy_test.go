package destroy

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

type res struct {
	id    string
	tags  map[string]string
	snaps []string
	state string
}

// cloud is an account: instances, images and disks with tags. Filters are
// honoured, so a test that forgets cg's tag finds another project's AMI and fails.
type cloud struct {
	instances, images, volumes []res
	spot                       map[string]string // instance -> request
	failTerminate              bool
	failLookup, failCancel     bool // the spot request cannot be found / cancelled
	failImageRead              bool // DescribeImages by id fails
	lookups                    int
	failDeregister, failSnap   map[string]bool
	failVolume                 map[string]bool
	calls                      []string
}

func match(r res, fs []ec2types.Filter) bool {
	for _, f := range fs {
		name := aws.ToString(f.Name)
		switch {
		case strings.HasPrefix(name, "tag:"):
			v := r.tags[strings.TrimPrefix(name, "tag:")]
			ok := false
			for _, want := range f.Values {
				ok = ok || v == want
			}
			if !ok {
				return false
			}
		case name == "status" || name == "instance-state-name":
			ok := false
			for _, want := range f.Values {
				ok = ok || r.state == want
			}
			if !ok {
				return false
			}
		}
	}
	return true
}

func (c *cloud) DescribeInstances(_ context.Context, in *ec2.DescribeInstancesInput, _ ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	var out []ec2types.Instance
	for _, r := range c.instances {
		if match(r, in.Filters) {
			out = append(out, ec2types.Instance{InstanceId: aws.String(r.id)})
		}
	}
	return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: out}}}, nil
}
func (c *cloud) DescribeSpotInstanceRequests(_ context.Context, in *ec2.DescribeSpotInstanceRequestsInput, _ ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error) {
	c.lookups++
	if c.failLookup {
		return nil, errors.New("RequestLimitExceeded")
	}
	id := in.Filters[0].Values[0]
	if r, ok := c.spot[id]; ok {
		return &ec2.DescribeSpotInstanceRequestsOutput{SpotInstanceRequests: []ec2types.SpotInstanceRequest{{SpotInstanceRequestId: aws.String(r)}}}, nil
	}
	return &ec2.DescribeSpotInstanceRequestsOutput{}, nil
}
func (c *cloud) CancelSpotInstanceRequests(_ context.Context, in *ec2.CancelSpotInstanceRequestsInput, _ ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error) {
	if c.failCancel {
		return nil, errors.New("UnauthorizedOperation")
	}
	c.calls = append(c.calls, "cancel "+strings.Join(in.SpotInstanceRequestIds, ","))
	return &ec2.CancelSpotInstanceRequestsOutput{}, nil
}
func (c *cloud) TerminateInstances(_ context.Context, in *ec2.TerminateInstancesInput, _ ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error) {
	if c.failTerminate {
		return nil, errors.New("UnauthorizedOperation")
	}
	c.calls = append(c.calls, "terminate "+strings.Join(in.InstanceIds, ","))
	return &ec2.TerminateInstancesOutput{}, nil
}
func (c *cloud) DescribeImages(_ context.Context, in *ec2.DescribeImagesInput, _ ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error) {
	if c.failImageRead && len(in.ImageIds) > 0 {
		return nil, errors.New("RequestLimitExceeded")
	}
	var out []ec2types.Image
	for _, r := range c.images {
		if len(in.ImageIds) > 0 {
			ok := false
			for _, id := range in.ImageIds {
				ok = ok || id == r.id
			}
			if !ok {
				continue
			}
		}
		if !match(r, in.Filters) {
			continue
		}
		im := ec2types.Image{ImageId: aws.String(r.id)}
		for _, s := range r.snaps {
			im.BlockDeviceMappings = append(im.BlockDeviceMappings, ec2types.BlockDeviceMapping{Ebs: &ec2types.EbsBlockDevice{SnapshotId: aws.String(s)}})
		}
		out = append(out, im)
	}
	return &ec2.DescribeImagesOutput{Images: out}, nil
}
func (c *cloud) DeregisterImage(_ context.Context, in *ec2.DeregisterImageInput, _ ...func(*ec2.Options)) (*ec2.DeregisterImageOutput, error) {
	id := aws.ToString(in.ImageId)
	if c.failDeregister[id] {
		return nil, errors.New("AuthFailure")
	}
	c.calls = append(c.calls, "deregister "+id)
	return &ec2.DeregisterImageOutput{}, nil
}
func (c *cloud) DeleteSnapshot(_ context.Context, in *ec2.DeleteSnapshotInput, _ ...func(*ec2.Options)) (*ec2.DeleteSnapshotOutput, error) {
	id := aws.ToString(in.SnapshotId)
	if c.failSnap[id] {
		return nil, errors.New("InvalidSnapshot.InUse")
	}
	c.calls = append(c.calls, "delete-snapshot "+id)
	return &ec2.DeleteSnapshotOutput{}, nil
}
func (c *cloud) DescribeVolumes(_ context.Context, in *ec2.DescribeVolumesInput, _ ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	var out []ec2types.Volume
	for _, r := range c.volumes {
		if match(r, in.Filters) {
			out = append(out, ec2types.Volume{VolumeId: aws.String(r.id)})
		}
	}
	return &ec2.DescribeVolumesOutput{Volumes: out}, nil
}
func (c *cloud) DeleteVolume(_ context.Context, in *ec2.DeleteVolumeInput, _ ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error) {
	id := aws.ToString(in.VolumeId)
	if c.failVolume[id] {
		return nil, errors.New("VolumeInUse")
	}
	c.calls = append(c.calls, "delete-volume "+id)
	return &ec2.DeleteVolumeOutput{}, nil
}

func account() *cloud {
	mine := map[string]string{"cg:host": "gamevps"}
	return &cloud{
		instances: []res{{id: "i-mine", tags: map[string]string{"Name": "gamevps"}, state: "running"}, {id: "i-dead", tags: map[string]string{"Name": "gamevps"}, state: "terminated"},
			{id: "i-other", tags: map[string]string{"Name": "work"}, state: "running"}},
		images: []res{{id: "ami-mine", tags: mine, snaps: []string{"snap-1", "snap-2"}}, {id: "ami-old", tags: map[string]string{"Name": "gamevps-image"}},
			{id: "ami-work", tags: map[string]string{"Name": "work-image"}}},
		volumes: []res{{id: "vol-left", tags: mine, state: "available"}, {id: "vol-games", tags: map[string]string{"Name": "gamevps-games"}, state: "available"},
			{id: "vol-theirs", tags: map[string]string{"Name": "gamevps-scratch"}, state: "available"}, {id: "vol-busy", tags: mine, state: "in-use"}},
		spot: map[string]string{"i-mine": "sir-9"},
	}
}

func TestReadFindsOnlyWhatIsCgs(t *testing.T) {
	p, err := Read(context.Background(), account(), "gamevps", "cg:host")
	if err != nil {
		t.Fatal(err)
	}
	j := func(l []string) string { return strings.Join(l, ",") }
	if j(p.Instances) != "i-mine" {
		t.Errorf("a terminated instance and another host's are not this box: %v", p.Instances)
	}
	if j(p.Images) != "ami-mine,ami-old" {
		t.Errorf("by the tag, or by the exact name before the tag existed: %v", p.Images)
	}
	if j(p.Volumes) != "vol-left" {
		t.Errorf("the games volume is kept and a disk in use is not detached: %v", p.Volumes)
	}
	if !strings.Contains(j(p.Others), "ami-work") || !strings.Contains(j(p.Others), "vol-theirs") || strings.Contains(j(p.Others), "ami-mine") || strings.Contains(j(p.Others), "vol-games") {
		t.Errorf("not cg's, and said: %v", p.Others)
	}
}

func TestRunCancelsTheSpotRequestFirstAndTakesTheSnapshotsToo(t *testing.T) {
	c := account()
	p, _ := Read(context.Background(), c, "gamevps", "cg:host")
	var said, failed []string
	rm := Remover{C: c, Say: func(s string) { said = append(said, s) }, Log: func(string) {}, Fail: func(s string) { failed = append(failed, s) },
		Wait: func(context.Context, string) bool { return true }}
	f, gone := rm.Run(context.Background(), p)
	if len(f) != 0 || !gone {
		t.Fatalf("%v %v", f, gone)
	}
	want := "cancel sir-9,terminate i-mine,deregister ami-mine,delete-snapshot snap-1,delete-snapshot snap-2,deregister ami-old,delete-volume vol-left"
	if strings.Join(c.calls, ",") != want {
		t.Errorf("a persistent request relaunches the box the moment it dies, so it goes first:\ngot  %s\nwant %s", strings.Join(c.calls, ","), want)
	}
	for _, s := range []string{"terminating i-mine", "deregistering image ami-mine", "deleting the box's leftover volume vol-left"} {
		found := false
		for _, x := range said {
			found = found || x == s
		}
		if !found {
			t.Errorf("never said %q: %v", s, said)
		}
	}
}

func TestFailuresAreCollectedNotSuppressed(t *testing.T) {
	c := account()
	c.failSnap = map[string]bool{"snap-2": true}
	c.failVolume = map[string]bool{"vol-left": true}
	p, _ := Read(context.Background(), c, "gamevps", "cg:host")
	var failed []string
	rm := Remover{C: c, Say: func(string) {}, Log: func(string) {}, Fail: func(s string) { failed = append(failed, s) }, Wait: func(context.Context, string) bool { return true }}
	f, gone := rm.Run(context.Background(), p)
	if !gone || len(f) != 2 || len(failed) != 2 || !strings.Contains(f[0], "snapshot snap-2 - it still bills") || !strings.Contains(f[1], "volume vol-left - it still bills") {
		t.Errorf("%v %v", f, gone)
	}
	// A box that cannot be terminated stops everything after it: nothing is deleted from under a running machine.
	c = account()
	c.failTerminate = true
	p, _ = Read(context.Background(), c, "gamevps", "cg:host")
	f, gone = (Remover{C: c, Say: func(string) {}, Log: func(string) {}, Fail: func(string) {}}).Run(context.Background(), p)
	if gone || len(f) != 1 || strings.Contains(strings.Join(c.calls, ","), "deregister") {
		t.Errorf("%v %v %v", f, gone, c.calls)
	}
	// An image that will not deregister keeps its snapshots: they are still its.
	c = account()
	c.failDeregister = map[string]bool{"ami-mine": true}
	p, _ = Read(context.Background(), c, "gamevps", "cg:host")
	_, _ = (Remover{C: c, Say: func(string) {}, Log: func(string) {}, Fail: func(string) {}, Wait: func(context.Context, string) bool { return true }}).Run(context.Background(), p)
	if strings.Contains(strings.Join(c.calls, ","), "delete-snapshot snap-1") {
		t.Error("deleted the snapshots of an image that is still registered")
	}
}

func TestDescribeSaysWhenTheArchiveGoes(t *testing.T) {
	p := Plan{Instances: []string{"i-1"}, Others: []string{"ami-x"}}
	now := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
	got := Describe(p, "gamevps", 14, now)
	for _, want := range []string{"instances       i-1", "images          none", "security group  gamevps-sg", "it is DELETED after 14 days with no box - around 2026-11-08.", "Left alone - not cg's: ami-x"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if forever := Describe(Plan{}, "gamevps", 0, now); !strings.Contains(forever, "GAME_ARCHIVE_EXPIRY_DAYS=0 keeps it forever.") || strings.Contains(forever, "Left alone") {
		t.Errorf("%s", forever)
	}
}

// An instance whose spot request cannot be found or cancelled is left running:
// terminating it could trade a box we know for a replacement we do not.
func TestAnInstanceWhoseSpotRequestCannotBeHandledIsNotTerminated(t *testing.T) {
	for name, set := range map[string]func(*cloud){
		"the lookup fails": func(c *cloud) { c.failLookup = true },
		"the cancel fails": func(c *cloud) { c.failCancel = true },
	} {
		c := account()
		set(c)
		p, _ := Read(context.Background(), c, "gamevps", "cg:host")
		var failed []string
		rm := Remover{C: c, Say: func(string) {}, Log: func(string) {}, Fail: func(s string) { failed = append(failed, s) }, Sleep: func(time.Duration) {},
			Wait: func(context.Context, string) bool { return true }}
		f, gone := rm.Run(context.Background(), p)
		if gone || len(f) == 0 || strings.Contains(strings.Join(c.calls, ","), "terminate") {
			t.Errorf("%s: gone=%v failures=%v calls=%v", name, gone, f, c.calls)
		}
		if len(failed) == 0 || !strings.Contains(failed[0], "not terminating it") {
			t.Errorf("%s: the failure must say why it stopped: %v", name, failed)
		}
		if name == "the lookup fails" && c.lookups != 3 {
			t.Errorf("a throttled lookup is tried three times, not %d", c.lookups)
		}
	}
}

// Deregistering an image whose snapshots could not be read would leave them
// unreachable and billing, so it is left registered and reported.
func TestAnImageWhoseSnapshotsCannotBeReadIsNotDeregistered(t *testing.T) {
	c := account()
	c.failImageRead = true
	p, _ := Read(context.Background(), c, "gamevps", "cg:host")
	var failed []string
	rm := Remover{C: c, Say: func(string) {}, Log: func(string) {}, Fail: func(s string) { failed = append(failed, s) }, Wait: func(context.Context, string) bool { return true }}
	f, _ := rm.Run(context.Background(), p)
	if strings.Contains(strings.Join(c.calls, ","), "deregister") || strings.Contains(strings.Join(c.calls, ","), "delete-snapshot") {
		t.Errorf("nothing of the images was touched: %v", c.calls)
	}
	if len(f) == 0 || !strings.Contains(f[0], "not deregistering it") {
		t.Errorf("%v", f)
	}
}
