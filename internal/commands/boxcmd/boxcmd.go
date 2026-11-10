// Package boxcmd is what runs the AWS box: open it, stop it, clean it, pair with
// it, and ask it about the game library. They all reach it over the tailnet, as
// the ubuntu user, with the key ayis made for it.
package boxcmd

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/jebin2/ayis/internal/ask"
	"github.com/jebin2/ayis/internal/box"
	"github.com/jebin2/ayis/internal/config"
	"github.com/jebin2/ayis/internal/local"
	"github.com/jebin2/ayis/internal/output"
	"github.com/jebin2/ayis/internal/session"
	"github.com/jebin2/ayis/internal/stream"
	"github.com/jebin2/ayis/internal/sunshine"
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
	// GOOS is the system this runs on; empty is the real one. Tests set it.
	GOOS string
	// Takes is "the last one took 12 min", or "it takes a while".
	Takes func() string
	// MoonlightConf is Moonlight's config file.
	MoonlightConf string
	// Destroy is `ayis destroy`, which a spot box's stop turns into.
	Destroy func(ctx context.Context) int
	// Force is --force.
	Force bool
	// Sure is --yes on stop: the caller (the app) has already asked, so ayis does not ask again.
	Sure bool
	// Skip is --skip on stop: the games (appids, comma-separated) not to save.
	Skip string
	// UnsavedOK is `ayis disk remove --unsaved-ok`: delete the games disk even when
	// Saved games has no complete save, because the person chose that loss.
	UnsavedOK bool
	// Reach opens a TCP connection to the machine over Tailscale, for the wait that
	// checks it can be reached; nil is the real one. Tests set it.
	Reach func(addr string, timeout time.Duration) error
	// Pushed is when the archive last had everything saved (the marker the box
	// writes after a clean push); nil reads nothing, which is a "no".
	Pushed func(ctx context.Context) (at time.Time, found bool, err error)
	// ExtraGB and ExtraApps: ayis open makes a disk of this size and restores
	// these games (appids, comma separated) onto it. Zero and "" make none.
	ExtraGB   int
	ExtraApps string
	// Games are the games ayis open brings onto the machine before the stream
	// starts, "appid:bytes,appid:bytes" (bytes as Saved games holds them). The
	// ones in ExtraApps go on the added disk, the rest on the machine's own drive.
	Games string
	// DiskAWS is AWS's disks, for the play that makes one; nil makes none.
	DiskAWS DiskAPI
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
	d.Out.Die(fmt.Sprintf("'%s' is not on the tailnet. Is the box running? Try: ayis status", d.Box.Node))
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

const ayisLibrary = "/usr/local/bin/ayis-library"

// Library is the on-box `ayis library` forms, which need the box: status, check,
// push/sync, pull/restore, and account push/pull. The on-box ayis-library script is
// still the implementation; it is called over ssh.
func (d Deps) Library(ctx context.Context, sub string, args []string) int {
	if !d.NeedNode(ctx) {
		return 1
	}
	var command string
	title := ""
	switch sub {
	case "status", "":
		command, title = remote(ayisLibrary, "status"), "Game library on the box"
	case "push", "sync":
		command = remote(ayisLibrary, append([]string{"push"}, args...)...)
	case "pull", "restore":
		command = remote(ayisLibrary, append([]string{"pull"}, args...)...)
	case "check":
		command = remote(ayisLibrary, "check")
	case "account":
		if len(args) == 0 {
			return d.die("usage: ayis library account [status|push|pull|forget]")
		}
		w := strings.Replace(args[0], "restore", "pull", 1)
		command = remote(ayisLibrary, "account", w)
	default:
		return d.die("usage: ayis library [list|status|push|pull [--apps <csv>]|account [status|push|pull|forget]|check|forget <appid> [--from <bucket>]|reset <appid> [--from <bucket>]|keep-for <days>|move <appid> --from <bucket>|elsewhere|clean|--bucket]")
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
	command := remote(ayisLibrary, "push")
	if extra != "" {
		command = remote(ayisLibrary, "push", extra)
	}
	stop := d.watchSave(ctx)
	err := d.relay(ctx, command)
	stop()
	return err == nil
}
