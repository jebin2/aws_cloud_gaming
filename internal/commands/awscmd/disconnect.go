package awscmd

import (
	"context"
	"fmt"
	"sort"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/inventory"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
	"github.com/jebin2/aws_cloud_gaming/internal/teardown"
)

// Disconnector is `cg aws disconnect`: this laptop stops playing on AWS, and leaves
// nothing there that bills: the machine, every region's saved games, leftover disks
// and images, the watchdog, the budget - cg destroy --all, every other region's
// archive, then a look to make sure. What stays is free and yours: the account, the
// access key it signs in with, region opt-ins and GPU quota.
type Disconnector struct {
	Out *output.Out
	Ask *ask.Asker
	Env *config.Env
	// Inventory reads what is there, live.
	Inventory func(ctx context.Context) inventory.Result
	// DestroyHere is `cg destroy --all --force` for the region in use.
	DestroyHere func(ctx context.Context) int
	// RemoveWatchdog removes the cloud watchdog in a region; the last of them,
	// finding none left that uses the shared role, takes it too.
	RemoveWatchdog func(ctx context.Context, region string)
	// RoleLeft says whether the watchdog's role is still there with no function.
	RoleLeft       func(ctx context.Context) bool
	RemoveRoleOnly func(ctx context.Context)
	Teardown       teardown.Teardown
	Scan           func(ctx context.Context) storage.Everywhere
	DeleteBucket   func(ctx context.Context, bucket, region string) error
}

// Plan says what is there, and changes nothing.
func (d Disconnector) Plan(ctx context.Context, asJSON bool) int {
	res := d.Inventory(ctx)
	if asJSON {
		return emitJSON(res, d.Out)
	}
	d.Out.Echo(trim(inventory.Show(res)))
	return 0
}

func trim(s string) string {
	for len(s) > 0 && s[len(s)-1] == '\n' {
		s = s[:len(s)-1]
	}
	return s
}

// Run is the disconnect itself. It asks for DELETE first: saved games cannot be
// brought back. Exit 3 when AWS could not be asked what is there.
func (d Disconnector) Run(ctx context.Context) int {
	inv := d.Inventory(ctx)
	if inv.Error != nil {
		d.Out.Die("AWS could not be asked what is there - nothing was deleted")
		return 3
	}
	d.Out.Say("this deletes everything cg has in AWS")
	for _, it := range inv.Items {
		d.Out.Echo(fmt.Sprintf("  %-22s %s", it.Label, it.Detail))
	}
	d.Out.Log("your saved games cannot be brought back; the account, its access key, region opt-ins and GPU quota stay")
	if !d.Ask.Typed("aws-disconnect", "  type DELETE to confirm: ", "DELETE") {
		d.Out.Log("not confirmed - nothing was deleted")
		return 1
	}

	// The machine, this region's archive, IAM, the watchdog, the budget, leftovers.
	// Carried on past a failure here: one snapshot AWS would not delete must not leave
	// another region's machine or saved games billing. The look at the end says what
	// is still there, and fails if anything is.
	if d.DestroyHere(ctx) != 0 {
		d.Out.LogAs("fail", "not everything here could be deleted - carrying on; the check at the end says what is left")
	}
	here := inv.Region

	// The watchdog in any other region: each removed as this one was.
	for _, it := range inv.Items {
		if it.Kind != "watchdog" {
			continue
		}
		for _, r := range it.Regions {
			if r == here {
				continue
			}
			d.Out.Say("removing the cloud watchdog in " + r)
			d.RemoveWatchdog(ctx, r)
		}
	}
	// A role left with no function anywhere: this region's removal takes it.
	if d.RoleLeft(ctx) {
		d.RemoveRoleOnly(ctx)
	}

	// Machines in any other region: a spot request cancelled first, so it cannot launch
	// another, then the machine ended - its disk goes with it.
	for _, it := range inv.Items {
		if it.Kind == "machine" && it.Region != "" && it.Region != here {
			d.Teardown.EndMachine(ctx, it.Region, it.ID)
		}
	}

	// cg's disks, images and snapshots in every region - this one's went with destroy
	// above; a region move left others behind.
	if !d.Teardown.CleanEverywhere(ctx, d.Scan(ctx)) {
		d.Out.LogAs("fail", "some of cg's disks, images or snapshots could not be deleted")
	}

	// Every other region's saved games.
	for _, it := range inv.Items {
		if it.Kind == "games" && it.Label == "Saved games elsewhere" {
			d.Out.Say(fmt.Sprintf("deleting the saved games in %s (s3://%s)", it.Region, it.Bucket))
			if err := d.DeleteBucket(ctx, it.Bucket, it.Region); err != nil {
				d.Out.LogAs("fail", "could not delete s3://"+it.Bucket)
			}
		}
	}

	// Its settings in SSM, every region they were found in.
	by := map[string][]string{}
	for _, it := range inv.Items {
		for _, n := range it.Names {
			by[n.Region] = append(by[n.Region], n.Name)
		}
	}
	if len(by) > 0 {
		d.Teardown.DeleteSettings(ctx, by)
	}

	// A look, not a hope: anything of cg's still there - billing or not - is said, and
	// AWS stays set up here so it can still be seen and deleted.
	d.Out.Say("checking nothing is left")
	left := d.Inventory(ctx)
	var lines [][2]string
	if left.Error != nil {
		lines = append(lines, [2]string{"?", *left.Error})
	}
	for _, it := range left.Items {
		lines = append(lines, [2]string{it.Label, it.Detail})
	}
	if len(lines) > 0 {
		sort.SliceStable(lines, func(i, j int) bool { return false })
		for _, l := range lines {
			if l[1] != "" {
				d.Out.LogAs("fail", fmt.Sprintf("still there: %s - %s", l[0], l[1]))
			} else {
				d.Out.LogAs("fail", "still there: "+l[0])
			}
		}
		d.Out.Die("not everything could be deleted - AWS is still set up here so it can be seen; try again")
		return 1
	}
	if err := d.Env.Unset("GAME_REGION"); err != nil {
		d.Out.Die("could not write .env")
		return 1
	}
	d.Out.LogAs("ok", "AWS disconnected - nothing of cg is left billing, nor anything else of cg's")
	d.Out.Log("the account, its access key, region opt-ins and GPU quota were kept; they cost nothing")
	return 0
}
