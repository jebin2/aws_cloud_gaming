package status

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

const host = "gamevps"

var now = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

type probe struct{}

func (probe) Alive(int) bool          { return false }
func (probe) Args(int) (string, bool) { return "", false }

// account is tests/status-json.sh's: a paid account, no box, 6218 games archived
// with the Steam login beside them, a budget of $57 with two alerts.
func account() *fx.Scenario {
	s := &fx.Scenario{
		Account: "123456789012", Plan: "PAID", Credits: 139.35, KeyPair: true, KeyName: host, SecGroup: true, SGID: "sg-test",
		Ingress: [][3]string{{"udp", "41641", "0.0.0.0/0"}},
		VCPUs:   4, MemMiB: 16384, GPU: "L4", GPUMem: 22888, QuotaOnDemand: 4, QuotaSpot: 4,
		Budget: "57.0", Notifications: 2, Bucket: "cg-library-test",
		Roles: map[string]bool{host + "-box": true, host + "-cloud-watchdog": true},
		LogEvents: []fx.LogEvent{{At: now.Add(-10 * time.Minute),
			Msg: "cg-watchdog: archive: kept - last used 2d ago; deleted in 12d unless a box is launched"}},
	}
	each := int64(172000000000 / 6218)
	for i := 0; i < 6217; i++ {
		s.Objects = append(s.Objects, fx.Object{Key: "steam/steamapps/common/Game x/pak.bin", Size: each})
	}
	s.Objects = append(s.Objects, fx.Object{Key: "steam/steamapps/common/Game last/pak.bin", Size: 172000000000 - each*6217},
		fx.Object{Key: "steam/account/steam-account.tgz", Size: 22458, Modified: time.Date(2026, 10, 10, 16, 30, 3, 0, time.UTC)})
	return s
}

func running(s *fx.Scenario, lifecycle string) {
	s.Instances = []fx.Instance{{ID: "i-0abc123", State: "running", Type: "g6.xlarge", Lifecycle: lifecycle, AZ: "ap-south-2a",
		Name: host, PublicIP: "13.1.1.1", Launched: time.Date(2026, 9, 26, 10, 0, 0, 0, time.UTC), RootVolume: "vol-root"}}
	s.Volumes = []fx.Volume{{ID: "vol-root", State: "in-use", GB: 50, Instance: "i-0abc123"}}
}

type env struct {
	home, cache string
	runner      *fx.Runner
	ts          string
	answers     map[string]string
	fail        bool
}

func newEnv(t *testing.T) *env {
	home := t.TempDir()
	_ = os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	_ = os.WriteFile(filepath.Join(home, ".ssh", host+".pem"), nil, 0o600)
	e := &env{home: home, cache: filepath.Join(home, ".cache", "cg"),
		ts: "100.64.0.9  gamevps  you@  linux  offline, last seen 2d ago\n"}
	return e
}

func (e *env) gather(t *testing.T, s *fx.Scenario) View {
	t.Helper()
	e.runner = &fx.Runner{Installed: map[string]bool{"tailscale": true, "moonlight": true, "ssh": true},
		Answers: map[string]string{"tailscale status": e.ts}, Failing: map[string]bool{}}
	for k, v := range e.answers {
		e.runner.Answers[k] = v
	}
	if e.fail {
		e.runner.Failing["ssh"] = true
	}
	g := &Gatherer{
		EC2: fx.EC2{S: s}, Quotas: fx.Quotas{S: s}, Budgets: fx.Budgets{S: s}, FreeTier: fx.FreeTier{S: s},
		S3: fx.S3{S: s}, STS: fx.STS{S: s}, IAM: fx.IAM{S: s}, Logs: fx.Logs{S: s}, Runner: e.runner, Probe: probe{},
		Host: host, Node: host, Region: "ap-south-2", Type: "g6.xlarge", Bucket: s.Bucket, Home: e.home, CacheDir: e.cache,
		LockFile: filepath.Join(e.home, "cg-session.pid"), ExpiryDays: 14, Now: func() time.Time { return now },
		AuthKey: true,
	}
	f := g.Gather(context.Background())
	v := View{Facts: f, Host: host, Node: host, Region: "ap-south-2", Type: "g6.xlarge", Now: now,
		Rates: pricing.Rates{S3GBMonth: fl(0.025), EBSGBMonth: fl(0.0912), SnapshotGBMonth: fl(0.05), IPv4Hour: fl(0.005),
			CECallUSD: fl(0.01), INRPerUSD: fl(88), FXINRPerUSD: fl(88), EgressGB: fl(0.1093), EgressFreeGB: 100},
		DiskGB: 50, Spot: "auto"}
	return v
}

func fl(v float64) *float64 { return &v }

func jq(t *testing.T, v View) map[string]any {
	t.Helper()
	b, err := v.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, b)
	}
	return m
}

func at(m map[string]any, path string) any {
	var cur any = m
	for _, k := range strings.Split(path, ".") {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[k]
	}
	return cur
}

func has(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("lacks %q:\n%s", w, out)
		}
	}
}

func lacks(t *testing.T, out string, bad ...string) {
	t.Helper()
	for _, w := range bad {
		if strings.Contains(out, w) {
			t.Errorf("has %q:\n%s", w, out)
		}
	}
}

func eq(t *testing.T, name string, got, want any) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %v (%T) want %v (%T)", name, got, got, want, want)
	}
}

// 1. no box: the report and the JSON say the same thing.
func TestNoBox(t *testing.T) {
	v := newEnv(t).gather(t, account())
	text, j := v.Human(), jq(t, v)
	has(t, text, "instance        none", "6218 objects", "steam login", "budget          $57 limit",
		"game archive    kept - last used 2d ago; deleted in 12d unless a box is launched  (checked 10 min ago)")
	eq(t, "box is null", at(j, "box"), nil)
	eq(t, "objects", at(j, "archive.objects"), 6218.0)
	eq(t, "bytes", at(j, "archive.bytes"), 172000000000.0)
	// The login is not a game: counting it reported 22 KB of games for an empty archive.
	eq(t, "login present", at(j, "login.present"), true)
	eq(t, "login bytes", at(j, "login.bytes"), 22458.0)
	eq(t, "monthly cost", at(j, "archive.usd_month"), 4.0)
	eq(t, "plan", at(j, "account.plan"), "PAID")
	eq(t, "credits", at(j, "account.credits"), "139.35")
	eq(t, "budget limit", at(j, "budget.limit"), 57.0)
	eq(t, "alerts", at(j, "budget.alerts"), 2.0)
	eq(t, "spot quota", at(j, "quota.spot"), 4.0)
	eq(t, "host", at(j, "host"), "gamevps")
	eq(t, "vcpus", at(j, "spec.vcpus"), 4.0)
	eq(t, "memory", at(j, "spec.memory_mib"), 16384.0)
	eq(t, "gpu", at(j, "spec.gpu"), "L4")
	eq(t, "gpu memory", at(j, "spec.gpu_memory_mib"), 22888.0)
	eq(t, "quota reuses the vcpus", at(j, "quota.vcpus"), 4.0)
	eq(t, "no session is null", at(j, "session"), nil)
	eq(t, "decision", at(j, "archive.expiry_days"), 14.0)
}

func TestARunningBox(t *testing.T) {
	e := newEnv(t)
	s := account()
	running(s, "spot")
	v := e.gather(t, s)
	has(t, v.Human(), "instance        i-0abc123  g6.xlarge  running")
	j := jq(t, v)
	eq(t, "id", at(j, "box.id"), "i-0abc123")
	eq(t, "launched", at(j, "box.launched"), "2026-09-26T10:00:00+00:00")
	eq(t, "volumes follow the box", at(j, "res.volumes_gb"), 50.0)
	eq(t, "spot", at(j, "box.lifecycle"), "spot")
	// Running is not ready: an app read "running" as ready and offered Play on
	// a box still installing its desktop.
	eq(t, "running, not set up: not ready", at(j, "box.ready"), false)
	eq(t, "not built here yet", at(j, "box.built"), false)

	_ = os.MkdirAll(e.cache, 0o755)
	_ = os.WriteFile(filepath.Join(e.cache, "ready-i-0abc123"), nil, 0o644)
	_ = os.WriteFile(filepath.Join(e.cache, "built-i-0abc123"), nil, 0o644)
	j = jq(t, e.gather(t, s))
	eq(t, "seen ready once: ready without asking again", at(j, "box.ready"), true)
	eq(t, "and built", at(j, "box.built"), true)

	running(s, "")
	eq(t, "no lifecycle is on-demand", at(jq(t, e.gather(t, s)), "box.lifecycle"), "on-demand")
}

func TestReadyIsAskedOverTheTailnet(t *testing.T) {
	e := newEnv(t)
	e.ts = "100.64.0.9  gamevps  you@  linux  active; direct\n"
	s := account()
	running(s, "spot")
	e.answers = map[string]string{"ssh": "yes 268435456000\n"}
	v := e.gather(t, s)
	eq(t, "ready after asking the box", at(jq(t, v), "box.ready"), true)
	b, _ := os.ReadFile(filepath.Join(e.cache, "scratch-g6.xlarge"))
	if string(b) != "250" {
		t.Errorf("the game disk, measured once per type, in GiB: %q", b)
	}
	if _, err := os.Stat(filepath.Join(e.cache, "ready-i-0abc123")); err != nil {
		t.Error("ready, once seen, is remembered for that instance")
	}
	// An ssh that did not answer is unknown, never "no".
	e2 := newEnv(t)
	e2.ts = e.ts
	e2.fail = true
	eq(t, "unreachable: unknown", at(jq(t, e2.gather(t, s)), "box.ready"), nil)
}

func TestSnapshotsAndRates(t *testing.T) {
	s := account()
	s.Snapshots = []fx.Snapshot{{ID: "snap-1", GB: 30}, {ID: "snap-2", GB: 50}}
	j := jq(t, newEnv(t).gather(t, s))
	eq(t, "snapshots counted", at(j, "res.snapshots"), 2.0)
	eq(t, "and their size", at(j, "res.snapshots_gb"), 80.0)
	eq(t, "s3 price", at(j, "rates.s3_gb_month"), 0.025)
	eq(t, "ebs", at(j, "rates.ebs_gb_month"), 0.0912)
	eq(t, "ipv4", at(j, "rates.ipv4_hour"), 0.005)
	eq(t, "rupee", at(j, "rates.inr_per_usd"), 88.0)
	eq(t, "exact-cost call", at(j, "rates.ce_call_usd"), 0.01)
}

func TestTheLocalSide(t *testing.T) {
	e := newEnv(t)
	j := jq(t, e.gather(t, account()))
	eq(t, "tailscale", at(j, "local.tailscale"), true)
	eq(t, "moonlight", at(j, "local.moonlight"), true)
	eq(t, "ssh key", at(j, "local.ssh_key"), true)
	eq(t, "auth key", at(j, "local.auth_key"), true)
	eq(t, "the node is named, not addressed", at(j, "tailnet.node"), "gamevps")
	eq(t, "offline is false, not a string", at(j, "tailnet.online"), false)
	e.ts = "100.64.0.9  gamevps  you@  linux  active; direct\n"
	eq(t, "online is true", at(jq(t, e.gather(t, account())), "tailnet.online"), true)

	// Being on no tailnet is a NORMAL state and has to report as one.
	e.ts = "100.64.0.1  someone-else  you@  linux  active\n"
	v := e.gather(t, account())
	j = jq(t, v)
	if _, ok := j["tailnet"]; !ok {
		t.Fatal("a missing node must still report a tailnet section")
	}
	eq(t, "no node", at(j, "tailnet.node"), nil)
	eq(t, "offline", at(j, "tailnet.online"), false)
	eq(t, "the fields around it are intact", at(j, "local.moonlight"), true)
	has(t, v.Human(), "no 'gamevps' node on the tailnet")
}

func TestNoCredentialsStillReportsEverythingLocal(t *testing.T) {
	e := newEnv(t)
	s := account()
	s.Fail = map[string]bool{"GetCallerIdentity": true, "GetAccountPlanState": true, "DescribeInstances": true,
		"DescribeVolumes": true, "DescribeSnapshots": true, "DescribeImages": true, "DescribeAddresses": true,
		"DescribeKeyPairs": true, "DescribeSecurityGroups": true, "ListObjectsV2": true, "GetServiceQuota": true,
		"DescribeInstanceTypes": true, "GetRole": true, "FilterLogEvents": true}
	v := e.gather(t, s)
	j := jq(t, v)
	eq(t, "the local side survives", at(j, "local.tailscale"), true)
	if _, ok := j["tailnet"]; !ok {
		t.Error("the tailnet section is gone")
	}
	if at(j, "error.credentials") == nil {
		t.Error("it must say what is actually wrong")
	}
	text := v.Human()
	has(t, text, "NO CREDENTIALS", "CREDENTIALS", "Everything below is unknown, not empty.",
		"unknown - the credentials above were rejected, so nothing was read")
	lacks(t, text, "instance        none", "not set up yet", "EMPTY")
	// A probe that fails is unknown: never 0, never "none".
	eq(t, "volumes unknown", at(j, "res.volumes_gb"), nil)
	eq(t, "quota unknown", at(j, "quota.spot"), nil)
}

func TestAnArchiveThatCannotBeListedIsUnknownNotEmpty(t *testing.T) {
	s := account()
	s.Fail = map[string]bool{"ListObjectsV2": true}
	v := newEnv(t).gather(t, s)
	text := v.Human()
	has(t, text, "UNREADABLE", "this says nothing about what is in it", "steam login     unknown - the archive could not be listed")
	lacks(t, text, "EMPTY")
	j := jq(t, v)
	eq(t, "objects unknown", at(j, "archive.objects"), nil)
	eq(t, "login unknown, not false", at(j, "login.present"), nil)
}

func TestTheWatchdogDecisionIsCarriedThrough(t *testing.T) {
	j := jq(t, newEnv(t).gather(t, account()))
	if d, _ := at(j, "archive.decision").(string); !strings.Contains(d, "deleted in 12d") {
		t.Errorf("decision %v", d)
	}
}

func TestStrandedSpotBox(t *testing.T) {
	s := account()
	running(s, "spot")
	s.Instances[0].State = "stopped"
	s.SpotRequest = "disabled"
	text := newEnv(t).gather(t, s).Human()
	has(t, text, "STRANDED       this stopped spot box can never start again (request: disabled)",
		"its 50 GB root volume still bills $4.56/mo (INR 401)", "reclaim it: cg destroy")
	s.SpotRequest = "active"
	lacks(t, newEnv(t).gather(t, s).Human(), "STRANDED")
	s.Instances[0].Lifecycle = ""
	s.SpotRequest = "disabled"
	lacks(t, newEnv(t).gather(t, s).Human(), "STRANDED")
}

func TestAStreamHeldFromThisLaptop(t *testing.T) {
	e := newEnv(t)
	s := account()
	lock := filepath.Join(e.home, "cg-session.pid")
	_ = os.WriteFile(lock, []byte("42 "+"1\n"), 0o644)
	v := e.gather(t, s)
	v.Facts.Session = Known[session.Lock]{V: session.Lock{PID: 42, Started: now.Add(-125 * time.Second).Unix()}, OK: true}
	has(t, v.Human(), "streaming       yes - cg open is running here (pid 42, 2m 05s)")
	j := jq(t, v)
	eq(t, "pid", at(j, "session.pid"), 42.0)
	eq(t, "age", at(j, "session.age_s"), 125.0)
}

func TestTheBudgetBeforeAndAfterAWSHasCalculatedIt(t *testing.T) {
	s := account()
	has(t, newEnv(t).gather(t, s).Human(), "budget          $57 limit, AWS reports $0.00 spent - not calculated yet",
		"(Budgets lags up to 24h after creation; real spend: cg cost)")
	s.Spent = "12.5"
	has(t, newEnv(t).gather(t, s).Human(), "budget          $57 limit, $12.50 spent so far")
	s.Budget = ""
	has(t, newEnv(t).gather(t, s).Human(), "budget          missing")
}

func TestLegacyVolumeAndEIPNote(t *testing.T) {
	s := account()
	s.Volumes = []fx.Volume{{ID: "vol-games", State: "available", GB: 160, AZ: "ap-south-2a", Tags: map[string]string{"Name": host + "-games"}}}
	s.Addresses = 1
	text := newEnv(t).gather(t, s).Human()
	has(t, text, "old EBS volume  vol-games  160 GB in ap-south-2a  (~$14.59/mo, LEGACY - cg games --volume --delete)",
		"elastic ips     1   <- in this region, not made by cg; they bill while idle")
	lacks(t, text, "game library")
}

func TestQuotaWarnings(t *testing.T) {
	s := account()
	s.QuotaOnDemand, s.QuotaSpot = 0, 2
	text := newEnv(t).gather(t, s).Human()
	has(t, text, "on-demand G/VT  0 vCPU  <- too low to launch", "spot G/VT       2 vCPU  <- GAME_SPOT=1 will fail")
}

func TestIAMRoles(t *testing.T) {
	s := account()
	text := newEnv(t).gather(t, s).Human()
	has(t, text, "instance role   gamevps-box  (lets the box read/write its library bucket)",
		"watchdog role   gamevps-cloud-watchdog  (the cloud watchdog: ends only the gamevps box)")
	s.Roles = map[string]bool{}
	has(t, newEnv(t).gather(t, s).Human(), "instance role   none - cg init creates it", "watchdog role   none - cg init creates it")
}

func tailGatherer(t *testing.T, e *env, s *fx.Scenario, r *fx.Runner) *Gatherer {
	return &Gatherer{EC2: fx.EC2{S: s}, Runner: r, Host: host, Node: host, Home: e.home, CacheDir: e.cache,
		Now: func() time.Time { return now }}
}

func TestTheTailAsksTheBoxOverTheTailnet(t *testing.T) {
	e := newEnv(t)
	s := account()
	running(s, "spot")
	r := &fx.Runner{
		Installed: map[string]bool{"tailscale": true, "ssh": true},
		Answers:   map[string]string{"tailscale ip -4 gamevps": "100.64.0.9\n"},
		Contains: map[string]string{
			"cg-library status": "  on the box: 6218 files\n  in S3: 6218 files\n",
			"df -h":             "  Mounted on  Used  Size  Use%\n  /           8.0G  49G   17%\n",
			"tailscale0":        "1073741824 2147483648 536870912 7200\n",
		}}
	egress := filepath.Join(e.home, "egress")
	_ = os.WriteFile(egress, []byte(strconv.FormatInt(now.Add(-10*time.Minute).Unix(), 10)+" 9.4 100\n"), 0o644)
	out := tailGatherer(t, e, s, r).Tail(context.Background(), "i-0abc123", egress)
	has(t, out, "instance: running", "disk:", "  /           8.0G  49G   17%", "\ngame library\n  on the box: 6218 files",
		"TRAFFIC (this boot only - see cg cost for the billed month)",
		"stream out      1.00 GB   avg 1.2 Mbps over 2.0 h",
		"total out       2.00 GB   <- what AWS bills", "total in        0.50 GB",
		"monthly egress  9.4 GB used, ~91 GB of 100 GB free left  (as of 10 min ago)")
	lacks(t, out, "stale")
}

func TestTheTailSaysWhenTheBoxDoesNotAnswer(t *testing.T) {
	e := newEnv(t)
	s := account()
	r := &fx.Runner{
		Installed: map[string]bool{"tailscale": true, "ssh": true},
		Answers:   map[string]string{"tailscale ip -4 gamevps": "100.64.0.9\n"},
		Failing:   map[string]bool{"ssh": true}}
	out := tailGatherer(t, e, s, r).Tail(context.Background(), "", filepath.Join(e.home, "none"))
	has(t, out, "game library\n  box not reachable - the archive is listed by: cg library list")
	lacks(t, out, "TRAFFIC", "instance:", "disk:")
	// A box in .env that cannot be reached.
	running(s, "spot")
	out = tailGatherer(t, e, s, r).Tail(context.Background(), "i-0abc123", "")
	has(t, out, "disk:\n  (host unreachable - box stopped?)")
}

func TestNoTailnetNoTail(t *testing.T) {
	r := &fx.Runner{Installed: map[string]bool{"tailscale": true}, Failing: map[string]bool{"tailscale": true}}
	if out := tailGatherer(t, newEnv(t), account(), r).Tail(context.Background(), "", ""); out != "" {
		t.Errorf("a node that is on no tailnet has no tail: %q", out)
	}
}

func TestEgressMonthIsStampedWithItsAge(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "egress")
	if got := EgressMonth(p, now); got != "  monthly egress  unknown - run: cg cost\n" {
		t.Errorf("never run: %q", got)
	}
	write := func(ago time.Duration) {
		_ = os.WriteFile(p, []byte(strconv.FormatInt(now.Add(-ago).Unix(), 10)+" 120 100\n"), 0o644)
	}
	write(3 * time.Hour)
	has(t, EgressMonth(p, now), "120.0 GB used, ~0 GB of 100 GB free left  (as of 3 h ago)")
	lacks(t, EgressMonth(p, now), "stale")
	write(30 * time.Hour)
	has(t, EgressMonth(p, now), "(as of 30 h ago)", "stale - refresh with: cg cost")
	write(72 * time.Hour)
	has(t, EgressMonth(p, now), "(as of 3 days ago)")
}
