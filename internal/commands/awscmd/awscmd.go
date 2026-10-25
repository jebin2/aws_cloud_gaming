// Package awscmd is `cg aws`: stop playing on AWS from this computer. Only the
// read - what is there - is ported so far; forget and disconnect come with the
// destroy phases.
package awscmd

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/inventory"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

const usage = "usage: cg aws forget [--anyway] | cg aws disconnect | cg aws inventory [--json]"

// Run is `cg aws ...`.
func Run(ctx context.Context, env *config.Env, args []string, jsonFlag bool, out *output.Out) int {
	if len(args) == 0 {
		out.Die(usage)
		return 1
	}
	sub, args := args[0], args[1:]
	switch sub {
	case "inventory":
	case "forget", "disconnect":
		if sub == "disconnect" && len(args) > 0 && args[0] == "--plan" {
			break
		}
		out.Die("aws " + sub + " is not ported to Go yet")
		return 1
	default:
		out.Die(usage)
		return 1
	}
	for _, a := range args {
		jsonFlag = jsonFlag || a == "--json"
	}
	// Whether this computer ever played on AWS is a fact about its settings file.
	if env.FileValue("GAME_REGION") == "" {
		if jsonFlag {
			fmt.Fprintln(out.Stdout, `{"connected": false, "items": []}`)
		}
		out.Log("AWS is not set up on this laptop - nothing to disconnect")
		return 0
	}
	region := env.Region()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	products := pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}
	popts := pricing.Options{Getenv: env.Get, Source: pricing.AWSSource{API: products}}
	rates := pricing.Load(ctx, popts, region)
	host := env.Host()
	account := ""
	if id, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err == nil {
		account = aws.ToString(id.Account)
	}
	inv := inventory.Inventory{
		Cloud: &inventory.AWS{Home: region, Host: host},
		Lib: library.Library{S3: &library.AWSStore{Home: region}, Host: host, Region: region, Account: account,
			Bucket: env.Get("GAME_S3_BUCKET"), S3USD: rates.S3GBMonth, INR: rates.INRPerUSD},
		Params: library.SSMParams{Client: ssm.NewFromConfig(cfg)},
		Prices: func(ctx context.Context, r, key string) *float64 { return pricing.For(ctx, popts, r, key) },
		Scan: func(ctx context.Context, regions []string) storage.Everywhere {
			return storage.Scan(ctx, regions, storage.ForHost(ctx, host))
		},
		Rates: rates, Here: region, Expiry: env.Int("GAME_ARCHIVE_EXPIRY_DAYS"),
	}
	res := inv.Read(ctx)
	if jsonFlag {
		b, _ := json.MarshalIndent(res, "", "  ")
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	fmt.Fprint(out.Stdout, inventory.Show(res))
	return 0
}
