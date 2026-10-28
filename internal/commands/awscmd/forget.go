package awscmd

import (
	"context"
	"fmt"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Forgetter is `cg aws forget [--anyway]`: this laptop stops playing on AWS. The
// region it was set up in leaves .env, which is what "an AWS machine" means here:
// the app then shows none and asks AWS nothing. Only when nothing cg made there
// still bills: no machine, and no saved games in any region. Nothing in AWS is
// deleted, and the access key stays in ~/.aws/credentials - other tools on this
// laptop may use it. Exit 3 when AWS could not be asked, so whether anything bills
// is not known; --anyway forgets it all the same.
type Forgetter struct {
	Out *output.Out
	Env *config.Env
	// BoxState is the instance's state: "none" when there is no id, "unknown" when
	// AWS could not be asked.
	BoxState func(ctx context.Context) string
	// Games are the games saved in the bucket in use; err when AWS could not be asked.
	Games func(ctx context.Context) (int, error)
	// Elsewhere are the games saved in other regions; err when AWS could not be asked.
	Elsewhere func(ctx context.Context) (int, error)
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// Run returns the exit status.
func (f Forgetter) Run(ctx context.Context, args []string) int {
	anyway := len(args) > 0 && args[0] == "--anyway"
	if f.Env.FileValue("GAME_REGION") == "" {
		f.Out.Log("AWS is not set up on this laptop - nothing to forget")
		return 0
	}
	if !anyway {
		f.Out.Say("checking nothing is left billing on AWS")
		switch st := f.BoxState(ctx); st {
		case "none", "terminated":
		case "unknown", "":
			f.Out.Die("AWS could not be asked whether a machine is still there")
			return 3
		default:
			f.Out.Die(fmt.Sprintf("a machine is still on AWS (%s) - delete it first: cg destroy", st))
			return 1
		}
		n, err := f.Games(ctx)
		if err != nil {
			f.Out.Die("AWS could not be asked about your saved games")
			return 3
		}
		if n != 0 {
			f.Out.Die(fmt.Sprintf("%d game%s still saved in AWS - delete them first, or keep using AWS: cg library list", n, plural(n)))
			return 1
		}
		o, err := f.Elsewhere(ctx)
		if err != nil {
			f.Out.Die("AWS could not be asked about games saved in other regions")
			return 3
		}
		if o != 0 {
			f.Out.Die(fmt.Sprintf("%d game%s still saved in another AWS region - see cg library elsewhere", o, plural(o)))
			return 1
		}
	}
	if err := f.Env.Unset("GAME_REGION"); err != nil {
		f.Out.Die("could not write .env")
		return 1
	}
	f.Out.LogAs("ok", "this laptop no longer plays on AWS")
	f.Out.Log("nothing in AWS was deleted; your access key stays in ~/.aws/credentials")
	return 0
}

// CountElsewhere counts the games in the places a region move left behind.
func CountElsewhere(e library.Elsewhere) (int, error) {
	if e.Error != nil || e.Places == nil {
		return 0, fmt.Errorf("could not be read")
	}
	n := 0
	for _, p := range *e.Places {
		n += len(p.Games)
	}
	return n, nil
}
