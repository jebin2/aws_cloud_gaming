// Package destroy is taking the box away: the instance, the images of it and the
// disks it left, and nothing that is not cg's. A plain destroy removes only what
// BILLS. The security group, the key pair and the tailnet node cost nothing, and
// cg init reuses every one of them.
package destroy

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

// EC2 is what a destroy uses.
type EC2 interface {
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
	DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error)
	CancelSpotInstanceRequests(context.Context, *ec2.CancelSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error)
	TerminateInstances(context.Context, *ec2.TerminateInstancesInput, ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error)
	DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
	DeregisterImage(context.Context, *ec2.DeregisterImageInput, ...func(*ec2.Options)) (*ec2.DeregisterImageOutput, error)
	DeleteSnapshot(context.Context, *ec2.DeleteSnapshotInput, ...func(*ec2.Options)) (*ec2.DeleteSnapshotOutput, error)
	DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error)
	DeleteVolume(context.Context, *ec2.DeleteVolumeInput, ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error)
}

// Plan is what a destroy would remove, and what it leaves alone.
type Plan struct {
	Instances []string
	Images    []string
	Volumes   []string
	// Others are images and unattached disks that are not cg's: said, never touched.
	Others []string
	// With --all, the free things too: the security group and the key pair.
	SecurityGroup, KeyPair string
}

func tagFilter(key, value string) ec2types.Filter {
	return ec2types.Filter{Name: aws.String("tag:" + key), Values: []string{value}}
}

func add(list *[]string, seen map[string]bool, id string) {
	if id != "" && id != "None" && !seen[id] {
		seen[id] = true
		*list = append(*list, id)
	}
}

// Read finds what is cg's: by the tag cg puts on everything it makes
// (<host>-image for an image, <host>-games for the old games volume), or by the
// exact name it gave them before that tag existed. Nothing else, whatever its Name
// says. It fails when AWS cannot be asked - a plan made from half an answer would
// leave things billing.
func Read(ctx context.Context, c EC2, host, tagKey string) (Plan, error) {
	var p Plan
	seen := map[string]bool{}
	inst, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{Filters: []ec2types.Filter{
		tagFilter("Name", host), {Name: aws.String("instance-state-name"), Values: []string{"pending", "running", "stopping", "stopped"}}}})
	if err != nil {
		return p, err
	}
	for _, r := range inst.Reservations {
		for _, i := range r.Instances {
			add(&p.Instances, seen, aws.ToString(i.InstanceId))
		}
	}
	mine := map[string]bool{}
	for _, f := range []ec2types.Filter{tagFilter(tagKey, host), tagFilter("Name", host+"-image")} {
		o, err := c.DescribeImages(ctx, &ec2.DescribeImagesInput{Owners: []string{"self"}, Filters: []ec2types.Filter{f}})
		if err != nil {
			return p, err
		}
		for _, im := range o.Images {
			id := aws.ToString(im.ImageId)
			mine[id] = true
			add(&p.Images, seen, id)
		}
	}
	avail := ec2types.Filter{Name: aws.String("status"), Values: []string{"available"}}
	for _, f := range []ec2types.Filter{tagFilter(tagKey, host), tagFilter("Name", host+"-games")} {
		o, err := c.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{Filters: []ec2types.Filter{avail, f}})
		if err != nil {
			return p, err
		}
		for _, v := range o.Volumes {
			id := aws.ToString(v.VolumeId)
			mine[id] = true
			// The games volume is kept, as before: cg games --volume --delete.
			if f.Values[0] == host+"-games" {
				continue
			}
			add(&p.Volumes, seen, id)
		}
	}
	all, err := c.DescribeImages(ctx, &ec2.DescribeImagesInput{Owners: []string{"self"}})
	if err != nil {
		return p, err
	}
	for _, im := range all.Images {
		if id := aws.ToString(im.ImageId); !mine[id] {
			p.Others = append(p.Others, id)
		}
	}
	vols, err := c.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{Filters: []ec2types.Filter{avail}})
	if err != nil {
		return p, err
	}
	for _, v := range vols.Volumes {
		if id := aws.ToString(v.VolumeId); !mine[id] {
			p.Others = append(p.Others, id)
		}
	}
	return p, nil
}

func none(l []string) string {
	if len(l) == 0 {
		return "none"
	}
	return strings.Join(l, " ")
}

// AllEC2 is what --all adds: the security group and the key pair, which a plain
// destroy keeps because they cost nothing and cg init reuses them.
type AllEC2 interface {
	EC2
	DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error)
	DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error)
}

// ReadAll is Read plus the group and the key pair, as far as they exist.
func ReadAll(ctx context.Context, c AllEC2, host, tagKey string) (Plan, error) {
	p, err := Read(ctx, c, host, tagKey)
	if err != nil {
		return p, err
	}
	if o, err := c.DescribeSecurityGroups(ctx, &ec2.DescribeSecurityGroupsInput{Filters: []ec2types.Filter{{Name: aws.String("group-name"), Values: []string{host + "-sg"}}}}); err == nil && len(o.SecurityGroups) > 0 {
		p.SecurityGroup = aws.ToString(o.SecurityGroups[0].GroupId)
	}
	if o, err := c.DescribeKeyPairs(ctx, &ec2.DescribeKeyPairsInput{KeyNames: []string{host}}); err == nil && len(o.KeyPairs) > 0 {
		p.KeyPair = aws.ToString(o.KeyPairs[0].KeyName)
	}
	return p, nil
}

// DescribeAll is the block for --all: the free things go too, and so does the
// archive, so nothing here says the games are safe. A destroy must not tell you
// your games are safe while deleting them.
func DescribeAll(p Plan, host string) string {
	var b strings.Builder
	b.WriteString("\nThis permanently deletes the box and everything listed here:\n")
	fmt.Fprintf(&b, "  instances       %s\n", none(p.Instances))
	fmt.Fprintf(&b, "  images          %s\n", none(p.Images))
	fmt.Fprintf(&b, "  volumes         %s\n", none(p.Volumes))
	fmt.Fprintf(&b, "  security group  %s\n", orNone(p.SecurityGroup))
	fmt.Fprintf(&b, "  key pair        %s  (and ~/.ssh/%s.pem)\n", orNone(p.KeyPair), host)
	fmt.Fprintf(&b, "  tailnet nodes   %s, %s-N\n", host, host)
	fmt.Fprintf(&b, "  budget          %s-monthly\n\n", host)
	b.WriteString("The desktop, its configuration AND the S3 game archive all go.\nThere is no undo, no image and no versioning behind the archive.\n\n")
	if len(p.Others) > 0 {
		sort.Strings(p.Others)
		fmt.Fprintf(&b, "Left alone - not cg's: %s\n\n", strings.Join(p.Others, " "))
	}
	return b.String()
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

// Describe is the block that says what is about to happen. keepDays is how long
// the archive is kept with no box (0: forever); now is today.
func Describe(p Plan, host string, keepDays int, now time.Time) string {
	var b strings.Builder
	b.WriteString("\nThis permanently deletes the box and everything listed here:\n")
	fmt.Fprintf(&b, "  instances       %s\n", none(p.Instances))
	fmt.Fprintf(&b, "  images          %s\n", none(p.Images))
	fmt.Fprintf(&b, "  volumes         %s\n", none(p.Volumes))
	b.WriteString("\nKept, because they are free and cg init reuses them:\n")
	fmt.Fprintf(&b, "  security group  %s-sg\n", host)
	fmt.Fprintf(&b, "  key pair        %s, with ~/.ssh/%s.pem\n", host, host)
	b.WriteString("  tailnet node    left offline - pruned before the next launch\n")
	b.WriteString("  budget          guards the account, not the box\n")
	b.WriteString("  (cg destroy --all removes all of these)\n\n")
	b.WriteString("The desktop and its configuration go. The GAMES stay in S3: they were\nmirrored before this started, and the next cg init restores them.\nCheck with: cg library\n")
	// The archive is not kept for good: the cloud watchdog deletes it after the
	// expiry window with no box. Saying "nothing touches it" here was true until
	// that existed, and is the sentence someone would rely on.
	if keepDays == 0 {
		b.WriteString("There is no undo and no image is kept. The S3 archive is kept - nothing here\ntouches it, and GAME_ARCHIVE_EXPIRY_DAYS=0 keeps it forever.\n")
	} else {
		fmt.Fprintf(&b, "There is no undo and no image is kept. The S3 archive is kept for now, but\nit is DELETED after %d days with no box - around %s.\nLaunch a box before then to keep it, or set GAME_ARCHIVE_EXPIRY_DAYS=0 in .env.\n",
			keepDays, now.AddDate(0, 0, keepDays).Format("2006-01-02"))
	}
	b.WriteString("\n")
	if len(p.Others) > 0 {
		sort.Strings(p.Others)
		fmt.Fprintf(&b, "Left alone - not cg's: %s\n\n", strings.Join(p.Others, " "))
	}
	return b.String()
}

// Remover carries a plan out.
type Remover struct {
	C     EC2
	Say   func(string)
	Log   func(string)
	Fail  func(string)
	Wait  func(ctx context.Context, id string) bool // waits for terminated
	Sleep func(time.Duration)
}

// Run does it, and returns what could not be done. Cleanup failures are collected
// and said, not suppressed: something that stays behind still bills.
func (r Remover) Run(ctx context.Context, p Plan) (failures []string, instancesGone bool) {
	gone := true
	fail := func(s string) {
		failures = append(failures, s)
		r.Fail(s)
	}
	// A persistent spot request relaunches the moment its instance dies, so an
	// instance whose request cannot be found or cancelled is NOT terminated: that
	// would trade a box we know about for a replacement we do not. It is reported,
	// and a second run (or a person) deals with it.
	var terminate []string
	for _, id := range p.Instances {
		var o *ec2.DescribeSpotInstanceRequestsOutput
		var err error
		// A throttled call is the usual cause and the next one works.
		for try := 1; try <= 3; try++ {
			o, err = r.C.DescribeSpotInstanceRequests(ctx, &ec2.DescribeSpotInstanceRequestsInput{Filters: []ec2types.Filter{{Name: aws.String("instance-id"), Values: []string{id}}}})
			if err == nil {
				break
			}
			if r.Sleep != nil && try < 3 {
				r.Sleep(2 * time.Second)
			}
		}
		if err != nil {
			fail(fmt.Sprintf("could not look up the spot request for %s (%v) - not terminating it, because a request that relaunches would replace it; run the destroy again", id, err))
			gone = false
			continue
		}
		var reqs []string
		for _, q := range o.SpotInstanceRequests {
			reqs = append(reqs, aws.ToString(q.SpotInstanceRequestId))
		}
		if len(reqs) > 0 {
			if _, err := r.C.CancelSpotInstanceRequests(ctx, &ec2.CancelSpotInstanceRequestsInput{SpotInstanceRequestIds: reqs}); err != nil {
				fail(fmt.Sprintf("could not cancel the spot request for %s (%v) - not terminating it, because the request would launch a replacement; run the destroy again", id, err))
				gone = false
				continue
			}
		}
		terminate = append(terminate, id)
	}
	if len(terminate) > 0 {
		r.Say("terminating " + strings.Join(terminate, " "))
		if _, err := r.C.TerminateInstances(ctx, &ec2.TerminateInstancesInput{InstanceIds: terminate}); err != nil {
			fail("could not terminate " + strings.Join(terminate, " ") + ": " + err.Error())
			return failures, false
		}
		for _, id := range terminate {
			if r.Wait != nil && !r.Wait(ctx, id) {
				fail(id + " did not reach terminated")
				gone = false
			}
		}
	}
	instancesGone = gone
	for _, id := range p.Images {
		r.Say("deregistering image " + id)
		// Capture the backing snapshots first; they are unreachable afterwards and
		// would keep billing silently.
		var snaps []string
		o, err := r.C.DescribeImages(ctx, &ec2.DescribeImagesInput{ImageIds: []string{id}})
		if err != nil {
			// Deregistering first would make the snapshots unreachable, and they
			// bill by the gigabyte-month for ever with nothing left to point at them.
			fail(fmt.Sprintf("could not read the snapshots of %s (%v) - not deregistering it, because they would be left behind billing; run the destroy again", id, err))
			continue
		}
		for _, im := range o.Images {
			for _, m := range im.BlockDeviceMappings {
				if m.Ebs != nil && aws.ToString(m.Ebs.SnapshotId) != "" {
					snaps = append(snaps, aws.ToString(m.Ebs.SnapshotId))
				}
			}
		}
		if _, err := r.C.DeregisterImage(ctx, &ec2.DeregisterImageInput{ImageId: aws.String(id)}); err != nil {
			fail(fmt.Sprintf("could not deregister %s: %v", id, err))
			continue
		}
		for _, s := range snaps {
			if _, err := r.C.DeleteSnapshot(ctx, &ec2.DeleteSnapshotInput{SnapshotId: aws.String(s)}); err != nil {
				fail(fmt.Sprintf("could not delete snapshot %s - it still bills", s))
			}
		}
	}
	// A disk of the box's left detached still bills. Only one carrying the box's
	// name - the games volume has its own, and is kept.
	for _, v := range p.Volumes {
		r.Say("deleting the box's leftover volume " + v)
		if _, err := r.C.DeleteVolume(ctx, &ec2.DeleteVolumeInput{VolumeId: aws.String(v)}); err != nil {
			fail(fmt.Sprintf("could not delete volume %s - it still bills", v))
		}
	}
	return failures, instancesGone
}
