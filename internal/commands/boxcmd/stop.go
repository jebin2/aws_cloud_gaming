package boxcmd

import (
	"bytes"
	"context"
	"regexp"

	"fmt"
	ayis "github.com/jebin2/ayis"
	"strings"
	"time"
)

// steamShutdown closes Steam so cloud saves finish syncing. Save games live
// inside the Proton prefix, in the Steam library on /scratch - so they survive a
// stop only by way of the S3 mirror, which runs after this. Steam Cloud is the
// independent copy, and Cloud only syncs when Steam shuts down cleanly, so ask it
// to exit and give it time before stopping the box.
func (d Deps) steamShutdown(ctx context.Context) {
	if _, ok := d.Box.IP(ctx); !ok {
		return
	}
	if _, err := d.Box.SSH(ctx, "pgrep -x steam >/dev/null", nil); err != nil {
		return
	}
	d.Out.Say("closing Steam so cloud saves finish syncing")
	// `steam -shutdown` is the supported way to ask it to exit and sync; a plain
	// kill skips the sync entirely.
	out, _ := d.Box.SSH(ctx, `
    export DISPLAY=:0 XAUTHORITY="$HOME/.Xauthority"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    /usr/bin/steam -shutdown >/dev/null 2>&1 || true
    for i in $(seq 1 30); do pgrep -x steam >/dev/null || break; sleep 2; done
    pgrep -x steam >/dev/null && echo "still running after 60s" || echo "closed"
  `, nil)
	for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if l != "" {
			d.Out.Echo("      steam: " + l)
		}
	}
}

// Stop is `ayis stop [--force]`.
//
// Stopping wipes the instance store, exactly like destroying does, so it gets the
// same gate. The push is here and in destroy and nowhere else: there is no timer
// and no pre-shutdown hook, so if this does not run, the games are gone. Which is
// why a failure stops the stop rather than printing a note next to it.
func (d Deps) Stop(ctx context.Context, args []string) int {
	for i := 0; i < len(args); i++ {
		switch a := args[i]; a {
		case "--force":
			d.Force = true
		case "--yes":
			d.Sure = true
		case "--skip":
			if i+1 >= len(args) || !appids.MatchString(args[i+1]) {
				return d.die("--skip takes the appids not to save, comma-separated: --skip 730,1057090")
			}
			i++
			d.Skip = args[i]
		default:
			return d.die(fmt.Sprintf("unknown option '%s' for stop (only --force, --yes and --skip are accepted)", a))
		}
	}
	d.steamShutdown(ctx)
	return d.endSession(ctx)
}

// endSession is how `ayis stop` ends a session.
//
// On spot there is no stop worth offering. A one-time request cannot be stopped
// at all (AWS only allows it for persistent requests), and a persistent one that
// is stopped becomes permanently unstartable while its root volume keeps billing.
// Either way the answer is destroy, and that is free of consequence now that the
// games are mirrored to S3.
func (d Deps) endSession(ctx context.Context) int {
	if d.Box.Lifecycle(ctx) == "spot" {
		d.block("Nothing to stop on a spot box",
			"",
			"This is a SPOT instance, so there is nothing useful to stop:",
			"  - a one-time spot instance cannot be stopped at all",
			"  - stopping a persistent one disables its request, and it can then",
			"    NEVER start again while its root volume keeps billing",
			"",
			"Your games are mirrored to S3, so destroying costs a rebuild ("+d.Takes()+")",
			"and nothing else.")
		a := d.Ask.Ask("session-end", "[d] destroy (recommended)  [n] leave it running: ", "d", "d,n")
		switch a {
		case "d", "D", "":
			if d.Destroy == nil {
				return d.die("destroy is not available")
			}
			return d.Destroy(ctx)
		}
		d.Out.Echo("left running - it is STILL BILLING by the hour")
		return 0
	}
	if d.Sure || d.Ask.Confirm("stop-box", "stop instance now? [Y/n] ", "Y") {
		return d.down(ctx)
	}
	return 0
}

// down stops the box after mirroring the library. The mirror is written HERE, in
// the one function every stop path goes through: `ayis stop`, the "stop instance
// now?" prompt at the end of `ayis open`, and the pre-image stop in destroy.
func (d Deps) down(ctx context.Context) int {
	if s, _ := d.Box.State(ctx); s == "stopped" {
		d.Out.Echo("already stopped")
		return 0
	}
	if code := d.leaveOut(ctx); code != 0 {
		return code
	}
	if !d.Push(ctx, "", "box is not reachable over the tailnet - cannot mirror the library", d.saveWords()) {
		if !d.Force {
			d.block("The push from here failed",
				"",
				"  The push from here failed - usually ssh cannot reach the box.",
				"  ayis-library-shutdown.service mirrors from ON the box as it shuts",
				"  down and needs no ssh, so --force is usually safe. Check after:",
				"      ayis library list",
				"")
			return d.die("not mirrored from here - see above, then: ayis stop --force")
		}
		d.Out.Log("WARNING: stopping without a mirror (--force) - games will be re-downloaded")
	}
	// The save is over; what is left is AWS stopping the machine, a minute or more
	// during which the last thing on screen used to be the save.
	d.Out.Say("Stopping the machine at AWS (billing ends once it has stopped)")
	if err := d.Box.Stop(ctx); err != nil {
		return d.die(err.Error())
	}
	// AWS stops it only once the machine has shut down - and on the way down it
	// saves the games once more itself. A wait of minutes said nothing; what the
	// machine prints meanwhile is in its console, which AWS keeps.
	quiet := d.watchConsole(ctx)
	stopped := d.Box.WaitState(ctx, "stopped", 600*time.Second)
	quiet()
	if !stopped {
		return d.die("the box was asked to stop but is not confirmed stopped - it may still be billing; check: ayis status")
	}
	d.Out.Log("billing has ended")
	return 0
}

var appids = regexp.MustCompile(`^[0-9]+(,[0-9]+)*$`)

// leaveOut tells the machine which games not to save on this boot: the saving
// script as this ayis knows it (a machine built earlier has one that cannot skip),
// then the list, marked with the boot it is for. Both the save from here and the
// one the machine makes on its way down read it. If either cannot be written the
// stop does not go ahead: the games would be saved after all, and a game just
// deleted from Saved games would be put straight back.
func (d Deps) leaveOut(ctx context.Context) int {
	// The script goes on every time, games unticked or not: it is also what lets
	// the save on the way down stand on this one rather than check every file again.
	if d.Skip != "" {
		d.Out.Say("Leaving out the games you unticked")
	}
	script, err := ayis.Files.ReadFile("host/ayis-library")
	if err != nil {
		return d.die("the saving script is missing from this ayis: " + err.Error())
	}
	if _, err := d.Box.SSH(ctx, "sudo tee "+ayisLibrary+" >/dev/null && sudo chmod 755 "+ayisLibrary, bytes.NewReader(script)); err != nil {
		// With games to leave out, the old script would save them anyway: stop here.
		// Without, the old one saves everything as it always did - only slower.
		if d.Skip == "" {
			d.Out.Log("  the saving script on the machine was not updated; it saves as before: " + firstErrorLine(err.Error()))
			return 0
		}
		d.said(err)
		return d.die("could not update the saving script on the machine - nothing was stopped")
	}
	if d.Skip == "" {
		return 0
	}
	if _, err := d.Box.SSH(ctx, "printf '%s %s\\n' \"$(cat /proc/sys/kernel/random/boot_id)\" "+quote(d.Skip)+" > /var/lib/ayis-library/skip", nil); err != nil {
		d.said(err)
		return d.die("could not tell the machine which games to leave out - nothing was stopped")
	}
	return 0
}

// saveWords is what the save before a stop or a delete is called on screen. With
// games unticked it still runs: it saves the Steam login (so the next machine is
// signed in) and whatever games were kept - possibly none.
func (d Deps) saveWords() string {
	if d.Skip != "" {
		return "Saving your Steam login and the games you kept to Saved games"
	}
	return "Saving your games and Steam login to Saved games"
}

// watchConsole logs, every 20 s or so until the returned function is called, the
// machine's newest console lines not logged before - for a screen that would
// otherwise show only "stopping" for minutes. Events only: a terminal has
// WaitState's own lines.
func (d Deps) watchConsole(ctx context.Context) func() {
	if !d.Out.JSON {
		return func() {}
	}
	wctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		seen := map[string]bool{}
		for {
			select {
			case <-wctx.Done():
				return
			case <-time.After(20 * time.Second):
			}
			for _, l := range d.consoleLines(wctx, 3) {
				if !seen[l] {
					seen[l] = true
					d.Out.Log("  machine: " + l)
				}
			}
		}
	}()
	return func() { cancel(); <-done }
}
