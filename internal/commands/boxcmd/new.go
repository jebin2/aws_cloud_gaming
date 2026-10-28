package boxcmd

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/box"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
	"github.com/jebin2/aws_cloud_gaming/internal/stream"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	"github.com/jebin2/aws_cloud_gaming/internal/teardown"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// New is Deps for this computer, the AWS account in use, and the settings in force.
func New(ctx context.Context, get config.Lookup, env *config.Env, out *output.Out) (Deps, *ec2.Client, error) {
	cfg, err := awscfg.New(ctx, env.Region())
	if err != nil {
		return Deps{}, nil, err
	}
	client := ec2.NewFromConfig(cfg)
	r := local.Exec{}
	home, _ := os.UserHomeDir()
	cache := filepath.Join(home, ".cache", "cg")
	if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		cache = filepath.Join(base, "cg")
	}
	host := env.Host()
	node := env.Get("GAME_TS_NODE")
	if node == "" {
		node = host
	}
	a := ask.New(out, os.Getenv("CG_YES") == "1")
	sun := sunshine.Client{}
	d := Deps{
		Box: box.Box{EC2: client, ID: env.Get("GAME_INSTANCE_ID"), Host: host, Node: node, Key: filepath.Join(home, ".ssh", host+".pem"), R: r,
			Log: out.Log, TagKey: config.TagKey},
		Out: out, Ask: a, Env: env, R: r, Sun: sun,
		Pair:        sunshine.Pairer{C: sun, R: r, Sleep: time.Sleep, Log: out.Log},
		Player:      stream.Player{R: r, Get: env.Get, CacheDir: cache, Echo: out.Echo, Log: out.Log, Warn: func(t string) { out.LogAs("warn", t) }},
		SessionFile: session.File(get, os.Getuid()), Probe: session.Proc{}, Now: time.Now, Moonlight: r.Has("moonlight"),
		Takes:         func() string { return takes(cache) },
		MoonlightConf: filepath.Join(home, ".config", "Moonlight Game Streaming Project", "Moonlight.conf"),
	}
	return d, client, nil
}

// takes is how long a build takes: measured, not promised. cg init records, when
// it finishes, the minutes from the machine's launch to ready-to-play; with no
// build measured yet it says no number at all.
func takes(cache string) string {
	if b, err := os.ReadFile(filepath.Join(cache, "last-build-min")); err == nil {
		if m := trimSpace(string(b)); m != "" {
			return "the last one took " + m + " min"
		}
	}
	return "it takes a while"
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == ' ') {
		s = s[:len(s)-1]
	}
	return s
}

// NewDestroyDeps is what `cg destroy` uses beyond the box, for the account in use.
func NewDestroyDeps(ctx context.Context, env *config.Env, client *ec2.Client, out *output.Out) (DestroyDeps, error) {
	cfg, err := awscfg.New(ctx, env.Region())
	if err != nil {
		return DestroyDeps{}, err
	}
	acct := ""
	if id, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err == nil {
		acct = aws.ToString(id.Account)
	}
	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		return DestroyDeps{}, err
	}
	store := &library.AWSStore{Home: env.Region()}
	host, home := env.Host(), env.Region()
	iamc := iam.NewFromConfig(cfg)
	var mu sync.Mutex
	clients := map[string]aws.Config{}
	regionCfg := func(r string) aws.Config {
		mu.Lock()
		defer mu.Unlock()
		if c, ok := clients[r]; ok {
			return c
		}
		c, err := awscfg.New(context.Background(), r)
		if err != nil {
			c = cfg
		}
		clients[r] = c
		return c
	}
	userHome, _ := os.UserHomeDir()
	td := teardown.Teardown{
		EC2: func(r string) teardown.RegionAPI { return ec2.NewFromConfig(regionCfg(r)) },
		SSM: func(r string) teardown.SSMAPI { return ssm.NewFromConfig(regionCfg(r)) },
		IAM: iamc, Say: out.Say, Log: out.Log, Fail: func(s string) { out.LogAs("fail", s) },
		Wait: func(ctx context.Context, r, id string) bool {
			return box.Box{EC2: ec2.NewFromConfig(regionCfg(r)), ID: id, Log: out.Log}.WaitState(ctx, "terminated", 600*time.Second)
		},
	}
	all := &AllDeps{EC2: client, Budgets: budgets.NewFromConfig(us), Account: acct, W: store, Teardown: td,
		Scan: func(ctx context.Context) storage.Everywhere {
			regions := []string{home}
			if o, err := client.DescribeRegions(ctx, &ec2.DescribeRegionsInput{}); err == nil && len(o.Regions) > 0 {
				regions = nil
				for _, r := range o.Regions {
					regions = append(regions, aws.ToString(r.RegionName))
				}
			}
			return storage.Scan(ctx, regions, storage.ForHost(ctx, host))
		},
		RoleExists: func(ctx context.Context) bool {
			_, err := iamc.GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String(host + "-box")})
			return err == nil
		},
		WatchdogExists: func(ctx context.Context) bool { return watchdog.Exists(ctx, env) },
		RemoveWatchdog: func(ctx context.Context) { watchdog.RemoveQuietly(ctx, env, out) },
		TS:             func(t string) tskey.Client { return tskey.Client{Token: t} },
		Pem:            filepath.Join(userHome, ".ssh", host+".pem")}
	return DestroyDeps{EC2: client, IAM: iamc, All: all,
		Lib: library.Library{S3: store, Host: host, Region: home, Account: acct, Bucket: env.Get("GAME_S3_BUCKET")}}, nil
}

// WithDestroy lets a spot box's stop turn into a destroy.
func (d *Deps) WithDestroy(env *config.Env, client *ec2.Client) {
	d.Destroy = func(ctx context.Context) int {
		x, err := NewDestroyDeps(ctx, env, client, d.Out)
		if err != nil {
			d.Out.Die(err.Error())
			return 1
		}
		return d.DestroyBox(ctx, x, nil)
	}
}
