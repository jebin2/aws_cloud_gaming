package creds

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

type rig struct {
	s    Setter
	dir  string
	said *bytes.Buffer
	env  *config.Env
}

// newRig answers the questions in order: each secret and each ask reads a line.
func newRig(t *testing.T, input string, verify func(id, secret string) (string, error), ts *httptest.Server) rig {
	dir := t.TempDir()
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	a := &ask.Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &bytes.Buffer{}, TTY: true}
	a.ReadSecret = func() (string, error) { s, err := a.In.ReadString('\n'); return strings.TrimRight(s, "\n"), err }
	env := config.Load(func(k string) (string, bool) { return "", false }, dir)
	s := Setter{Out: out, Ask: a, Env: env, Home: dir, Getenv: func(string) string { return "" },
		Verify: func(_ context.Context, id, secret, _ string) (string, error) { return verify(id, secret) },
		TS: func(token string) tskey.Client {
			c := tskey.Client{Token: token}
			if ts != nil {
				c.Base = ts.URL
			}
			return c
		}}
	return rig{s, dir, &o, env}
}

func TestAWSKeyIsCheckedBeforeItIsWritten(t *testing.T) {
	cred := func(r rig) string { b, _ := os.ReadFile(filepath.Join(r.dir, ".aws", "credentials")); return string(b) }
	r := newRig(t, fakeKey+"\nsecretvalue\n", func(id, secret string) (string, error) {
		if id != fakeKey || secret != "secretvalue" {
			t.Errorf("verified %q %q", id, secret)
		}
		return "123456789012", nil
	}, nil)
	if rc := r.s.SetAWS(context.Background(), "ap-south-1"); rc != 0 {
		t.Fatalf("rc %d: %s", rc, r.said)
	}
	if got := cred(r); got != "[default]\naws_access_key_id = "+fakeKey+"\naws_secret_access_key = secretvalue\n" {
		t.Errorf("credentials:\n%s", got)
	}
	cfg, _ := os.ReadFile(filepath.Join(r.dir, ".aws", "config"))
	if string(cfg) != "[default]\nregion = ap-south-1\n" {
		t.Errorf("config:\n%s", cfg)
	}
	st, _ := os.Stat(filepath.Join(r.dir, ".aws", "credentials"))
	if st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode())
	}
	if !strings.Contains(r.said.String(), "credentials work (account 123456789012)") || strings.Contains(r.said.String(), "secretvalue") {
		t.Errorf("said: %s", r.said)
	}

	// A key AWS refuses: the old one is untouched and the message says so.
	old := cred(r)
	r.s.Ask.In = bufio.NewReader(strings.NewReader("AKbad\nbadsecret\n"))
	r.s.Verify = func(context.Context, string, string, string) (string, error) {
		return "", errors.New("operation error STS: InvalidClientTokenId\n\tstatus 403")
	}
	if rc := r.s.SetAWS(context.Background(), "ap-south-1"); rc != 1 || cred(r) != old {
		t.Errorf("a refused key must change nothing: rc %d\n%s", rc, cred(r))
	}
	if !strings.Contains(r.said.String(), "AWS rejected that key: operation error STS: InvalidClientTokenId status 403") ||
		!strings.Contains(r.said.String(), "the key you had before is untouched") {
		t.Errorf("said: %s", r.said)
	}

	// Nothing typed: nothing asked of AWS.
	r.s.Ask.In = bufio.NewReader(strings.NewReader("\n\n"))
	r.s.Verify = func(context.Context, string, string, string) (string, error) {
		t.Error("nothing to check")
		return "", nil
	}
	if rc := r.s.SetAWS(context.Background(), ""); rc != 1 {
		t.Error("no key given is a failure")
	}
}

func TestAWSKeyKeepsEverythingElseInTheFiles(t *testing.T) {
	r := newRig(t, "AKnew\nnewsecret\n", func(string, string) (string, error) { return "1", nil }, nil)
	dir := filepath.Join(r.dir, ".aws")
	_ = os.MkdirAll(dir, 0o700)
	_ = os.WriteFile(filepath.Join(dir, "credentials"),
		[]byte("[default]\naws_access_key_id = AKold\naws_secret_access_key = oldsecret\naws_session_token = x\n\n[work]\naws_access_key_id = AKwork\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "config"), []byte("[default]\noutput = json\nregion = us-east-1\n\n[profile work]\nregion = eu-west-1\n"), 0o600)
	if r.s.SetAWS(context.Background(), "ap-south-1") != 0 {
		t.Fatal(r.said)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "credentials"))
	if string(b) != "[default]\naws_access_key_id = AKnew\naws_secret_access_key = newsecret\naws_session_token = x\n\n[work]\naws_access_key_id = AKwork\n" {
		t.Errorf("credentials:\n%s", b)
	}
	b, _ = os.ReadFile(filepath.Join(dir, "config"))
	if string(b) != "[default]\noutput = json\nregion = ap-south-1\n\n[profile work]\nregion = eu-west-1\n" {
		t.Errorf("config:\n%s", b)
	}
}

func TestAWSKeyForANamedProfile(t *testing.T) {
	dir := t.TempDir()
	f := AWSFiles{Credentials: filepath.Join(dir, "c"), Config: filepath.Join(dir, "cfg")}
	if err := WriteAWSKey(f, "game", "AKx", "s", "ap-south-1"); err != nil {
		t.Fatal(err)
	}
	c, _ := os.ReadFile(f.Credentials)
	g, _ := os.ReadFile(f.Config)
	if string(c) != "[game]\naws_access_key_id = AKx\naws_secret_access_key = s\n" || string(g) != "[profile game]\nregion = ap-south-1\n" {
		t.Errorf("%q %q", c, g)
	}
}

func TestSettingNeedsSomeoneToAsk(t *testing.T) {
	r := newRig(t, "", nil, nil)
	r.s.Ask.TTY = false
	if r.s.SetAWS(context.Background(), "x") != 1 || r.s.SetToken(context.Background()) != 1 || r.s.SetAuthKey(context.Background()) != 1 {
		t.Error("nobody to ask")
	}
}

// tailscale answers for one good token and the keys it knows.
func tailscale(t *testing.T) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tskey-api-abc123" {
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/tailnet/-/devices":
		case "/tailnet/-/keys/live":
			_, _ = w.Write([]byte(`{}`))
		case "/tailnet/-/keys/dead":
			_, _ = w.Write([]byte(`{"invalid":true}`))
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func TestTokenIsCheckedBeforeItIsKept(t *testing.T) {
	ts := tailscale(t)
	r := newRig(t, "tskey-api-wrong\ntskey-api-abc123\nnot-a-key\n", nil, ts)
	ctx := context.Background()
	if r.s.SetToken(ctx) != 1 || r.env.Get("TAILSCALE_API_KEY") != "" ||
		!strings.Contains(r.said.String(), "Tailscale rejected that token (401) - nothing was saved") {
		t.Errorf("rejected must save nothing: %s", r.said)
	}
	if r.s.SetToken(ctx) != 0 || r.env.Get("TAILSCALE_API_KEY") != "tskey-api-abc123" {
		t.Errorf("a good token is kept: %s", r.said)
	}
	b, _ := os.ReadFile(r.env.File)
	if !strings.Contains(string(b), "TAILSCALE_API_KEY=tskey-api-abc123") {
		t.Errorf("not in .env: %s", b)
	}
	if r.s.SetToken(ctx) != 1 || !strings.Contains(r.said.String(), "they start with tskey-") {
		t.Error("shape is checked first")
	}
	// Tailscale unreachable says nothing about the token.
	r2 := newRig(t, "tskey-api-abc123\n", nil, nil)
	r2.s.TS = func(token string) tskey.Client { return tskey.Client{Token: token, Base: "http://127.0.0.1:1"} }
	if r2.s.SetToken(ctx) != 1 || !strings.Contains(r2.said.String(), "could not reach api.tailscale.com (000) - nothing was saved") {
		t.Errorf("%s", r2.said)
	}
}

func TestAuthKeyIsCheckedWhenThereIsAToken(t *testing.T) {
	ts := tailscale(t)
	ctx := context.Background()
	r := newRig(t, "tskey-auth-dead-s\ntskey-auth-live-s\n", nil, ts)
	_ = r.env.Set("TAILSCALE_API_KEY", "tskey-api-abc123")
	if r.s.SetAuthKey(ctx) != 1 || r.env.Get("TAILSCALE_AUTH_KEY") != "" || !strings.Contains(r.said.String(), "expired or been revoked") {
		t.Errorf("%s", r.said)
	}
	if r.s.SetAuthKey(ctx) != 0 || r.env.Get("TAILSCALE_AUTH_KEY") != "tskey-auth-live-s" || !strings.Contains(r.said.String(), "the key works, and is saved") {
		t.Errorf("%s", r.said)
	}
	// With no token, the key is taken at its word and the message says so.
	r = newRig(t, "tskey-auth-any-s\n", nil, ts)
	if r.s.SetAuthKey(ctx) != 0 || !strings.Contains(r.said.String(), "there is no API token to check it with") {
		t.Errorf("%s", r.said)
	}
}

func TestSigninStartsTheDaemonAndFindsTheLink(t *testing.T) {
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	run := &fx.Runner{Installed: map[string]bool{"tailscale": true, "sh": true},
		Failing:  map[string]bool{"tailscale status": true},
		Contains: map[string]string{"tailscale up": "To authenticate, visit:\n\n\thttps://login.tailscale.com/a/abc123\n"}}
	l := laptop.Laptop{Runner: run, Getenv: func(string) string { return "" }, TTY: func() bool { return true },
		LookPath: func(n string) (string, error) { return "/usr/bin/" + n, nil }}
	if signin(context.Background(), l, out) != 1 {
		t.Error("still down after the command: not signed in")
	}
	got := o.String()
	for _, want := range []string{"sign in here: https://login.tailscale.com/a/abc123", "still not signed in"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	ran := strings.Join(run.Ran, "\n")
	if !strings.Contains(ran, "/usr/bin/sudo /usr/bin/tailscale up") {
		t.Errorf("ran:\n%s", ran)
	}

	// Already signed in: nothing is run as root.
	run2 := &fx.Runner{Installed: map[string]bool{"tailscale": true}}
	l.Runner = run2
	if signin(context.Background(), l, out) != 0 || len(run2.Ran) != 1 {
		t.Errorf("ran %v", run2.Ran)
	}

	// A daemon that will not start is said, with the whole sign-in to do by hand.
	o.Reset()
	l.Runner = &fx.Runner{Installed: map[string]bool{"tailscale": true, "systemctl": true, "sh": true},
		Failing: map[string]bool{"tailscale status": true, "systemctl is-active --quiet tailscaled": true}}
	if signin(context.Background(), l, out) != 1 || !strings.Contains(o.String(), "could not start tailscaled") ||
		strings.Contains(o.String(), "finishing the sign-in") {
		t.Errorf("%s", o.String())
	}

	// No terminal and no polkit: it says why instead of failing inside sudo.
	o.Reset()
	l = laptop.Laptop{Runner: &fx.Runner{Installed: map[string]bool{"tailscale": true}, Failing: map[string]bool{"tailscale": true}},
		Getenv: func(string) string { return "" }, TTY: func() bool { return false }}
	if signin(context.Background(), l, out) != 1 || !strings.Contains(o.String(), "no terminal, and polkit (pkexec) is not installed") {
		t.Errorf("%s", o.String())
	}
}

func TestRootLinesExplainAMissingPolkitAgent(t *testing.T) {
	lines := laptop.RootLines("Error executing command as another user: No authentication agent found.")
	if len(lines) != 3 || !strings.Contains(lines[1][1], "no polkit agent") {
		t.Errorf("%v", lines)
	}
	if laptop.RootLines("   ") != nil {
		t.Error("blank says nothing")
	}
}
