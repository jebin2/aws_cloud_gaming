package watcher

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/commands/status"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

var numeric = regexp.MustCompile(`^[0-9.]+$`)

// Render is the guards report. Rows say what they mean rather than having it
// read from their words: a row saying something was NOT enabled contained
// "enabled", and got a tick.
func (w *Watcher) Render(f Facts, out *output.Out) {
	out.Say("guards")
	kind := "info"
	if f.State == "running" {
		kind = "ok"
	}
	out.LogAs(kind, "instance          "+f.State)
	if f.Stranded != nil {
		for _, l := range strings.Split(strings.TrimRight(status.StrandedLines(f.Stranded, w.Rates), "\n"), "\n") {
			out.Echo(l)
		}
	}
	if f.Reachable {
		k := "warn"
		if f.OnHost == "active" {
			k = "ok"
		}
		shown := f.OnHost
		if shown == "" {
			shown = "unreachable"
		}
		out.LogAs(k, "on-host watchdog  "+shown)
		// What it MUST be depends on the purchase model, so say which. The hint
		// used to read "must be 'stop'" unconditionally, which became wrong the
		// moment spot switched to one-time+terminate - a correct setting
		// flagged as an error, next to a guard people read to check it.
		k, verdict := "fail", "(WRONG)"
		if f.Shutdown == f.Want {
			k, verdict = "ok", "(ok)"
		}
		out.LogAs(k, fmt.Sprintf("shutdown action   %s  <- must be '%s' %s", f.Shutdown, f.Want, verdict))
		out.Gap()
		out.Relay(strings.NewReader(f.Journal), "      ")
	} else {
		out.LogAs("info", "on-host watchdog  (box not reachable)")
	}
	// Layer 3, the guard that keeps working when the box is gone.
	out.Gap()
	for _, row := range watchdog.RowsFor(f.Layer3, w.Reader.Host, w.Reader.Now()) {
		if row[0] == "" {
			out.Log(row[1])
		} else {
			out.LogAs(row[0], row[1])
		}
	}
	out.Gap()
	bud := "absent"
	if f.BudgetKnown {
		bud = f.Budget
	}
	k := "warn"
	if numeric.MatchString(bud) {
		k = "ok"
	}
	out.LogAs(k, "budget            "+bud)
}
