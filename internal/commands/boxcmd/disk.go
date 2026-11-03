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
// extraDevice is where a disk added to a machine that had none goes: beside the
// machine's own drive, mounted at /scratch2, with the games left where they are.
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
}

// volumes are the ids of the games disk and of the disk added beside the
// machine's own drive, "" for one that is not there, and the zone the machine
// is in.
func volumes(ctx context.Context, c DiskAPI, id string) (games, extra, zone string, err error) {
	o, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{id}})
	if err != nil {
		return "", "", "", err
	}
	if len(o.Reservations) == 0 || len(o.Reservations[0].Instances) == 0 {
		return "", "", "", fmt.Errorf("InvalidInstanceID.NotFound: %s", id)
	}
	in := o.Reservations[0].Instances[0]
	if in.Placement != nil {
		zone = aws.ToString(in.Placement.AvailabilityZone)
	}
	for _, m := range in.BlockDeviceMappings {
		if m.Ebs == nil {
			continue
		}
		switch aws.ToString(m.DeviceName) {
		case gamesDevice:
			games = aws.ToString(m.Ebs.VolumeId)
		case extraDevice:
			extra = aws.ToString(m.Ebs.VolumeId)
		}
	}
	return games, extra, zone, nil
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
		games, extra, _, err := volumes(ctx, c, d.Box.ID)
		if err != nil {
			return d.die(firstErrorLine(err.Error()))
		}
		for _, vol := range []string{games, extra} {
			if vol != "" {
				if gb, err := volumeGB(ctx, c, vol); err == nil {
					st.Disk += gb
				}
			}
		}
		st.Second = games == "" && extra == ""
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
	games, extra, zone, err := volumes(ctx, c, d.Box.ID)
	if err != nil {
		return d.die(firstErrorLine(err.Error()))
	}
	// Whichever disk is already there is the one made bigger; a machine with
	// only its own drive, which cannot grow, gets a second disk.
	vol, mount := games, gamesMount
	if extra != "" {
		vol, mount = extra, extraMount
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
		return d.growDisk(ctx, c, vol, mount, have+gb)
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
	if _, err := c.AttachVolume(ctx, &ec2.AttachVolumeInput{InstanceId: aws.String(d.Box.ID), VolumeId: aws.String(vol), Device: aws.String(extraDevice)}); err != nil {
		return fail("AWS would not connect the disk: " + firstErrorLine(err.Error()))
	}
	if !d.waitVolume(ctx, c, vol, "in-use") {
		return d.die("the new disk is made but did not connect; cg destroy removes it, or try again")
	}
	// So that it goes with the machine and stops billing when the machine goes.
	if _, err := c.ModifyInstanceAttribute(ctx, &ec2.ModifyInstanceAttributeInput{
		InstanceId: aws.String(d.Box.ID),
		BlockDeviceMappings: []ec2types.InstanceBlockDeviceMappingSpecification{{
			DeviceName: aws.String(extraDevice), Ebs: &ec2types.EbsInstanceBlockDeviceSpecification{VolumeId: aws.String(vol), DeleteOnTermination: aws.Bool(true)}}}}); err != nil {
		d.Out.LogAs("warn", "the disk was not marked to go with the machine; cg destroy still removes it")
	}
	d.Out.SayID("disk.copy", "Setting the new disk up")
	if err := d.relay(ctx, remote("bash", "-c", extraScript)); err != nil {
		d.said(err)
		return d.die("the new disk could not be set up. Your games are untouched; the new disk bills until the machine goes. Try again.")
	}
	d.Out.SayID("disk.done", fmt.Sprintf("Done: %d GB added. Close Steam and open it again to see the new space", gb))
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
// Steam is told about the folder by steam-add-extra-library, which waits for
// Steam to be closed first: Steam writes its list of folders as it exits, and an
// entry added while it runs is thrown away.
const extraScript = `set -euo pipefail
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
sudo chown -R ubuntu:ubuntu /scratch2
sudo tee /usr/local/bin/steam-add-extra-library >/dev/null <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
LIB=/scratch2/steam
# The client itself, by exact name. Matching "/ubuntu12_64/steam" as a pattern also
# matched steamwebhelper and the other processes Steam leaves running for a while
# after it closes, so the wait never ended.
steam_running() {
  pgrep -u "$(id -u)" -x steam >/dev/null 2>&1
}
say() { echo "$*"; }
add_entry() {
ROOT=$(readlink -f "$HOME/.steam/steam" 2>/dev/null || echo "")
CONF="$ROOT/config/libraryfolders.vdf"
MARKER="$LIB/steamapps/libraryfolder.vdf"
CID=$(sed -n 's/.*"contentid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$MARKER" 2>/dev/null | tail -1)
[[ -n $CID ]] || CID=$(python3 -c 'import random;print(random.getrandbits(63))')
printf '"libraryfolder"\n{\n\t"contentid"\t\t"%s"\n\t"label"\t\t""\n}\n' "$CID" > "$MARKER"
for F in "$CONF" "$ROOT/steamapps/libraryfolders.vdf"; do
  [[ -f $F ]] || continue
  grep -q "$LIB" "$F" && continue
  python3 - "$F" "$CID" "$LIB" <<'PY'
import re, sys
p, cid, lib = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = max([int(x) for x in re.findall(r'^\t"(\d+)"\s*$', s, re.M)] + [0]) + 1
entry = ('\t"%d"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"label"\t\t""\n' % (n, lib)
         + '\t\t"contentid"\t\t"' + cid + '"\n\t\t"totalsize"\t\t"0"\n'
         '\t\t"update_clean_bytes_tally"\t\t"0"\n\t\t"time_last_update_verified"\t\t"0"\n'
         '\t\t"apps"\n\t\t{\n\t\t}\n\t}\n')
i = s.rstrip().rfind('}')
open(p, 'w').write(s[:i] + entry + s[i:])
PY
done
say "added $LIB to Steam's folders"
}
# On duty for as long as the machine is up, not once: Steam rewrites its list of
# folders as it exits, so if it drops the entry, it is put back the next time Steam
# is closed. Never touched while Steam runs.
while true; do
  # The client is not signed in on a fresh machine, and has no list of folders
  # until it is; nothing to add to yet.
  ROOT=$(readlink -f "$HOME/.steam/steam" 2>/dev/null || echo "")
  CONF="$ROOT/config/libraryfolders.vdf"
  if ! steam_running && [[ -n $ROOT && -f $CONF ]] && ! grep -q "$LIB" "$CONF" 2>/dev/null; then
    sleep 2
    steam_running || add_entry
  fi
  sleep 2
done
EOS
sudo chmod 755 /usr/local/bin/steam-add-extra-library
sudo tee /etc/systemd/system/cg-extra-library.service >/dev/null <<'EOU'
[Unit]
Description=Keep the extra game disk registered with Steam
After=local-fs.target

[Service]
User=ubuntu
Environment=HOME=/home/ubuntu
ExecStart=/usr/local/bin/steam-add-extra-library
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOU
sudo systemctl daemon-reload
sudo systemctl enable cg-extra-library >/dev/null 2>&1
sudo systemctl restart cg-extra-library
df -h /scratch2 | tail -1
echo "the new disk is ready"`
