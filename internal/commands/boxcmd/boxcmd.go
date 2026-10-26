// Package boxcmd is what runs the AWS box: open it, stop it, clean it, pair with
// it, and ask it about the game library. They all reach it over the tailnet, as
// the ubuntu user, with the key cg made for it.
package boxcmd

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/box"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
	"github.com/jebin2/aws_cloud_gaming/internal/stream"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
)

// Deps is what the box commands use.
type Deps struct {
	Box    box.Box
	Out    *output.Out
	Ask    *ask.Asker
	Env    *config.Env
	Sun    sunshine.Client
	Pair   sunshine.Pairer
	Player stream.Player
	R      local.Runner

	SessionFile string
	Probe       session.Probe
	Now         func() time.Time
	Sleep       func(time.Duration)
	Moonlight   bool
	// Takes is "the last one took 12 min", or "it takes a while".
	Takes func() string
	// MoonlightConf is Moonlight's config file.
	MoonlightConf string
	// Destroy is `cg destroy`, which a spot box's stop turns into.
	Destroy func(ctx context.Context) int
	// Force is --force.
	Force bool
	// Dial checks a TCP port; nil really dials.
	Dial func(addr string, timeout time.Duration) error
}

func (d Deps) sleep(t time.Duration) {
	if d.Sleep != nil {
		d.Sleep(t)
		return
	}
	time.Sleep(t)
}

func (d Deps) die(text string) int {
	d.Out.Die(text)
	return 1
}

// NeedNode: stop, with what to try, when the box is not on the tailnet.
func (d Deps) NeedNode(ctx context.Context) bool {
	if _, ok := d.Box.IP(ctx); ok {
		return true
	}
	d.Out.Die(fmt.Sprintf("'%s' is not on the tailnet. Is the box running? Try: cg status", d.Box.Node))
	return false
}

// quote makes one argument safe for the shell on the box.
func quote(s string) string {
	if s != "" && !strings.ContainsAny(s, " \t\n'\"\\$`!*?[]{}()<>|&;#~") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// remote builds the command for the box from an argv, so nothing typed here is
// interpolated into a shell string. OpenSSH still joins what it is given with
// spaces and hands it to the remote shell, which is why each word is quoted.
func remote(prog string, args ...string) string {
	parts := []string{prog}
	for _, a := range args {
		parts = append(parts, quote(a))
	}
	return strings.Join(parts, " ")
}

// relay streams the box's output, indented, as it arrives.
func (d Deps) relay(ctx context.Context, command string) error {
	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() { d.Out.Relay(pr, "      "); close(done) }()
	err := d.Box.Stream(ctx, pw, command)
	pw.Close()
	<-done
	return err
}

// block says a boxed note.
func (d Deps) block(title string, lines ...string) {
	d.Out.Block(title, "\n"+strings.Join(lines, "\n")+"\n\n")
}

const library = "/usr/local/bin/cg-library"

// Library is the on-box `cg library` forms, which need the box: status, check,
// push/sync, pull/restore, and account push/pull. The on-box cg-library script is
// still the implementation; it is called over ssh.
func (d Deps) Library(ctx context.Context, sub string, args []string) int {
	if !d.NeedNode(ctx) {
		return 1
	}
	var command string
	title := ""
	switch sub {
	case "status", "":
		command, title = remote(library, "status"), "Game library on the box"
	case "push", "sync":
		command = remote(library, append([]string{"push"}, args...)...)
	case "pull", "restore":
		command = remote(library, append([]string{"pull"}, args...)...)
	case "check":
		command = remote(library, "check")
	case "account":
		if len(args) == 0 {
			return d.die("usage: cg library account [status|push|pull|forget]")
		}
		w := strings.Replace(args[0], "restore", "pull", 1)
		command = remote(library, "account", w)
	default:
		return d.die("usage: cg library [list|status|push|pull [--apps <csv>]|account [status|push|pull|forget]|check|forget <appid> [--from <bucket>]|reset <appid> [--from <bucket>]|keep-for <days>|move <appid> --from <bucket>|elsewhere|clean|--bucket]")
	}
	if title != "" {
		out, err := d.Box.SSH(ctx, command, nil)
		d.Out.Report(title, string(out))
		d.said(err)
		return exit(err)
	}
	return exit(d.Box.Stream(ctx, d.Out.Stdout, command))
}

// said shows what a failed command on the box said on its standard error, which a
// captured run would otherwise swallow: ssh's own reason is the whole message.
func (d Deps) said(err error) {
	if err == nil {
		return
	}
	if s := strings.TrimRight(local.Stderr(err), "\n"); s != "" {
		fmt.Fprintln(d.Out.Stderr, s)
	}
}

func exit(err error) int {
	if err == nil {
		return 0
	}
	if c := local.ExitCode(err); c > 0 {
		return c
	}
	return 1
}

// Push mirrors the game library to S3 from here (`library_push`). It is here and
// in destroy and nowhere else: there is no timer and no pre-shutdown hook, so if
// this does not run, the games are gone.
func (d Deps) Push(ctx context.Context, extra, unreachable, say string) bool {
	if _, ok := d.Box.IP(ctx); !ok {
		d.Out.Log(unreachable)
		return false
	}
	d.Out.Say(say)
	command := remote(library, "push")
	if extra != "" {
		command = remote(library, "push", extra)
	}
	return d.relay(ctx, command) == nil
}
