package watcher

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	cg "github.com/jebin2/aws_cloud_gaming"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Options are what the command line said.
type Options struct{ JSON, Watch bool }

// ParseArgs reads the arguments after `watcher` (or its alias `guards`).
func ParseArgs(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch a {
		case "--json":
			o.JSON = true
		case "--watch":
			o.Watch = true
		default:
			return o, fmt.Errorf("unknown option '%s' (see: cg help)", a)
		}
	}
	return o, nil
}

// Run is `cg watcher`.
func Run(ctx context.Context, env *config.Env, opts Options, out *output.Out) int {
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
	reader, err := watchdog.NewReader(ctx, env)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	home, _ := os.UserHomeDir()
	host := env.Host()
	node := env.Get("GAME_TS_NODE")
	if node == "" {
		node = host
	}
	script, _ := cg.Files.ReadFile("host/idle-watchdog.sh")
	w := &Watcher{
		EC2: ec2.NewFromConfig(cfg), Budgets: budgets.NewFromConfig(us), STS: sts.NewFromConfig(cfg), Reader: reader,
		Runner: local.Exec{}, Host: host, Node: node, InstanceID: env.Get("GAME_INSTANCE_ID"), Home: home,
		HostIdleLimit: HostIdleLimit(script), IdleMin: env.Int("GAME_WATCHDOG_IDLE_MIN"),
		StuckMin: env.Int("GAME_WATCHDOG_STUCK_MIN"), ExpiryDays: env.Int("GAME_ARCHIVE_EXPIRY_DAYS"),
	}
	if opts.Watch {
		ip := w.nodeIP(ctx)
		if ip == "" {
			out.Die(fmt.Sprintf("'%s' is not on the tailnet. Is the box running? Try: cg status", node))
			return 1
		}
		err := w.Runner.Stream(ctx, out.Stdout, "ssh", "-i", home+"/.ssh/"+host+".pem", "-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "ubuntu@"+ip, "journalctl -t idle-watchdog -f")
		if err != nil && ctx.Err() == nil {
			return 1
		}
		return 0
	}
	f := w.Gather(ctx)
	if opts.JSON {
		b, err := w.JSON(f, time.Now())
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	w.Render(f, out)
	return 0
}
