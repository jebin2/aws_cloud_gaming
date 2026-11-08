package boxcmd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	cg "github.com/jebin2/aws_cloud_gaming"
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
	DetachVolume(context.Context, *ec2.DetachVolumeInput, ...func(*ec2.Options)) (*ec2.DetachVolumeOutput, error)
	DeleteVolume(context.Context, *ec2.DeleteVolumeInput, ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error)
	ModifyInstanceAttribute(context.Context, *ec2.ModifyInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.ModifyInstanceAttributeOutput, error)
}

// The disk added for the games that do not fit the machine's own drive is
// /dev/sdf when the build made it and /dev/sdg when Add disk did (the same disk,
// told apart only by when it was made), and is mounted at /scratch2 either way.
// The machine's own drive stays at /scratch.
const (
	gamesDevice = "/dev/sdf"
	extraDevice = "/dev/sdg"
	gamesMount  = "/scratch"
	extraMount  = "/scratch2"
)

// DiskStatus is `cg disk --json`: how full the games' space is, and what adding
// to it would do. It is the one place the app learns whether Add disk grows a
// disk that is already there (the game keeps running) or has to move the games
// puts a second disk beside the machine's drive (Steam is closed and opened
// again to see it).
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
	// Second: adding puts a second disk beside the machine's own drive. Nothing is
	// moved or closed; Steam sees the new folder once it has been closed and
	// opened again.
	Second bool `json:"second"`
	// ExtraInSteam: Steam's own list of folders has the added disk in it, so a game
	// can be put there. The app asks for it when the person says they added the
	// disk in Steam's storage settings, and says so when it is not there yet.
	ExtraInSteam bool `json:"extra_in_steam"`
	// State is the machine's: "running", "stopped" and so on. The rest is read
	// from AWS and the archive alone, so it is answered with the machine off.
	State string `json:"state,omitempty"`
	// ExtraGB is the added disk's size, running or stopped; 0 when there is none.
	ExtraGB int `json:"extra_gb"`
	// Removable: the machine is stopped, has an added disk, and the archive holds
	// everything saved since it last started. Why is the reason when it does not.
	Removable bool `json:"removable"`
	// StoppedAt is when it stopped (RFC 3339), when AWS says; ExpiryDays is how
	// long a stopped machine is kept before the watchdog deletes it (0 = never).
	StoppedAt  string `json:"stopped_at,omitempty"`
	ExpiryDays int    `json:"expiry_days,omitempty"`
	Why        string `json:"why,omitempty"`
}

// addedVolume is the id of the disk added for the games, "" when the machine has
// none, and the zone the machine is in.
func addedVolume(ctx context.Context, c DiskAPI, id string) (vol, zone string, err error) {
	vol, zone, _, _, err = diskFacts(ctx, c, id)
	return vol, zone, err
}

var stopReason = regexp.MustCompile(`\((\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) GMT\)`)

// diskFacts is addedVolume and when the machine last started (AWS restarts the
// launch time at every start), which says whether a push is newer than the session.
func diskFacts(ctx context.Context, c DiskAPI, id string) (vol, zone string, launched time.Time, stopped string, err error) {
	o, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{id}})
	if err != nil {
		return "", "", time.Time{}, "", err
	}
	if len(o.Reservations) == 0 || len(o.Reservations[0].Instances) == 0 {
		return "", "", time.Time{}, "", fmt.Errorf("InvalidInstanceID.NotFound: %s", id)
	}
	in := o.Reservations[0].Instances[0]
	if in.Placement != nil {
		zone = aws.ToString(in.Placement.AvailabilityZone)
	}
	if in.LaunchTime != nil {
		launched = *in.LaunchTime
	}
	// "User initiated (2026-11-08 12:00:11 GMT)": when it stopped, if AWS says.
	if m := stopReason.FindStringSubmatch(aws.ToString(in.StateTransitionReason)); m != nil {
		if t, perr := time.Parse("2006-01-02 15:04:05", m[1]); perr == nil {
			stopped = t.UTC().Format(time.RFC3339)
		}
	}
	for _, m := range in.BlockDeviceMappings {
		if m.Ebs == nil {
			continue
		}
		if d := aws.ToString(m.DeviceName); d == gamesDevice || d == extraDevice {
			vol = aws.ToString(m.Ebs.VolumeId)
		}
	}
	return vol, zone, launched, stopped, nil
}

// removable says whether the added disk may be deleted: the machine is stopped
// and the archive holds every game as of the last time it ran. The marker the
// box's push writes only when it saved everything is the evidence; nothing else
// is, and an answer that cannot be read is a no.
func (d Deps) removable(ctx context.Context, launched time.Time) (bool, string) {
	if d.Pushed == nil {
		return false, "could not read Saved games"
	}
	at, found, err := d.Pushed(ctx)
	switch {
	case err != nil:
		return false, "could not read Saved games: " + firstErrorLine(err.Error())
	case !found:
		return false, "Saved games has no complete save from this machine. Start it, let it go idle and stop by itself, then try again"
	case !launched.IsZero() && at.Before(launched):
		return false, "the games have not been saved since the machine last started. Start it, let it go idle and stop by itself, then try again"
	}
	return true, ""
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

// df is the size and use of the games' space, in GB, as the machine sees it:
// the games disk or the machine's own drive, and the disk added beside it.
func (d Deps) df(ctx context.Context) (total, used float64, ok bool) {
	out, err := d.Box.SSH(ctx, "df -B1 --output=size,used "+gamesMount+" "+extraMount+" 2>/dev/null | tail -n +2", nil)
	if err != nil {
		return 0, 0, false
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		t, e1 := strconv.ParseFloat(f[0], 64)
		u, e2 := strconv.ParseFloat(f[1], 64)
		if e1 != nil || e2 != nil {
			continue
		}
		total, used, ok = total+t/1e9, used+u/1e9, true
	}
	return total, used, ok
}

// extraInSteam is whether Steam's list of folders, as the machine has it, holds a
// library on the disk added beside the machine's own drive.
func (d Deps) extraInSteam(ctx context.Context) bool {
	// Steam's Add Drive does not use the folder cg made: it lists the drives and
	// creates its own folder on the one picked (/scratch2/SteamLibrary), so any
	// library on the added disk counts, wherever Steam put it.
	out, err := d.Box.SSH(ctx, `grep -qsE '"path"[[:space:]]*"`+extraMount+`(/[^"]*)?"' /home/ubuntu/.local/share/Steam/config/libraryfolders.vdf && echo yes`, nil)
	return err == nil && strings.TrimSpace(string(out)) == "yes"
}

// Disk is `cg disk`.
func (d Deps) Disk(ctx context.Context, c DiskAPI, asJSON bool) int {
	if d.Box.ID == "" {
		return d.die("there is no game PC yet")
	}
	st := DiskStatus{StepGB: provision.ExtraDiskStepGB}
	if s, err := d.Box.State(ctx); err != nil {
		return d.die(err.Error())
	} else {
		st.State = s
		if s == "running" {
			if _, ok := d.Box.IP(ctx); ok {
				st.Running = true
			}
		}
	}
	if st.State == "stopped" {
		vol, _, launched, stopped, err := diskFacts(ctx, c, d.Box.ID)
		if err != nil {
			return d.die(firstErrorLine(err.Error()))
		}
		st.StoppedAt = stopped
		if v := strings.TrimSpace(d.Env.Get("GAME_ARCHIVE_EXPIRY_DAYS")); v != "" {
			st.ExpiryDays, _ = strconv.Atoi(v)
		} else {
			st.ExpiryDays = 14
		}
		if vol != "" {
			if gb, err := volumeGB(ctx, c, vol); err == nil {
				st.ExtraGB = gb
			}
			st.Removable, st.Why = d.removable(ctx, launched)
		}
	}
	if st.Running {
		vol, _, err := addedVolume(ctx, c, d.Box.ID)
		if err != nil {
			return d.die(firstErrorLine(err.Error()))
		}
		if vol != "" {
			if gb, err := volumeGB(ctx, c, vol); err == nil {
				st.Disk = gb
				st.ExtraGB = gb
			}
		}
		st.Second = vol == ""
		st.ExtraInSteam = d.extraInSteam(ctx)
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
	if st.Second {
		d.Out.Log("adding space puts a second disk beside the machine's own drive; nothing is moved or closed")
	} else {
		d.Out.Log(fmt.Sprintf("adding space makes the %d GB of added disk bigger; the game keeps running", st.Disk))
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
	vol, zone, err := addedVolume(ctx, c, d.Box.ID)
	if err != nil {
		return d.die(firstErrorLine(err.Error()))
	}
	// A disk already added is the one made bigger; a machine with only its own
	// drive, which cannot grow, gets one.
	have := 0
	if vol != "" {
		if have, err = volumeGB(ctx, c, vol); err != nil {
			return d.die(firstErrorLine(err.Error()))
		}
	}
	if have+gb > provision.MaxExtraDiskGB {
		return d.die(fmt.Sprintf("that is more than a game PC here can hold (%d GB of added disk at most; this one has %d GB)", provision.MaxExtraDiskGB, have))
	}
	if vol != "" {
		return d.growDisk(ctx, c, vol, extraMount, have+gb)
	}
	return d.addSecondDisk(ctx, c, zone, gb)
}

// growDisk makes the games disk bigger, then the filesystem on it.
func (d Deps) growDisk(ctx context.Context, c DiskAPI, vol, mount string, target int) int {
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
	script := fmt.Sprintf(growScript, target, mount)
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
// filesystem into it while it stays mounted. The first %d is the size in GB, the
// second the place it is mounted.
const growScript = `set -euo pipefail
want=%[1]d
mnt=%[2]s
dev=$(findmnt -no SOURCE "$mnt")
for i in $(seq 1 24); do
  have=$(( $(sudo blockdev --getsize64 "$dev") / 1073741824 ))
  [ "$have" -ge "$want" ] && break
  sleep 5
done
sudo resize2fs "$dev"
df -h "$mnt" | tail -1`

// addSecondDisk attaches a new disk beside the machine's own drive and mounts
// it at /scratch2 as a place for games. Nothing is copied and nothing closes:
// the games stay where they are, and Steam is told about the new folder when it
// next closes (it rewrites its list of folders as it exits, so it is not edited
// under a running Steam). From then on the machine has a disk of its own to
// grow, and the next Add disk just makes that one bigger.
func (d Deps) addSecondDisk(ctx context.Context, c DiskAPI, zone string, gb int) int {
	vol, code := d.makeAndAttach(ctx, c, zone, gb)
	if vol == "" {
		return code
	}
	return d.setUpExtra(ctx, c, vol, gb)
}

// makeAndAttach makes the disk and connects it to the machine, running or
// stopped (AWS attaches to either). "" and the exit code when it could not.
func (d Deps) makeAndAttach(ctx context.Context, c DiskAPI, zone string, gb int) (string, int) {
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
		return "", d.die("AWS would not make the disk: " + firstErrorLine(err.Error()))
	}
	vol := aws.ToString(cv.VolumeId)
	// Whatever happens after this, the disk exists and bills: it is removed again
	// if it cannot be put to use, rather than left behind.
	fail := func(text string) (string, int) {
		d.dropVolume(ctx, c, vol)
		return "", d.die(text)
	}
	if !d.waitVolume(ctx, c, vol, "available") {
		return fail("the new disk did not become ready")
	}
	d.Out.SayID("disk.attach", "Connecting it to the game PC")
	if _, err := c.AttachVolume(ctx, &ec2.AttachVolumeInput{InstanceId: aws.String(d.Box.ID), VolumeId: aws.String(vol), Device: aws.String(extraDevice)}); err != nil {
		return fail("AWS would not connect the disk: " + firstErrorLine(err.Error()))
	}
	if !d.waitVolume(ctx, c, vol, "in-use") {
		return "", d.die("the new disk is made but did not connect; cg destroy removes it, or try again")
	}
	// So that it goes with the machine and stops billing when the machine goes.
	if _, err := c.ModifyInstanceAttribute(ctx, &ec2.ModifyInstanceAttributeInput{
		InstanceId: aws.String(d.Box.ID),
		BlockDeviceMappings: []ec2types.InstanceBlockDeviceMappingSpecification{{
			DeviceName: aws.String(extraDevice), Ebs: &ec2types.EbsInstanceBlockDeviceSpecification{VolumeId: aws.String(vol), DeleteOnTermination: aws.Bool(true)}}}}); err != nil {
		d.Out.LogAs("warn", "the disk was not marked to go with the machine; cg destroy still removes it")
	}
	return vol, 0
}

// dropVolume deletes a disk that could not be put to use, rather than leave it billing.
func (d Deps) dropVolume(ctx context.Context, c DiskAPI, vol string) {
	if _, err := c.DeleteVolume(context.WithoutCancel(ctx), &ec2.DeleteVolumeInput{VolumeId: aws.String(vol)}); err != nil {
		d.Out.LogAs("warn", "the new disk could not be removed again; it is tagged for cg, and cg destroy takes it")
	}
}

// setUpExtra formats and mounts the connected disk, on the running machine.
func (d Deps) setUpExtra(ctx context.Context, c DiskAPI, vol string, gb int) int {
	d.Out.SayID("disk.copy", "Setting the new disk up")
	script, err := extraScript()
	if err != nil {
		d.dropVolume(ctx, c, vol)
		return d.die("the app is missing a file it needs: " + err.Error())
	}
	if err := d.relay(ctx, remote("bash", "-c", script)); err != nil {
		d.said(err)
		return d.die("the new disk could not be set up. Your games are untouched; the new disk bills until the machine goes. Try again.")
	}
	d.Out.SayID("disk.done", fmt.Sprintf("Done: %d GB added. In Steam: Settings > Storage > Add Drive > pick the drive named cgextra", gb))
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

// extraScript makes the new disk a place for games. The new disk is the one
// nothing is mounted on: the root disk has its partitions mounted, and the
// machine's own drive is told apart by its model. It is mounted at /scratch2
// by label on every boot ("nofail": a machine that lost it still starts).
//
// Steam is told about the folder by steam-add-extra-library, a service that
// waits for Steam to be closed first: Steam writes its list of folders as it
// exits, and an entry added while it runs is thrown away. Its files are the ones
// a new build installs (host/), carried over here so there is one copy of them.
func extraScript() (string, error) {
	helper, err := cg.Files.ReadFile("host/steam-add-extra-library")
	if err != nil {
		return "", err
	}
	unit, err := cg.Files.ReadFile("host/cg-extra-library.service")
	if err != nil {
		return "", err
	}
	b64 := func(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
	return fmt.Sprintf(extraScriptHead+`
echo '%s' | base64 -d | sudo tee /usr/local/bin/steam-add-extra-library >/dev/null
sudo chmod 755 /usr/local/bin/steam-add-extra-library
echo '%s' | base64 -d | sudo tee /etc/systemd/system/cg-extra-library.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable cg-extra-library >/dev/null 2>&1
sudo systemctl restart cg-extra-library
df -h /scratch2 | tail -1
echo "the new disk is ready"`, b64(helper), b64(unit)), nil
}

const extraScriptHead = `set -euo pipefail
dev=""
for i in $(seq 1 30); do
  for n in $(lsblk -dno NAME,MODEL | awk '/Elastic Block Store/{print $1}'); do
    if [ -z "$(lsblk -no MOUNTPOINT "/dev/$n" | tr -d '[:space:]')" ]; then dev="/dev/$n"; break; fi
  done
  [ -n "$dev" ] && break
  sleep 2
done
[ -n "$dev" ] || { echo "the new disk did not show up on the game PC"; exit 1; }
sudo blkid "$dev" >/dev/null 2>&1 || sudo mkfs.ext4 -q -F -m 0 -L cgextra "$dev"
sudo mkdir -p /scratch2
grep -q '^LABEL=cgextra ' /etc/fstab || echo 'LABEL=cgextra /scratch2 ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab >/dev/null
mountpoint -q /scratch2 || sudo mount /scratch2
sudo mkdir -p /scratch2/steam/steamapps/common
sudo chown -R ubuntu:ubuntu /scratch2`

// RemoveDisk is `cg disk remove`: delete the games disk of a STOPPED machine.
// The games are in Saved games, and the disk is $0.0912 a GB-month for nothing.
// It refuses unless the archive says everything was saved since the machine
// last started, because this deletes the only other copy of whatever was not.
func (d Deps) RemoveDisk(ctx context.Context, c DiskAPI) int {
	if d.Box.ID == "" {
		return d.die("there is no game PC yet")
	}
	if s, err := d.Box.State(ctx); err != nil {
		return d.die(firstErrorLine(err.Error()))
	} else if s != "stopped" {
		return d.die("the game PC is " + s + "; a disk can only be removed while it is stopped")
	}
	d.Out.SayID("disk.find", "Looking at the game PC's disks")
	vol, _, launched, _, err := diskFacts(ctx, c, d.Box.ID)
	if err != nil {
		return d.die(firstErrorLine(err.Error()))
	}
	if vol == "" {
		return d.die("this game PC has no added disk")
	}
	if ok, why := d.removable(ctx, launched); !ok {
		return d.die("not removing the disk: " + why)
	}
	d.Out.SayID("disk.remove", "Disconnecting the disk")
	if _, err := c.DetachVolume(ctx, &ec2.DetachVolumeInput{VolumeId: aws.String(vol), InstanceId: aws.String(d.Box.ID)}); err != nil {
		return d.die("AWS would not disconnect the disk: " + firstErrorLine(err.Error()))
	}
	if !d.waitVolume(ctx, c, vol, "available") {
		return d.die("the disk did not disconnect; nothing was deleted. Try again")
	}
	d.Out.SayID("disk.delete", "Deleting the disk")
	if _, err := c.DeleteVolume(ctx, &ec2.DeleteVolumeInput{VolumeId: aws.String(vol)}); err != nil {
		return d.die("AWS would not delete the disk: " + firstErrorLine(err.Error()))
	}
	d.Out.SayID("disk.removed", "Done: the games disk is gone. Playing again makes a new one and brings your games back from Saved games")
	return 0
}
