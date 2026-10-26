package games

import (
	"context"
	"fmt"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/remote"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// Run is `cg games` and `cg games --volume`.
func Run(ctx context.Context, env *config.Env, args []string, out *output.Out) int {
	if len(args) > 0 && (args[0] == "--volume" || args[0] == "volume") {
		return runVolume(ctx, env, args[1:], out)
	}
	if len(args) > 0 {
		// `cg games --delete` has never existed: the volume's is --volume --delete.
		out.Die("usage: cg games [--volume [--delete]]")
		return 1
	}
	box := remote.New(env)
	ip, err := box.IP(ctx)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	raw, err := box.Runner.Output(ctx, "ssh", box.SSHArgs(ip, remoteScript)...)
	if err != nil && len(raw) == 0 {
		out.Die("could not read the box")
		return 1
	}
	// No index: none of the games are saved.
	var archived []library.App
	if cfg, err := awscfg.New(ctx, env.Region()); err == nil {
		acct := ""
		if id, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err == nil {
			acct = aws.ToString(id.Account)
		}
		l := library.Library{S3: &library.AWSStore{Home: env.Region()}, Host: env.Host(), Region: env.Region(), Account: acct, Bucket: env.Get("GAME_S3_BUCKET")}
		if b, ok := l.BucketName(); ok {
			region := env.Region()
			if loc, err := l.S3.Location(ctx, b); err == nil && loc != "" {
				region = loc
			}
			archived, _ = l.Index(ctx, b, region)
		}
	}
	out.Report("Games", Render(ParseBox(string(raw)), archived))
	return 0
}

func runVolume(ctx context.Context, env *config.Env, args []string, out *output.Out) int {
	sub := "show"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "show", "":
	case "--delete", "delete":
	default:
		out.Die("usage: cg games [--volume [--delete]]")
		return 1
	}
	cfg, err := awscfg.New(ctx, env.Region())
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	v, err := FindVolume(ctx, ec2.NewFromConfig(cfg), env.Host())
	if err != nil {
		out.Die("could not look for the volume: " + err.Error())
		return 1
	}
	if sub == "--delete" || sub == "delete" {
		return DeleteVolume(ctx, ec2.NewFromConfig(cfg), v, ask.New(out, os.Getenv("CG_YES") == "1"), out)
	}
	us, _ := awscfg.New(ctx, "us-east-1")
	rates := pricing.Load(ctx, pricing.Options{Getenv: env.Get,
		Source: pricing.AWSSource{API: pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}}}, env.Region())
	fmt.Fprint(out.Stdout, ShowVolume(v, rates.EBSGBMonth, rates.INRPerUSD))
	return 0
}
