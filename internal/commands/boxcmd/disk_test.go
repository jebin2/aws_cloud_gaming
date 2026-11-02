package boxcmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

// fakeDisk is the machine's disks, and what is done to them.
type fakeDisk struct {
	gamesVol    string // "" when the games live on the machine's own drive
	gamesGB     int32
	calls       []string
	modifyErr   error
	modState    ec2types.VolumeModificationState
	createErr   error
	attachErr   error
	markErr     error
	newVol      string
	newState    string
	newAttached bool
	deleted     []string
	size        int32 // the size asked for
}

func (f *fakeDisk) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	in := ec2types.Instance{InstanceId: aws.String("i-0abc"), Placement: &ec2types.Placement{AvailabilityZone: aws.String("ap-south-1b")},
		BlockDeviceMappings: []ec2types.InstanceBlockDeviceMapping{{DeviceName: aws.String("/dev/sda1"), Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String("vol-root")}}}}
	if f.gamesVol != "" {
		in.BlockDeviceMappings = append(in.BlockDeviceMappings, ec2types.InstanceBlockDeviceMapping{DeviceName: aws.String("/dev/sdf"), Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String(f.gamesVol)}})
	}
	return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: []ec2types.Instance{in}}}}, nil
}
func (f *fakeDisk) DescribeVolumes(_ context.Context, in *ec2.DescribeVolumesInput, _ ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	id := in.VolumeIds[0]
	switch {
	case id == f.gamesVol:
		return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{{VolumeId: aws.String(id), Size: aws.Int32(f.gamesGB)}}}, nil
	case id == f.newVol:
		v := ec2types.Volume{VolumeId: aws.String(id), State: ec2types.VolumeState(f.newState)}
		if f.newAttached {
			v.State = ec2types.VolumeStateInUse
			v.Attachments = []ec2types.VolumeAttachment{{State: ec2types.VolumeAttachmentStateAttached}}
		}
		return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{v}}, nil
	}
	return &ec2.DescribeVolumesOutput{}, nil
}
func (f *fakeDisk) DescribeVolumesModifications(context.Context, *ec2.DescribeVolumesModificationsInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesModificationsOutput, error) {
	return &ec2.DescribeVolumesModificationsOutput{VolumesModifications: []ec2types.VolumeModification{{ModificationState: f.modState}}}, nil
}
func (f *fakeDisk) ModifyVolume(_ context.Context, in *ec2.ModifyVolumeInput, _ ...func(*ec2.Options)) (*ec2.ModifyVolumeOutput, error) {
	f.calls = append(f.calls, fmt.Sprintf("modify %s %d", aws.ToString(in.VolumeId), aws.ToInt32(in.Size)))
	return &ec2.ModifyVolumeOutput{}, f.modifyErr
}
func (f *fakeDisk) CreateVolume(_ context.Context, in *ec2.CreateVolumeInput, _ ...func(*ec2.Options)) (*ec2.CreateVolumeOutput, error) {
	if f.createErr != nil {
		return nil, f.createErr
	}
	tags := ""
	for _, s := range in.TagSpecifications {
		for _, t := range s.Tags {
			tags += aws.ToString(t.Key) + "=" + aws.ToString(t.Value) + ","
		}
	}
	f.calls = append(f.calls, fmt.Sprintf("create %dGB %s %s %s", aws.ToInt32(in.Size), in.VolumeType, aws.ToString(in.AvailabilityZone), tags))
	f.newVol, f.newState = "vol-new", "available"
	return &ec2.CreateVolumeOutput{VolumeId: aws.String("vol-new")}, nil
}
func (f *fakeDisk) AttachVolume(_ context.Context, in *ec2.AttachVolumeInput, _ ...func(*ec2.Options)) (*ec2.AttachVolumeOutput, error) {
	if f.attachErr != nil {
		return nil, f.attachErr
	}
	f.calls = append(f.calls, "attach "+aws.ToString(in.VolumeId)+" "+aws.ToString(in.Device))
	f.newAttached = true
	return &ec2.AttachVolumeOutput{}, nil
}
func (f *fakeDisk) DeleteVolume(_ context.Context, in *ec2.DeleteVolumeInput, _ ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error) {
	f.deleted = append(f.deleted, aws.ToString(in.VolumeId))
	return &ec2.DeleteVolumeOutput{}, nil
}
func (f *fakeDisk) ModifyInstanceAttribute(_ context.Context, in *ec2.ModifyInstanceAttributeInput, _ ...func(*ec2.Options)) (*ec2.ModifyInstanceAttributeOutput, error) {
	if f.markErr != nil {
		return nil, f.markErr
	}
	m := in.BlockDeviceMappings[0]
	f.calls = append(f.calls, fmt.Sprintf("mark %s %s delete-with-box=%v", aws.ToString(m.DeviceName), aws.ToString(m.Ebs.VolumeId), aws.ToBool(m.Ebs.DeleteOnTermination)))
	return &ec2.ModifyInstanceAttributeOutput{}, nil
}

func diskRig(t *testing.T) *rig {
	r := newRig(t, "")
	inner := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "df -B1") {
			return true, "250000000000 186000000000\n", nil
		}
		return inner(line)
	}
	return r
}

func TestDiskStatusSaysWhetherAddingGrowsOrMoves(t *testing.T) {
	for _, c := range []struct {
		vol  string
		gb   int32
		move bool
		max  int
	}{{"vol-games", 100, false, 900}, {"", 0, true, 1000}} {
		r := diskRig(t)
		f := &fakeDisk{gamesVol: c.vol, gamesGB: c.gb}
		if rc := r.d.Disk(context.Background(), f, true); rc != 0 {
			t.Fatalf("%s%s", r.o, r.w)
		}
		var st DiskStatus
		if err := json.Unmarshal(r.o.Bytes(), &st); err != nil {
			t.Fatalf("%v\n%s", err, r.o)
		}
		if !st.Running || st.Move != c.move || st.MaxAddGB != c.max || st.Disk != int(c.gb) || st.StepGB != 10 {
			t.Errorf("%+v", st)
		}
		if st.TotalGB != 250 || st.UsedGB != 186 || st.FreeGB != 64 {
			t.Errorf("the machine's own figures: %+v", st)
		}
	}
	r := diskRig(t)
	r.e.state = "stopped"
	if rc := r.d.Disk(context.Background(), &fakeDisk{}, true); rc != 0 || !strings.Contains(r.o.String(), `"running": false`) {
		t.Errorf("a stopped machine cannot be read, and says so: %s", r.o)
	}
}

func TestAddDiskGrowsTheGamesDiskWhileItIsInUse(t *testing.T) {
	r := diskRig(t)
	f := &fakeDisk{gamesVol: "vol-games", gamesGB: 100, modState: ec2types.VolumeModificationStateOptimizing}
	if rc := r.d.AddDisk(context.Background(), f, 95); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	// 95 is rounded up to the 10 GB the rest of cg works in.
	if got := strings.Join(f.calls, ";"); got != "modify vol-games 200" {
		t.Errorf("%s", got)
	}
	ssh := sshLines(r.r)
	for _, want := range []string{"resize2fs", "blockdev --getsize64"} {
		if !strings.Contains(ssh, want) {
			t.Errorf("lacks %q in\n%s", want, ssh)
		}
	}
	for _, bad := range []string{"umount", "pkill", "mkfs"} {
		if strings.Contains(ssh, bad) {
			t.Errorf("growing a disk that is in use must not %q:\n%s", bad, ssh)
		}
	}
	if !strings.Contains(r.o.String(), "now 200 GB") {
		t.Errorf("%s", r.o)
	}
}

func TestAddDiskExplainsAWSsSixHourRule(t *testing.T) {
	r := diskRig(t)
	f := &fakeDisk{gamesVol: "vol-games", gamesGB: 100, modifyErr: errors.New("api error VolumeModificationRateExceeded: You've reached the maximum modification rate")}
	if rc := r.d.AddDisk(context.Background(), f, 50); rc != 1 || !strings.Contains(r.w.String(), "only once every 6 hours") {
		t.Errorf("%s", r.w)
	}
	if strings.Contains(sshLines(r.r), "resize2fs") {
		t.Error("nothing was made bigger, so nothing is resized")
	}
}

func TestAddDiskRefusesWhatWouldPassTheMost(t *testing.T) {
	r := diskRig(t)
	f := &fakeDisk{gamesVol: "vol-games", gamesGB: 950}
	if rc := r.d.AddDisk(context.Background(), f, 100); rc != 1 || !strings.Contains(r.w.String(), "more than a game PC here can hold") || len(f.calls) != 0 {
		t.Errorf("%s %v", r.w, f.calls)
	}
}

func TestAddDiskOnTheMachinesOwnDriveMakesAttachesAndMoves(t *testing.T) {
	r := diskRig(t)
	f := &fakeDisk{}
	if rc := r.d.AddDisk(context.Background(), f, 120); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	want := []string{"create 120GB gp3 ap-south-1b Name=gamevps,cg:host=gamevps,", "attach vol-new /dev/sdf", "mark /dev/sdf vol-new delete-with-box=true"}
	if got := strings.Join(f.calls, ";"); got != strings.Join(want, ";") {
		t.Errorf("%s", got)
	}
	ssh := sshLines(r.r)
	for _, want := range []string{"mkfs.ext4", "rsync", "DATA_GB=", "mount-scratch.sh", "pkill -x steam"} {
		if !strings.Contains(ssh, want) {
			t.Errorf("lacks %q in\n%s", want, ssh)
		}
	}
	// The games must never be copied FROM the new disk or onto itself, and the
	// disk that is formatted is only the one nothing is mounted on.
	if !strings.Contains(ssh, `MOUNTPOINT`) {
		t.Error("the new disk is the one with nothing mounted on it")
	}
	if len(f.deleted) != 0 {
		t.Errorf("a disk in use was deleted: %v", f.deleted)
	}
}

func TestAddDiskRemovesTheNewDiskIfItCannotBeConnected(t *testing.T) {
	r := diskRig(t)
	f := &fakeDisk{attachErr: errors.New("api error AttachmentLimitExceeded: no more")}
	if rc := r.d.AddDisk(context.Background(), f, 100); rc != 1 || !strings.Contains(r.w.String(), "would not connect the disk") {
		t.Errorf("%s", r.w)
	}
	if len(f.deleted) != 1 || f.deleted[0] != "vol-new" {
		t.Errorf("a disk that cannot be used must not be left billing: %v", f.deleted)
	}
	if strings.Contains(sshLines(r.r), "rsync") {
		t.Error("nothing to copy onto")
	}
}

func TestAddDiskNeedsARunningMachine(t *testing.T) {
	r := diskRig(t)
	r.e.state = "stopped"
	if rc := r.d.AddDisk(context.Background(), &fakeDisk{}, 100); rc != 1 || !strings.Contains(r.w.String(), "not running") {
		t.Errorf("%s", r.w)
	}
	r = diskRig(t)
	if rc := r.d.AddDisk(context.Background(), &fakeDisk{}, 0); rc != 1 {
		t.Errorf("how much? %s", r.w)
	}
}
