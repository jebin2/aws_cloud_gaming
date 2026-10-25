package laptop

import (
	"bytes"
	"context"
	"os/exec"
	"regexp"
	"strings"
)

// Say is how this package speaks: kind is "log" for a plain line, or what
// output.LogAs takes ("ok", "fail", "warn").
type Say func(kind, text string)

// path is where a program is, absolute: pkexec resets the environment and wants
// one, so the program is resolved here rather than left to a PATH it will not have.
func (l Laptop) path(prog string) string {
	look := l.LookPath
	if look == nil {
		look = exec.LookPath
	}
	if p, err := look(prog); err == nil {
		return p
	}
	return prog
}

var loginURL = regexp.MustCompile(`https://login\.tailscale\.com/[^\s]+`)

// RootLines turns one line of a root command's output into what to say. A blank
// line says nothing. polkit's own refusal is the likeliest way this fails on a
// fresh desktop - pkexec is installed and nothing is listening to authenticate -
// and on its own the message says nothing about what to do. The login link goes
// on a line of its own so the app can lift the URL out and offer it.
func RootLines(line string) [][2]string {
	switch {
	case strings.TrimSpace(line) == "":
		return nil
	case strings.Contains(line, "authentication agent"), strings.Contains(line, "Not authorized"),
		strings.Contains(line, "Error executing command as another user"):
		return [][2]string{{"log", line},
			{"log", "  no polkit agent is answering on this desktop"},
			{"log", "  start one (Hyprland/Omarchy: systemctl --user start hyprpolkitagent),"}}
	case strings.Contains(line, "https://login.tailscale.com/"):
		return [][2]string{{"log", "sign in here: " + loginURL.FindString(line)}}
	}
	return [][2]string{{"log", line}}
}

// lineWriter passes each complete line on as it ARRIVES: `tailscale up` prints a
// login URL and then waits for someone to visit it, so a line held until the
// command returns arrives after it was needed.
type lineWriter struct {
	buf bytes.Buffer
	say Say
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf.Write(p)
	for {
		i := bytes.IndexByte(w.buf.Bytes(), '\n')
		if i < 0 {
			return len(p), nil
		}
		w.emit(string(w.buf.Next(i + 1)))
	}
}

func (w *lineWriter) emit(l string) {
	for _, s := range RootLines(strings.TrimRight(l, "\r\n")) {
		w.say(s[0], s[1])
	}
}

func (w *lineWriter) flush() {
	if w.buf.Len() > 0 {
		w.emit(w.buf.String())
		w.buf.Reset()
	}
}

// RootRun runs a program as root through `as` (sudo or pkexec), standard error
// folded into standard output, and says every line as it arrives.
func (l Laptop) RootRun(ctx context.Context, as string, say Say, prog string, args ...string) error {
	w := &lineWriter{say: say}
	argv := append([]string{"-c", `exec "$@" 2>&1`, "sh", l.path(as), l.path(prog)}, args...)
	err := l.Runner.Stream(ctx, w, "sh", argv...)
	w.flush()
	return err
}

// TailscaleUp signs this computer in. Root is needed twice - to start tailscaled
// and to run `tailscale up` - and in a window that is polkit's job, the same as
// installing.
func (l Laptop) TailscaleUp(ctx context.Context, say Say) bool {
	as, why := l.Root()
	if as == "" {
		say("log", "cannot sign in from here: "+why)
		say("log", "  in a terminal:  sudo tailscale up")
		return false
	}
	if !l.Runner.Has("tailscale") {
		say("fail", "Tailscale is not installed")
		return false
	}
	if l.Runner.Has("systemctl") {
		if _, err := l.Runner.Output(ctx, "systemctl", "is-active", "--quiet", "tailscaled"); err != nil {
			say("log", "starting tailscaled")
			// Relayed like everything else: this is the FIRST thing that asks
			// polkit, so it is where a missing agent shows up.
			_ = l.RootRun(ctx, as, say, "systemctl", "enable", "--now", "tailscaled")
			if _, err := l.Runner.Output(ctx, "systemctl", "is-active", "--quiet", "tailscaled"); err != nil {
				say("fail", "could not start tailscaled")
				say("log", "  from a terminal:  sudo systemctl enable --now tailscaled && sudo tailscale up")
				return false
			}
		}
	}
	say("log", "finishing the sign-in needs a browser - the link appears below")
	_ = l.RootRun(ctx, as, say, "tailscale", "up")
	// Decided by asking tailscale, not by an exit code: the command can print a
	// link and be cancelled, and it can succeed with nothing to show.
	if l.TailscaleDown(ctx) {
		say("fail", "still not signed in")
		say("log", "  or sign in from a terminal:  sudo tailscale up")
		return false
	}
	say("ok", "signed in")
	return true
}
