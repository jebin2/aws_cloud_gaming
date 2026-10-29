package boxcmd

import (
	"context"
	"fmt"
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

// Stop is `cg stop [--force]`.
//
// Stopping wipes the instance store, exactly like destroying does, so it gets the
// same gate. The push is here and in destroy and nowhere else: there is no timer
// and no pre-shutdown hook, so if this does not run, the games are gone. Which is
// why a failure stops the stop rather than printing a note next to it.
func (d Deps) Stop(ctx context.Context, args []string) int {
	for _, a := range args {
		if a != "--force" {
			return d.die(fmt.Sprintf("unknown option '%s' for stop (only --force is accepted)", a))
		}
		d.Force = true
	}
	d.steamShutdown(ctx)
	return d.endSession(ctx)
}

// endSession is how `cg stop` ends a session.
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
	if d.Ask.Confirm("stop-box", "stop instance now? [Y/n] ", "Y") {
		return d.down(ctx)
	}
	return 0
}

// down stops the box after mirroring the library. The mirror is written HERE, in
// the one function every stop path goes through: `cg stop`, the "stop instance
// now?" prompt at the end of `cg open`, and the pre-image stop in destroy.
func (d Deps) down(ctx context.Context) int {
	if s, _ := d.Box.State(ctx); s == "stopped" {
		d.Out.Echo("already stopped")
		return 0
	}
	if !d.Push(ctx, "", "box is not reachable over the tailnet - cannot mirror the library", "mirroring the game library to S3 (the instance store is wiped on stop)") {
		if !d.Force {
			d.block("The push from here failed",
				"",
				"  The push from here failed - usually ssh cannot reach the box.",
				"  cg-library-shutdown.service mirrors from ON the box as it shuts",
				"  down and needs no ssh, so --force is usually safe. Check after:",
				"      cg library list",
				"")
			return d.die("not mirrored from here - see above, then: cg stop --force")
		}
		d.Out.Log("WARNING: stopping without a mirror (--force) - games will be re-downloaded")
	}
	if err := d.Box.Stop(ctx); err != nil {
		return d.die(err.Error())
	}
	if !d.Box.WaitState(ctx, "stopped", 600*time.Second) {
		return d.die("the box was asked to stop but is not confirmed stopped - it may still be billing; check: cg status")
	}
	d.Out.Log("billing has ended")
	return 0
}
