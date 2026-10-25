package config

import (
	"os"
	"path/filepath"
	"testing"
)

func lookup(m map[string]string) Lookup {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestResolveOrder(t *testing.T) {
	repo := t.TempDir()
	xdg := t.TempDir()
	base := map[string]string{"XDG_CONFIG_HOME": xdg, "HOME": "/h"}
	if got, want := Resolve(lookup(map[string]string{"CG_ENV_FILE": "/x/e", "CG_HOME": "/y", "XDG_CONFIG_HOME": xdg}), repo), "/x/e"; got != want {
		t.Errorf("CG_ENV_FILE: %s", got)
	}
	if got, want := Resolve(lookup(map[string]string{"CG_HOME": "/y"}), repo), "/y/.env"; got != want {
		t.Errorf("CG_HOME: %s", got)
	}
	if got, want := Resolve(lookup(base), repo), filepath.Join(repo, ".env"); got != want {
		t.Errorf("a writable checkout: %s", got)
	}
	ro := filepath.Join(t.TempDir(), "missing")
	if got, want := Resolve(lookup(base), ro), filepath.Join(xdg, "cg", ".env"); got != want {
		t.Errorf("an installed copy: %s", got)
	}
}

func TestLoadReadsButNeverExecutes(t *testing.T) {
	f := filepath.Join(t.TempDir(), ".env")
	body := "# a comment\nGAME_REGION=ap-south-1\ngamevps\n  # indented comment\nGAME_TS_HOST=box=1\n$(touch /tmp/x)\nGAME_S3_BUCKET=b"
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	e := Load(lookup(map[string]string{"CG_ENV_FILE": f, "GAME_REGION": ""}), "")
	if e.Region() != "ap-south-1" {
		t.Errorf("region %q", e.Region())
	}
	if e.Host() != "box=1" {
		t.Errorf("a value keeps everything after the first =, got %q", e.Host())
	}
	if e.Get("GAME_S3_BUCKET") != "b" {
		t.Error("a last line with no newline was ignored")
	}
}

func TestExportedWinsAndDefaultsBackStop(t *testing.T) {
	f := filepath.Join(t.TempDir(), ".env")
	_ = os.WriteFile(f, []byte("GAME_REGION=ap-south-1\n"), 0o600)
	e := Load(lookup(map[string]string{"CG_ENV_FILE": f, "GAME_REGION": "eu-west-1"}), "")
	if e.Region() != "eu-west-1" {
		t.Errorf("an exported value must beat the file, got %q", e.Region())
	}
	e = Load(lookup(map[string]string{"CG_ENV_FILE": filepath.Join(t.TempDir(), "none")}), "")
	if e.Region() != "ap-south-2" || e.Host() != "gamevps" {
		t.Errorf("defaults: %q %q", e.Region(), e.Host())
	}
}

func TestValidate(t *testing.T) {
	for _, c := range []struct{ key, val, want string }{
		{"GAME_DISK_GB", "50", ""},
		{"GAME_DISK_GB", "29", "must be at least 30"},
		{"GAME_DISK_GB", "five", "must be a whole number"},
		{"GAME_ARCHIVE_EXPIRY_DAYS", "0", ""},
		{"GAME_SPOT", "auto", ""},
		{"GAME_SPOT", "maybe", "must be one of: auto, 1, 0"},
		{"TAILSCALE_API_KEY", "", ""},
		{"TAILSCALE_API_KEY", "nope", "does not look like a Tailscale token"},
		{"TAILSCALE_API_KEY", "tskey-api-abc123", ""},
		{"GAME_NTFY_URL", "my-topic", ""},
		{"GAME_NTFY_URL", "not a url", "not a valid ntfy topic or URL"},
		{"EMAIL_ALERTS", "a@b.co", ""},
		{"EMAIL_ALERTS", "ab", "does not look like an email address"},
		{"GAME_REGION", "ap-south-1", ""},
		{"GAME_REGION", "mumbai", "does not look like an AWS region, e.g. ap-south-1"},
		{"GAME_RES", "", "cannot be empty"},
		{"NOT_A_KEY", "x", "unknown setting 'NOT_A_KEY'"},
		{"GAME_RES", "a\nb", "a setting cannot contain a newline"},
	} {
		if got := Validate(c.key, c.val); got != c.want {
			t.Errorf("%s=%q: got %q want %q", c.key, c.val, got, c.want)
		}
	}
}

func TestIntFloorsAndDefaults(t *testing.T) {
	f := filepath.Join(t.TempDir(), ".env")
	_ = os.WriteFile(f, []byte("GAME_WATCHDOG_IDLE_MIN=3\nGAME_ARCHIVE_EXPIRY_DAYS=oops\n"), 0o600)
	e := Load(lookup(map[string]string{"CG_ENV_FILE": f}), "")
	if e.Int("GAME_WATCHDOG_IDLE_MIN") != 10 {
		t.Errorf("under the floor: %d", e.Int("GAME_WATCHDOG_IDLE_MIN"))
	}
	if e.Int("GAME_ARCHIVE_EXPIRY_DAYS") != 14 {
		t.Errorf("not a number falls back to the default: %d", e.Int("GAME_ARCHIVE_EXPIRY_DAYS"))
	}
	if e.Setting("GAME_DISK_GB") != "50" {
		t.Errorf("registry default: %q", e.Setting("GAME_DISK_GB"))
	}
}
