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
