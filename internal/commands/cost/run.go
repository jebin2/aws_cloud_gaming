package cost

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/status"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/costreport"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

// Options are what the command line said.
type Options struct {
	Daily bool // the day-by-day table above the summary
	JSON  bool
}

// ParseArgs reads the arguments after `cost`. --json is the app's view and is
// always day by day.
func ParseArgs(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch a {
		case "--daily":
			o.Daily = true
		case "--json":
			o.JSON, o.Daily = true, true
		case "--watch":
		default:
			return o, fmt.Errorf("unknown option '%s' (see: cg help)", a)
		}
	}
	return o, nil
}

// Run is `cg cost`. It returns the exit code.
func Run(ctx context.Context, env *config.Env, get config.Lookup, opts Options, out *output.Out) int {
	region := env.Region()
	home, _ := os.UserHomeDir()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		out.Die("AWS is not set up on this computer: " + err.Error() + " - check the access key: cg creds")
		return 1
	}
	us, err := awscfg.New(ctx, "us-east-1") // Cost Explorer, the Free Tier and the Price List answer only there
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	g := &costfacts.Gatherer{
		EC2: ec2.NewFromConfig(cfg), CloudWatch: cloudwatch.NewFromConfig(cfg),
		CE: costexplorer.NewFromConfig(us), Budgets: budgets.NewFromConfig(us),
		FreeTier: freetier.NewFromConfig(us), S3: s3.NewFromConfig(cfg), STS: sts.NewFromConfig(cfg),
		Host: env.Host(), Region: region, TagKey: config.TagKey, Bucket: env.Get("GAME_S3_BUCKET"), EnvID: env.Get("GAME_INSTANCE_ID"),
	}
	facts, err := g.Gather(ctx)
	if err != nil {
		out.Die(fmt.Sprintf("%v - check the access key: cg creds", firstLine(err)))
		return 1
	}

	products := pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}
	rates := pricing.Load(ctx, pricing.Options{
		Getenv: env.Get, Source: pricing.AWSSource{API: products},
	}, region)

	in := Inputs{Facts: facts, Rates: rates, Host: env.Host(), Region: region,
		ConfiguredType: env.Setting("GAME_INSTANCE_TYPE"), Now: time.Now(), CacheEgress: cacheEgress(cacheDir(get, home))}
	if v, err := strconv.ParseFloat(env.Get("GAME_BITRATE_KBPS"), 64); err == nil {
		in.BitrateKBPS = v
	}
	// Prices are per-region and change; read them rather than hard-coding. A
	// spot box is priced at the spot price, already read with the facts.
	if inst := in.instance(); inst == nil || inst.Lifecycle != "spot" {
		in.OnDemandRate = pricing.OnDemandHourly(ctx, products, in.MachineType(), region)
	}

	if !opts.JSON {
		sg := &status.Gatherer{EC2: ec2.NewFromConfig(cfg), S3: g.S3, IAM: iam.NewFromConfig(cfg), Logs: cloudwatchlogs.NewFromConfig(cfg),
			Host: env.Host(), ExpiryDays: env.Int("GAME_ARCHIVE_EXPIRY_DAYS"), Now: time.Now}
		x := sg.Extras(ctx, env.Get("GAME_INSTANCE_ID"), facts.Bucket.Name)
		in.Extras = &x
	}

	if opts.JSON {
		b, err := in.JSON()
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	out.Report("", in.Human(opts.Daily, ""))
	out.Report("", otherRegions(ctx, env, get, cfg, region, rates, g.Host))
	return 0
}

// cacheEgress writes down what this command already paid Cost Explorer for, so
// `cg status` can show the real number for free. Each call costs $0.01 and
// status must not make one: at 20 runs a day that is more than the S3 bill.
// Stamped with its age so it is never mistaken for live. Silent on failure -
// a cache must never break the command. It lives in the cache directory, not
// beside the scripts: an installed copy is read-only.
func cacheEgress(dir string) costreport.Cache {
	return func(outGB float64, free *float64) {
		f := 0.0
		if free != nil {
			f = *free
		}
		if os.MkdirAll(dir, 0o755) != nil {
			return
		}
		_ = os.WriteFile(filepath.Join(dir, "egress"),
			[]byte(fmt.Sprintf("%d %.3f %.0f\n", time.Now().Unix(), outGB, f)), 0o644)
	}
}

func cacheDir(get config.Lookup, home string) string {
	if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		return filepath.Join(base, "cg")
	}
	return filepath.Join(home, ".cache", "cg")
}

// firstLine is AWS's refusal in one line: the SDK wraps it in layers of
// "operation error ...", and the last clause is the reason.
func firstLine(err error) string {
	msg := err.Error()
	if i := strings.Index(msg, "failed to refresh cached credentials"); i >= 0 {
		return "no AWS access key was found on this computer"
	}
	return msg
}

// otherRegions reads what cg has in the regions this report did not look at.
func otherRegions(ctx context.Context, env *config.Env, get config.Lookup, cfg aws.Config, here string, rates pricing.Rates, host string) string {
	regions := []string{here}
	if o, err := ec2.NewFromConfig(cfg).DescribeRegions(ctx, &ec2.DescribeRegionsInput{}); err == nil {
		regions = nil
		for _, r := range o.Regions {
			regions = append(regions, aws.ToString(r.RegionName))
		}
	}
	st := storage.Scan(ctx, regions, storage.ForHost(ctx, host))
	account := ""
	if id, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err == nil {
		account = aws.ToString(id.Account)
	}
	us, _ := awscfg.New(ctx, "us-east-1")
	products := pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}
	popts := pricing.Options{Getenv: env.Get, Source: pricing.AWSSource{API: products}}
	lib := library.Library{S3: &library.AWSStore{Home: here}, Host: host, Region: here, Account: account,
		Bucket: env.Get("GAME_S3_BUCKET"), S3USD: rates.S3GBMonth, INR: rates.INRPerUSD}
	el := lib.ReadElsewhere(ctx, library.SSMParams{Client: ssm.NewFromConfig(cfg)},
		func(ctx context.Context, region, key string) *float64 { return pricing.For(ctx, popts, region, key) },
		env.Int("GAME_ARCHIVE_EXPIRY_DAYS"))
	return OtherRegions(el, st, here, rates)
}
