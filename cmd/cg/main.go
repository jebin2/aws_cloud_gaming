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

	"github.com/jebin2/aws_cloud_gaming/internal/commands/awscmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/boxcmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/check"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/configcmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/cost"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/creds"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/deps"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/games"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/hostcmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/initcmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/librarycmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/machines"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/notify"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/quota"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/regions"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/remote"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/snapshot"
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
	// Flags are also accepted after the subcommand, which is how people
	// actually type them.
	for _, a := range args {
		switch a {
		case "--json":
			jsonFlag = true
		case "--watch":
			watchFlag = true
		}
	}
	switch cmd {
	case "help":
		fmt.Fprintln(stdout, "cg - cloud gaming (Go port, in progress)")
		fmt.Fprintln(stdout)
		for _, c := range contract.Registry {
			fmt.Fprintf(stdout, "  cg %-10s %s\n", c.Path[0], c.Summary)
		}
		return 0
	case "notify":
		return notify.Send(ctx, nil, config.Load(get, repoDir(get)), out)
	case "games":
		return games.Run(ctx, config.Load(get, repoDir(get)), args, out)
	case "aws":
		return awscmd.Run(ctx, config.Load(get, repoDir(get)), args, jsonFlag, out)
	case "snapshot":
		sub := "create"
		if len(args) > 0 {
			sub = args[0]
		}
		switch sub {
		case "--list", "list":
			return snapshot.Run(ctx, config.Load(get, repoDir(get)), args, jsonFlag, out)
		case "create", "":
			d, _, err := boxcmd.New(ctx, get, config.Load(get, repoDir(get)), out)
			if err != nil {
				out.Die(err.Error())
				return 1
			}
			return d.SnapshotCreate(ctx)
		case "--delete", "delete":
			d, c, err := boxcmd.New(ctx, get, config.Load(get, repoDir(get)), out)
			if err != nil {
				out.Die(err.Error())
				return 1
			}
			id := ""
			if len(args) > 1 {
				id = args[1]
			}
			return d.SnapshotDelete(ctx, id, c)
		}
		out.Die("usage: cg snapshot [create|--list|--delete <id>]")
		return 1
	case "init":
		// Not on by default: this launches billing machines, and it has not yet been
		// run against a real account. The Bash cg init is the one to use until it has.
		if v, _ := get("CG_GO_INIT"); v != "1" {
			out.Die("cg-go init has not passed its real-AWS test yet, so it is off.\n       It launches a machine that bills by the hour. Use the Bash cg init, or set CG_GO_INIT=1 to try this one on purpose.")
			return 1
		}
		env := config.Load(get, repoDir(get))
		i, err := initcmd.New(ctx, get, env, out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return i.Run(ctx)
	case "open", "up":
		env := config.Load(get, repoDir(get))
		if len(args) > 0 && args[0] == "--on" {
			name := ""
			if len(args) > 1 {
				name = args[1]
			}
			return hostcmd.Run(ctx, hostcmd.New(get, env, out), []string{"open", name}, false, out)
		}
		d, _, err := boxcmd.New(ctx, get, env, out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return d.Open(ctx)
	case "stop", "down":
		env := config.Load(get, repoDir(get))
		d, c, err := boxcmd.New(ctx, get, env, out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		d.WithDestroy(env, c)
		return d.Stop(ctx, args)
	case "destroy":
		env := config.Load(get, repoDir(get))
		d, c, err := boxcmd.New(ctx, get, env, out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		x, err := boxcmd.NewDestroyDeps(ctx, env, c)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return d.DestroyBox(ctx, x, args)
	case "clean":
		d, _, err := boxcmd.New(ctx, get, config.Load(get, repoDir(get)), out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return d.Clean(ctx)
	case "pair":
		d, _, err := boxcmd.New(ctx, get, config.Load(get, repoDir(get)), out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		return d.PairMoonlight(ctx)
	case "host":
		return hostcmd.Run(ctx, hostcmd.New(get, config.Load(get, repoDir(get)), out), args, jsonFlag, out)
	case "library", "lib":
		if sub := firstArg(args, "status"); onBoxLibrary(sub, args) {
			d, _, err := boxcmd.New(ctx, get, config.Load(get, repoDir(get)), out)
			if err != nil {
				out.Die(err.Error())
				return 1
			}
			rest := []string{}
			if len(args) > 1 {
				rest = args[1:]
			}
			if sub == "account" || sub == "login" {
				rest = accountRest(args[1:])
				sub = "account"
			}
			return d.Library(ctx, sub, rest)
		}
		return librarycmd.Run(ctx, config.Load(get, repoDir(get)), get, args, jsonFlag, out)
	case "regions":
		return regions.Run(ctx, config.Load(get, repoDir(get)), args, jsonFlag, out)
	case "quota":
		return quota.Run(ctx, config.Load(get, repoDir(get)), get, args, jsonFlag, out)
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
	case "check":
		return check.Run(ctx, config.Load(get, repoDir(get)), args, out)
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

func firstArg(args []string, def string) string {
	if len(args) > 0 {
		return args[0]
	}
	return def
}

// onBoxLibrary: the forms of `cg library` that ask the box.
func onBoxLibrary(sub string, args []string) bool {
	switch sub {
	case "status", "push", "sync", "pull", "restore", "check":
		return true
	case "account", "login":
		for _, a := range accountRest(args[1:]) {
			switch a {
			case "push", "pull", "restore":
				return true
			}
			return false
		}
	}
	return false
}

// accountRest drops the flags that come before the account word: flags are
// recognised globally but are not removed from the arguments.
func accountRest(args []string) []string {
	for len(args) > 0 && len(args[0]) > 0 && args[0][0] == '-' {
		args = args[1:]
	}
	return args
}
