package remote

import (
	"context"
	"fmt"
	"os"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// New is the box for the settings in force.
func New(env *config.Env) Box {
	home, _ := os.UserHomeDir()
	host := env.Host()
	node := env.Get("GAME_TS_NODE")
	if node == "" {
		node = host
	}
	return Box{Runner: local.Exec{}, Host: host, Node: node, Home: home}
}

// RunPing is `cg ping`.
func RunPing(ctx context.Context, env *config.Env, args []string, jsonOut, watch bool, out *output.Out) int {
	for _, a := range args {
		switch a {
		case "--json":
			jsonOut = true
		case "--watch":
			watch = true
		default:
			out.Die(fmt.Sprintf("unknown option '%s' (see: cg help)", a))
			return 1
		}
	}
	return New(env).Ping(ctx, jsonOut, watch, out.Stdout, out)
}

// RunLog is `cg log` (also `cg logs`).
func RunLog(ctx context.Context, env *config.Env, args []string, out *output.Out) int {
	what, watch := "build", false
	var rest []string
	for _, a := range args {
		if a == "--watch" {
			watch = true
		} else if a != "--json" {
			rest = append(rest, a)
		}
	}
	if len(rest) > 0 {
		what = rest[0]
	}
	return New(env).Log(ctx, what, watch, out.Stdout, out)
}

// RunSSH is `cg ssh`.
func RunSSH(ctx context.Context, env *config.Env, args []string, out *output.Out) int {
	return New(env).SSH(ctx, args, out)
}
