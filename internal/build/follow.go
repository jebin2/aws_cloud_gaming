// Package build is the second half of every build, whatever the machine is: an
// AWS box cg just launched, or a machine of your own. From "it is building itself"
// to "ready to play" - one path, so both say the same things in the same order and
// fail the same way.
package build

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// Remote runs a command on the machine under sh.
type Remote interface {
	SSH(ctx context.Context, command string) ([]byte, error)
}

// ErrStopped: the build did not finish, and has said why.
var ErrStopped = errors.New("the build did not finish")

// Aborted: is the build over, and not well? A machine of yours says it outright:
// the build script ended, and not well. No reboot follows there and no FAILED line
// is owed - set -e stops a build without printing one - so "exited" alone is the
// end. state is "<cloud-init status>|<reached-finish>".
func Aborted(failedSeen bool, state string) bool {
	ci, finished, _ := strings.Cut(state, "|")
	if ci == "exited" {
		return true
	}
	if !failedSeen {
		return false
	}
	return state != "" && ci == "error" && finished == "no"
}

// stateCmd is the one ssh probe that answers Aborted's second argument. The
// build's own result file first (the header module writes it on exit, and setup
// deletes it before a run, so one there is this run's): it is the script's own
// word. cloud-init only when there is none - a machine of yours may have
// cloud-init too, and its "done" or "disabled" is about that machine's own
// install, not this build: read first, it hid every failed setup there until the
// 40-minute timeout.
const stateCmd = `s="";
if [ -f /var/lib/cloud-gaming-bootstrap.rc ]; then
  [ "$(cat /var/lib/cloud-gaming-bootstrap.rc)" = 0 ] && s=done || s=exited;
else s=$(cloud-init status 2>/dev/null | head -1); s=${s#status: }; fi;
grep -q "bootstrap complete" /var/log/cloud-gaming-bootstrap.log 2>/dev/null && f=yes || f=no;
printf "%s|%s\n" "${s:-unknown}" "$f"`

var (
	interesting = regexp.MustCompile(`^>>> |^E: |^ERROR|[Ee]rror:|[Ff]ailed to |command not found|curl: \([0-9]+\)|No such file`)
	noise       = regexp.MustCompile(`Setting up|Unpacking|Preparing to unpack|Selecting previously|^Get:|^info:|^ls: |usbmux|/nonexistent|NetworkManager`)
)

// Follower reads the build's log as it grows.
type Follower struct {
	R     Remote
	Log   func(string)
	Sleep func(time.Duration)
	// Target and Key are only for the lines that tell a person how to look.
	Target, Key string
	Timeout     time.Duration // 40 minutes by default
}

func (f Follower) stoppedLines(ctx context.Context, last string) {
	if last != "" {
		f.Log("the build STOPPED here: " + last)
	} else {
		f.Log("the build STOPPED before it finished - the end of its log:")
	}
	if out, err := f.R.SSH(ctx, "tail -n 8 /var/log/cloud-gaming-bootstrap.log"); err == nil {
		for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
			if l != "" {
				f.Log("    " + l)
			}
		}
	}
	f.Log("  nothing after that step ran.")
	f.Log("  ssh " + f.ssh())
	f.Log("  sudo tail -50 /var/log/cloud-gaming-bootstrap.log")
}

func (f Follower) ssh() string {
	if f.Key != "" {
		return "-i " + f.Key + " " + f.Target
	}
	return f.Target
}

// Stream prints the build's progress until it is ready, or has stopped.
func (f Follower) Stream(ctx context.Context) error {
	timeout := f.Timeout
	if timeout == 0 {
		timeout = 2400 * time.Second
	}
	seen, rebooted, failedSeen, last := 0, false, false, ""
	for waited := time.Duration(0); waited < timeout; waited += 10 * time.Second {
		out, err := f.R.SSH(ctx, fmt.Sprintf("tail -n +%d /var/log/cloud-gaming-bootstrap.log 2>/dev/null", seen+1))
		switch {
		case err == nil:
			if news := strings.TrimRight(string(out), "\n"); news != "" {
				seen += strings.Count(news, "\n") + 1
				// Only the progress markers and anything that looks like a
				// failure - `set -x` traces thousands of lines that are useless to
				// watch. Anchored and punctuated deliberately: a bare /error/
				// matches package names like libgpg-error0 and floods the output
				// with routine apt lines.
				for _, line := range strings.Split(news, "\n") {
					if !interesting.MatchString(line) || noise.MatchString(line) {
						continue
					}
					switch {
					case strings.HasPrefix(line, ">>> FAILED: "):
						last = strings.TrimPrefix(line, ">>> FAILED: ")
						f.Log("FAILED: " + last)
						failedSeen = true
					case strings.HasPrefix(line, ">>> ok: "):
						f.Log("  ok  " + strings.TrimPrefix(line, ">>> ok: "))
					case strings.HasPrefix(line, ">>> "):
						f.Log(strings.TrimPrefix(line, ">>> "))
					default:
						f.Log("! " + line)
					}
				}
			}
			if _, err := f.R.SSH(ctx, "test -f /var/lib/cloud-gaming-ready"); err == nil {
				f.Log(fmt.Sprintf("build complete after %dm", int(waited/time.Minute)))
				return nil
			}
			// Asked at once when a FAILED has been seen, and once a minute
			// otherwise: set -e ends a build without a FAILED line, and a machine
			// of yours then says so in its result file - not a 40-minute wait.
			if failedSeen || int(waited/time.Second)%60 == 0 {
				state, _ := f.R.SSH(ctx, stateCmd)
				if Aborted(failedSeen, strings.TrimSpace(string(state))) {
					f.stoppedLines(ctx, last)
					return ErrStopped
				}
			}
		case strings.Contains(local.Stderr(err), "HOST IDENTIFICATION HAS CHANGED") || strings.Contains(local.Stderr(err), "Host key verification failed"):
			// Distinguish "cannot connect" from "refused to connect". Reporting a
			// reboot here was actively misleading: the box was building fine and
			// only our view of it was broken, which is the hardest kind of failure
			// to see.
			f.Log("ssh refused: the host key for this name changed")
			f.Log("  a rebuilt box reclaims the hostname, so the old key is stale:")
			host := f.Target
			if _, h, ok := strings.Cut(host, "@"); ok {
				host = h
			}
			f.Log("    ssh-keygen -R " + host)
			return ErrStopped
		case !rebooted && waited > 300*time.Second:
			// Only call it a reboot once the box has been reachable for a while -
			// ssh refusing in the first minutes is just sshd not up yet. Do NOT
			// reset `seen`: the log is a file that survives the reboot, so
			// starting over replays every line already printed.
			f.Log("host rebooting - reconnecting")
			rebooted = true
		}
		f.Sleep(10 * time.Second)
	}
	f.Log(fmt.Sprintf("TIMEOUT after %dm. Check on the box:", int(timeout/time.Minute)))
	f.Log("  ssh " + f.ssh())
	f.Log("  sudo tail -50 /var/log/cloud-gaming-bootstrap.log")
	return ErrStopped
}

// WaitSteam waits for the prewarm service, which runs after graphical.target and
// downloads ~500 MB, so it is still going long after setup would otherwise
// finish. Waiting means the completion message can tell the truth about whether
// Steam is ready.
func (f Follower) WaitSteam(ctx context.Context, timeout time.Duration) bool {
	last, beat := "", time.Duration(0)
	for waited := time.Duration(0); waited < timeout; waited += 15 * time.Second {
		if _, err := f.R.SSH(ctx, "test -f ~/.steam-prewarmed"); err == nil {
			f.Log(fmt.Sprintf("steam ready after %dm", int(waited/time.Minute)))
			return true
		}
		// Report the phase, not just the size: after the download the client stops
		// growing while library adoption and the dock pin still run, which read as
		// a stall if all you print is an unchanging number. '|'-separated, not
		// space: phase names contain spaces. Size follows symlinks and covers both
		// client layouts.
		out, err := f.R.SSH(ctx, `printf "%s|%s\n" "$(cat ~/.steam-phase 2>/dev/null || echo working)" "$(du -shcL ~/.steam ~/.local/share/Steam 2>/dev/null | tail -1 | cut -f1)"`)
		phase, size := "working", ""
		if err == nil {
			p, s, _ := strings.Cut(strings.TrimSpace(string(out)), "|")
			if p != "" {
				phase = p
			}
			size = s
		}
		cur := phase + " " + size
		switch {
		case cur != last:
			if size != "" {
				f.Log(fmt.Sprintf("%s (%s)", phase, size))
			} else {
				f.Log(phase)
			}
			last, beat = cur, waited
		case waited-beat >= 60*time.Second:
			f.Log(fmt.Sprintf("%s (%ds)", phase, int(waited/time.Second)))
			beat = waited
		}
		f.Sleep(15 * time.Second)
	}
	f.Log(fmt.Sprintf("steam did not finish within %dm - check ~/steam-prewarm.log on the box", int(timeout/time.Minute)))
	return false
}
