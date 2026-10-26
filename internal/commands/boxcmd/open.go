package boxcmd

import (
	"context"
	"fmt"
	"net"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/format"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
)

// waitFor waits for something to come up, a dot per try.
func (d Deps) waitFor(desc string, tries int, ok func() bool) bool {
	fmt.Fprint(d.Out.Stdout, desc)
	for i := 0; i < tries; i++ {
		if ok() {
			fmt.Fprint(d.Out.Stdout, " ok\n")
			return true
		}
		fmt.Fprint(d.Out.Stdout, ".")
		d.sleep(2 * time.Second)
	}
	fmt.Fprint(d.Out.Stdout, " TIMEOUT\n")
	return false
}

var firstError = regexp.MustCompile(`(?i)error`)

func firstErrorLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for _, l := range lines {
		if firstError.MatchString(l) {
			return l
		}
	}
	return lines[len(lines)-1]
}

// MoonlightSyskeys: Alt+Tab, Super and friends are swallowed by the *client*
// desktop unless Moonlight is told to capture them, and nothing about the remote
// box can change that - so set it here, once. Only ever ADDS the key when absent:
// someone who deliberately set it to 0 keeps that. And never while Moonlight runs
// - it does not re-read its config, and it rewrites the file on exit, discarding
// anything changed underneath it.
func (d Deps) moonlightSyskeys(ctx context.Context) {
	b, err := os.ReadFile(d.MoonlightConf)
	if err != nil {
		return
	}
	if out, err := d.R.Run(ctx, local.Cmd{Name: "pgrep", Args: []string{"-x", "moonlight"}}); err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return
	}
	s := string(b)
	if regexp.MustCompile(`(?m)^capturesyskeys=`).MatchString(s) {
		return
	}
	if i := strings.Index(s, "[General]"); i >= 0 && (i == 0 || s[i-1] == '\n') {
		s = s[:i] + "[General]\ncapturesyskeys=2" + s[i+len("[General]"):]
		if os.WriteFile(d.MoonlightConf, []byte(s), 0o644) == nil {
			d.Out.Log("enabled Moonlight system-key capture (Alt+Tab, Super)")
		}
	}
}

// Open is `cg open`: start the box if it is stopped, wait for it, stream.
func (d Deps) Open(ctx context.Context) int {
	d.moonlightSyskeys(ctx)
	// A stream from this laptop is already running: a second Moonlight window
	// would fight the first for the box's GPU and spend egress twice, and both
	// `cg open` runs would try to end the session afterwards. Refuse, and say
	// where the first one is.
	if l, held := session.Running(d.SessionFile, d.Probe); held {
		age := ""
		if a, ok := l.Age(d.Now()); ok {
			age = " (started " + format.Duration(int64(a/time.Second)) + " ago)"
		}
		d.block("Already streaming",
			"",
			"A stream from this laptop is already running"+age+".",
			"",
			"  Moonlight is happy to open a second window; the box is not. Two",
			"  streams share one GPU, both spend egress, and whichever ends first",
			"  ends the session for the other.",
			"",
			"  Look for the Moonlight window that is already open. To stop it from",
			"  here instead:",
			"",
			fmt.Sprintf("      kill %d", l.PID),
			"")
		return d.die(fmt.Sprintf("a session is already running (pid %d)", l.PID))
	}
	session.Claim(d.SessionFile, d.Now())
	defer session.Release(d.SessionFile)

	// The state, or why it could not be read. A machine already deleted - by
	// auto-stop once it sat idle, by AWS taking a spot one back - used to be
	// "started" anyway: AWS refused, its words went to stderr, and the session
	// ended with nothing said at all.
	st, err := d.Box.State(ctx)
	if err != nil {
		e := err.Error()
		if strings.Contains(e, "InvalidInstanceID.NotFound") || strings.Contains(e, "InvalidInstanceID.Malformed") {
			return d.die("there is no machine to start - it was deleted, most likely by auto-stop after it sat idle or by AWS taking back a spot machine. Build a new one: cg init")
		}
		return d.die("could not read the machine from AWS: " + firstErrorLine(e))
	}
	if st == "terminated" || st == "shutting-down" {
		return d.die("there is no machine to start - it was deleted, most likely by auto-stop after it sat idle or by AWS taking back a spot machine. Build a new one: cg init")
	}
	if st == "running" {
		d.Out.Echo("instance already running")
	} else {
		// Checked BEFORE calling start, so the explanation replaces the API error
		// rather than following it.
		if d.Box.Lifecycle(ctx) == "spot" {
			if _, srs := d.Box.SpotRequest(ctx); srs != "active" {
				d.block("This box cannot be started again",
					"",
					"This box cannot be started again.",
					"",
					"  It is a SPOT instance and its spot request is '"+srs+"'. Stopping a spot",
					"  instance yourself disables its request, and AWS refuses to start an",
					"  instance whose request is not active. There is no way to re-enable it.",
					"",
					"  Meanwhile the stopped box still bills for its root volume.",
					"",
					"  Your games are in S3, so throwing this box away costs nothing:",
					"",
					"      cg destroy && cg init          # rebuild ("+d.Takes()+"), games restored",
					"",
					"  To get stop/start back, build on demand instead - dearer per hour,",
					"  but it can be stopped and restarted as often as you like:",
					"",
					"      cg destroy && GAME_SPOT=0 cg init",
					"")
				return d.die(fmt.Sprintf("spot request is '%s'", srs))
			}
		}
		d.Out.Echo("starting " + d.Box.ID + " ...")
		if err := d.Box.Start(ctx); err != nil {
			return d.die("AWS would not start the machine: " + firstErrorLine(err.Error()))
		}
		d.Box.WaitState(ctx, "running", 600*time.Second)
	}

	node := d.Box.Node
	d.waitFor("waiting for tailscale", 60, func() bool {
		_, err := d.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"ping", "-c", "1", "--timeout", "2s", node}})
		return err == nil
	})

	// Confirm the path is direct. A relayed path adds tens of ms.
	out, _ := d.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"ping", "-c", "1", node}})
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	path := lines[len(lines)-1]
	d.Out.Echo("  " + path)
	if strings.Contains(path, "relay") || strings.Contains(path, "DERP") {
		d.Out.Echo("  WARNING: relayed, not direct - latency will suffer")
	}

	ip, _ := d.Box.IP(ctx)
	if !d.waitFor("waiting for sunshine", 60, func() bool {
		addr := net.JoinHostPort(ip, "47989")
		if d.Dial != nil {
			return d.Dial(addr, 2*time.Second) == nil
		}
		c, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil {
			c.Close()
		}
		return err == nil
	}) {
		// Two minutes of dots and then `exit 1`, for a box that could never work:
		// if user-data aborted, there is no sunshine on it AT ALL, and no amount
		// of waiting will open that port. Ask the box which it is before giving up.
		d.noSunshine(ctx, ip)
		return d.die(fmt.Sprintf("sunshine never answered on %s:47989", ip))
	}

	d.Out.Echo("disk:")
	d.Out.Echo(d.disks(ctx))

	// The stream itself is every machine's; starting the AWS box, above, is this
	// file's.
	app := d.Env.Get("GAME_APP")
	d.Player.Play(ctx, ip, app)

	// Closing Moonlight ends the session and nothing else. The machine is kept for
	// the next session; auto-stop ends it once it sits idle, and it can be deleted
	// now from the app or with cg destroy.
	d.Out.Echo("session ended - the machine is still running and billing until auto-stop ends it when idle, or delete it now: cg destroy")
	return 0
}

// disks: root cannot be shrunk once grown, so its usage is the number worth
// watching; /scratch is local NVMe and holds the games, and is wiped on every stop
// - the S3 mirror is what makes that survivable (cg library).
func (d Deps) disks(ctx context.Context) string {
	out, err := d.Box.SSH(ctx, `df -h --output=target,used,size,pcent / /scratch 2>/dev/null | sed "s/^/  /"`, nil)
	if err != nil {
		return "  (host unreachable - box stopped?)"
	}
	return strings.TrimRight(string(out), "\n")
}

// noSunshine: Sunshine never answered. The useful question is not "is it slow"
// but "was it ever installed", because a build that aborted leaves a box that is
// reachable, pingable, has an address and a tailnet name - and no streaming stack
// whatever. It speaks only when it is certain the build never finished, so the
// caller still reports the plain timeout for every other cause.
func (d Deps) noSunshine(ctx context.Context, ip string) bool {
	out, err := d.Box.SSH(ctx, `test -x /usr/bin/sunshine && echo sunshine=yes || echo sunshine=no
              test -f /var/lib/cloud-gaming-ready && echo marker=yes || echo marker=no
              grep ">>> FAILED: " /var/log/cloud-gaming-bootstrap.log 2>/dev/null | tail -1`, nil)
	if err != nil {
		d.Out.Echo("  the box answers tailscale but not ssh, so I cannot ask it why")
		return false
	}
	var sunshine, marker, failed string
	for _, l := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(l, "sunshine="):
			sunshine = strings.TrimPrefix(l, "sunshine=")
		case strings.HasPrefix(l, "marker="):
			marker = strings.TrimPrefix(l, "marker=")
		case strings.Contains(l, ">>> FAILED: "):
			failed = l[strings.Index(l, ">>> FAILED: ")+len(">>> FAILED: "):]
		}
	}
	// Both, not either. Sunshine present means this is a real streaming fault and
	// the caller's plain timeout is the right message; the readiness marker
	// present means the build DID finish, whatever else is wrong.
	if sunshine != "no" || marker != "no" {
		return false
	}
	lines := []string{"",
		"Sunshine is not installed on this box, so nothing can connect to it.",
		"",
		"  The build stopped partway. user-data runs under 'set -e', so a failed",
		"  step ends it - the box still boots, joins the tailnet and answers ssh,",
		"  which is why it looks alive. It has no desktop, no Steam and no",
		"  Sunshine, and waiting longer cannot change that."}
	if failed != "" {
		lines = append(lines, "", "  It stopped at:  "+failed)
	}
	lines = append(lines, "",
		"  There is nothing to repair here - the box is disposable and your games",
		"  are in S3:",
		"",
		"      cg destroy && cg init",
		"",
		"  To read the whole build log first:",
		"",
		"      ssh -i ~/.ssh/"+d.Box.Host+".pem ubuntu@"+ip,
		"      sudo tail -50 /var/log/cloud-gaming-bootstrap.log",
		"")
	d.block("This box never finished building", lines...)
	return true
}
