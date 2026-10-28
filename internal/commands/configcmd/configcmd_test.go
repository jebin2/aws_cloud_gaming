package configcmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// The cases of tests/config.sh.

func setup(t *testing.T) (*config.Env, string, *output.Out, *bytes.Buffer, *bytes.Buffer) {
	f := filepath.Join(t.TempDir(), ".env")
	_ = os.WriteFile(f, []byte("GAME_DISK_GB=80\nGAME_NTFY_URL=https://ntfy.sh/topic-abc\n"), 0o600)
	env := config.Load(func(k string) (string, bool) {
		if k == "CG_ENV_FILE" {
			return f, true
		}
		return "", false
	}, "")
	var o, e bytes.Buffer
	return env, f, &output.Out{Stdout: &o, Stderr: &e}, &o, &e
}

func rows(t *testing.T, env *config.Env) map[string]Row {
	b, err := JSON(env)
	if err != nil {
		t.Fatal(err)
	}
	var list []Row
	if err := json.Unmarshal(b, &list); err != nil {
		t.Fatal(err)
	}
	m := map[string]Row{}
	for _, r := range list {
		m[r.Key] = r
	}
	return m
}

func str(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

func TestTheRegistryAsData(t *testing.T) {
	env, _, _, _, _ := setup(t)
	b, _ := JSON(env)
	var list []Row
	_ = json.Unmarshal(b, &list)
	var keys []string
	for _, r := range list {
		keys = append(keys, r.Key)
	}
	// The KEYS, not a count: a count says the same for one added and one silently dropped.
	want := "GAME_DISK_GB GAME_DISK_RESERVE_GB GAME_ARCHIVE_EXPIRY_DAYS GAME_INSTANCE_TYPE GAME_REGION GAME_SPOT GAME_STEAM_LOGIN GAME_BUDGET_INR GAME_WATCHDOG_IDLE_MIN GAME_WATCHDOG_STUCK_MIN GAME_NTFY_URL TAILSCALE_API_KEY EMAIL_ALERTS GAME_RES GAME_FPS GAME_BITRATE_KBPS"
	if got := strings.Join(keys, " "); got != want {
		t.Errorf("settings: %s", got)
	}
	r := rows(t, env)
	if str(r["GAME_DISK_GB"].Value) != "80" || str(r["GAME_DISK_GB"].Default) != "50" || str(r["GAME_DISK_GB"].Rule) != "30" {
		t.Errorf("%+v", r["GAME_DISK_GB"])
	}
	if e := r["GAME_ARCHIVE_EXPIRY_DAYS"]; str(e.Effective) != "14" || e.IsSet || e.Mentioned {
		t.Errorf("an unset one falls back and is marked unset: %+v", e)
	}
}

func TestSecretsAreNeverHandedOut(t *testing.T) {
	env, _, _, _, _ := setup(t)
	_ = env.Set("TAILSCALE_API_KEY", "tskey-api-abc123")
	r := rows(t, env)
	if n := r["GAME_NTFY_URL"]; !n.IsSet || !strings.Contains(str(n.Value), "topic-abc") || n.Secret {
		t.Errorf("the ntfy topic is shown on purpose: %+v", n)
	}
	if k := r["TAILSCALE_API_KEY"]; !k.Secret || k.Value != nil || k.Effective != nil || !k.IsSet {
		t.Errorf("the token is withheld: %+v", k)
	}
	b, _ := JSON(env)
	if strings.Contains(string(b), "tskey-api-abc123") {
		t.Error("the token is in the JSON")
	}
	if r["TAILSCALE_API_KEY"].Group != nil || r["GAME_DISK_GB"].Group == nil || r["GAME_DISK_GB"].Label == "" {
		t.Error("a card of its own has no group; the rest have a group and a label")
	}
}

func TestSetEnforcesTheRules(t *testing.T) {
	env, f, out, _, e := setup(t)
	file := func() string { b, _ := os.ReadFile(f); return string(b) }
	if err := Set(env, "GAME_DISK_GB", "120", out); err != nil || !strings.Contains(file(), "GAME_DISK_GB=120") {
		t.Fatalf("%v\n%s", err, file())
	}
	_ = e
	for _, c := range []struct{ key, val, why string }{
		{"GAME_DISK_GB", "12", "must be at least 30"},
		{"GAME_DISK_GB", "fifty", "must be a whole number"},
		{"GAME_SPOT", "maybe", "must be one of: auto, 1, 0"},
		{"GAME_NOT_A_SETTING", "1", "unknown setting"},
		{"TAILSCALE_API_KEY", "not-a-token", "does not look like a Tailscale token"},
		{"EMAIL_ALERTS", "nope", "does not look like an email"},
		{"GAME_NTFY_URL", "not a url!", "not a valid ntfy topic or URL"},
	} {
		err := Set(env, c.key, c.val, out)
		if err == nil || !strings.Contains(err.Error(), c.why) {
			t.Errorf("%s=%s: %v", c.key, c.val, err)
		}
	}
	if !strings.Contains(file(), "GAME_DISK_GB=120") {
		t.Errorf("a refused value must keep the old one:\n%s", file())
	}
	if err := Set(env, "GAME_ARCHIVE_EXPIRY_DAYS", "0", out); err != nil || !strings.Contains(file(), "GAME_ARCHIVE_EXPIRY_DAYS=0") {
		t.Errorf("0 days is allowed - keep forever: %v", err)
	}
}

func TestSettingASecretSaysNothingAboutIt(t *testing.T) {
	env, f, out, _, errb := setup(t)
	if err := Set(env, "TAILSCALE_API_KEY", "tskey-api-abc123", out); err != nil {
		t.Fatal(err)
	}
	said := errb.String() // events or plain, nothing on stdout
	_ = said
	var o, e bytes.Buffer
	jout := &output.Out{Stdout: &o, Stderr: &e, JSON: true}
	_ = Set(env, "TAILSCALE_API_KEY", "tskey-api-abc123", jout)
	if !strings.Contains(e.String(), "TAILSCALE_API_KEY = set") || strings.Contains(e.String(), "abc123") {
		t.Errorf("it confirms, without echoing the token: %s", e.String())
	}
	if b, _ := os.ReadFile(f); !strings.Contains(string(b), "TAILSCALE_API_KEY=tskey-api-abc123") {
		t.Error("and it is written")
	}
	e.Reset()
	_ = Set(env, "GAME_NTFY_URL", "", jout)
	if !strings.Contains(e.String(), "GAME_NTFY_URL = cleared") {
		t.Errorf("clearing: %s", e.String())
	}
	if b, _ := os.ReadFile(f); !strings.Contains(string(b), "GAME_NTFY_URL=\n") {
		t.Errorf("remembered as off: %s", b)
	}
	e.Reset()
	_ = Set(env, "GAME_DISK_GB", "90", jout)
	if !strings.Contains(e.String(), "applies to the next cg init") {
		t.Errorf("it says when it applies: %s", e.String())
	}
}

func TestGetIsTheOneWayToSeeASecret(t *testing.T) {
	env, _, out, _, _ := setup(t)
	_ = Set(env, "TAILSCALE_API_KEY", "tskey-api-abc123", out)
	if v, err := Get(env, "TAILSCALE_API_KEY"); err != nil || v != "tskey-api-abc123" {
		t.Errorf("%q %v", v, err)
	}
	if v, _ := Get(env, "GAME_DISK_GB"); v != "80" {
		t.Errorf("%q", v)
	}
	if _, err := Get(env, "GAME_NOPE"); err == nil || !strings.Contains(err.Error(), "unknown setting") {
		t.Errorf("%v", err)
	}
}

func TestTheHumanView(t *testing.T) {
	env, _, out, _, _ := setup(t)
	_ = Set(env, "TAILSCALE_API_KEY", "tskey-api-abc123", out)
	text := Show(env)
	for _, want := range []string{"SETTING", "GAME_DISK_GB", "Cannot be shrunk later", "GAME_BITRATE_KBPS",
		"  " + padRight("GAME_NTFY_URL", 28) + " " + padRight("set", 12)} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "topic-abc") {
		t.Error("the topic is a secret: the human view says only that it is set")
	}
	// The note ENDS there; the registry's other columns are not part of it.
	if strings.Contains(text, "applies to the next build.|") {
		t.Error("the registry's columns slid into the note")
	}
	if strings.Contains(text, "tskey-api-abc123") || !strings.Contains(text, "TAILSCALE_API_KEY            set ") {
		t.Errorf("secrets as set or not, never a value:\n%s", text)
	}
	// An unset one with no default is a dash, and every row is there to the last.
	if !strings.Contains(text, padRight("GAME_RES", 28)+" "+padRight("–", 12)) {
		t.Errorf("a dash:\n%s", text)
	}
	if !strings.Contains(text, "20 (default)") {
		t.Errorf("a default is marked:\n%s", text)
	}
}

func padRight(s string, n int) string {
	for len([]rune(s)) < n {
		s += " "
	}
	return s
}

func TestRun(t *testing.T) {
	env, _, out, o, e := setup(t)
	if rc := Run(env, []string{"get"}, false, out); rc != 1 || !strings.Contains(e.String(), "usage: cg config get <key>") {
		t.Errorf("rc %d %q", rc, e.String())
	}
	e.Reset()
	if rc := Run(env, []string{"bogus"}, false, out); rc != 1 || !strings.Contains(e.String(), "usage: cg config [show|--json|get <key>|set <key> [value]]") {
		t.Errorf("rc %d %q", rc, e.String())
	}
	o.Reset()
	if rc := Run(env, []string{"get", "GAME_DISK_GB"}, false, out); rc != 0 || o.String() != "80\n" {
		t.Errorf("rc %d %q", rc, o.String())
	}
	o.Reset()
	Run(env, nil, true, out)
	if !strings.HasPrefix(o.String(), "[") {
		t.Errorf("--json after the subcommand: %q", o.String())
	}
	o.Reset()
	Run(env, nil, false, out)
	if !strings.Contains(o.String(), "SETTING") {
		t.Errorf("bare config shows: %q", o.String())
	}
}
