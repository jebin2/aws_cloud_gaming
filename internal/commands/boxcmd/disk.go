package boxcmd

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/jebin2/aws_cloud_gaming/internal/provision"
)

// DiskAPI is what adding space to the games disk asks of AWS. It is its own
// list, not part of box.EC2, so the machine's lifecycle does not grow a method
// for something only this file does.
type DiskAPI interface {
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
	DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error)
	DescribeVolumesModifications(context.Context, *ec2.DescribeVolumesModificationsInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesModificationsOutput, error)
	ModifyVolume(context.Context, *ec2.ModifyVolumeInput, ...func(*ec2.Options)) (*ec2.ModifyVolumeOutput, error)
	CreateVolume(context.Context, *ec2.CreateVolumeInput, ...func(*ec2.Options)) (*ec2.CreateVolumeOutput, error)
	AttachVolume(context.Context, *ec2.AttachVolumeInput, ...func(*ec2.Options)) (*ec2.AttachVolumeOutput, error)
	DeleteVolume(context.Context, *ec2.DeleteVolumeInput, ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error)
	ModifyInstanceAttribute(context.Context, *ec2.ModifyInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.ModifyInstanceAttributeOutput, error)
}

// gamesDevice is where the games disk is attached; the build puts it there too.
const gamesDevice = "/dev/sdf"

// DiskStatus is `cg disk --json`: how full the games' space is, and what adding
// to it would do. It is the one place the app learns whether Add disk grows a
// disk that is already there (the game keeps running) or has to move the games
// onto a new one (the game closes).
type DiskStatus struct {
	Running bool `json:"running"`
	// Disk is the size of the games disk in GB; 0 when the games live on the
	// machine's own drive.
	Disk    int     `json:"disk_gb"`
	TotalGB float64 `json:"total_gb"`
	UsedGB  float64 `json:"used_gb"`
	FreeGB  float64 `json:"free_gb"`
	// MaxAddGB is the most that can be added now.
	MaxAddGB int `json:"max_add_gb"`
	StepGB   int `json:"step_gb"`
	// Move: adding means moving the games onto a new disk, which closes Steam.
	Move bool `json:"move"`
}

// gamesVolume is the id of the games disk, "" when the machine has none, and
// the zone the machine is in.
func gamesVolume(ctx context.Context, c DiskAPI, id string) (vol, zone string, err error) {
	o, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{id}})
	if err != nil {
		return "", "", err
	}
	if len(o.Reservations) == 0 || len(o.Reservations[0].Instances) == 0 {
		return "", "", fmt.Errorf("InvalidInstanceID.NotFound: %s", id)
	}
	in := o.Reservations[0].Instances[0]
	if in.Placement != nil {
		zone = aws.ToString(in.Placement.AvailabilityZone)
	}
	for _, m := range in.BlockDeviceMappings {
		if aws.ToString(m.DeviceName) == gamesDevice && m.Ebs != nil {
			vol = aws.ToString(m.Ebs.VolumeId)
		}
	}
	return vol, zone, nil
}

func volumeGB(ctx context.Context, c DiskAPI, vol string) (int, error) {
	o, err := c.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{VolumeIds: []string{vol}})
	if err != nil {
		return 0, err
	}
	if len(o.Volumes) == 0 {
		return 0, fmt.Errorf("InvalidVolume.NotFound: %s", vol)
	}
	return int(aws.ToInt32(o.Volumes[0].Size)), nil
}

// df is the size and use of the games' space, in GB, as the machine sees it.
func (d Deps) df(ctx context.Context) (total, used float64, ok bool) {
	out, err := d.Box.SSH(ctx, "df -B1 --output=size,used /scratch | tail -1", nil)
	if err != nil {
		return 0, 0, false
	}
	f := strings.Fields(string(out))
	if len(f) < 2 {
		return 0, 0, false
	}
	t, e1 := strconv.ParseFloat(f[0], 64)
	u, e2 := strconv.ParseFloat(f[1], 64)
	if e1 != nil || e2 != nil {
		return 0, 0, false
	}
	return t / 1e9, u / 1e9, true
}

// Disk is `cg disk`.
func (d Deps) Disk(ctx context.Context, c DiskAPI, asJSON bool) int {
	if d.Box.ID == "" {
		return d.die("there is no game PC yet")
	}
	st := DiskStatus{StepGB: provision.ExtraDiskStepGB}
	if s, err := d.Box.State(ctx); err != nil {
		return d.die(err.Error())
	} else if s == "running" {
		if _, ok := d.Box.IP(ctx); ok {
			st.Running = true
		}
	}
	if st.Running {
		vol, _, err := gamesVolume(ctx, c, d.Box.ID)
		if err != nil {
			return d.die(firstErrorLine(err.Error()))
		}
		if vol != "" {
			if gb, err := volumeGB(ctx, c, vol); err == nil {
				st.Disk = gb
			}
		}
		st.Move = vol == ""
		st.MaxAddGB = provision.MaxExtraDiskGB - st.Disk
		if t, u, ok := d.df(ctx); ok {
			st.TotalGB, st.UsedGB, st.FreeGB = t, u, t-u
		}
	}
	if asJSON {
		b, _ := json.MarshalIndent(st, "", "  ")
		fmt.Fprintf(d.Out.Stdout, "%s\n", b)
		return 0
	}
	if !st.Running {
		d.Out.Log("the game PC is not running, so its space cannot be read")
		return 0
	}
	d.Out.Log(fmt.Sprintf("game space: %.0f of %.0f GB used, %.0f GB free", st.UsedGB, st.TotalGB, st.FreeGB))
	if st.Move {
		d.Out.Log("adding space moves your games onto a new disk, and closes Steam while it does")
	} else {
		d.Out.Log(fmt.Sprintf("adding space makes the %d GB disk bigger; the game keeps running", st.Disk))
	}
	return 0
}

// AddDisk is `cg disk add <GB>`: more room for the games on a machine that is
// running. A machine with a games disk gets it made bigger - AWS does that while
// it is in use, and the games, their archive and Steam never notice. A machine
// whose games sit on its own drive, which cannot grow, gets a new disk and the
// games are copied onto it; Steam is closed for that.
func (d Deps) AddDisk(ctx context.Context, c DiskAPI, gb int) int {
	if d.Box.ID == "" {
		return d.die("there is no game PC yet")
	}
	if gb < 1 {
		return d.die("how much space? For example: cg disk add 100")
	}
	if s, err := d.Box.State(ctx); err != nil || s != "running" {
		return d.die("the game PC is not running; start it first")
	}
	if !d.NeedNode(ctx) {
		return 1
	}
	step := provision.ExtraDiskStepGB
	gb = (gb + step - 1) / step * step

	d.Out.SayID("disk.find", "Looking at the game PC's disks")
	vol, zone, err := gamesVolume(ctx, c, d.Box.ID)
	if err != nil {
		return d.die(firstErrorLine(err.Error()))
	}
	have := 0
	if vol != "" {
		if have, err = volumeGB(ctx, c, vol); err != nil {
			return d.die(firstErrorLine(err.Error()))
		}
	}
	if have+gb > provision.MaxExtraDiskGB {
		return d.die(fmt.Sprintf("that is more than a game PC here can hold (%d GB of game disk at most; this one has %d GB)", provision.MaxExtraDiskGB, have))
	}
	if vol != "" {
		return d.growDisk(ctx, c, vol, have+gb)
	}
	return d.moveToNewDisk(ctx, c, zone, gb)
}

// growDisk makes the games disk bigger, then the filesystem on it.
func (d Deps) growDisk(ctx context.Context, c DiskAPI, vol string, target int) int {
	d.Out.SayID("disk.make", fmt.Sprintf("Making the disk %d GB", target))
	if _, err := c.ModifyVolume(ctx, &ec2.ModifyVolumeInput{VolumeId: aws.String(vol), Size: aws.Int32(int32(target))}); err != nil {
		if strings.Contains(err.Error(), "VolumeModificationRateExceeded") {
			return d.die("AWS lets a disk be made bigger only once every 6 hours, and this one was changed recently. Try again later.")
		}
		return d.die("AWS would not make the disk bigger: " + firstErrorLine(err.Error()))
	}
	if !d.waitModified(ctx, c, vol) {
		return 1
	}
	d.Out.SayID("disk.grow", "Telling the game PC about the new space")
	script := fmt.Sprintf(growScript, target)
	if err := d.relay(ctx, remote("bash", "-c", script)); err != nil {
		d.said(err)
		return d.die("the disk is bigger, but the game PC did not take up the new space. Try again.")
	}
	d.Out.SayID("disk.done", fmt.Sprintf("Done: the game disk is now %d GB", target))
	return 0
}

// waitModified waits until AWS has the new size in effect. It is usable as soon
// as the change is "optimizing": the rest is AWS tidying up in the background.
func (d Deps) waitModified(ctx context.Context, c DiskAPI, vol string) bool {
	for waited := 0; waited < 300; waited += 5 {
		if ctx.Err() != nil {
			return false
		}
		o, err := c.DescribeVolumesModifications(ctx, &ec2.DescribeVolumesModificationsInput{VolumeIds: []string{vol}})
		if err == nil && len(o.VolumesModifications) > 0 {
			switch o.VolumesModifications[0].ModificationState {
			case ec2types.VolumeModificationStateOptimizing, ec2types.VolumeModificationStateCompleted:
				return true
			case ec2types.VolumeModificationStateFailed:
				d.Out.Die("AWS could not make the disk bigger")
				return false
			}
		}
		d.sleep(5 * time.Second)
	}
	d.Out.Die("AWS is taking too long to make the disk bigger; look again in a few minutes")
	return false
}

// growScript waits for the machine to see the disk's new size, then grows the
// filesystem into it while it stays mounted. %d is the size in GB.
const growScript = `set -euo pipefail
want=%d
dev=$(findmnt -no SOURCE /scratch)
for i in $(seq 1 24); do
  have=$(( $(sudo blockdev --getsize64 "$dev") / 1073741824 ))
  [ "$have" -ge "$want" ] && break
  sleep 5
done
sudo resize2fs "$dev"
df -h /scratch | tail -1`

// moveToNewDisk attaches a new disk, copies the games onto it and mounts it
// where the games were. From then on this machine is one with a games disk, and
// the next Add disk just makes it bigger.
func (d Deps) moveToNewDisk(ctx context.Context, c DiskAPI, zone string, gb int) int {
	d.Out.SayID("disk.make", fmt.Sprintf("Making a %d GB disk", gb))
	tagKey := d.Box.TagKey
	if tagKey == "" {
		tagKey = "cg:host"
	}
	tags := []ec2types.Tag{{Key: aws.String("Name"), Value: aws.String(d.Box.Host)}, {Key: aws.String(tagKey), Value: aws.String(d.Box.Host)}}
	cv, err := c.CreateVolume(ctx, &ec2.CreateVolumeInput{
		AvailabilityZone: aws.String(zone), Size: aws.Int32(int32(gb)), VolumeType: ec2types.VolumeTypeGp3,
		TagSpecifications: []ec2types.TagSpecification{{ResourceType: ec2types.ResourceTypeVolume, Tags: tags}}})
	if err != nil {
		return d.die("AWS would not make the disk: " + firstErrorLine(err.Error()))
	}
	vol := aws.ToString(cv.VolumeId)
	// Whatever happens after this, the disk exists and bills: it is removed again
	// if it cannot be put to use, rather than left behind.
	fail := func(text string) int {
		if _, err := c.DeleteVolume(context.WithoutCancel(ctx), &ec2.DeleteVolumeInput{VolumeId: aws.String(vol)}); err != nil {
			d.Out.LogAs("warn", "the new disk could not be removed again; it is tagged for cg, and cg destroy takes it")
		}
		return d.die(text)
	}
	if !d.waitVolume(ctx, c, vol, "available") {
		return fail("the new disk did not become ready")
	}
	d.Out.SayID("disk.attach", "Connecting it to the game PC")
	if _, err := c.AttachVolume(ctx, &ec2.AttachVolumeInput{InstanceId: aws.String(d.Box.ID), VolumeId: aws.String(vol), Device: aws.String(gamesDevice)}); err != nil {
		return fail("AWS would not connect the disk: " + firstErrorLine(err.Error()))
	}
	if !d.waitVolume(ctx, c, vol, "in-use") {
		return d.die("the new disk is made but did not connect; cg destroy removes it, or try again")
	}
	// So that it goes with the machine and stops billing when the machine goes.
	if _, err := c.ModifyInstanceAttribute(ctx, &ec2.ModifyInstanceAttributeInput{
		InstanceId: aws.String(d.Box.ID),
		BlockDeviceMappings: []ec2types.InstanceBlockDeviceMappingSpecification{{
			DeviceName: aws.String(gamesDevice), Ebs: &ec2types.EbsInstanceBlockDeviceSpecification{VolumeId: aws.String(vol), DeleteOnTermination: aws.Bool(true)}}}}); err != nil {
		d.Out.LogAs("warn", "the disk was not marked to go with the machine; cg destroy still removes it")
	}
	d.Out.SayID("disk.copy", "Moving your games onto it. Steam closes while this happens")
	if err := d.relay(ctx, remote("bash", "-c", fmt.Sprintf(moveScript, gb))); err != nil {
		d.said(err)
		return d.die("the games could not be moved. They are still where they were; the new disk bills until the machine goes. Try again.")
	}
	d.Out.SayID("disk.done", fmt.Sprintf("Done: your games are on a %d GB disk", gb))
	return 0
}

// waitVolume waits for the disk to be in a state: "available", or "in-use" once
// attached.
func (d Deps) waitVolume(ctx context.Context, c DiskAPI, vol, want string) bool {
	for waited := 0; waited < 120; waited += 3 {
		if ctx.Err() != nil {
			return false
		}
		o, err := c.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{VolumeIds: []string{vol}})
		if err == nil && len(o.Volumes) > 0 {
			v := o.Volumes[0]
			if string(v.State) == want && (want != "in-use" || (len(v.Attachments) > 0 && v.Attachments[0].State == ec2types.VolumeAttachmentStateAttached)) {
				return true
			}
		}
		d.sleep(3 * time.Second)
	}
	return false
}

// moveScript puts the games on the new disk. %d is its size in GB, which the
// machine remembers (DATA_GB) so that every later boot mounts this disk at
// /scratch instead of looking for the drive that came with the machine.
//
// The new disk is the one nothing is mounted on: the root disk has its
// partitions mounted, and the machine's own drive is told apart by its model.
const moveScript = `set -euo pipefail
gb=%d
dev=""
for i in $(seq 1 30); do
  for n in $(lsblk -dno NAME,MODEL | awk '/Elastic Block Store/{print $1}'); do
    if [ -z "$(lsblk -no MOUNTPOINT "/dev/$n" | tr -d '[:space:]')" ]; then dev="/dev/$n"; break; fi
  done
  [ -n "$dev" ] && break
  sleep 2
done
[ -n "$dev" ] || { echo "the new disk did not show up on the game PC"; exit 1; }
sudo blkid "$dev" >/dev/null 2>&1 || sudo mkfs.ext4 -q -F -m 0 -L scratch "$dev"
sudo mkdir -p /mnt/newscratch
sudo mount -o noatime "$dev" /mnt/newscratch
echo "closing Steam"
sudo -u ubuntu pkill -x steam || true
sleep 3
echo "copying $(sudo du -sh /scratch/steam | cut -f1) of games"
sudo mkdir -p /mnt/newscratch/steam
if command -v rsync >/dev/null; then sudo rsync -aH /scratch/steam/ /mnt/newscratch/steam/; else sudo cp -a /scratch/steam/. /mnt/newscratch/steam/; fi
sudo umount /mnt/newscratch
sudo umount /scratch || { sudo fuser -km /scratch || true; sleep 2; sudo umount /scratch; }
sudo sed -i "s/^DATA_GB=.*/DATA_GB=$gb/" /usr/local/bin/mount-scratch.sh
sudo /usr/local/bin/mount-scratch.sh
mountpoint -q /scratch
df -h /scratch | tail -1
echo "your games are on the new disk"`
