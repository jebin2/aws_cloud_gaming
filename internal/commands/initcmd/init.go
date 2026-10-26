// Package initcmd is `cg init`: everything from "no box" to "ready to play". It is
// the largest command, and it is a sequence of steps each of which is its own
// package - the preflight, the bucket and role, the launch, the build - so what is
// here is the order, and what to say between them.
package initcmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/ec2"

	cg "github.com/jebin2/aws_cloud_gaming"
	"github.com/jebin2/aws_cloud_gaming/internal/box"
	"github.com/jebin2/aws_cloud_gaming/internal/build"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/check"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/provision"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	"github.com/jebin2/aws_cloud_gaming/internal/tailnet"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// Init is one run of cg init.
type Init struct {
	Out *output.Out
	Env *config.Env
	R   local.Runner

	// The steps that are their own commands.
	EnsureWatchdog func(ctx context.Context)
	ChooseGames    func(ctx context.Context)
	Preflight      func(ctx context.Context) (check.Result, int)

	// The AWS side.
	Lib func(bucket string) provision.Library
	// Prices gives the cross-region price per GB for leaving a region, and the rupee
	// rate; nil when unknown.
	Prices func(ctx context.Context, region string) (xregion, inr *float64)
	// BucketRegion is where a bucket really is: the region in .env is where the box
	// is, and the two are the same until GAME_REGION moves.
	BucketRegion func(ctx context.Context, bucket string) (string, error)
	Provisioner  provision.Provisioner
	Budget       func(inr float64) provision.Budget
	Shutdown     provision.ShutdownAPI
	EC2          box.EC2
	TS           func(token string) tskey.Client

	// The build, which needs the box over the tailnet.
	Sun       sunshine.Client
	Pair      sunshine.Pairer
	Moonlight bool
	Notify    func(ctx context.Context, title, message, priority, tags string)
	// WatchdogState says whether the cloud watchdog is armed and how often it checks.
	WatchdogState func(ctx context.Context) (armed bool, idleMin int)

	Home, Cache string
	Now         func() time.Time
	Sleep       func(time.Duration)
	// BuildTimeout and friends are the build's own limits; zero uses the defaults.
	NodeTimeout time.Duration
	Build       build.Follower
}

func (i *Init) die(text string) int {
	i.Out.Die(text)
	return 1
}

// cont is a line relayed from a step, indented as the shell relayed it.
func (i *Init) cont(indent, line string) {
	i.Out.Relay(strings.NewReader(line+"\n"), indent)
}

var nodeName = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$`)

// Run is `cg init`.
func (i *Init) Run(ctx context.Context) int {
	if i.EnsureWatchdog != nil {
		i.EnsureWatchdog(ctx)
	}
	if i.ChooseGames != nil {
		i.ChooseGames(ctx)
	}
	pre, rc := i.Preflight(ctx)
	if rc != 0 {
		return rc
	}
	host, region := i.Env.Host(), i.Env.Region()
	now := i.Now

	// Snapshot the tailnet before anything launches, so the new node can be
	// identified by *being new* rather than by having an expected name.
	before := tailnet.Keys(tailnet.Nodes(ctx, i.R))
	stale := 0
	for _, n := range tailnet.Names(ctx, i.R) {
		if n == host {
			stale++
		}
	}
	// Whether provisioning will reuse an instance or launch one decides how to find
	// the box on the tailnet afterwards, and it has to be known BEFORE it runs.
	existing, _ := i.Provisioner.Existing(ctx, host)
	reused := existing != ""

	// Only about a NEW box, and only saying what will actually happen. An offline
	// node of that name is pruned seconds from now, so the box takes the name - the
	// note used to predict a suffix there, and then the prune made it wrong. Only a
	// node that is still online forces one.
	if stale > 0 && !reused {
		if tailnet.Offline(ctx, i.R, host) {
			i.Out.Log(fmt.Sprintf("note: an offline '%s' node is left from an earlier box - it is pruned before launch, so the new box takes the name", host))
		} else {
			i.Out.Log(fmt.Sprintf("note: a node named '%s' is online, so a new box joins as '%s-1' - which is handled", host, host))
		}
	}

	// The budget first: it is account-level, costs nothing, and needs no instance.
	// If the build dies - or the laptop does - the bill is still being watched.
	i.Out.Say("arming the budget before anything launches")
	inr := float64(i.Env.Int("GAME_BUDGET_INR"))
	if inr == 0 {
		inr = 5000
	}
	b := i.Budget(inr)
	b.Out = func(l string) { i.cont("    ", l) }
	if err := b.Arm(ctx); err != nil {
		i.Out.Log("budget setup failed - continuing")
	}

	// Notifications are off unless GAME_NTFY_URL is set. A value that is set but
	// malformed is said once, here, rather than silently sending nothing.
	ntfy := config.NtfyURL(i.Env.Get("GAME_NTFY_URL"))
	if i.Env.Get("GAME_NTFY_URL") != "" && ntfy == "" {
		i.Out.Log("GAME_NTFY_URL is not a valid ntfy topic or URL - notifications are off (test with: cg notify)")
	}

	i.Out.Say("provisioning instance")
	res, ok := i.provision(ctx, pre, ntfy)
	if !ok {
		return 1
	}
	id := res.InstanceID
	_ = i.Env.Set("GAME_INSTANCE_ID", id)
	_ = i.Env.Set("GAME_REGION", region)
	_ = i.Env.Set("GAME_TS_HOST", host)
	i.cont("", "updated "+i.Env.File)

	// Confirm this BEFORE the build, not after. The watchdog arms on the box within
	// a minute and its only action is `shutdown -h`; whether that stops the instance
	// or TERMINATES it - deleting the root volume - is decided at launch.
	i.Out.Say("confirming what shutdown does to this instance")
	if err := provision.CheckShutdown(ctx, i.Shutdown, id, func(l string) { i.cont("    ", l) }); err != nil {
		return i.die("the shutdown behaviour is not what the watchdog needs - see above; nothing will be built on it")
	}

	bx := box.Box{EC2: i.EC2, ID: id, Host: host, Node: host, R: i.R, Sleep: i.Sleep, Log: i.Out.Log, Key: filepath.Join(i.Home, ".ssh", host+".pem"), TagKey: config.TagKey}
	// A reused instance may be stopped, in which case nothing will ever join the
	// tailnet until it is started.
	if st, err := bx.State(ctx); err == nil && st == "stopped" {
		i.Out.Say("starting the existing instance")
		_ = bx.Start(ctx)
		bx.WaitState(ctx, "running", 600*time.Second)
	}

	node, rc := i.findNode(ctx, bx, before, reused, host, region)
	if rc != 0 {
		return rc
	}
	// The AWS resources stay named after the host; only the tailnet name may differ,
	// so record it separately rather than letting a suffix rename everything.
	if node != host {
		i.Out.Log(fmt.Sprintf("this box is '%s' on the tailnet, not '%s' - a node held the", node, host))
		i.Out.Log("name when it first joined. Everything uses the real name, so this is fine.")
		i.Out.Log(fmt.Sprintf("To reclaim '%s', delete stale nodes then rebuild the box.", host))
	}
	// Refuse to write anything that is not a plain hostname. A multi-line value once
	// landed in .env and left a bare word on its own line, which every later run
	// then tried to execute.
	if !nodeName.MatchString(node) {
		return i.die(fmt.Sprintf("refusing to record a malformed tailnet node name: '%s'", node))
	}
	_ = i.Env.Set("GAME_TS_NODE", node)
	bx.Node = node

	// Key expiry used to be a manual step after every build. The API token that
	// prunes stale nodes can turn it off, so it is done here, as soon as the node
	// exists - and shown as a step only when it could not be.
	i.Out.Say(fmt.Sprintf("turning off Tailscale key expiry for '%s'", node))
	exp := i.TS(i.Env.Get("TAILSCALE_API_KEY")).DisableExpiry(ctx, node)
	for _, l := range exp.Lines {
		i.cont("", "    "+l)
	}

	// Now that destroy prunes stale tailnet nodes, a rebuilt box reclaims the same
	// hostname - and ssh refuses it, because known_hosts still holds the PREVIOUS
	// machine's key under that name. This is a genuinely new host that we created
	// seconds ago, so the old entry is stale rather than suspicious, and dropping it
	// is correct. Left in place it cost five minutes of a build looking hung.
	_, _ = i.R.Run(ctx, local.Cmd{Name: "ssh-keygen", Args: []string{"-R", node}})
	ip, _ := bx.IP(ctx)
	if ip != "" {
		_, _ = i.R.Run(ctx, local.Cmd{Name: "ssh-keygen", Args: []string{"-R", ip}})
	}

	return i.finish(ctx, bx, pre, id, node, ip, ntfy, exp.Off, now)
}

// provision makes the bucket and role, prunes the stale nodes, and launches.
func (i *Init) provision(ctx context.Context, pre check.Result, ntfy string) (provision.Result, bool) {
	host, region := i.Env.Host(), i.Env.Region()
	// Before anything joins the tailnet, clear entries left by boxes that
	// terminated themselves. Otherwise this build takes a suffixed name.
	for _, l := range i.TS(i.Env.Get("TAILSCALE_API_KEY")).PruneStale(ctx, host) {
		i.cont("", l)
	}
	i.cont("", "==> ensuring the S3 game library and the box's instance role")
	lib := i.Lib(i.Env.Get("GAME_S3_BUCKET"))
	lib.Note = func(l string) { i.cont("", "    "+l) }
	bucket, err := lib.Ensure(ctx)
	if err != nil {
		for _, l := range strings.Split(err.Error(), "\n") {
			i.cont("", l)
		}
		i.cont("", "could not set up the game library bucket/role")
		i.Out.Die("could not launch the instance - see the launch error above")
		return provision.Result{}, false
	}
	// Remember the bucket so every later run resolves the same name without another
	// sts call, and so `cg library` can find it.
	_ = i.Env.Set("GAME_S3_BUCKET", bucket)
	i.cont("", "    s3://"+bucket)

	bucketRegion := region
	if loc, err := i.BucketRegion(ctx, bucket); err == nil && loc != "" {
		bucketRegion = loc
	}
	p := i.Provisioner
	p.Out = func(l string) { i.cont("", l) }
	home := i.Home
	apps := i.Env.Get("GAME_APPS")
	if apps == "" {
		apps = "all"
	}
	login := i.Env.Get("GAME_STEAM_LOGIN")
	if login == "" {
		login = "use"
	}
	var xr, inr *float64
	if i.Prices != nil {
		xr, inr = i.Prices(ctx, bucketRegion)
	}
	res, err := p.Run(ctx, provision.Params{XRegionUSD: xr, INR: inr, Host: host, Region: region, Type: pre.Type, DiskGB: i.diskGB(), Spot: pre.Spot, TagKey: config.TagKey,
		AuthKey: pre.AuthKey, Apps: apps, Login: login, ReserveGB: i.Env.Setting("GAME_DISK_RESERVE_GB"),
		Bucket: bucket, BucketRegion: bucketRegion, NtfyURL: ntfy, KeyFile: filepath.Join(home, ".ssh", host+".pem")})
	if err != nil {
		var le *provision.LaunchError
		if errors.As(err, &le) {
			for _, l := range le.Report {
				i.cont("", l)
			}
		} else {
			i.cont("", err.Error())
		}
		i.Out.Die("could not launch the instance - see the launch error above")
		return res, false
	}
	return res, true
}

func (i *Init) diskGB() int {
	if n := i.Env.Int("GAME_DISK_GB"); n > 0 {
		return n
	}
	return 50
}

// findNode works out the box's name on the tailnet. Tailscale is installed first on
// the box precisely so this happens early - it is the point from which the build
// becomes observable. Reusing an existing instance means its node is already on the
// tailnet and was in the snapshot - so waiting for a *new* one would wait forever.
func (i *Init) findNode(ctx context.Context, bx box.Box, before map[string]bool, reused bool, host, region string) (string, int) {
	// Work out the node name for a reused box. .env is the first source but it is
	// not reliable: `cg destroy` clears GAME_TS_NODE, and an init that aborts before
	// writing it leaves nothing behind - while the box itself joined the tailnet
	// minutes ago. So fall back to finding a node named after this host.
	reusedNode := ""
	if reused {
		names := tailnet.Names(ctx, i.R)
		have := func(n string) bool {
			for _, x := range names {
				if x == n {
					return true
				}
			}
			return false
		}
		if n := i.Env.Get("GAME_TS_NODE"); n != "" && have(n) {
			reusedNode = n
		} else {
			pat := regexp.MustCompile(`^` + regexp.QuoteMeta(host) + `(-[0-9]+)?$`)
			for _, c := range names {
				if !pat.MatchString(c) {
					continue
				}
				if reusedNode == "" {
					reusedNode = c
				}
				if i.ping(ctx, c, 2, "5s") {
					reusedNode = c
					break
				}
			}
			if reusedNode != "" {
				i.Out.Log(fmt.Sprintf("found '%s' on the tailnet (not recorded in .env)", reusedNode))
			}
		}
	}
	switch {
	case reusedNode != "":
		i.Out.Say(fmt.Sprintf("reusing the existing box, already on the tailnet as '%s'", reusedNode))
		// Nice to have, not a gate: give the path a realistic budget and carry on
		// either way, since ssh will establish it soon enough regardless.
		if i.ping(ctx, reusedNode, 3, "5s") {
			i.Out.Log("path up")
		} else {
			i.Out.Log("path not up yet - continuing, ssh will establish it")
		}
		return reusedNode, 0
	case i.Env.Get("GAME_TS_NODE") != "" && i.ping(ctx, i.Env.Get("GAME_TS_NODE"), 3, "5s"):
		n := i.Env.Get("GAME_TS_NODE")
		i.Out.Say(fmt.Sprintf("box already on the tailnet as '%s'", n))
		return n, 0
	}
	i.Out.Say("waiting for the box to join the tailnet")
	timeout := i.NodeTimeout
	if timeout == 0 {
		timeout = 1800 * time.Second
	}
	n, ok := tailnet.Wait(ctx, i.R, before, host, timeout, i.Sleep, i.Out.Log)
	if !ok {
		return "", i.die(fmt.Sprintf("no new node joined after 30 min.\n       The box may have failed before installing tailscale. Check its console:\n       aws ec2 get-console-output --region %s --instance-id %s --output text | tail -40", region, orID(bx.ID)))
	}
	return n, 0
}

func orID(id string) string {
	if id == "" {
		return "<id>"
	}
	return id
}

func (i *Init) ping(ctx context.Context, node string, count int, timeout string) bool {
	_, err := i.R.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"ping", "-c", fmt.Sprint(count), "--timeout", timeout, node}})
	return err == nil
}

// finish is the rest, which is every build's: shared with your own machines. What
// is the AWS box's alone comes in as hooks - the on-host watchdog, and the game
// library on /scratch.
func (i *Init) finish(ctx context.Context, bx box.Box, pre check.Result, id, node, ip, ntfy string, expiryOff bool, now func() time.Time) int {
	host := i.Env.Host()
	gamesLib := i.Env.Get("GAME_LIB_DIR")
	if gamesLib == "" {
		gamesLib = "/scratch/steam"
	}
	login := &sunshine.Login{User: i.Env.Get("SUNSHINE_USER"), Pass: i.Env.Get("SUNSHINE_PASS")}
	save := func(k, v string) {
		_ = i.Env.Set(k, v)
		switch k {
		case "SUNSHINE_USER":
			login.User = v
		case "SUNSHINE_PASS":
			login.Pass = v
		}
	}
	remote := remoteBox{bx}
	f := &build.Finisher{
		Follow: build.Follower{R: remote, Log: i.Out.Log, Sleep: i.Sleep, Target: "ubuntu@" + node, Key: bx.Key},
		Sun:    i.Sun, Pair: i.Pair, Run: i.R, Login: login, Save: save, Name: "the box", Takes: i.takes(),
		IP: ip, Say: i.Out.Say, Log: i.Out.Log, Sleep: i.Sleep, HasMoonlight: i.Moonlight,
	}
	// The build already installed the watchdog (15-watchdog.sh), so the box has been
	// guarded since minute one. This pass refreshes it from the local host/ - which
	// matters on a REUSED instance built from older code, and costs nothing here.
	f.AfterStream = func(ctx context.Context) (string, error) {
		i.Out.Say("refreshing the on-host watchdog")
		i.Out.Log("copying host/ ...")
		bundle, err := provision.HostBundle(cg.Files, ntfy)
		if err == nil {
			_, err = bx.SSH(ctx, "mkdir -p host && tar -xz -C host", strings.NewReader(string(bundle)))
		}
		if err != nil {
			i.Out.Log("could not copy host/: " + firstLine(err))
		}
		// The notification URL goes beside the scripts, as the build put it there;
		// removing it here is what turns notifications off on a box that had them.
		if ntfy == "" {
			_, _ = bx.SSH(ctx, "rm -f host/notify.url", nil)
		}
		i.Out.Log("installing units ...")
		out, _ := bx.SSH(ctx, "cd host && sudo ./install-watchdog.sh 2>&1", nil)
		i.Out.Relay(strings.NewReader(string(out)), "    ")
		ip, _ := bx.IP(ctx)
		return ip, nil
	}
	f.SteamReport = func(msg *string) {
		// Report what actually happened rather than assuming the three sub-steps
		// (client, library registration, dock pin) all succeeded.
		script := fmt.Sprintf(`echo "    client:  $(du -shcL ~/.steam ~/.local/share/Steam 2>/dev/null | tail -1 | cut -f1)"
        echo "    library: $(grep -q '%s' ~/.steam/steam/config/libraryfolders.vdf 2>/dev/null && echo "%s registered" || echo "NOT registered")"
        echo "    dock:    $(test -f ~/.config/xfce4/.steam-pinned && echo pinned || echo "not pinned")"`, gamesLib, gamesLib)
		if out, err := bx.SSH(ctx, script, nil); err == nil {
			i.Out.Relay(strings.NewReader(string(out)), "")
		}
		// Report the library separately - it fails independently of the client, and
		// claiming "ready" when games would land on the 50 GB root disk is worse than
		// saying nothing.
		if _, err := bx.SSH(ctx, fmt.Sprintf("grep -q '%s' ~/.steam/steam/config/libraryfolders.vdf", gamesLib), nil); err == nil {
			*msg = fmt.Sprintf("installed, game library on %s registered, pinned to the dock. Log in and it is ready.", gamesLib)
		} else {
			*msg = fmt.Sprintf("installed and pinned, but the game library is NOT registered - games would fill the %d GB root disk. Add %s in Steam > Settings > Storage.", i.diskGB(), gamesLib)
		}
	}
	if err := f.Finish(ctx); err != nil {
		i.Notify(ctx, "build failed", "The box is still running and billing. Look at: cg log build", "high", "warning")
		return i.die("the build did not finish. The instance is still running and still\n       billing - stop it with cg stop once you have looked at the log.")
	}

	// This laptop's half of the build is done for this machine: it waited for the box
	// and paired with it. cg status reads it (box.built), so an app closed in the
	// middle of a build - which ends this script, though the box carries on - knows on
	// reopening that the build is not finished and runs it again; a re-run finds the
	// same instance and picks up here. Written whether or not pairing stuck: a failed
	// pairing is said above, and `cg pair` is its fix.
	if os.MkdirAll(i.Cache, 0o755) == nil {
		_ = os.WriteFile(filepath.Join(i.Cache, "built-"+id), nil, 0o644)
		// How long it took, launch to ready, for every "a build takes" that follows.
		// From the instance's own launch time, so a build picked up again after the app
		// was closed still counts from the start.
		if o, err := i.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{id}}); err == nil && len(o.Reservations) > 0 && len(o.Reservations[0].Instances) > 0 {
			if lt := o.Reservations[0].Instances[0].LaunchTime; lt != nil {
				mins := int((now().Sub(*lt) + 59*time.Second) / time.Minute)
				_ = os.WriteFile(filepath.Join(i.Cache, "last-build-min"), []byte(fmt.Sprint(mins)), 0o644)
			}
		}
	}
	i.Notify(ctx, "box ready", "Built, paired and running - it bills by the hour. Play with: cg open", "default", "video_game")

	armed, idle := false, 0
	if i.WatchdogState != nil {
		armed, idle = i.WatchdogState(ctx)
	}
	facts := BoxFacts{}
	if out, err := bx.SSH(ctx, "bash -s "+gamesLib, strings.NewReader(FactsScript+"\n")); err == nil {
		facts = ParseFacts(string(out))
	}
	title, text := Summary(SummaryIn{InstanceID: id, Type: pre.Type, Region: i.Env.Region(), Spot: pre.Spot, Node: node, IP: f.IP, ExpiryOff: expiryOff, Paired: f.Paired,
		SunshineUser: login.User, SteamMsg: f.SteamMsg, GamesLib: gamesLib, Facts: facts, WatchdogArmed: armed, WatchdogIdleMin: idle,
		HostIdleMin: hostIdle(), ExpiryDays: i.Env.Int("GAME_ARCHIVE_EXPIRY_DAYS"), BudgetINR: i.budgetINR(), NotificationsOn: ntfy != ""})
	i.Out.Block(title, text)
	_ = host
	return 0
}

func (i *Init) budgetINR() string {
	if v := i.Env.Get("GAME_BUDGET_INR"); v != "" {
		return v
	}
	return "5000"
}

func (i *Init) takes() string {
	if b, err := os.ReadFile(filepath.Join(i.Cache, "last-build-min")); err == nil {
		if m := strings.TrimSpace(string(b)); m != "" {
			return "the last one took " + m + " min"
		}
	}
	return "it takes a while"
}

var idleLimit = regexp.MustCompile(`(?m)^IDLE_LIMIT="\$\{IDLE_LIMIT:-([0-9]*)\}"`)

// hostIdle is the on-host limit as its own script sets it, the same read cg watcher
// does.
func hostIdle() string {
	b, err := cg.Files.ReadFile("host/idle-watchdog.sh")
	if err != nil {
		return ""
	}
	if m := idleLimit.FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return ""
}

func firstLine(err error) string { return strings.SplitN(strings.TrimSpace(err.Error()), "\n", 2)[0] }

// remoteBox adapts a box to the build's Remote: commands under sh on the box.
type remoteBox struct{ b box.Box }

func (r remoteBox) SSH(ctx context.Context, command string) ([]byte, error) {
	return r.b.SSH(ctx, command, nil)
}
