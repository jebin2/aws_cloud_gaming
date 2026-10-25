// Command cg is the cloud-gaming CLI. This is the Go port: it is built beside
// the Bash cg, one command at a time, and the Bash one is the oracle until the
// port is complete (docs/migration/go-plan.md).
package main

import (
	"fmt"
	"os"
	"runtime/debug"

	"github.com/jebin2/aws_cloud_gaming/internal/contract"
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
				if len(s.Value) > 7 {
					rev = s.Value[:7]
				} else {
					rev = s.Value
				}
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

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, stdout, stderr *os.File) int {
	// Global flags come before the command, as in the Bash cg.
	for len(args) > 0 && len(args[0]) > 0 && args[0][0] == '-' {
		switch args[0] {
		case "--version":
			fmt.Fprintf(stdout, "cg %s\nevents %d\n", buildVersion(), contract.EventsVersion)
			return 0
		case "--contract":
			b, err := contract.JSON()
			if err != nil {
				fmt.Fprintln(stderr, err)
				return 1
			}
			fmt.Fprintf(stdout, "%s\n", b)
			return 0
		case "-h", "--help":
			args = []string{"help"}
		default:
			fmt.Fprintf(stderr, "unknown flag '%s' (see: cg help)\n", args[0])
			return 1
		}
	}
	cmd := "help"
	if len(args) > 0 {
		cmd = args[0]
	}
	if cmd == "help" {
		fmt.Fprintln(stdout, "cg - cloud gaming (Go port, in progress)")
		fmt.Fprintln(stdout)
		for _, c := range contract.Registry {
			fmt.Fprintf(stdout, "  cg %-10s %s\n", c.Path[0], c.Summary)
		}
		return 0
	}
	fmt.Fprintf(stderr, "cg: '%s' is not ported to Go yet (see: cg help)\n", cmd)
	return 1
}
