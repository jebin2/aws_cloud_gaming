package boxcmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

// fakeDisk is the machine's disks, and what is done to them.
type fakeDisk struct {
	gamesVol    string // "" when the games live on the machine's own drive
	gamesGB     int32
	extraVol    string // the disk added beside the machine's own drive
	extraGB     int32
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
	detached    []string
	launched    time.Time // the machine's launch time; zero leaves it unset
	size        int32     // the size asked for
}

func (f *fakeDisk) DetachVolume(_ context.Context, in *ec2.DetachVolumeInput, _ ...func(*ec2.Options)) (*ec2.DetachVolumeOutput, error) {
	f.detached = append(f.detached, aws.ToString(in.VolumeId))
	f.extraVol = ""
	f.newVol, f.newState, f.newAttached = aws.ToString(in.VolumeId), "available", false
	return &ec2.DetachVolumeOutput{}, nil
}

func (f *fakeDisk) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	in := ec2types.Instance{InstanceId: aws.String("i-0abc"), Placement: &ec2types.Placement{AvailabilityZone: aws.String("ap-south-1b")},
		BlockDeviceMappings: []ec2types.InstanceBlockDeviceMapping{{DeviceName: aws.String("/dev/sda1"), Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String("vol-root")}}}}
	if f.gamesVol != "" {
		in.BlockDeviceMappings = append(in.BlockDeviceMappings, ec2types.InstanceBlockDeviceMapping{DeviceName: aws.String("/dev/sdf"), Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String(f.gamesVol)}})
	}
	if !f.launched.IsZero() {
		in.LaunchTime = aws.Time(f.launched)
	}
	if f.extraVol != "" {
		in.BlockDeviceMappings = append(in.BlockDeviceMappings, ec2types.InstanceBlockDeviceMapping{DeviceName: aws.String("/dev/sdg"), Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String(f.extraVol)}})
	} else if f.newAttached {
		// The disk this fake just made and connected, as AWS would then list it.
		in.BlockDeviceMappings = append(in.BlockDeviceMappings, ec2types.InstanceBlockDeviceMapping{DeviceName: aws.String("/dev/sdg"), Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String("vol-new")}})
	}
	return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: []ec2types.Instance{in}}}}, nil
}
func (f *fakeDisk) DescribeVolumes(_ context.Context, in *ec2.DescribeVolumesInput, _ ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	id := in.VolumeIds[0]
	switch {
	case id == f.gamesVol:
		return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{{VolumeId: aws.String(id), Size: aws.Int32(f.gamesGB)}}}, nil
	case f.extraVol != "" && id == f.extraVol:
		return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{{VolumeId: aws.String(id), Size: aws.Int32(f.extraGB)}}}, nil
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

func TestDiskStatusSaysWhetherAddingGrowsOrAddsASecondDisk(t *testing.T) {
	for _, c := range []struct {
		vol    string
		gb     int32
		second bool
		max    int
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
		if !st.Running || st.Second != c.second || st.MaxAddGB != c.max || st.Disk != int(c.gb) || st.StepGB != 10 {
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

func TestDiskStatusSaysWhetherSteamListsTheAddedDisk(t *testing.T) {
	for _, listed := range []bool{false, true} {
		r := diskRig(t)
		inner := r.r.Hook
		r.r.Hook = func(line string) (bool, string, error) {
			if strings.Contains(line, "libraryfolders.vdf") {
				if !strings.Contains(line, "/scratch2") || strings.Contains(line, "/scratch2/steam") {
					t.Errorf("it looks for any library on the added disk, not one folder: %s", line)
				}
				if listed {
					return true, "yes\n", nil
				}
				return true, "", fmt.Errorf("exit status 1")
			}
			return inner(line)
		}
		if rc := r.d.Disk(context.Background(), &fakeDisk{gamesVol: "vol-games", gamesGB: 100}, true); rc != 0 {
			t.Fatalf("%s%s", r.o, r.w)
		}
		var st DiskStatus
		if err := json.Unmarshal(r.o.Bytes(), &st); err != nil {
			t.Fatalf("%v\n%s", err, r.o)
		}
		if st.ExtraInSteam != listed {
			t.Errorf("Steam lists the disk = %v, status says %v", listed, st.ExtraInSteam)
		}
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
	for _, want := range []string{"resize2fs", "blockdev --getsize64", "mnt=/scratch2"} {
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

func TestAddDiskOnTheMachinesOwnDriveAttachesASecondDiskAndMovesNothing(t *testing.T) {
	r := diskRig(t)
	f := &fakeDisk{}
	if rc := r.d.AddDisk(context.Background(), f, 120); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	want := []string{"create 120GB gp3 ap-south-1b Name=gamevps,cg:host=gamevps,", "attach vol-new /dev/sdg", "mark /dev/sdg vol-new delete-with-box=true"}
	if got := strings.Join(f.calls, ";"); got != strings.Join(want, ";") {
		t.Errorf("%s", got)
	}
	ssh := sshLines(r.r)
	for _, want := range []string{"mkfs.ext4", "cgextra", "/scratch2", "steam-add-extra-library", "cg-extra-library.service", "base64 -d", "MOUNTPOINT"} {
		if !strings.Contains(ssh, want) {
			t.Errorf("lacks %q in\n%s", want, ssh)
		}
	}
	// The games stay where they are and Steam is not closed under a game.
	for _, never := range []string{"rsync", "pkill", "umount", "DATA_GB="} {
		if strings.Contains(ssh, never) {
			t.Errorf("moved or closed something (%q):\n%s", never, ssh)
		}
	}
	if !strings.Contains(r.o.String()+r.w.String(), "Settings > Storage > Add Drive > pick the drive at /scratch2 (named cgextra)") {
		t.Errorf("it says what to do next: %s%s", r.o, r.w)
	}
	if len(f.deleted) != 0 {
		t.Errorf("a disk in use was deleted: %v", f.deleted)
	}
}

func TestAddDiskAgainMakesTheSecondDiskBigger(t *testing.T) {
	r := diskRig(t)
	f := &fakeDisk{extraVol: "vol-extra", extraGB: 100, modState: ec2types.VolumeModificationStateOptimizing}
	if rc := r.d.AddDisk(context.Background(), f, 50); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	if got := strings.Join(f.calls, ";"); got != "modify vol-extra 150" {
		t.Errorf("%s", got)
	}
	if ssh := sshLines(r.r); !strings.Contains(ssh, "mnt=/scratch2") || !strings.Contains(ssh, "resize2fs") {
		t.Errorf("the second disk's own filesystem is grown:\n%s", ssh)
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

// A stopped machine with an added disk: whether it may be deleted depends on the
// archive alone - a save that finished clean, after the machine last started.
func stoppedRig(t *testing.T, pushed func(context.Context) (time.Time, bool, error)) (*rig, *fakeDisk) {
	r := diskRig(t)
	r.e.state = "stopped"
	r.d.Pushed = pushed
	f := &fakeDisk{extraVol: "vol-extra", extraGB: 160, launched: time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)}
	return r, f
}

func TestStoppedDiskSaysWhetherItMayBeRemoved(t *testing.T) {
	launch := time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		name   string
		pushed func(context.Context) (time.Time, bool, error)
		ok     bool
		why    string
	}{
		{"saved after it started", func(context.Context) (time.Time, bool, error) { return launch.Add(time.Hour), true, nil }, true, ""},
		{"no complete save", func(context.Context) (time.Time, bool, error) { return time.Time{}, false, nil }, false, "no complete save"},
		{"saved before it started", func(context.Context) (time.Time, bool, error) { return launch.Add(-time.Hour), true, nil }, false, "not been saved since"},
		{"archive unreadable", func(context.Context) (time.Time, bool, error) { return time.Time{}, false, fmt.Errorf("AccessDenied") }, false, "could not read Saved games"},
	} {
		r, f := stoppedRig(t, c.pushed)
		if rc := r.d.Disk(context.Background(), f, true); rc != 0 {
			t.Fatalf("%s: %s%s", c.name, r.o, r.w)
		}
		var st DiskStatus
		if err := json.Unmarshal(r.o.Bytes(), &st); err != nil {
			t.Fatalf("%v\n%s", err, r.o)
		}
		if st.State != "stopped" || st.ExtraGB != 160 || st.Removable != c.ok || !strings.Contains(st.Why, c.why) {
			t.Errorf("%s: %+v", c.name, st)
		}
	}
	r, _ := stoppedRig(t, nil)
	r.d.Pushed = nil
	if rc := r.d.Disk(context.Background(), &fakeDisk{extraVol: "vol-extra", extraGB: 160}, true); rc != 0 || strings.Contains(r.o.String(), `"removable": true`) {
		t.Errorf("without a way to read the archive nothing is removable: %s", r.o)
	}
}

// Chosen at Stop machine with the loss shown (a download no save can hold): the
// disk goes although Saved games has no complete save, and the log says so.
func TestRemoveDiskUnsavedOKIsTheChosenLoss(t *testing.T) {
	r, f := stoppedRig(t, func(context.Context) (time.Time, bool, error) { return time.Time{}, false, nil })
	r.d.UnsavedOK = true
	if rc := r.d.RemoveDisk(context.Background(), f); rc != 0 || len(f.deleted) != 1 || !strings.Contains(r.o.String()+r.w.String(), "chosen at Stop machine") {
		t.Errorf("rc %d deleted %v\n%s%s", rc, f.deleted, r.o, r.w)
	}
}

func TestRemoveDiskDeletesOnlyAfterACompleteSave(t *testing.T) {
	launch := time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)
	r, f := stoppedRig(t, func(context.Context) (time.Time, bool, error) { return launch.Add(time.Hour), true, nil })
	if rc := r.d.RemoveDisk(context.Background(), f); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	if len(f.detached) != 1 || f.detached[0] != "vol-extra" || len(f.deleted) != 1 || f.deleted[0] != "vol-extra" {
		t.Errorf("detached %v, deleted %v", f.detached, f.deleted)
	}

	r, f = stoppedRig(t, func(context.Context) (time.Time, bool, error) { return time.Time{}, false, nil })
	if rc := r.d.RemoveDisk(context.Background(), f); rc == 0 {
		t.Errorf("no complete save must refuse: %s", r.o)
	}
	if len(f.detached) != 0 || len(f.deleted) != 0 {
		t.Errorf("nothing may be touched: detached %v, deleted %v", f.detached, f.deleted)
	}

	r, f = stoppedRig(t, func(context.Context) (time.Time, bool, error) { return launch.Add(time.Hour), true, nil })
	r.e.state = "running"
	if rc := r.d.RemoveDisk(context.Background(), f); rc == 0 || len(f.deleted) != 0 {
		t.Errorf("a running machine's disk is never removed: %s", r.o)
	}
	r, f = stoppedRig(t, func(context.Context) (time.Time, bool, error) { return launch.Add(time.Hour), true, nil })
	f.extraVol = ""
	if rc := r.d.RemoveDisk(context.Background(), f); rc == 0 {
		t.Errorf("no disk to remove must say so: %s", r.o)
	}
}

// Play with a disk on a machine that is ALREADY running: the disk is made and
// connected then. It used to fail with "the games disk is not connected", because
// only a stopped machine went through the step that makes it.
func TestPlayOnARunningMachineMakesTheDiskToo(t *testing.T) {
	r := diskRig(t)
	r.e.state = "running"
	f := &fakeDisk{}
	r.d.DiskAWS, r.d.ExtraGB = f, 30
	if rc := r.d.extraAfterStart(context.Background()); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.w)
	}
	want := []string{"create 30GB gp3 ap-south-1b Name=", "attach vol-new /dev/sdg"}
	for i, w := range want {
		if i >= len(f.calls) || !strings.HasPrefix(f.calls[i], w) {
			t.Errorf("call %d: want %q, calls %v", i, w, f.calls)
		}
	}
	if strings.Contains(r.w.String(), "not connected") {
		t.Errorf("it said not connected: %s", r.w)
	}
}

func TestPlayAfterRemovalMakesTheDiskBeforeTheMachineStarts(t *testing.T) {
	r := diskRig(t)
	r.e.state = "stopped"
	f := &fakeDisk{}
	r.d.DiskAWS, r.d.ExtraGB, r.d.ExtraApps = f, 95, "2358720,1245620"
	if rc := r.d.extraBeforeStart(context.Background()); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	want := []string{"create 100GB gp3 ap-south-1b Name=", "attach vol-new /dev/sdg", "mark /dev/sdg vol-new delete-with-box=true"}
	for i, w := range want {
		if i >= len(f.calls) || !strings.HasPrefix(f.calls[i], w) {
			t.Errorf("call %d: want %q, calls %v", i, w, f.calls)
		}
	}
	// A disk that is already there is left alone.
	r = diskRig(t)
	f = &fakeDisk{extraVol: "vol-extra", extraGB: 160}
	r.d.DiskAWS, r.d.ExtraGB = f, 95
	if rc := r.d.extraBeforeStart(context.Background()); rc != 0 || len(f.calls) != 0 {
		t.Errorf("a disk that is there is not made again: rc %d calls %v", rc, f.calls)
	}
	// Anything that is not a list of game ids never reaches the machine's shell.
	r = diskRig(t)
	r.d.DiskAWS, r.d.ExtraGB, r.d.ExtraApps = &fakeDisk{}, 95, "1; rm -rf /"
	if rc := r.d.extraBeforeStart(context.Background()); rc == 0 {
		t.Error("a game list with a shell command in it must be refused")
	}
}
