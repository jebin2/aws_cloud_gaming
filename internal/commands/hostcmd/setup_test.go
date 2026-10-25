package hostcmd

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/commands/creds"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
	"github.com/jebin2/aws_cloud_gaming/internal/stream"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// ready wires a rig for setup and open: the machine builds itself in one look at its
// log, Sunshine is configured with the saved login, and Moonlight is paired.
func ready(t *testing.T, input string, facts string) *rig {
	r := newRig(t, input, true)
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		switch {
		case strings.HasSuffix(line, "sh -s"):
			return true, facts, nil
		case strings.Contains(line, "mktemp"):
			return true, "/tmp/build.AbC\n", nil
		case strings.Contains(line, "tail -n +"):
			return true, ">>> installing\n>>> ok: installing\n", nil
		case strings.Contains(line, "cloud-gaming-ready"), strings.Contains(line, ".steam-prewarmed"):
			return true, "", nil
		case strings.Contains(line, `printf "%s|%s`):
			return true, "working|\n", nil
		case line == "tailscale status":
			return true, "100.64.0.9   desk-pc   me@   linux   -\n", nil
		case strings.HasPrefix(line, "moonlight list"):
			return true, "Desktop\n", nil
		case strings.Contains(line, "sunshine-login.new"):
			return true, "", nil
		}
		return prev(line)
	}
	r.r.Installed["sh"] = true
	r.d.Runner = r.r
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		if q.URL.Path == "/welcome" {
			w.WriteHeader(302)
			return
		}
		if u, p, ok := q.BasicAuth(); ok && u == "admin" && p == "saved-pw" {
			w.WriteHeader(200)
			return
		}
		w.WriteHeader(401)
	}))
	t.Cleanup(srv.Close)
	r.d.Sun = sunshine.Client{HTTP: srv.Client(), URL: func(ip, path string) string { return srv.URL + path }}
	dir := t.TempDir()
	r.d.Env = config.Load(func(string) (string, bool) { return "", false }, dir)
	r.d.TS = func(token string) tskey.Client { return tskey.Client{Token: token, Base: "http://127.0.0.1:1"} }
	r.d.Creds = creds.Setter{Out: r.out, Ask: r.d.Ask, Env: r.d.Env, Getenv: func(string) string { return "" }, TS: r.d.TS}
	r.d.Sleep = func(time.Duration) {}
	r.d.Now = func() time.Time { return time.Unix(1700000000, 0) }
	r.d.CacheDir = t.TempDir()
	r.d.Pair = sunshine.Pairer{C: r.d.Sun, R: r.r, Sleep: r.d.Sleep, Log: r.out.Log}
	r.d.SessionFile = dir + "/cg-session.pid"
	r.d.Probe = session.Proc{}
	r.d.Player = stream.Player{R: r.r, Get: r.d.Env.Get, CacheDir: r.d.CacheDir, Root: t.TempDir(), Echo: r.out.Echo, Log: r.out.Log, Warn: r.out.Log}
	_ = r.d.Store.Set("desk-pc", "ssh", "me@pc", "os", "Linux", "sunshine_user", "admin", "sunshine_pass", "saved-pw")
	return r
}

var onTailnet = linuxFacts + "ts_ip=100.64.0.9\n"

func TestSetupBuildsAndLeavesTheMachineReady(t *testing.T) {
	r := ready(t, "", onTailnet)
	if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e)
	}
	rec := r.d.Store.Get("desk-pc")
	if rec.Field("ready") != "yes" || rec.Field("ts_ip") != "100.64.0.9" {
		t.Errorf("%v", rec)
	}
	got := r.o.String()
	for _, want := range []string{"==> asking desk-pc what it is", "Ubuntu 24.04 LTS, signed in as me", "==> starting the build on desk-pc", "==> building desk-pc - live progress below (it takes a while)",
		"installing", "  ok  installing", "build complete after 0m", "==> Sunshine account", "already configured, and the saved login works", "==> moonlight pairing", "already paired",
		"==> waiting for Steam to finish installing", "on the tailnet at 100.64.0.9", "no TAILSCALE_API_KEY in .env - key expiry left on", "ready: cg host open desk-pc"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	// The build is copied before it is started, and what is copied is the assembled script.
	copyAt, startAt := -1, -1
	for i, l := range r.r.Ran {
		if strings.Contains(l, "mktemp") {
			copyAt = i
			script := r.r.Stdin[l]
			if strings.Contains(script, "__TS_HOST__") || !strings.Contains(script, "desk-pc") || len(script) < 1000 {
				t.Errorf("the copied script is not the assembled build: %.200s", script)
			}
		}
		if strings.Contains(l, "setsid nohup bash") {
			startAt = i
			if !strings.Contains(l, "sudo -n sh -c") || !strings.Contains(l, "/tmp/build.AbC") {
				t.Errorf("%s", l)
			}
		}
	}
	if copyAt < 0 || startAt < copyAt {
		t.Errorf("copy %d start %d", copyAt, startAt)
	}
	// The login is kept on the machine over stdin, never on a command line.
	for _, l := range r.r.Ran {
		if strings.Contains(l, "saved-pw") {
			t.Errorf("the Sunshine password is on a command line: %s", l)
		}
	}
}

func TestSetupAsksTheSudoPasswordOnceAndChecksItFirst(t *testing.T) {
	r := ready(t, "wrong\n", strings.Replace(onTailnet, "sudo=nopass", "sudo=password", 1))
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		// The check of the password: sudo -S -p '' -v, whatever the quoting around it.
		if strings.Contains(line, "sudo -S") && strings.Contains(line, " -v") {
			return true, "", &exit{1}
		}
		return prev(line)
	}
	if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "sudo did not accept that password on desk-pc - nothing was changed") {
		t.Fatalf("rc %d\n%s", rc, r.e)
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "setsid") || strings.Contains(l, "mktemp") {
			t.Errorf("nothing runs before the password is known good: %s", l)
		}
		if strings.Contains(l, "wrong") {
			t.Errorf("password on a command line: %s", l)
		}
	}
	// A good one is fed on stdin to the build's start as well.
	r = ready(t, "right\n", strings.Replace(onTailnet, "sudo=nopass", "sudo=password", 1))
	if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 0 {
		t.Fatalf("%s", r.e)
	}
	n := 0
	for l, in := range r.r.Stdin {
		if strings.Contains(l, "sudo -S") && in == "right\n" {
			n++
		}
	}
	if n != 2 {
		t.Errorf("the checked password starts the build too: %d", n)
	}
}

func TestSetupRefusesWhatItCannotBuild(t *testing.T) {
	for name, c := range map[string]struct{ facts, want string }{
		"windows":           {"os=Windows\n", "setting a Windows machine up is not built yet"},
		"gentoo":            {strings.Replace(linuxFacts, "id=ubuntu\nid_like=debian\n", "id=gentoo\n", 1), "cg sets up Ubuntu, Debian, Arch and Fedora; Ubuntu 24.04 LTS is not one."},
		"arm":               {strings.Replace(linuxFacts, "arch=x86_64", "arch=aarch64", 1), "x86_64 only - Steam and Proton need it (aarch64 here)"},
		"no ubuntu release": {strings.Replace(linuxFacts, "ubuntu_version=24.04\n", "", 1), "which Ubuntu release it is could not be read"},
	} {
		r := ready(t, "", c.facts)
		if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), c.want) {
			t.Errorf("%s: rc %d\n%s", name, rc, r.e)
		}
		for _, l := range r.r.Ran {
			if strings.Contains(l, "setsid") {
				t.Errorf("%s: started a build", name)
			}
		}
	}
	r := ready(t, "", onTailnet)
	if rc := r.d.Setup(context.Background(), []string{"nope"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "no machine called 'nope' - add it: cg host add nope --ssh <user@address>") {
		t.Error(r.e.String())
	}
}

func TestAMachineNotOnTheTailnetJoinsWithAKeyOrIsNotTouched(t *testing.T) {
	r := ready(t, "", linuxFacts) // no ts_ip
	r.d.Ask.TTY = false
	if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "desk-pc is not on your tailnet, and there is no Tailscale auth key to join it with - cg creds tailscale authkey saves one") {
		t.Fatalf("%s", r.e)
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "mktemp") {
			t.Error("nothing is copied to a machine that cannot join")
		}
	}
	// With a stored key (no API token to check it, so it is taken at its word), the key goes into the build.
	r = ready(t, "", linuxFacts)
	_ = r.d.Env.Set("TAILSCALE_AUTH_KEY", "tskey-auth-stored-key1")
	// After the build it must be reachable: its address is on this laptop's tailnet.
	prev := r.r.Hook
	built := false
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.HasSuffix(line, "sh -s") && built {
			return true, onTailnet, nil
		}
		if strings.Contains(line, "tail -n +") {
			built = true
		}
		return prev(line)
	}
	if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 0 {
		t.Fatalf("%s%s", r.o, r.e)
	}
	for l, in := range r.r.Stdin {
		if strings.Contains(l, "mktemp") && !strings.Contains(in, "tskey-auth-stored-key1") {
			t.Error("the key is in the script that is copied")
		}
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "tskey-auth-stored-key1") {
			t.Errorf("the auth key is on a command line: %s", l)
		}
	}
}

func TestAMachineOnAnotherTailnetIsSaidNotGuessedAt(t *testing.T) {
	r := ready(t, "", onTailnet)
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if line == "tailscale status" {
			return true, "100.64.0.1   laptop   me@   linux   -\n", nil
		}
		return prev(line)
	}
	if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "desk-pc is on Tailscale, but not on the tailnet this laptop is on - sign it in to the same one") {
		t.Errorf("%s", r.e)
	}
	if r.d.Store.Get("desk-pc").Field("ready") == "yes" {
		t.Error("not ready")
	}
}

func TestABuildThatStopsIsNotReady(t *testing.T) {
	r := ready(t, "", onTailnet)
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		switch {
		case strings.Contains(line, "tail -n +"):
			return true, ">>> FAILED: installing the driver\n", nil
		case strings.Contains(line, "test -f /var/lib/cloud-gaming-ready"):
			return true, "", &exit{1}
		case strings.Contains(line, "cloud-gaming-bootstrap.rc"):
			return true, "exited|no\n", nil
		}
		return prev(line)
	}
	if rc := r.d.Setup(context.Background(), []string{"desk-pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "the build on desk-pc did not finish - its log is /var/log/cloud-gaming-bootstrap.log there") {
		t.Fatalf("%s%s", r.o, r.e)
	}
	if r.d.Store.Get("desk-pc").Field("ready") == "yes" || !strings.Contains(r.o.String(), "the build STOPPED here: installing the driver") {
		t.Errorf("%s", r.o)
	}
}

func TestOpenStreamsUnderTheLockAndReleasesIt(t *testing.T) {
	r := ready(t, "", onTailnet)
	_ = r.d.Store.Set("desk-pc", "ts_ip", "100.64.0.9", "ready", "yes")
	r.d.Moonlight = true
	if rc := r.d.Open(context.Background(), []string{"desk-pc"}, r.out); rc != 0 {
		t.Fatalf("%s%s", r.o, r.e)
	}
	got := r.o.String()
	for _, want := range []string{"==> checking desk-pc is ready to stream", "==> streaming from desk-pc", "session ended after "} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if strings.Count(strings.Join(r.r.Ran, "\n"), "moonlight stream 100.64.0.9 Desktop") != 1 {
		t.Errorf("%v", r.r.Ran)
	}
	if _, held := session.Running(r.d.SessionFile, session.Proc{}); held {
		t.Error("the lock is released")
	}
	// Not set up, no Moonlight, already streaming, Sunshine silent: each says so.
	for name, c := range map[string]struct {
		setup func(*rig)
		args  []string
		want  string
	}{
		"not set up":   {func(r *rig) { _ = r.d.Store.Set("desk-pc", "ts_ip", "") }, []string{"desk-pc"}, "'desk-pc' is not set up yet: cg host setup desk-pc"},
		"no moonlight": {func(r *rig) { r.d.Moonlight = false }, []string{"desk-pc"}, "Moonlight is not installed - cg check --fix installs it"},
		"no name":      {func(r *rig) {}, nil, "usage: cg host open <name>"},
		"silent": {func(r *rig) {
			r.d.Sun = sunshine.Client{URL: func(ip, path string) string { return "https://127.0.0.1:1" + path }}
		}, []string{"desk-pc"}, "Sunshine is not answering on desk-pc (100.64.0.9) - is it on, and a desktop signed in?"},
	} {
		r := ready(t, "", onTailnet)
		_ = r.d.Store.Set("desk-pc", "ts_ip", "100.64.0.9")
		r.d.Moonlight = true
		c.setup(r)
		if rc := r.d.Open(context.Background(), c.args, r.out); rc != 1 || !strings.Contains(r.e.String(), c.want) {
			t.Errorf("%s: rc %d\n%s", name, rc, r.e)
		}
	}
	// A stream already running from this laptop is not started twice.
	r = ready(t, "", onTailnet)
	_ = r.d.Store.Set("desk-pc", "ts_ip", "100.64.0.9")
	r.d.Moonlight = true
	session.Claim(r.d.SessionFile, time.Now())
	r.d.Probe = alwaysCg{}
	if rc := r.d.Open(context.Background(), []string{"desk-pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "a stream from this laptop is already running (pid ") {
		t.Errorf("rc %d\n%s", rc, r.e)
	}
}

// alwaysCg is a probe that sees a live cg at any pid: the test binary is not called cg.
type alwaysCg struct{}

func (alwaysCg) Alive(int) bool          { return true }
func (alwaysCg) Args(int) (string, bool) { return "cg host open", true }
