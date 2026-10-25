package hostcmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/hosts"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

func store(t *testing.T, body string) hosts.Store {
	p := filepath.Join(t.TempDir(), "cg", "hosts.json")
	if body != "" {
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		_ = os.WriteFile(p, []byte(body), 0o600)
	}
	return hosts.Store{Path: p}
}

const two = `{"homeserver":{"ssh":"user@192.168.1.10","os":"linux","family":"debian","sunshine_pass":"hunter2"},"desk":{"ssh":"me@desk","os":"linux"}}`

func TestListNeverHandsOutAPassword(t *testing.T) {
	out := List(store(t, two), true)
	if strings.Contains(out, "hunter2") || strings.Contains(out, "sunshine_pass") {
		t.Errorf("a password in a list: %s", out)
	}
	var rows []map[string]any
	if err := json.Unmarshal([]byte(out), &rows); err != nil || len(rows) != 2 || rows[0]["name"] != "desk" || rows[1]["name"] != "homeserver" || rows[1]["ssh"] != "user@192.168.1.10" {
		t.Errorf("sorted by name, with the name inside: %v %s", err, out)
	}
	// Nothing yet is an empty list, not an error.
	if got := List(store(t, ""), true); got != "[]\n" {
		t.Errorf("%q", got)
	}
}

func TestListForAPerson(t *testing.T) {
	text := List(store(t, two), false)
	if text != "  desk             me@desk                      linux\n  homeserver       user@192.168.1.10            linux\n" {
		t.Errorf("%q", text)
	}
	if got := List(store(t, ""), false); !strings.Contains(got, "no machines of your own yet - add one: cg host add <name> --ssh <user@address>") {
		t.Errorf("%q", got)
	}
	// A file that is not JSON is no machines, not a crash.
	if got := List(store(t, "not json"), true); got != "[]\n" {
		t.Errorf("%q", got)
	}
}

func TestRun(t *testing.T) {
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	s := store(t, two)
	if rc := Run(s, nil, false, out); rc != 0 || !strings.Contains(o.String(), "homeserver") {
		t.Errorf("default is list: %d %q", rc, o.String())
	}
	o.Reset()
	if rc := Run(s, []string{"list", "--json"}, false, out); rc != 0 || !strings.HasPrefix(o.String(), "[") {
		t.Errorf("%q", o.String())
	}
	if rc := Run(s, []string{"remove", "x"}, false, out); rc != 1 || !strings.Contains(e.String(), "not ported") {
		t.Errorf("%q", e.String())
	}
	e.Reset()
	if rc := Run(s, []string{"bogus"}, false, out); rc != 1 || !strings.Contains(e.String(), "usage: cg host [list|add") {
		t.Errorf("%q", e.String())
	}
}
