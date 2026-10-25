package status

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
)

// Options are what the command line said.
type Options struct {
	JSON bool
	On   string // a machine of yours, instead of the AWS box
}

// ParseArgs reads the arguments after `status`.
func ParseArgs(args []string) (Options, error) {
	var o Options
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			o.JSON = true
		case "--watch":
		case "--on":
			if i+1 >= len(args) {
				return o, fmt.Errorf("--on needs the name of a machine (see: cg host list)")
			}
			i++
			o.On = args[i]
		default:
			return o, fmt.Errorf("unknown option '%s' (see: cg help)", args[i])
		}
	}
	return o, nil
}

// Run is `cg status`. It returns the exit code. Nothing in it stops at the
// first failed read: a probe that fails is a fact.
func Run(ctx context.Context, env *config.Env, get config.Lookup, opts Options, out output.Out) int {
	if opts.On != "" {
		out.Die("status --on <machine> is not ported to Go yet (see: cg host status)")
		return 1
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
	home, _ := os.UserHomeDir()
	cacheDir := cacheDir(get, home)
	host := env.Host()
	node := env.Get("GAME_TS_NODE")
	if node == "" {
		node = host
	}
	g := &Gatherer{
		EC2: ec2.NewFromConfig(cfg), Quotas: servicequotas.NewFromConfig(cfg), Budgets: budgets.NewFromConfig(us),
		FreeTier: freetier.NewFromConfig(us), S3: s3.NewFromConfig(cfg), STS: sts.NewFromConfig(cfg),
		IAM: iam.NewFromConfig(cfg), Logs: cloudwatchlogs.NewFromConfig(cfg), Runner: local.Exec{}, Probe: session.Proc{},
		Host: host, Node: node, Region: region, Type: env.Setting("GAME_INSTANCE_TYPE"), Bucket: env.Get("GAME_S3_BUCKET"),
		Home: home, CacheDir: cacheDir, LockFile: session.File(get, os.Getuid()),
		ExpiryDays: env.Int("GAME_ARCHIVE_EXPIRY_DAYS"), Now: time.Now,
		AuthKey: env.Get("TAILSCALE_AUTH_KEY") != "" || env.Get("GAME_TS_AUTHKEY") != "",
	}
	facts := g.Gather(ctx)
	rates := pricing.Load(ctx, pricing.Options{Getenv: env.Get,
		Source: pricing.AWSSource{API: pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}}}, region)

	v := View{Facts: facts, Rates: rates, Host: host, Node: node, Region: region, Type: g.Type, Now: time.Now(),
		DiskGB: env.Int("GAME_DISK_GB"), Spot: env.Get("GAME_SPOT")}
	v.Flags.Notifications = env.Get("GAME_NTFY_URL") != ""
	v.Flags.TailscaleAPIKey = env.Get("TAILSCALE_API_KEY") != ""
	v.Flags.AlertEmail = env.Get("EMAIL_ALERTS") != "" || env.Get("GAME_ALERT_EMAIL") != ""
	// How long a build takes is measured by cg init, never promised.
	if b, err := os.ReadFile(filepath.Join(cacheDir, "last-build-min")); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
			v.LastBuildMin = ok(n)
		}
	}
	if opts.JSON {
		b, err := v.JSON()
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	fmt.Fprint(out.Stdout, v.Human())
	fmt.Fprint(out.Stdout, g.Tail(ctx, env.Get("GAME_INSTANCE_ID"), filepath.Join(cacheDir, "egress")))
	return 0
}

// cacheDir is where throwaway answers live: XDG_CACHE_HOME, so that clearing a
// cache is the one thing a user already knows how to do.
func cacheDir(get config.Lookup, home string) string {
	if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		return filepath.Join(base, "cg")
	}
	return filepath.Join(home, ".cache", "cg")
}
