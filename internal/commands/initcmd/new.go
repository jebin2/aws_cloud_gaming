package initcmd

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	cg "github.com/jebin2/aws_cloud_gaming"
	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/check"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/notify"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/provision"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// uploader puts the host bundle in S3 and signs a URL for it.
type uploader struct{ s *library.AWSStore }

func (u uploader) Put(ctx context.Context, b, r, k string, body []byte) error {
	return u.s.Put(ctx, b, r, k, body)
}
func (u uploader) Presign(ctx context.Context, b, r, k string, v time.Duration) (string, error) {
	return u.s.Presign(ctx, b, r, k, v)
}
func (u uploader) List(ctx context.Context, b, r, p string) ([]provision.Object, error) {
	objs, err := u.s.List(ctx, b, r, p)
	var out []provision.Object
	for _, o := range objs {
		out = append(out, provision.Object{Size: o.Size})
	}
	return out, err
}

// New is an Init for this computer and the AWS account in use.
func New(ctx context.Context, get config.Lookup, env *config.Env, out *output.Out) (*Init, error) {
	region, host := env.Region(), env.Host()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		return nil, err
	}
	home, _ := os.UserHomeDir()
	cache := filepath.Join(home, ".cache", "cg")
	if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		cache = filepath.Join(base, "cg")
	}
	account := ""
	if id, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err == nil {
		account = aws.ToString(id.Account)
	}
	ec := ec2.NewFromConfig(cfg)
	store := &library.AWSStore{Home: region}
	r := local.Exec{}
	popts := pricing.Options{Getenv: env.Get, Source: pricing.AWSSource{API: pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}}}
	sun := sunshine.Client{}
	ts := func(t string) tskey.Client { return tskey.Client{Token: t} }
	email := env.Get("GAME_ALERT_EMAIL")
	if email == "" {
		email = env.Get("EMAIL_ALERTS")
	}
	return &Init{
		Out: out, Env: env, R: r,
		EnsureWatchdog: func(ctx context.Context) { watchdog.Ensure(ctx, env, out) },
		Preflight:      func(ctx context.Context) (check.Result, int) { return check.New(env, false, out).Run(ctx) },
		ChooseGames: func(ctx context.Context) {
			avail, reserve := availableGB(ctx, ec, env, cache)
			Chooser{Lib: library.Library{S3: store, Host: host, Region: region, Account: account, Bucket: env.Get("GAME_S3_BUCKET")}, Env: env, Out: out,
				Ask: ask.New(out, os.Getenv("CG_YES") == "1"), AvailGB: avail, ReserveGB: reserve}.Choose(ctx)
		},
		Lib: func(named string) provision.Library {
			return provision.Library{S3: s3.NewFromConfig(cfg), IAM: iam.NewFromConfig(cfg), Account: account, Host: host, Region: region, Named: named, TagKey: config.TagKey}
		},
		BucketRegion: func(ctx context.Context, b string) (string, error) { return store.Location(ctx, b) },
		Prices: func(ctx context.Context, r string) (*float64, *float64) {
			rates := pricing.Load(ctx, popts, region)
			return pricing.For(ctx, popts, r, "CG_XREGION_USD_GB"), rates.INRPerUSD
		},
		Provisioner: provision.Provisioner{EC2: ec, SSM: ssm.NewFromConfig(cfg), Up: uploader{store}, Src: cg.Files,
			WaitRunning: func(ctx context.Context, id string) error {
				return ec2.NewInstanceRunningWaiter(ec).Wait(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{id}}, 10*time.Minute)
			}},
		Budget: func(inr float64) provision.Budget {
			rates := pricing.Load(ctx, popts, region)
			return provision.Budget{C: budgets.NewFromConfig(us), Account: account, Host: host, INR: inr, FX: rates.FXINRPerUSD, Email: email}
		},
		Shutdown: ec, EC2: ec, TS: ts, Sun: sun,
		Pair:      sunshine.Pairer{C: sun, R: r, Sleep: time.Sleep, Log: out.Log},
		Moonlight: r.Has("moonlight"),
		Notify: func(ctx context.Context, title, msg, prio, tags string) {
			notify.Push(ctx, http.DefaultClient, env, out, title, msg, prio, tags)
		},
		WatchdogState: func(ctx context.Context) (bool, int) {
			rd, err := watchdog.NewReader(ctx, env)
			if err != nil {
				return false, 0
			}
			return rd.Current(ctx).Rule == "ENABLED", env.Int("GAME_WATCHDOG_IDLE_MIN")
		},
		Home: home, Cache: cache, Now: time.Now, Sleep: time.Sleep,
	}, nil
}

// availableGB is what the machine being built can hold, less what is kept free:
// its instance store as AWS reports it for the type (in GiB, a little less than the
// 10^9 GB figure once formatted), and nil when that could not be read - then nothing
// is refused here.
func availableGB(ctx context.Context, c *ec2.Client, env *config.Env, cache string) (avail *float64, reserve float64) {
	reserve = float64(env.Int("GAME_DISK_RESERVE_GB"))
	t := env.Setting("GAME_INSTANCE_TYPE")
	// Measured on a real one once one has run (cg status writes it, cached per type).
	if b, err := os.ReadFile(filepath.Join(cache, "scratch-"+t)); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && n > 0 {
			a := float64(n) - reserve
			if a < 0 {
				a = 0
			}
			return &a, reserve
		}
	}
	o, err := c.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{InstanceTypes: []ec2types.InstanceType{ec2types.InstanceType(t)}})
	if err != nil || len(o.InstanceTypes) == 0 || o.InstanceTypes[0].InstanceStorageInfo == nil || o.InstanceTypes[0].InstanceStorageInfo.TotalSizeInGB == nil {
		return nil, reserve
	}
	disk := float64(*o.InstanceTypes[0].InstanceStorageInfo.TotalSizeInGB) * 1e9 / 1073741824
	a := disk - reserve
	if a < 0 {
		a = 0
	}
	return &a, reserve
}
