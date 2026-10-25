// Package deps is `cg deps`: the tools this computer needs, and what is missing.
package deps

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Tool is one row of the dependency list, as data. The app draws a page from
// this; `cg check` says the same thing in prose.
type Tool struct {
	Tool    string  `json:"tool"`
	Label   string  `json:"label"`
	Present bool    `json:"present"`
	Why     *string `json:"why"`
	Plan    *string `json:"plan"`
	Manual  *string `json:"manual"`
	For     string  `json:"for"`
}

// Status is `cg deps --json`.
type Status struct {
	Tools          []Tool  `json:"tools"`
	PackageManager *string `json:"package_manager"`
	Root           *string `json:"root"`
	// RootBlocked is why this process cannot become root, when it cannot: the
	// app needs it to know whether an Install button can do anything at all.
	RootBlocked *string `json:"root_blocked"`
	// Installed but not signed in is its own state: nothing to install, and
	// nothing works until someone signs in. Null when Tailscale is not here.
	TailscaleSignedIn *bool `json:"tailscale_signed_in"`
}

func nz(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Read asks the machine.
func Read(ctx context.Context, l laptop.Laptop) Status {
	pm := l.PackageManager()
	missing := l.Missing()
	root, why := l.Root()
	s := Status{PackageManager: nz(pm), Root: nz(root), RootBlocked: nz(why), Tools: []Tool{}}
	for _, t := range laptop.Tools {
		plan := ""
		if pm != "" {
			plan = laptop.Plan(pm, t.Key)
		}
		s.Tools = append(s.Tools, Tool{t.Key, t.Label, !laptop.In(missing, t.Key), nz(t.Why), nz(plan), nz(laptop.Manual(t.Key)), t.For})
	}
	if l.Runner.Has("tailscale") {
		signed := !l.TailscaleDown(ctx)
		s.TailscaleSignedIn = &signed
	}
	return s
}

// JSON is `cg deps --json`.
func JSON(s Status) ([]byte, error) { return json.MarshalIndent(s, "", "  ") }

// Report is `cg deps` in words, and whether everything is ready. after is true
// after --fix: what is left is for you to install, and suggesting --fix again
// would only send you round in a loop.
func Report(ctx context.Context, l laptop.Laptop, out *output.Out, afterFix bool) (ready bool) {
	missing := l.Missing()
	var found []string
	for _, t := range laptop.Tools {
		if !laptop.In(missing, t.Key) {
			found = append(found, t.Label)
		}
	}
	if len(found) > 0 {
		out.LogAs("ok", "installed: "+strings.Join(found, ", "))
	}
	pm := l.PackageManager()
	byHand := pm == "" || afterFix
	ready = true
	for _, m := range missing {
		out.LogAs("fail", "missing: "+laptop.Label(m))
		ready = false
		if byHand {
			out.Log("  install it yourself: " + laptop.Manual(m))
		}
	}
	switch {
	case l.TailscaleDown(ctx):
		out.LogAs("fail", "Tailscale is installed but not signed in, or not running")
		ready = false
		if afterFix {
			out.Log("  sign in yourself: sudo tailscale up")
		}
	case l.Runner.Has("tailscale"):
		out.LogAs("ok", "Tailscale signed in")
	}
	// --fix can sign Tailscale in with no package manager, so offer it for that too.
	if !ready && !afterFix && (pm != "" || len(missing) == 0) {
		out.Log("cg check --fix installs and signs in what is missing, after asking")
	}
	return ready
}

// Run is `cg deps [status|install [tool...]|--json]`.
func Run(ctx context.Context, l laptop.Laptop, args []string, jsonFlag bool, out *output.Out) int {
	sub := "status"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "--json":
		jsonFlag = true
	case "status", "":
	case "install":
		return Install(ctx, l, &laptop.Installer{L: l, Say: sayTo(out)}, args[1:], out)
	default:
		out.Die("usage: setup deps [status|install [tool...]|--json]")
		return 1
	}
	if jsonFlag {
		b, err := JSON(Read(ctx, l))
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	if Report(ctx, l, out, false) {
		return 0
	}
	return 1
}

// Main is `cg deps` against this computer.
func Main(ctx context.Context, args []string, jsonFlag bool, out *output.Out) int {
	return Run(ctx, laptop.New(local.Exec{}), args, jsonFlag, out)
}

func sayTo(out *output.Out) laptop.Say {
	return func(kind, text string) {
		if kind == "log" {
			out.Log(text)
		} else {
			out.LogAs(kind, text)
		}
	}
}

// Install is `cg deps install [tool...]`: what is missing, or just the tools named.
func Install(ctx context.Context, l laptop.Laptop, in *laptop.Installer, want []string, out *output.Out) int {
	missing := l.Missing()
	if len(missing) == 0 {
		out.LogAs("ok", "nothing to install - every tool cg needs is here")
		// Installed but signed out is the other half of being ready.
		if !l.TailscaleDown(ctx) {
			return 0
		}
		out.Log("Tailscale is installed but not signed in")
		if !l.TTY() {
			out.Log("  signing in needs a terminal:  sudo tailscale up")
			return 1
		}
		if l.TailscaleUp(ctx, sayTo(out)) {
			return 0
		}
		return 1
	}
	pm := l.PackageManager()
	if pm == "" {
		out.Log("no supported package manager (pacman, apt, dnf, zypper) - install these by hand:")
		for _, t := range missing {
			out.Log("  " + laptop.Label(t) + ": " + laptop.Manual(t))
		}
		return 1
	}
	if len(want) == 0 {
		want = missing
	}
	out.Say("installing")
	rc := 0
	for _, t := range want {
		if !laptop.In(missing, t) {
			out.LogAs("ok", laptop.Label(t)+" is already here")
			continue
		}
		out.Log("installing " + laptop.Label(t) + " - " + laptop.Plan(pm, t))
		if in.Install(ctx, pm, t) {
			out.LogAs("ok", laptop.Label(t)+" installed")
			continue
		}
		out.LogAs("fail", "could not install "+laptop.Label(t))
		// -Sy without -u is a partial upgrade: the database is current and the
		// installed system is not, so a package can want a library that is newer
		// than the one here. That is the one failure a refresh cannot fix.
		if pm == "pacman" {
			out.Log("  if it asked for a newer library, this system is behind: sudo pacman -Syu")
		}
		out.Log("  by hand: " + laptop.Manual(t))
		rc = 1
	}
	return rc
}
