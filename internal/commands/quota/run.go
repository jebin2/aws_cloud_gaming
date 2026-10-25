package quota

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/sweep"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

const usage = "usage: cg quota [status|request [ondemand|spot]|appeal [ondemand|spot]]"

// Run is `cg quota`.
func Run(ctx context.Context, env *config.Env, get config.Lookup, args []string, jsonFlag bool, out *output.Out) int {
	sub := "status"
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	kind := "ondemand"
	if len(args) > 0 {
		kind = args[0]
	}
	if sub == "--json" {
		sub, jsonFlag = "status", true
	}
	switch sub {
	case "status", "", "request", "appeal":
	default:
		out.Die(usage)
		return 1
	}
	region := env.Region()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	q := Quota{SQ: servicequotas.NewFromConfig(cfg), EC2: ec2.NewFromConfig(cfg), Region: region, Type: env.Setting("GAME_INSTANCE_TYPE")}
	switch sub {
	case "status", "":
		s := q.Read(ctx)
		if jsonFlag {
			b, _ := json.MarshalIndent(s, "", "  ")
			fmt.Fprintf(out.Stdout, "%s\n", b)
			return 0
		}
		out.Say("gpu quota in " + region)
		rows, after := Rows(s)
		for _, r := range rows {
			out.LogAs(r.Kind, r.Text)
		}
		for _, l := range after {
			out.Echo(l)
		}
		return 0
	case "request":
		if kind != "ondemand" && kind != "spot" {
			out.Die("usage: cg quota request [ondemand|spot]")
			return 1
		}
		return Asker{Quota: q, Say: out.Say, LogAs: out.LogAs, Log: out.Log}.Request(ctx, kind)
	default: // appeal
		f := AppealFacts{Type: q.Type, Need: q.Need(ctx), Region: region, BudgetINR: env.Int("GAME_BUDGET_INR"),
			IdleMin: env.Int("GAME_WATCHDOG_IDLE_MIN"), StuckMin: env.Int("GAME_WATCHDOG_STUCK_MIN"), CloudWatchEvery: wd.EveryMin}
		// The sweep remembers what this laptop measured; without one, the line is
		// left out rather than guessed at.
		dir := cacheDir(get)
		if c := (sweep.Store{Dir: dir, Name: "sweep.json"}).Cached(); c["cached"] == true {
			if rs, ok := c["regions"].([]any); ok {
				for _, r := range rs {
					if m, ok := r.(map[string]any); ok && m["region"] == region {
						if s, ok := m["city"].(string); ok {
							f.City = sweep.Trim(s)
						}
						if v, ok := m["rtt_ms"].(float64); ok {
							f.RTT = strconv.FormatFloat(v, 'f', -1, 64)
							if !strings.Contains(f.RTT, ".") {
								f.RTT += ".0" // as Python printed a float
							}
						}
						break
					}
				}
			}
		}
		fmt.Fprint(out.Stdout, AppealText(f))
		return 0
	}
}

func cacheDir(get config.Lookup) string {
	if v, ok := get("CG_CACHE_DIR"); ok && v != "" {
		return v
	}
	if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		return filepath.Join(base, "cg")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "cg")
}
