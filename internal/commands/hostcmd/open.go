package hostcmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
)

// Open is `cg host open <name>`: stream from it. No machine to start, nothing
// billed by the hour: it is already there.
func (d Deps) Open(ctx context.Context, args []string, out *output.Out) int {
	var name string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			name = a
			break
		}
	}
	if name == "" {
		out.Die("usage: cg host open <name>")
		return 1
	}
	ip := d.Store.Get(name).Field("ts_ip")
	if ip == "" {
		out.Die(fmt.Sprintf("'%s' is not set up yet: cg host setup %s", name, name))
		return 1
	}
	if !d.Moonlight {
		out.Die("Moonlight is not installed - cg check --fix installs it")
		return 1
	}
	if l, held := session.Running(d.SessionFile, d.Probe); held {
		out.Die(fmt.Sprintf("a stream from this laptop is already running (pid %d)", l.PID))
		return 1
	}
	// Two steps, which the app shows as the AWS machine's session is shown: the
	// machine answering, then the stream.
	out.Say("checking " + name + " is ready to stream")
	if !d.Sun.Answers(ctx, ip) {
		out.Die(fmt.Sprintf("Sunshine is not answering on %s (%s) - is it on, and a desktop signed in?", name, ip))
		return 1
	}
	session.Claim(d.SessionFile, d.Now())
	defer session.Release(d.SessionFile)
	out.Say("streaming from " + name)
	app := d.Env.Get("GAME_APP")
	d.Player.Play(ctx, ip, app)
	return 0
}
