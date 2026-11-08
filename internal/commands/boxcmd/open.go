package boxcmd

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/ec2"

	cg "github.com/jebin2/aws_cloud_gaming"

	"github.com/jebin2/aws_cloud_gaming/internal/format"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/provision"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
)

// waitFor waits for something to come up, a dot per try.
func (d Deps) waitFor(ctx context.Context, id, desc string, tries int, ok func() bool) bool {
	// Off a terminal the dots would be raw text among the events; the wait is
	// reported as events instead, one every poll.
	dots := !d.Out.JSON
	if dots {
		fmt.Fprint(d.Out.Stdout, desc)
	}
	// Seconds as they really passed, not tries x 2: a try can itself take seconds
	// (a ping with a 5 s timeout), and "10 s" said over 40 real ones read as wrong.
	// No limit is given: in time it depends on how long each try takes.
	start := time.Now()
	since := func() int { return int(time.Since(start).Seconds()) }
	limit := 0
	for i := 0; i < tries; i++ {
		// Ctrl-C and SIGTERM cancel ctx; without this the loop ran to its end.
		if ctx.Err() != nil {
			if dots {
				fmt.Fprint(d.Out.Stdout, " interrupted\n")
			}
			d.Out.Wait(id, "interrupted", desc, since(), limit)
			return false
		}
		if ok() {
			if dots {
				fmt.Fprint(d.Out.Stdout, " ok\n")
			}
			d.Out.Wait(id, "done", desc, since(), limit)
			return true
		}
		if dots {
			fmt.Fprint(d.Out.Stdout, ".")
		}
		d.Out.Wait(id, "waiting", desc, since(), limit)
		d.sleep(2 * time.Second)
	}
	if dots {
		fmt.Fprint(d.Out.Stdout, " TIMEOUT\n")
	}
	d.Out.Wait(id, "timeout", desc, since(), limit)
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
	d.Out.Stage("open.start", "starting the machine")
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
		// A machine that stopped itself is still "stopping" while it saves the games
		// (a big first save takes many minutes), and AWS counts it against the
		// allowance for game PCs until it has stopped. Starting it then is refused,
		// and the refusal says "vCPU limit", which sends a person off to ask AWS for
		// more when all that is needed is to wait.
		if st == "stopping" {
			d.Out.SayID("open.stopping", "The machine is still shutting down and saving your games. Waiting for it to finish")
			if !d.Box.WaitState(ctx, "stopped", 35*time.Minute) {
				if ctx.Err() != nil {
					return 1
				}
				return d.die("the machine is still shutting down and saving your games. Try again in a few minutes")
			}
		}
		// Playing again after the games disk was removed: a new one is made and
		// connected BEFORE the machine starts, so it is there at the first boot.
		if code := d.extraBeforeStart(ctx); code != 0 {
			return code
		}
		d.Out.Echo("starting " + d.Box.ID + " ...")
		if err := d.Box.Start(ctx); err != nil {
			if strings.Contains(err.Error(), "VcpuLimitExceeded") {
				return d.die("AWS would not start the machine: your allowance for game PCs here is all in use. Another game PC may be running or still shutting down - wait for it to stop, then try again")
			}
			return d.die("AWS would not start the machine: " + firstErrorLine(err.Error()))
		}
		d.Box.WaitState(ctx, "running", 600*time.Second)
	}

	node := d.Box.Node
	d.Out.Stage("open.tailscale", "connecting over Tailscale")
	polls := 0
	if !d.waitFor(ctx, "open.tailscale", "waiting for tailscale", 60, func() bool {
		// --until-direct=false: an answer through Tailscale's relay is an answer.
		// Left at its default, tailscale ping exits 1 ("direct connection not
		// established") when the one pong came by relay - so a laptop that could
		// only reach the machine by relay waited out the whole limit, with the
		// machine answering every ping. The path is judged on its own just below.
		out, err := d.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"ping", "-c", "1", "--timeout", "5s", "--until-direct=false", node}})
		if err == nil {
			return true
		}
		// A real connection as well: the machine's ssh port, over its tailnet address.
		// A laptop's Tailscale may not set the machine up for traffic until traffic
		// asks for it - seen as in_engine=false and no handshake, with every ping
		// timing out for minutes on a machine that had booted in 8 s, while Play
		// pressed again (which opens an ssh connection first) got through at once.
		// This is that connection, made here, every try.
		if ip, ok := d.Box.IP(ctx); ok && d.reach(net.JoinHostPort(ip, "22"), 3*time.Second) {
			d.Out.Log("  reached the machine over Tailscale (its ssh port answered)")
			return true
		}
		// Why it has not answered, in the log: the first time and then about every
		// ten seconds. "waiting for tailscale" alone said nothing about whether the
		// machine was still booting, missing from the tailnet, or this laptop's own
		// Tailscale was down.
		polls++
		// Every half minute or so, what the machine itself is printing as it boots -
		// AWS keeps it, it costs nothing to read, and it is the one view of a machine
		// that does not answer yet. Before the summary, so the summary is said last.
		if polls%15 == 0 {
			d.bootLog(ctx)
		}
		if polls == 1 || polls%5 == 0 {
			d.tailscaleWhy(ctx, node, out, err)
		}
		return false
	}) {
		if ctx.Err() != nil {
			return 1
		}
		return d.die(fmt.Sprintf("%s never answered over Tailscale - is Tailscale up on this laptop? (tailscale status)", node))
	}

	// Confirm the path is direct. A relayed path adds tens of ms.
	out, _ := d.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"ping", "-c", "1", node}})
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	path := lines[len(lines)-1]
	d.Out.Echo("  " + path)
	if strings.Contains(path, "relay") || strings.Contains(path, "DERP") {
		d.Out.Echo("  WARNING: relayed, not direct - latency will suffer")
	}

	// A machine that stopped itself keeps its idle count on the root disk; older
	// ones wake up already counted and stop again 20 minutes in. Said to be zero
	// once it is reachable. Best effort: nothing about this may fail a play.
	_ = d.relay(ctx, "sudo sh -c 'echo 0 > /var/lib/idle-watchdog/idle' 2>/dev/null || true")

	d.syncIdle(ctx)
	if code := d.settleBootRestore(ctx); code != 0 {
		return code
	}
	if code := d.extraAfterStart(ctx); code != 0 {
		return code
	}
	if code := d.restoreGames(ctx); code != 0 {
		return code
	}

	ip, _ := d.Box.IP(ctx)
	d.Out.Stage("open.sunshine", "starting the game stream")
	if !d.waitFor(ctx, "open.sunshine", "waiting for sunshine", 60, func() bool {
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
	d.Out.Stage("open.play", "playing")
	// Copy and paste follows the stream: on while Moonlight is open, gone when it
	// closes.
	syncCtx, stopSync := context.WithCancel(ctx)
	synced := make(chan struct{})
	go func() { d.ClipSync(syncCtx); close(synced) }()
	d.Player.Play(ctx, ip, app)
	stopSync()
	select {
	case <-synced:
	case <-time.After(3 * time.Second):
	}

	// Closing Moonlight ends the session and nothing else. The machine is kept for
	// the next session; auto-stop ends it once it sits idle, and it can be deleted
	// now from the app or with cg destroy.
	d.Out.Stage("open.ended", "session ended")
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

var appIDs = regexp.MustCompile(`^[0-9]+(,[0-9]+)*$`)

// wantsExtra: this play was asked to have a games disk of its own.
func (d Deps) wantsExtra() bool { return d.ExtraGB > 0 && d.DiskAWS != nil }

// extraBeforeStart makes and connects the games disk when the machine has none.
// Connecting to a stopped machine is allowed, and it costs nothing until it runs.
func (d Deps) extraBeforeStart(ctx context.Context) int {
	if !d.wantsExtra() {
		return 0
	}
	if d.ExtraApps != "" && !appIDs.MatchString(d.ExtraApps) {
		return d.die("those games are not a list of game ids: " + d.ExtraApps)
	}
	vol, zone, _, _, err := diskFacts(ctx, d.DiskAWS, d.Box.ID)
	if err != nil {
		return d.die(firstErrorLine(err.Error()))
	}
	if vol != "" {
		return 0 // already there: it kept its games, or has room for them
	}
	gb := (d.ExtraGB + 9) / 10 * 10
	if gb > provision.MaxExtraDiskGB {
		return d.die(fmt.Sprintf("that is more than a game PC here can hold (%d GB of games disk at most)", provision.MaxExtraDiskGB))
	}
	_, code := d.makeAndAttach(ctx, d.DiskAWS, zone, gb)
	return code
}

// extraAfterStart mounts the games disk if it is not mounted yet. Bringing the
// games onto it is restoreGames, which the stream waits for.
func (d Deps) extraAfterStart(ctx context.Context) int {
	if !d.wantsExtra() {
		return 0
	}
	vol, _, _, _, err := diskFacts(ctx, d.DiskAWS, d.Box.ID)
	// A machine that was already running when Play was pressed was never through
	// extraBeforeStart, so its disk was never made: Play then failed here with
	// "not connected". It is made and connected now - AWS connects a disk to a
	// running machine as readily as to a stopped one.
	if err == nil && vol == "" {
		d.Out.SayID("open.disk", "Adding the games disk")
		if code := d.extraBeforeStart(ctx); code != 0 {
			return code
		}
		vol, _, _, _, err = diskFacts(ctx, d.DiskAWS, d.Box.ID)
	}
	if err != nil || vol == "" {
		return d.die("the games disk is not connected to the machine")
	}
	d.Out.SayID("open.disk", "Checking the games disk")
	if d.relay(ctx, remote("mountpoint", "-q", extraMount)) != nil {
		if code := d.setUpExtra(ctx, d.DiskAWS, vol, d.ExtraGB); code != 0 {
			return code
		}
	}
	return 0
}

// tailscaleWhy logs what is known while the machine does not answer over Tailscale:
// what the ping said, the machine's state at AWS, and this laptop's own line for it.
func (d Deps) tailscaleWhy(ctx context.Context, node string, out []byte, err error) {
	said := strings.TrimSpace(string(out))
	if i := strings.LastIndex(said, "\n"); i >= 0 {
		said = strings.TrimSpace(said[i+1:])
	}
	if said == "" && err != nil {
		said = err.Error()
	}
	d.Out.Log("  tailscale ping " + node + ": " + said)
	st, _ := d.Box.State(ctx)
	if st != "" {
		d.Out.Log("  machine state at AWS: " + st)
	}
	var peer peerState
	// The control server's view and this laptop's link to it, in detail: online or
	// not, which relay, a direct address if there is one, and when the last
	// WireGuard handshake was. "Connected" in the admin console with pings timing
	// out is exactly the case these tell apart.
	if js, e := d.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"status", "--json"}}); e == nil {
		if p, ok := peerFacts(js, node); ok {
			d.Out.Log("  tailscale peer: " + p.line)
			peer = p
		}
	}
	if list, e := d.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"status"}}); e == nil || len(list) > 0 {
		found := false
		for _, l := range strings.Split(string(list), "\n") {
			if strings.Contains(l, node) {
				d.Out.Log("  this laptop's tailscale: " + strings.Join(strings.Fields(l), " "))
				found = true
			}
		}
		if !found {
			d.Out.Log("  this laptop's tailscale does not list " + node + " (yet)")
		}
	} else {
		d.Out.Log("  tailscale status failed: " + e.Error())
	}
	// Last, in words: the line a screen shows under the wait.
	d.Out.Log(tailscaleWords(st, peer))
}

// tailscaleWords says where the connection is, from the machine's state at AWS
// and this laptop's view of it.
func tailscaleWords(state string, p peerState) string {
	switch {
	case state != "" && state != "running":
		return "The machine is still starting at AWS (" + state + ")."
	case !p.known || !p.online:
		return "The machine is booting. It is not on your tailnet yet; this usually takes a minute or two."
	case !p.handshake:
		return "The machine is on your tailnet. Your laptop is making the connection to it."
	default:
		return "Connected, but the machine is not answering yet."
	}
}

// settleBootRestore deals with a machine built before games were chosen at Play.
// Its config still says which games to bring back, and the restore service copies
// ALL of them from Saved games at every boot, whatever was ticked - which is why
// a Play with one game ticked could spend minutes copying every game, and why it
// ran beside the wait for Tailscale with nothing in the log saying so.
//
// Two things: the config is set to restore nothing from now on (this is the last
// boot that copies everything), and a copy that is still running is waited for and
// said so, in words, rather than raced by the games just chosen. It is not killed:
// stopped half-way it leaves a game with its manifest and part of its files, which
// Steam would call installed.
func (d Deps) settleBootRestore(ctx context.Context) int {
	_ = d.relay(ctx, "sudo sed -i 's/^CG_APPS=.*/CG_APPS=none/' /etc/cg-library.conf 2>/dev/null || true")
	active := func() bool {
		out, _ := d.Box.SSH(ctx, "systemctl is-active cg-library-restore.service", nil)
		return strings.TrimSpace(string(out)) == "activating"
	}
	if !active() {
		return 0
	}
	msg := "This machine was set up before games were chosen at Play, so it is first finishing a copy of every game. It happens once"
	if d.Games != "" {
		d.Out.SayID("open.restore", msg)
	} else {
		d.Out.Say(msg)
	}
	for i := 0; i < 720; i++ {
		if ctx.Err() != nil {
			return 1
		}
		d.sleep(5 * time.Second)
		if !active() {
			d.Out.Log("  the machine's own copy of every game has finished")
			return 0
		}
		if i%6 == 5 {
			out, _ := d.Box.SSH(ctx, "du -sb --exclude=downloading --exclude=temp /scratch/steam/steamapps/common 2>/dev/null | cut -f1", nil)
			if n, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64); err == nil {
				d.Out.Log(fmt.Sprintf("  still copying every game: %.1f GB on the machine so far", float64(n)/(1<<30)))
			}
		}
	}
	return d.die("the machine is still copying every game after an hour - try again later")
}

// consoleReader is the part of the EC2 client that reads a machine's console: the
// real client has it; the fakes in tests need not.
type consoleReader interface {
	GetConsoleOutput(context.Context, *ec2.GetConsoleOutputInput, ...func(*ec2.Options)) (*ec2.GetConsoleOutputOutput, error)
}

// bootLog logs the last lines the machine printed to its console: how far its boot
// has got while it does not answer over Tailscale. AWS updates it every minute or
// so; a read that fails is said and nothing more.
func (d Deps) bootLog(ctx context.Context) {
	for _, l := range d.consoleLines(ctx, 6) {
		d.Out.Log("  machine console: " + l)
	}
}

// consoleLines is the last n lines the machine printed to its console, as AWS
// keeps them (refreshed every minute or so, and on a change of state). Nothing
// when it cannot be read: a read that fails is said once and nothing more.
func (d Deps) consoleLines(ctx context.Context, n int) []string {
	c, ok := d.Box.EC2.(consoleReader)
	if !ok || d.Box.ID == "" {
		return nil
	}
	latest := true
	o, err := c.GetConsoleOutput(ctx, &ec2.GetConsoleOutputInput{InstanceId: &d.Box.ID, Latest: &latest})
	if err != nil || o.Output == nil {
		if err != nil && ctx.Err() == nil {
			d.Out.Log("  the machine's console could not be read: " + firstErrorLine(err.Error()))
		}
		return nil
	}
	raw, err := base64.StdEncoding.DecodeString(*o.Output)
	if err != nil {
		return nil
	}
	var lines []string
	for _, l := range strings.Split(strings.ReplaceAll(string(raw), "\r", ""), "\n") {
		if l = strings.TrimSpace(ansiCodes.ReplaceAllString(l, "")); l != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}

var ansiCodes = regexp.MustCompile(`\x1b\[[0-9;?]*[A-Za-z]`)

// peerState is this laptop's view of the node, from `tailscale status --json`.
type peerState struct {
	line                     string
	known, online, handshake bool
}

// peerFacts is one line about the node from `tailscale status --json`.
func peerFacts(js []byte, node string) (peerState, bool) {
	var st struct {
		Peer map[string]struct {
			HostName, DNSName, Relay, CurAddr string
			Online, Active, InEngine          bool
			LastHandshake, LastSeen           time.Time
		}
	}
	if json.Unmarshal(js, &st) != nil {
		return peerState{}, false
	}
	for _, p := range st.Peer {
		if p.HostName != node && !strings.HasPrefix(p.DNSName, node+".") {
			continue
		}
		hs, shook := "never", false
		if !p.LastHandshake.IsZero() && p.LastHandshake.Year() > 2000 {
			hs, shook = time.Since(p.LastHandshake).Round(time.Second).String()+" ago", true
		}
		direct := p.CurAddr
		if direct == "" {
			direct = "none"
		}
		return peerState{line: fmt.Sprintf("online=%v active=%v in_engine=%v relay=%s direct=%s last_handshake=%s", p.Online, p.Active, p.InEngine, p.Relay, direct, hs),
			known: true, online: p.Online, handshake: shook}, true
	}
	return peerState{}, false
}

// reach is whether a TCP connection to addr opens within timeout. Tests replace it
// through Reach; Dial is the stream port's own, and stays separate.
func (d Deps) reach(addr string, timeout time.Duration) bool {
	if d.Reach != nil {
		return d.Reach(addr, timeout) == nil
	}
	c, err := net.DialTimeout("tcp", addr, timeout)
	if err == nil {
		c.Close()
	}
	return err == nil
}

// syncIdle puts the idle minutes chosen in the app (GAME_IDLE_MIN) on the machine,
// with the watchdog script that reads them - a machine built earlier has one that
// does not. Every Play, so a changed setting takes effect at the next one. Best
// effort: a machine that keeps its old minutes still stops itself.
func (d Deps) syncIdle(ctx context.Context) {
	min := d.Env.Int("GAME_IDLE_MIN")
	if min <= 0 {
		return
	}
	script, err := cg.Files.ReadFile("host/idle-watchdog.sh")
	if err != nil {
		return
	}
	if _, err := d.Box.SSH(ctx, "sudo tee /usr/local/bin/idle-watchdog.sh >/dev/null && sudo chmod 755 /usr/local/bin/idle-watchdog.sh", bytes.NewReader(script)); err != nil {
		d.Out.Log("  the idle setting was not put on the machine; it keeps its own: " + firstErrorLine(err.Error()))
		return
	}
	if _, err := d.Box.SSH(ctx, fmt.Sprintf("echo IDLE_LIMIT=%d | sudo tee /etc/cg-idle.conf >/dev/null", min), nil); err != nil {
		d.Out.Log("  the idle setting was not put on the machine: " + firstErrorLine(err.Error()))
		return
	}
	d.Out.Log(fmt.Sprintf("  auto-stop when idle: %d min", min))
}
