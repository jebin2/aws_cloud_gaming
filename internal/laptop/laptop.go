// Package laptop is what this computer needs to play: which tools are here,
// what would install the ones that are not, and how this process could become
// root to do it. `cg check` reports it and `cg check --fix` acts on it.
//
// The Bash cg needed six tools, because it was made of them: python3 rendered
// every JSON answer, curl fetched installers, and the AWS CLI was the only thing
// that talked to AWS. The Go binary is all three, so what is left is what it
// actually runs: ssh, Tailscale and Moonlight.
package laptop

import (
	"context"
	"golang.org/x/term"
	"os"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// Tool is something cg runs.
type Tool struct {
	Key   string
	Label string
	Why   string // what it is FOR: a list of names tells you nothing about which you can live without
	For   string // "aws" when only a box rented from AWS needs it, else "all"
}

// Tools in install order.
var Tools = []Tool{
	{"ssh", "OpenSSH (ssh, scp)", "every command cg runs on the box goes through it", "all"},
	{"tailscale", "Tailscale", "the private network the box joins; there is no public SSH port", "all"},
	{"moonlight", "Moonlight", "the stream itself - this is what you play on", "all"},
}

// Laptop asks the machine.
type Laptop struct {
	Runner local.Runner
	Getenv func(string) string
	TTY    func() bool // is standard input a terminal
	// LookPath resolves a program to an absolute path; nil uses exec.LookPath.
	LookPath func(string) (string, error)
}

// New is the real one.
func New(r local.Runner) Laptop {
	return Laptop{Runner: r, Getenv: os.Getenv, TTY: func() bool {
		// A terminal, not merely a character device: /dev/null is one too.
		return term.IsTerminal(int(os.Stdin.Fd()))
	}}
}

// Missing is the tools that are absent. OpenSSH counts as absent without scp.
func (l Laptop) Missing() []string {
	var out []string
	for _, t := range Tools {
		switch t.Key {
		case "ssh":
			if !(l.Runner.Has("ssh") && l.Runner.Has("scp")) {
				out = append(out, t.Key)
			}
		default:
			if !l.Runner.Has(t.Key) {
				out = append(out, t.Key)
			}
		}
	}
	return out
}

// PackageManager is the first of pacman, apt-get, dnf, zypper that is here.
func (l Laptop) PackageManager() string {
	for _, pm := range []string{"pacman", "apt-get", "dnf", "zypper"} {
		if l.Runner.Has(pm) {
			return pm
		}
	}
	return ""
}

// TailscaleDown is installed but not signed in, or not running.
func (l Laptop) TailscaleDown(ctx context.Context) bool {
	if !l.Runner.Has("tailscale") {
		return false
	}
	_, err := l.Runner.Output(ctx, "tailscale", "status")
	return err != nil
}

// Package is the distro package that provides a tool; "" when it installs
// another way.
func Package(pm, tool string) string {
	switch pm + ":" + tool {
	case "pacman:ssh":
		return "openssh"
	case "apt-get:ssh":
		return "openssh-client"
	case "dnf:ssh", "zypper:ssh":
		return "openssh-clients"
	case "pacman:tailscale":
		return "tailscale"
	}
	if tool == "moonlight" {
		return "moonlight-qt"
	}
	return ""
}

// Manual is where to get a tool by hand.
func Manual(tool string) string {
	switch tool {
	case "tailscale":
		return "https://tailscale.com/download"
	// cg runs `moonlight`, which a Flatpak does not put on PATH.
	case "moonlight":
		return "https://github.com/moonlight-stream/moonlight-qt/releases (cg needs a moonlight command on PATH)"
	case "ssh":
		return "your distro's OpenSSH client package"
	}
	return "your distro's " + tool + " package"
}

// Plan is what --fix will run, in words.
func Plan(pm, tool string) string {
	if pkg := Package(pm, tool); pkg != "" {
		switch pm {
		case "pacman":
			return "sudo pacman -S " + pkg
		case "apt-get":
			return "sudo apt-get install " + pkg
		case "dnf":
			return "sudo dnf install " + pkg
		case "zypper":
			return "sudo zypper install " + pkg
		}
	}
	if tool == "tailscale" {
		return "Tailscale's install script, https://tailscale.com/install.sh (uses sudo)"
	}
	return ""
}

// Root is how this process would become root, and why it cannot when it
// cannot. A terminal has sudo; the app has neither a terminal nor anywhere for
// sudo to ask for a password, so it goes through polkit, which puts the prompt
// on the desktop where the person is already looking.
func (l Laptop) Root() (method, blocked string) {
	if l.TTY() {
		return "sudo", ""
	}
	if l.Runner.Has("pkexec") && (l.Getenv("DISPLAY") != "" || l.Getenv("WAYLAND_DISPLAY") != "") {
		return "pkexec", ""
	}
	if !l.Runner.Has("pkexec") {
		return "", "no terminal, and polkit (pkexec) is not installed"
	}
	return "", "no terminal, and no desktop session for polkit to show a password prompt on"
}

// Label is a tool's name for a person.
func Label(key string) string {
	for _, t := range Tools {
		if t.Key == key {
			return t.Label
		}
	}
	return key
}

// In reports whether the list has the item.
func In(list []string, item string) bool {
	for _, s := range list {
		if strings.EqualFold(s, item) {
			return true
		}
	}
	return false
}
