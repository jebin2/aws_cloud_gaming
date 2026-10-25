package machines

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/aws/aws-sdk-go-v2/service/ec2"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// NewReader builds a reader for a region.
func NewReader(ctx context.Context, region string, get config.Lookup, products pricing.Products) (*Reader, error) {
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	home, _ := os.UserHomeDir()
	cache := filepath.Join(home, ".cache", "cg")
	if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		cache = filepath.Join(base, "cg")
	}
	r := &Reader{EC2: ec2.NewFromConfig(cfg), Quotas: servicequotas.NewFromConfig(cfg), Products: products, Region: region, CacheDir: cache}
	if v, ok := get("CG_MACHINE_TYPES"); ok {
		r.Override = splitFields(v)
	}
	return r, nil
}

func splitFields(s string) []string {
	var out []string
	cur := ""
	for _, c := range s {
		if c == ' ' || c == '\t' || c == '\n' {
			if cur != "" {
				out = append(out, cur)
				cur = ""
			}
			continue
		}
		cur += string(c)
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}

// Run is `cg machines [region] [--all]` (also `cg types`).
func Run(ctx context.Context, env *config.Env, get config.Lookup, args []string, jsonFlag bool, out *output.Out) int {
	region := env.Region()
	if len(args) > 0 && IsRegion(args[0]) {
		region, args = args[0], args[1:]
	}
	all := false
	for _, a := range args {
		switch a {
		case "--all", "all", "1":
			all = true
		case "--sweep", "sweep":
			out.Die("machines --sweep is not ported to Go yet (see: cg sweep)")
			return 1
		case "--json":
			jsonFlag = true
		case "--watch":
		default:
			out.Die(fmt.Sprintf("unknown option '%s' (see: cg help)", a))
			return 1
		}
	}
	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	products := pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}
	r, err := NewReader(ctx, region, get, products)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	rates := pricing.Load(ctx, pricing.Options{Getenv: env.Get, Source: pricing.AWSSource{API: products}}, env.Region())
	spot := env.Get("GAME_SPOT")
	if spot == "" {
		spot = "0"
	}
	t := r.Build(ctx, env.Setting("GAME_INSTANCE_TYPE"), spot, rates.INRPerUSD)
	if jsonFlag {
		b, err := JSON(t)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	out.Report("Machines", Show(t, all))
	return 0
}
