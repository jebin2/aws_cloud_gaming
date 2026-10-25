// Package watchdog is `cg watchdog` and the guard rows of `cg watcher` that
// come from layer 3, the cloud watchdog: the Lambda that keeps working when the
// box and this laptop are both gone.
package watchdog

import (
	"context"
	"fmt"
	"strings"
	"time"

	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

// Status is `cg watchdog status`: is it installed, is the schedule on, what
// does the archive countdown say, and what did it last decide.
func Status(ctx context.Context, r *wd.Reader, expiryDays int) string {
	st := r.Current(ctx)
	var b strings.Builder
	if st.Installed {
		fmt.Fprintf(&b, "  function  %s  %s %s\n", wd.Name(r.Host), st.FnState, st.FnRuntime)
	} else {
		b.WriteString("  function  not installed - cg init creates it\n")
	}
	if st.Rule != "" {
		fmt.Fprintf(&b, "  schedule  every %d minutes, %s\n", wd.EveryMin, st.Rule)
	} else {
		b.WriteString("  schedule  none\n")
	}
	fmt.Fprintf(&b, "  can end   only the instance tagged %s\n", r.Host)
	fmt.Fprintf(&b, "  archive   %s\n", ArchiveText(st, expiryDays, r.Now()))
	b.WriteString("  recent decisions:\n")
	switch {
	case len(st.Recent) > 0:
		for _, e := range st.Recent {
			fmt.Fprintf(&b, "    %s %s\n", time.UnixMilli(e.MS).Local().Format("2006-01-02 15:04:05"), strings.TrimPrefix(e.Msg, "cg-watchdog: "))
		}
	case st.LogUnknown:
		b.WriteString("    (the log could not be read)\n")
	default:
		b.WriteString("    (none in the last hour)\n")
	}
	return b.String()
}

// ArchiveText is one line: off, the latest decision and its age, or not
// checked yet.
func ArchiveText(st wd.State, days int, now time.Time) string {
	switch {
	case days == 0:
		return "kept forever (GAME_ARCHIVE_EXPIRY_DAYS=0)"
	case st.ArchiveMS > 0:
		return fmt.Sprintf("%s  (checked %s ago)", st.ArchiveMsg, wd.Age(st.ArchiveMS, now))
	}
	return fmt.Sprintf("deleted after %d days with no box - not checked yet (hourly)", days)
}

// WatcherLines are layer 3's rows in `cg watcher`: is the schedule firing, and
// what did it last decide. Each is (kind, text).
func WatcherLines(ctx context.Context, r *wd.Reader) [][2]string {
	return RowsFor(r.Current(ctx), r.Host, r.Now())
}

// RowsFor is the same rows from a state already read.
func RowsFor(st wd.State, host string, now time.Time) [][2]string {
	rule := st.Rule
	kind := "warn"
	if rule == "ENABLED" {
		kind = "ok"
	}
	shown := rule
	if shown == "" {
		shown = "not installed"
	}
	lines := [][2]string{{kind, fmt.Sprintf("cloud watchdog    %s  (Lambda %s, every %d min)", shown, wd.Name(host), wd.EveryMin)}}
	switch {
	case st.LastMS > 0:
		lines = append(lines, [2]string{"", fmt.Sprintf("  last            %s ago: %s", wd.Age(st.LastMS, now), st.LastMsg)})
		if m := st.LastMsg; strings.Contains(m, "CANNOT QUERY AWS") || strings.Contains(m, "DENIED") || strings.Contains(m, "FAILED") {
			lines = append(lines, [2]string{"fail", "  ^ it cannot act on your account, so layer 3 is decoration"})
		}
	case st.LogUnknown:
		lines = append(lines, [2]string{"warn", "  ^ the watchdog's log could not be read"})
	case rule == "ENABLED":
		lines = append(lines, [2]string{"warn", fmt.Sprintf("  ^ nothing logged in the last hour, but it runs every %d min", wd.EveryMin)})
	}
	return lines
}
