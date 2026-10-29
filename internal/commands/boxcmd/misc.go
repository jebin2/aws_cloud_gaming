package boxcmd

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// Clean is `cg clean`: give the box back some of its root disk.
//
// NAMED things only. The Bash `cg clean` ran `find /scratch -mindepth 1 -maxdepth 1
// -exec rm -rf`, which deletes the installed games - /scratch/steam is the
// library - and the mirror then faithfully propagates the deletion to S3 at the
// next push. A safer version of the command had been written in lib/game and
// never wired up. This is that one: apt's cache, old journals, Steam's HTTP
// cache, and the temp and download folders on /scratch. /scratch/steam is never
// touched.
func (d Deps) Clean(ctx context.Context) int {
	if d.Box.ID == "" {
		return d.die("no instance in .env")
	}
	if s, err := d.Box.State(ctx); err != nil || s != "running" {
		return d.die("box is not running; cg open first, or use: cg destroy && cg init")
	}
	d.Out.Say("before")
	d.Out.Echo(d.disks(ctx))
	d.Out.Say("reclaiming")
	out, err := d.Box.SSH(ctx, cleanScript, nil)
	if s := strings.TrimRight(string(out), "\n"); s != "" {
		d.Out.Echo(s)
	}
	if err != nil {
		d.said(err)
		return exit(err)
	}
	d.Out.Say("after")
	d.Out.Echo(d.disks(ctx))
	return 0
}

const cleanScript = `set -e
    sudo apt-get clean
    sudo apt-get autoremove --purge -y >/dev/null 2>&1 || true
    sudo journalctl --vacuum-size=100M 2>&1 | tail -1
    rm -rf ~/.steam/steam/appcache/httpcache 2>/dev/null || true
    sudo rm -rf /scratch/tmp /scratch/downloads
    sudo /usr/local/bin/mount-scratch.sh 2>/dev/null || true
    echo "  caches, logs and downloads cleared; installed games are not touched"`

// Pair is `cg pair`: redo the Moonlight/Sunshine handshake without rebuilding the
// box. Pairing is per Sunshine instance, so every rebuild needs a fresh one, and
// `cg init` does it. When that step fails - it has - the box streams nothing and
// the only recourse used to be another twenty-minute build. Sunshine reporting
// "paired clients: 0" is the symptom; this is the four-second fix.
func (d Deps) PairMoonlight(ctx context.Context) int {
	if !d.NeedNode(ctx) {
		return 1
	}
	ip, _ := d.Box.IP(ctx)
	user, pass := d.Env.Get("SUNSHINE_USER"), d.Env.Get("SUNSHINE_PASS")
	if user == "" || pass == "" {
		return d.die("no Sunshine credentials in .env - they are written by cg init")
	}
	if !d.Moonlight {
		return d.die("moonlight is not installed")
	}
	lctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	out, _ := d.R.Run(lctx, local.Cmd{Name: "moonlight", Args: []string{"list", ip}})
	cancel()
	if len(strings.TrimSpace(string(out))) > 0 {
		d.Out.Log(fmt.Sprintf("already paired with %s (%s)", d.Box.Node, ip))
		return 0
	}
	d.Out.Say(fmt.Sprintf("pairing with %s (%s)", d.Box.Node, ip))
	if d.Pair.Pair(ctx, ip, user, pass) {
		d.Out.Log("paired - cg open should stream now")
		return 0
	}
	return d.die(fmt.Sprintf("pairing failed. The web UI is https://%s:47990 (credentials in .env)", ip))
}

// SnapshotCreate is `cg snapshot` / `cg snapshot create`.
func (d Deps) SnapshotCreate(ctx context.Context) int {
	return d.SnapshotCreateWith(ctx, true)
}

// SnapshotCreateWith is it with the wait optional. AWS takes ten minutes or more
// to finish a 50 GB image, and the image is made whether or not anyone waits:
// --no-wait starts it and leaves the rest to `cg snapshot --list`.
func (d Deps) SnapshotCreateWith(ctx context.Context, wait bool) int {
	if d.Box.ID == "" {
		return d.die("no instance in .env - nothing to snapshot")
	}
	s, err := d.Box.State(ctx)
	if err != nil {
		return d.die(err.Error())
	}
	if s != "stopped" {
		d.Out.Say(fmt.Sprintf("note: imaging a %s instance; stop it first for a consistent image", s))
	}
	name := d.Box.Host + "-" + d.Now().UTC().Format("20060102-150405")
	d.Out.Say(fmt.Sprintf("creating image %s (several minutes)", name))
	ami, err := d.Box.CreateImage(ctx, name)
	if err != nil {
		return d.die("could not create the image: " + err.Error())
	}
	d.Out.Log(ami)
	if !wait {
		d.Out.Log("AWS is making it in the background (ten minutes or more) - it shows as pending in: cg snapshot --list")
		return 0
	}
	if !d.Box.WaitImage(ctx, ami, 1800*time.Second) {
		if ctx.Err() != nil {
			d.Out.Log("stopped waiting - AWS is still making " + ami + "; see: cg snapshot --list")
		}
		return 1
	}
	d.Out.Log("ready - cg init will restore from it instead of rebuilding")
	return 0
}

// SnapshotDelete is `cg snapshot --delete <id>`. Deregistering leaves the backing
// snapshots behind, still billing - that is the classic way to believe you
// deleted something and keep paying - so each of them goes too.
func (d Deps) SnapshotDelete(ctx context.Context, id string, c interface {
	DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
	DeregisterImage(context.Context, *ec2.DeregisterImageInput, ...func(*ec2.Options)) (*ec2.DeregisterImageOutput, error)
	DeleteSnapshot(context.Context, *ec2.DeleteSnapshotInput, ...func(*ec2.Options)) (*ec2.DeleteSnapshotOutput, error)
}) int {
	if id == "" {
		return d.die("which image? see: cg snapshot --list")
	}
	var snaps []string
	if o, err := c.DescribeImages(ctx, &ec2.DescribeImagesInput{ImageIds: []string{id}}); err == nil && len(o.Images) > 0 {
		for _, m := range o.Images[0].BlockDeviceMappings {
			if m.Ebs != nil && aws.ToString(m.Ebs.SnapshotId) != "" {
				snaps = append(snaps, aws.ToString(m.Ebs.SnapshotId))
			}
		}
	}
	if _, err := c.DeregisterImage(ctx, &ec2.DeregisterImageInput{ImageId: aws.String(id)}); err != nil {
		return d.die(firstErrorLine(err.Error()))
	}
	d.Out.Log("deregistered " + id)
	for _, s := range snaps {
		if _, err := c.DeleteSnapshot(ctx, &ec2.DeleteSnapshotInput{SnapshotId: aws.String(s)}); err != nil {
			d.Out.Log(fmt.Sprintf("could not delete snapshot %s (in use by another image?)", s))
		} else {
			d.Out.Log("deleted snapshot " + s)
		}
	}
	return 0
}
