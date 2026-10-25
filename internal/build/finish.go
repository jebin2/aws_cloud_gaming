package build

import (
	"context"
	"fmt"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
)

// Finisher is the second half of a build, for any target. The target supplies
// how to reach the machine, where it keeps the Sunshine login, and two optional
// hooks.
type Finisher struct {
	Follow Follower
	Sun    sunshine.Client
	Pair   sunshine.Pairer
	Run    local.Runner
	// Login is the Sunshine login; Save keeps it (.env for the AWS box,
	// hosts.json for yours).
	Login *sunshine.Login
	Save  sunshine.Keeper
	Name  string // how to name it in what is said: "the box", "homeserver"
	Takes string // "the last one took 12 min", or "it takes a while"
	IP    string // its tailnet address, if already known
	// AfterStream runs once the machine reports it is built, and returns its
	// tailnet address.
	AfterStream func(ctx context.Context) (string, error)
	// SteamReport runs once Steam has installed and may change the message.
	SteamReport func(msg *string)

	Say          func(string)
	Log          func(string)
	Sleep        func(time.Duration)
	SteamWait    time.Duration // 25 minutes by default
	WelcomeTries int           // 40 by default
	HasMoonlight bool

	// What it leaves for the summary.
	Paired   bool
	SteamOK  bool
	SteamMsg string
}

// Finish runs from "it is building itself" to "ready to play". It returns
// ErrStopped when the build itself did not finish - what to say about a machine
// left running is the target's business.
func (f *Finisher) Finish(ctx context.Context) error {
	f.Say(fmt.Sprintf("building %s - live progress below (%s)", f.Name, f.Takes))
	if err := f.Follow.Stream(ctx); err != nil {
		return err
	}
	if f.AfterStream != nil {
		ip, err := f.AfterStream(ctx)
		if err != nil {
			return err
		}
		f.IP = ip
	}

	// Neutral heading: this block may create an account or find one already
	// there, and announcing "creating" before knowing which is how a rerun came to
	// look like it was regenerating credentials every time.
	f.Say("Sunshine account")
	tries := f.WelcomeTries
	if tries == 0 {
		tries = 40
	}
	up, first := f.Sun.Wait(ctx, f.IP, tries, f.Sleep)
	if !up {
		f.Log(fmt.Sprintf("Sunshine is not answering on %s:%s - skipping account and pairing", f.IP, sunshine.Port))
		f.Log("check on the box: systemctl --user status app-dev.lizardbyte.app.Sunshine.service")
	} else {
		// The login: saved here first, checked against the box, set again on the
		// box when they disagree.
		e := &sunshine.Ensure{C: f.Sun, IP: f.IP, Login: f.Login, Save: f.Save, Say: f.Log, Sleep: f.Sleep,
			OnMachine: func(ctx context.Context, cmd string) error { _, err := f.Follow.R.SSH(ctx, cmd); return err }}
		e.Run(ctx, first)
	}

	f.Say("moonlight pairing")
	f.Paired = false
	switch {
	case f.HasMoonlight && f.listsPaired(ctx):
		f.Log("already paired")
		f.Paired = true
	case f.HasMoonlight && f.Login.User != "" && f.Login.Pass != "":
		// Once more before giving up. A pairing that does not stick is REPORTED as
		// a failure instead of printed as "paired", so a retry is worth the seconds.
		if f.Pair.Pair(ctx, f.IP, f.Login.User, f.Login.Pass) {
			f.Paired = true
		} else {
			f.Log("pairing did not stick - trying once more")
			f.Paired = f.Pair.Pair(ctx, f.IP, f.Login.User, f.Login.Pass)
		}
		if f.Paired {
			f.Log("paired")
		} else {
			f.Log("automatic pairing failed - pair by hand, see below")
		}
	default:
		f.Log("skipped (moonlight or credentials missing) - pair by hand, see below")
	}

	f.Say("waiting for Steam to finish installing")
	f.SteamOK, f.SteamMsg = false, "still installing - check ~/steam-prewarm.log on the box."
	wait := f.SteamWait
	if wait == 0 {
		wait = 1500 * time.Second
	}
	if f.Follow.WaitSteam(ctx, wait) {
		f.SteamOK, f.SteamMsg = true, "installed. Sign in and it is ready."
		if f.SteamReport != nil {
			f.SteamReport(&f.SteamMsg)
		}
	}
	return nil
}

func (f *Finisher) listsPaired(ctx context.Context) bool {
	c, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	out, _ := f.Run.Run(c, local.Cmd{Name: "moonlight", Args: []string{"list", f.IP}})
	return len(out) > 0 && len(trim(out)) > 0
}

func trim(b []byte) string {
	s := string(b)
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == ' ') {
		s = s[:len(s)-1]
	}
	return s
}
