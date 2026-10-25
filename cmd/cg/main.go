// Command cg is the cloud-gaming CLI. This is the Go port: it is built beside
// the Bash cg, one command at a time, and the Bash one is the oracle until the
// port is complete (docs/migration/go-plan.md).
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"syscall"

	"github.com/jebin2/aws_cloud_gaming/internal/commands/configcmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/cost"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/creds"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/deps"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/machines"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/remote"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/status"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/sweep"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watcher"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/contract"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// version is set at release time with -ldflags "-X main.version=...".
var version string

func buildVersion() string {
	if version != "" {
		return version
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		var rev, dirty string
		for _, s := range bi.Settings {
			switch s.Key {
			case "vcs.revision":
				rev = s.Value[:min(7, len(s.Value))]
			case "vcs.modified":
				if s.Value == "true" {
					dirty = "-dirty"
				}
			}
		}
		if rev != "" {
			return rev + dirty
		}
	}
	return "unknown"
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Args[1:], os.LookupEnv, os.Stdout, os.Stderr))
}

// repoDir is where cg's files live: CG_REPO, else beside the binary.
func repoDir(get config.Lookup) string {
	if v, ok := get("CG_REPO"); ok && v != "" {
		return v
	}
	if exe, err := os.Executable(); err == nil {
		return filepath.Dir(exe)
	}
	return ""
}

func run(ctx context.Context, args []string, lookup config.Lookup, stdout, stderr io.Writer) (rc int) {
	cgJSON, _ := lookup("CG_JSON")
	out := &output.Out{Stdout: stdout, Stderr: stderr, JSON: cgJSON == "1"}
	// Every step ends - on success, on failure and on interrupt.
	defer func() {
		if ctx.Err() != nil {
			rc = 130
		}
		out.End(rc)
	}()
	overrides := map[string]string{}
	var jsonFlag, watchFlag bool
	get := func(k string) (string, bool) {
		if v, ok := overrides[k]; ok {
			return v, true
		}
		return lookup(k)
	}

	// Global flags come before the command, as in the Bash cg.
	for len(args) > 0 && len(args[0]) > 0 && args[0][0] == '-' {
		switch args[0] {
		case "--json":
			jsonFlag, args = true, args[1:]
		case "--watch":
			watchFlag, args = true, args[1:]
		case "--region", "--host":
			if len(args) < 2 {
				out.Die(fmt.Sprintf("%s needs a value (see: cg help)", args[0]))
				return 1
			}
			key := map[string]string{"--region": "GAME_REGION", "--host": "GAME_TS_HOST"}[args[0]]
			overrides[key] = args[1]
			args = args[2:]
		case "--version":
			fmt.Fprintf(stdout, "cg %s\nevents %d\n", buildVersion(), contract.EventsVersion)
			return 0
		case "--contract":
			b, err := contract.JSON()
			if err != nil {
				out.Die(err.Error())
				return 1
			}
			fmt.Fprintf(stdout, "%s\n", b)
			return 0
		case "-h", "--help":
			args = []string{"help"}
		default:
			out.Die(fmt.Sprintf("unknown flag '%s' (see: cg help)", args[0]))
			return 1
		}
	}
	cmd := "help"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "help":
		fmt.Fprintln(stdout, "cg - cloud gaming (Go port, in progress)")
		fmt.Fprintln(stdout)
		for _, c := range contract.Registry {
			fmt.Fprintf(stdout, "  cg %-10s %s\n", c.Path[0], c.Summary)
		}
		return 0
	case "sweep", "regions-sweep":
		return sweep.Run(ctx, config.Load(get, repoDir(get)), get, args, jsonFlag, out)
	case "machines", "types":
		// `cg machines [region] --sweep` is the sweep, whatever region was named.
		for i, a := range args {
			if a == "--sweep" || a == "sweep" {
				rest := append(append([]string{}, args[:i]...), args[i+1:]...)
				if len(rest) > 0 && machines.IsRegion(rest[0]) {
					rest = rest[1:]
				}
				return sweep.Run(ctx, config.Load(get, repoDir(get)), get, rest, jsonFlag, out)
			}
		}
		return machines.Run(ctx, config.Load(get, repoDir(get)), get, args, jsonFlag, out)
	case "deps", "dependencies":
		return deps.Main(ctx, args, jsonFlag, out)
	case "creds", "credentials":
		return creds.Run(ctx, config.Load(get, repoDir(get)), args, jsonFlag, out)
	case "config":
		return configcmd.Run(config.Load(get, repoDir(get)), args, jsonFlag, out)
	case "ping":
		return remote.RunPing(ctx, config.Load(get, repoDir(get)), args, jsonFlag, watchFlag, out)
	case "log", "logs":
		return remote.RunLog(ctx, config.Load(get, repoDir(get)), args, out)
	case "ssh":
		return remote.RunSSH(ctx, config.Load(get, repoDir(get)), args, out)
	case "watcher", "guards":
		opts, err := watcher.ParseArgs(args)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return watcher.Run(ctx, config.Load(get, repoDir(get)), opts, out)
	case "watchdog":
		watch := false
		for _, a := range args {
			watch = watch || a == "--watch"
		}
		return watchdog.Run(ctx, config.Load(get, repoDir(get)), args, watch, out)
	case "status":
		opts, err := status.ParseArgs(args)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return status.Run(ctx, config.Load(get, repoDir(get)), get, opts, out)
	case "cost":
		opts, err := cost.ParseArgs(args)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return cost.Run(ctx, config.Load(get, repoDir(get)), get, opts, out)
	}
	out.Die(fmt.Sprintf("'%s' is not ported to Go yet (see: cg help)", cmd))
	return 1
}
