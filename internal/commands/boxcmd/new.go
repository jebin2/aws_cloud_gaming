package boxcmd

import (
	"context"
	"os"
	"path/filepath"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/ec2"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/box"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
	"github.com/jebin2/aws_cloud_gaming/internal/stream"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
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
