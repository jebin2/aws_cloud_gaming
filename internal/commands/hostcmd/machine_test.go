package hostcmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/hosts"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/ownhost"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

const linuxFacts = "os=Linux\nid=ubuntu\nid_like=debian\nuser=me\nhostname=Desk-PC.local\npretty=Ubuntu 24.04 LTS\nubuntu_version=24.04\narch=x86_64\nmachine_id=m-1\nnvidia=RTX 3060\nsession=x11\nsteam=/usr/bin/steam\nsudo=nopass\n"

type rig struct {
	d      Deps
	r      *fx.Runner
	o, e   *bytes.Buffer
	out    *output.Out
	dir    string
	keyOn  *bool // whether cg's key lets in yet
	pwSeen *string
}

// newRig is a laptop with ssh, and a machine whose facts are linuxFacts. Until
// the password is given, "ssh ... exit" fails: cg's key is not on the machine.
func newRig(t *testing.T, input string, keyAlready bool) *rig {
	dir := t.TempDir()
	keyOn := keyAlready
	r := &fx.Runner{Installed: map[string]bool{"ssh": true, "ssh-keygen": true, "tailscale": true, "moonlight": true}}
	r.Hook = func(line string) (bool, string, error) {
		switch {
		case strings.HasPrefix(line, "ssh-keygen -q"):
			// make the files ssh-keygen would
			key := line[strings.LastIndex(line, "-f ")+3:]
			_ = os.MkdirAll(filepath.Dir(key), 0o700)
			_ = os.WriteFile(key, []byte("private"), 0o600)
			_ = os.WriteFile(key+".pub", []byte("ssh-ed25519 AAAAC3Nza cg@testbox\n"), 0o644)
			return true, "", nil
		case strings.Contains(line, "PubkeyAuthentication=no"):
			keyOn = true
			return true, "", nil
		case strings.HasSuffix(line, " exit"):
			if keyOn {
				return true, "", nil
			}
			return true, "", &exit{255}
		case strings.HasSuffix(line, "sh -s"):
			return true, linuxFacts, nil
		}
		return false, "", nil
	}
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	a := &ask.Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &bytes.Buffer{}, TTY: true}
	a.ReadSecret = func() (string, error) { s, err := a.In.ReadString('\n'); return strings.TrimRight(s, "\n"), err }
	d := Deps{Store: hosts.Store{Path: filepath.Join(dir, "hosts.json")},
		Conn: ownhost.Conn{R: r, Key: filepath.Join(dir, "cg", "ssh", "id_ed25519"), Hostname: func() string { return "testbox" }},
		Ask:  a, Runner: r, AWSHost: "gamevps", Moonlight: true}
	return &rig{d: d, r: r, o: &o, e: &e, out: out, dir: dir, keyOn: &keyOn}
}

type exit struct{ n int }

func (e *exit) Error() string { return "exit" }
func (e *exit) ExitCode() int { return e.n }

func TestAddAsksForThePasswordOnceAndNeverKeepsIt(t *testing.T) {
	r := newRig(t, "hunter2-pw\n", false)
	if rc := r.d.Add(context.Background(), []string{"--ssh", "me@192.168.1.5"}, r.out); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e)
	}
	rec := r.d.Store.Get("desk-pc")
	if rec.Field("ssh") != "me@192.168.1.5" || rec.Field("os") != "Linux" || rec.Field("family") != "ubuntu" || rec.Field("user") != "me" || len(rec.Field("machine")) != 16 {
		t.Errorf("%v", rec)
	}
	got := r.o.String()
	for _, want := range []string{"==> reaching me@192.168.1.5 over ssh", "cg's key is on me@192.168.1.5: no password from now on", "Ubuntu 24.04 LTS (x86_64), signed in as me", "GPU: RTX 3060", "added 'desk-pc'. Next: cg host setup desk-pc"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	b, _ := os.ReadFile(r.d.Store.Path)
	all := string(b) + got + r.e.String() + strings.Join(r.r.Ran, "\n")
	if strings.Contains(all, "hunter2-pw") {
		t.Error("the password is in the file, the output or a command line")
	}
}

func TestAddWithTheKeyAlreadyThereAsksNothing(t *testing.T) {
	r := newRig(t, "", true)
	if rc := r.d.Add(context.Background(), []string{"mypc", "--ssh", "me@pc"}, r.out); rc != 0 || r.d.Store.Get("mypc").Field("ssh") != "me@pc" {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e)
	}
	if strings.Contains(r.o.String(), "its password, once") {
		t.Error("asked for a password it did not need")
	}
}

func TestAddRefusesWhatWouldBeAddedTwice(t *testing.T) {
	r := newRig(t, "", true)
	ctx := context.Background()
	if r.d.Add(ctx, []string{"a", "--ssh", "me@pc"}, r.out) != 0 {
		t.Fatal(r.e)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"b", "--ssh", "me@pc"}, "me@pc is already added, as 'a'"},
		{[]string{"a", "--ssh", "me@other"}, "there is already a machine called 'a'"},
		{[]string{"b", "--ssh", "me@100.64.0.9"}, "is a machine already added, as 'a' - the same machine, by another address"},
		{[]string{"Bad Name", "--ssh", "me@x"}, "use lowercase letters, digits and dashes"},
		{[]string{"gamevps-2", "--ssh", "me@x"}, "clean-up would delete it"},
		{[]string{"b", "--ssh"}, "usage: cg host add [name] --ssh <user@address>"},
		{[]string{"b"}, "usage: cg host add [name] --ssh <user@address>"},
	} {
		r.e.Reset()
		if rc := r.d.Add(ctx, c.args, r.out); rc != 1 || !strings.Contains(r.e.String(), c.want) {
			t.Errorf("%v: rc %d, %s", c.args, rc, r.e)
		}
	}
	if len(r.d.Store.Names()) != 1 {
		t.Errorf("only the first was kept: %v", r.d.Store.Names())
	}
}

func TestAddWithNoOneToAskSaysWhatToDoInstead(t *testing.T) {
	r := newRig(t, "", false)
	r.d.Ask.TTY = false
	if rc := r.d.Add(context.Background(), []string{"--ssh", "me@pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "ssh-copy-id me@pc") {
		t.Errorf("%s", r.e)
	}
	r = newRig(t, "\n", false)
	if rc := r.d.Add(context.Background(), []string{"--ssh", "me@pc"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "no password given - nothing was changed on me@pc") {
		t.Errorf("%s", r.e)
	}
}

func TestRemoveTakesCgsKeyOffAndForgetsTheMachine(t *testing.T) {
	r := newRig(t, "", true)
	ctx := context.Background()
	_ = r.d.Add(ctx, []string{"pc", "--ssh", "me@pc"}, r.out)
	r.o.Reset()
	if rc := r.d.Remove(ctx, []string{"pc"}, r.out); rc != 0 || len(r.d.Store.Names()) != 0 {
		t.Fatalf("rc %d %v", rc, r.d.Store.Names())
	}
	if !strings.Contains(r.o.String(), "took cg's key off it") || !strings.Contains(r.o.String(), "forgot 'pc' - nothing else on the machine was changed") {
		t.Error(r.o.String())
	}
	var removal string
	for _, l := range r.r.Ran {
		if strings.Contains(l, "grep -vxF") {
			removal = l
		}
	}
	if !strings.Contains(removal, "ssh-ed25519 AAAAC3Nza cg@testbox") {
		t.Errorf("only cg's own line comes off: %q", removal)
	}
	if rc := r.d.Remove(ctx, []string{"nope"}, r.out); rc != 1 || !strings.Contains(r.e.String(), "usage: cg host remove <name>") {
		t.Error(r.e.String())
	}
	// A machine that cannot be reached is still forgotten, with the line said to stay.
	r = newRig(t, "", true)
	_ = r.d.Add(ctx, []string{"pc", "--ssh", "me@pc"}, r.out)
	r.r.Hook = nil
	r.r.Failing = map[string]bool{"ssh": true}
	r.o.Reset()
	if rc := r.d.Remove(ctx, []string{"pc"}, r.out); rc != 0 || !strings.Contains(r.o.String(), "that one line stays in its ~/.ssh/authorized_keys") || len(r.d.Store.Names()) != 0 {
		t.Errorf("rc %d\n%s", rc, r.o)
	}
}

// sunshineServer takes one login and answers the welcome page.
func sunshineServer(t *testing.T, user, pass string) sunshine.Client {
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/clients/list" {
			u, p, ok := r.BasicAuth()
			if !ok || u != user || p != pass {
				w.WriteHeader(401)
				return
			}
		}
		w.WriteHeader(200)
	}))
	t.Cleanup(s.Close)
	return sunshine.Client{HTTP: s.Client(), URL: func(ip, path string) string { return s.URL + path }}
}

func TestStatusReadsEveryFactAndSharesTheLoginThatWorks(t *testing.T) {
	r := newRig(t, "", true)
	ctx := context.Background()
	_ = r.d.Add(ctx, []string{"pc", "--ssh", "me@pc"}, r.out)
	_ = r.d.Store.Set("pc", "ts_ip", "100.64.0.9", "ready", "yes", "sunshine_user", "admin", "sunshine_pass", "good-pw")
	r.d.Sun = sunshineServer(t, "admin", "good-pw")
	r.r.Answers = map[string]string{"moonlight list 100.64.0.9": "Desktop\nSteam\n"}
	s := r.d.Read(ctx, "pc")
	if !s.Reachable || !s.Online || !s.Sunshine || !s.LoginOK || !s.Paired || !s.SetUp || s.Steam == nil || !*s.Steam || *s.GPU != "RTX 3060" || *s.Desktop != "x11" {
		t.Errorf("%+v", s)
	}
	// This device holds the working login and the machine does not: it is kept there.
	var shared string
	for line, in := range r.r.Stdin {
		if strings.Contains(line, "sunshine-login.new") {
			shared = in
		}
	}
	if shared != "admin\ngood-pw\n" {
		t.Errorf("shared %q", shared)
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "good-pw") {
			t.Errorf("password on a command line: %s", l)
		}
	}
}

func TestStatusTakesTheMachinesLoginWhenOursIsStale(t *testing.T) {
	r := newRig(t, "", true)
	ctx := context.Background()
	_ = r.d.Add(ctx, []string{"pc", "--ssh", "me@pc"}, r.out)
	_ = r.d.Store.Set("pc", "ts_ip", "100.64.0.9", "sunshine_user", "admin", "sunshine_pass", "stale")
	r.d.Sun = sunshineServer(t, "admin", "fresh")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.HasSuffix(line, "sh -s") {
			return true, linuxFacts + "sunlogin=" + base64.StdEncoding.EncodeToString([]byte("admin\nfresh\n")) + "\n", nil
		}
		return prev(line)
	}
	s := r.d.Read(ctx, "pc")
	if !s.LoginOK || r.d.Store.Get("pc").Field("sunshine_pass") != "fresh" {
		t.Errorf("%+v %v", s, r.d.Store.Get("pc"))
	}
}

func TestStatusForAMachineThatIsOff(t *testing.T) {
	r := newRig(t, "", true)
	ctx := context.Background()
	_ = r.d.Add(ctx, []string{"pc", "--ssh", "me@pc"}, r.out)
	_ = r.d.Store.Set("pc", "ts_ip", "100.64.0.9")
	r.d.Sun = sunshine.Client{URL: func(ip, path string) string { return "https://127.0.0.1:1" + path }}
	r.r.Hook = nil
	r.r.Failing = map[string]bool{"ssh": true, "tailscale": true}
	r.o.Reset()
	if rc := r.d.Status(ctx, []string{"pc"}, false, r.out); rc != 0 {
		t.Fatal(r.e)
	}
	want := "  pc me@pc (Linux)\n  ✗ ssh\n  ✗ on the tailnet at 100.64.0.9\n  ✗ Sunshine\n  ✗ Sunshine login\n  ✗ paired with Moonlight\n"
	if r.o.String() != want {
		t.Errorf("got:\n%s", r.o)
	}
	r.o.Reset()
	if r.d.Status(ctx, []string{"pc", "--json"}, true, r.out) != 0 || !strings.Contains(r.o.String(), `"steam": null`) || !strings.Contains(r.o.String(), `"reachable": false`) {
		t.Errorf("an unreachable machine's steam is unknown, not false:\n%s", r.o)
	}
	if rc := r.d.Status(ctx, []string{"nope"}, false, r.out); rc != 1 || !strings.Contains(r.e.String(), "no machine called 'nope'") {
		t.Error(r.e.String())
	}
}
