package boxcmd

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/jebin2/aws_cloud_gaming/internal/destroy"
	"github.com/jebin2/aws_cloud_gaming/internal/format"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
	"github.com/jebin2/aws_cloud_gaming/internal/teardown"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// AllEC2 is what --all uses of EC2.
type AllEC2 interface {
	destroy.AllEC2
	DeleteSecurityGroup(context.Context, *ec2.DeleteSecurityGroupInput, ...func(*ec2.Options)) (*ec2.DeleteSecurityGroupOutput, error)
	DeleteKeyPair(context.Context, *ec2.DeleteKeyPairInput, ...func(*ec2.Options)) (*ec2.DeleteKeyPairOutput, error)
}

// AllDeps is what `cg destroy --all` uses beyond a plain destroy.
type AllDeps struct {
	EC2     AllEC2
	Budgets interface {
		DeleteBudget(context.Context, *budgets.DeleteBudgetInput, ...func(*budgets.Options)) (*budgets.DeleteBudgetOutput, error)
	}
	Account  string
	W        library.Writer
	Teardown teardown.Teardown
	Scan     func(ctx context.Context) storage.Everywhere
	// RoleExists and WatchdogExists say whether those are there to remove.
	RoleExists, WatchdogExists func(ctx context.Context) bool
	RemoveWatchdog             func(ctx context.Context)
	TS                         func(token string) tskey.Client
	Pem                        string
}

// destroyEverything is `cg destroy --all`: the box AND every game you have.
//
// `--all` used to mean "the box and the EBS game volume". The games moved to S3, so
// a flag that deleted the volume and left the archive billing was promising
// "nothing left billing" while ignoring the only storage that still costs anything.
// It now deletes the ARCHIVE, which is the games. This is the single unrecoverable
// action in this repo: the archive is the only copy, with no versioning and no
// snapshot. So it asks for a typed word rather than trusting a flag - a mis-typed
// flag is exactly what must not reach here.
func (d Deps) destroyEverything(ctx context.Context, x DestroyDeps, a AllDeps, force bool) int {
	host := d.Box.Host
	// The bucket in use: .env's, else the one cg derives for this account.
	b, haveBucket := x.Lib.BucketName()
	region := x.Lib.Region
	if haveBucket {
		if loc, err := x.Lib.S3.Location(ctx, b); err == nil && loc != "" {
			region = loc
		}
	}
	var vol *struct {
		ID string
		GB int32
	}
	if o, err := a.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{Filters: []ec2types.Filter{{Name: aws.String("tag:Name"), Values: []string{host + "-games"}}}}); err == nil && len(o.Volumes) > 0 {
		vol = &struct {
			ID string
			GB int32
		}{aws.ToString(o.Volumes[0].VolumeId), aws.ToInt32(o.Volumes[0].Size)}
	}

	d.Out.Echo("--all deletes the box AND every game you have.")
	d.Out.Echo("")
	if haveBucket {
		// An archive that cannot be listed is not an empty one.
		if objs, err := a.W.List(ctx, b, region, "steam/"); err != nil {
			d.Out.Echo(fmt.Sprintf("  game archive    s3://%s/steam  could not be listed - AWS did not answer", b))
		} else {
			var size int64
			for _, o := range objs {
				size += o.Size
			}
			d.Out.Echo(fmt.Sprintf("  game archive    s3://%s/steam  %d objects, %s", b, len(objs), format.IEC(size)))
		}
		d.Out.Echo("                  THIS IS THE ONLY COPY - no versions, no snapshot, no undo")
	} else {
		d.Out.Echo("  game archive    (no bucket recorded in .env - nothing to delete)")
	}
	if vol != nil {
		d.Out.Echo(fmt.Sprintf("  old EBS volume  %s  %d GB", vol.ID, vol.GB))
	}
	d.Out.Echo("  the box         everything cg destroy normally removes")
	d.Out.Echo("")
	if haveBucket {
		d.Out.Echo("  the bucket      s3://" + b + " itself")
	}
	// Only list what actually EXISTS. This used to announce the role and the
	// watchdog user unconditionally, so a run with neither of them present read as
	// though both were about to be deleted.
	roleX, cwX := a.RoleExists(ctx), a.WatchdogExists(ctx)
	if roleX {
		d.Out.Echo(fmt.Sprintf("  instance role   %s-box, and its instance profile", host))
	}
	if cwX {
		d.Out.Echo(fmt.Sprintf("  cloud watchdog  %s-cloud-watchdog - its function, schedule, role and logs", host))
	}
	if !roleX && !cwX {
		d.Out.Echo("  IAM             nothing - no role or watchdog exists")
	}
	d.Out.Echo("")
	d.Out.Echo("  leftovers       cg's disks, images and snapshots, in every region")
	d.Out.Echo("")
	d.Out.Echo("Saved games and machines in other regions are cg aws disconnect's. cg init")
	d.Out.Echo("recreates all of this - the bucket name comes from your account, this host and")
	d.Out.Echo("the region, so it comes back identical.")
	d.Out.Echo("")
	if !force && !d.Ask.Typed("destroy-all", "type DESTROY-ALL to confirm: ", "DESTROY-ALL") {
		d.Out.Echo("aborted - nothing was deleted")
		return 1
	}

	failed := 0
	if d.removeAll(ctx, x, a) != 0 {
		failed = 1
	}

	if haveBucket {
		d.Out.Say(fmt.Sprintf("deleting the game archive and its bucket s3://%s", b))
		// Incomplete multipart uploads appear in no listing, are not emptied by
		// deleting the objects, and are the usual reason a bucket will not go: the
		// store aborts them first.
		if err := a.W.DeleteBucket(ctx, b, region); err == nil {
			d.Out.Log("bucket deleted - storage charges stop now")
			// Out of .env only once it is gone. Removed whatever happened, a bucket
			// that would not delete kept billing with nothing here pointing at it: cg
			// cost no longer showed it, and the next --all no longer tried.
			_ = d.Env.Unset("GAME_S3_BUCKET")
		} else {
			d.Out.LogAs("fail", fmt.Sprintf("could not delete the bucket s3://%s - it still bills, and stays in .env so it is still seen", b))
			d.Out.Log(fmt.Sprintf("  check: aws s3 ls s3://%s --recursive --summarize", b))
			failed = 1
		}
	}

	// The role and instance profile cost nothing, but "--all" that leaves IAM
	// objects behind is not --all.
	a.Teardown.RemoveRole(ctx, host)
	// The cloud watchdog costs nothing, but --all leaves nothing. It is removed
	// schedule first, so nothing invokes a half-deleted function.
	d.Out.Say(fmt.Sprintf("removing the cloud watchdog %s-cloud-watchdog", host))
	a.RemoveWatchdog(ctx)

	if vol != nil {
		// Terminating the instance detaches it, but AWS takes a moment to let go.
		d.Out.Say("deleting the old game library volume " + vol.ID)
		for i := 0; i < 40; i++ {
			o, err := a.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{VolumeIds: []string{vol.ID}})
			if err == nil && len(o.Volumes) > 0 && o.Volumes[0].State == ec2types.VolumeStateAvailable {
				break
			}
			d.sleep(3 * time.Second)
		}
		if _, err := a.EC2.DeleteVolume(ctx, &ec2.DeleteVolumeInput{VolumeId: aws.String(vol.ID)}); err == nil {
			d.Out.Log(fmt.Sprintf("deleted %s - storage charges stop now", vol.ID))
		} else {
			d.Out.LogAs("fail", fmt.Sprintf("could not delete %s; retry with: cg games --volume --delete", vol.ID))
			failed = 1
		}
	}

	// cg's disks, images and snapshots wherever they are: a region move left them
	// behind, and only this region was ever looked at.
	d.Out.Say("looking for cg's disks, images and snapshots in every region")
	if !a.Teardown.CleanEverywhere(ctx, a.Scan(ctx)) {
		failed = 1
	}
	if failed != 0 {
		return d.die("not everything could be deleted - see above; whatever is left still bills, and cg destroy --all can be run again")
	}
	return 0
}

// removeAll is the box and the free things that go with it: the group, the key
// pair, the local key, the budget and the tailnet nodes.
func (d Deps) removeAll(ctx context.Context, x DestroyDeps, a AllDeps) int {
	host := d.Box.Host
	plan, err := destroy.ReadAll(ctx, a.EC2, host, d.tagKey())
	if err != nil {
		return d.die("could not tell what to delete - AWS did not answer: " + err.Error())
	}
	d.Out.Block("What this destroy does", destroy.DescribeAll(plan, host))
	rm := destroy.Remover{C: a.EC2, Say: d.Out.Say, Log: d.Out.Log, Fail: func(s string) { d.Out.LogAs("fail", s) },
		Wait: func(ctx context.Context, id string) bool {
			b := d.Box
			b.ID = id
			return b.WaitState(ctx, "terminated", 600*time.Second)
		}}
	failures, gone := rm.Run(ctx, plan)

	// The BUDGET stays on a plain destroy: it guards the account, not the instance,
	// and deleting it there made it useless - AWS Budgets populates CalculatedSpend
	// up to 24h after a budget is created. `--all` is the command for leaving nothing
	// behind.
	d.Out.Say("removing the budget")
	if _, err := a.Budgets.DeleteBudget(ctx, &budgets.DeleteBudgetInput{AccountId: aws.String(a.Account), BudgetName: aws.String(host + "-monthly")}); err != nil && !strings.Contains(err.Error(), "NotFound") {
		failures = append(failures, "could not delete the budget")
		d.Out.LogAs("fail", "could not delete the budget "+host+"-monthly")
	}

	// The security group cannot go until the terminated instance's network interface
	// is released, which takes a little while - so retry rather than fail, and say so
	// rather than sitting silent.
	if plan.SecurityGroup != "" {
		d.Out.Say("deleting security group " + plan.SecurityGroup)
		fmt.Fprint(d.Out.Stdout, "    waiting for the network interface to be released")
		deleted := false
		for i := 1; i <= 12; i++ {
			if _, err := a.EC2.DeleteSecurityGroup(ctx, &ec2.DeleteSecurityGroupInput{GroupId: aws.String(plan.SecurityGroup)}); err == nil {
				fmt.Fprintf(d.Out.Stdout, " deleted (%ds)\n", (i-1)*5)
				deleted = true
				break
			}
			fmt.Fprint(d.Out.Stdout, ".")
			if i < 12 {
				d.sleep(5 * time.Second)
			}
		}
		if !deleted {
			fmt.Fprintf(d.Out.Stdout, "\n    still in use - delete it manually later: %s\n", plan.SecurityGroup)
		}
	}
	if plan.KeyPair != "" {
		d.Out.Say("deleting key pair")
		if _, err := a.EC2.DeleteKeyPair(ctx, &ec2.DeleteKeyPairInput{KeyName: aws.String(plan.KeyPair)}); err != nil {
			failures = append(failures, "could not delete the key pair")
			d.Out.LogAs("fail", "could not delete the key pair "+plan.KeyPair)
		}
	}
	_ = os.Remove(a.Pem)
	if gone {
		for _, k := range []string{"GAME_INSTANCE_ID", "GAME_TS_HOST", "GAME_TS_NODE", "SUNSHINE_USER", "SUNSHINE_PASS"} {
			_ = d.Env.Unset(k)
		}
	}
	d.Out.Say("everything deleted")
	// A node's identity lives on the disk just deleted, so the entry left behind can
	// never be reused - it only pushes the next build onto a suffixed name.
	tok := d.Env.Get("TAILSCALE_API_KEY")
	if tok != "" {
		d.Out.Say("removing tailnet nodes")
	}
	for _, l := range a.TS(tok).DeleteNodes(ctx, host) {
		if tok != "" {
			d.Out.Log(l)
		} else {
			d.Out.Echo(l)
		}
	}
	if len(failures) > 0 {
		return 1
	}
	return 0
}
