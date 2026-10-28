package awscmd

import (
	"context"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/iam"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/box"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/boxcmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/inventory"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

// runForget wires the forget to the real account.
func runForget(ctx context.Context, env *config.Env, args []string, out *output.Out) int {
	f := Forgetter{Out: out, Env: env}
	region, host := env.Region(), env.Host()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	b := box.Box{EC2: ec2.NewFromConfig(cfg), ID: env.Get("GAME_INSTANCE_ID"), Host: host}
	f.BoxState = func(ctx context.Context) string {
		st, err := b.State(ctx)
		if err != nil {
			return "unknown"
		}
		return st
	}
	inv, err := newInventory(ctx, env)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	f.Games = func(ctx context.Context) (int, error) {
		name, ok := inv.Lib.BucketName()
		if !ok {
			return 0, context.DeadlineExceeded
		}
		r := region
		if loc, err := inv.Lib.S3.Location(ctx, name); err == nil && loc != "" {
			r = loc
		}
		apps, err := inv.Lib.Index(ctx, name, r)
		return len(apps), err
	}
	f.Elsewhere = func(ctx context.Context) (int, error) {
		return CountElsewhere(inv.Lib.ReadElsewhere(ctx, inv.Params, inv.Prices, inv.Expiry))
	}
	return f.Run(ctx, args)
}

// newDisconnector wires the disconnect to the real account.
func newDisconnector(ctx context.Context, env *config.Env, inv inventory.Inventory, out *output.Out) (*Disconnector, error) {
	region, host := env.Region(), env.Host()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	get := config.OSLookup
	d := &Disconnector{Out: out, Ask: ask.New(out, os.Getenv("CG_YES") == "1"), Env: env,
		Inventory: func(ctx context.Context) inventory.Result { return inv.Read(ctx) }}
	// Everything the current region has goes through destroy --all --force, as the
	// Bash ran cmd_destroy --all --force; one failure there must not stop the rest.
	d.DestroyHere = func(ctx context.Context) int {
		client := ec2.NewFromConfig(cfg)
		bd, _, err := boxcmd.New(ctx, get, env, out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		x, err := boxcmd.NewDestroyDeps(ctx, env, client, out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return bd.DestroyBox(ctx, x, []string{"--all", "--force"})
	}
	d.RemoveWatchdog = func(ctx context.Context, r string) { watchdog.RemoveQuietly(ctx, env.InRegion(r), out) }
	iamc := iam.NewFromConfig(cfg)
	d.RoleLeft = func(ctx context.Context) bool {
		_, err := iamc.GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String(host + "-cloud-watchdog")})
		return err == nil
	}
	d.RemoveRoleOnly = func(ctx context.Context) { watchdog.RemoveQuietly(ctx, env, out) }
	x, err := boxcmd.NewDestroyDeps(ctx, env, ec2.NewFromConfig(cfg), out)
	if err != nil {
		return nil, err
	}
	d.Teardown = x.All.Teardown
	d.Scan = func(ctx context.Context) storage.Everywhere { return x.All.Scan(ctx) }
	store := &library.AWSStore{Home: region}
	d.DeleteBucket = func(ctx context.Context, bucket, r string) error { return store.DeleteBucket(ctx, bucket, r) }
	return d, nil
}
