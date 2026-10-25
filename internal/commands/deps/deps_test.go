package deps

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

func lap(tty bool, has ...string) (laptop.Laptop, *fx.Runner) {
	r := &fx.Runner{Installed: map[string]bool{}, Answers: map[string]string{}, Failing: map[string]bool{}}
	for _, h := range has {
		r.Installed[h] = true
	}
	return laptop.Laptop{Runner: r, Getenv: func(string) string { return "" }, TTY: func() bool { return tty }}, r
}

func outs() (*output.Out, *bytes.Buffer, *bytes.Buffer) {
	var o, e bytes.Buffer
	return &output.Out{Stdout: &o, Stderr: &e}, &o, &e
}

func TestWhatIsMissing(t *testing.T) {
	l, _ := lap(true, "ssh", "tailscale", "pacman")
	if got := strings.Join(l.Missing(), ","); got != "ssh,moonlight" {
		t.Errorf("OpenSSH without scp counts as absent, and moonlight is missing: %s", got)
	}
	l, _ = lap(true, "ssh", "scp", "tailscale", "moonlight")
	if len(l.Missing()) != 0 {
		t.Errorf("%v", l.Missing())
	}
}

func TestJSONShape(t *testing.T) {
	l, _ := lap(false, "ssh", "scp", "tailscale", "pacman")
	b, err := JSON(Read(context.Background(), l))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	tools := m["tools"].([]any)
	if len(tools) != 3 {
		t.Fatalf("the Go cg needs ssh, tailscale and moonlight - not python3, curl or the AWS CLI: %v", tools)
	}
	mo := tools[2].(map[string]any)
	if mo["tool"] != "moonlight" || mo["present"] != false || mo["plan"] != "sudo pacman -S moonlight-qt" || mo["for"] != "all" {
		t.Errorf("%v", mo)
	}
	if m["package_manager"] != "pacman" || m["tailscale_signed_in"] != true {
		t.Errorf("%v", m)
	}
	// No terminal and no polkit: the app is told an Install button can do nothing.
	if m["root"] != nil || !strings.Contains(m["root_blocked"].(string), "polkit (pkexec) is not installed") {
		t.Errorf("root %v blocked %v", m["root"], m["root_blocked"])
	}
}

func TestRoot(t *testing.T) {
	l, _ := lap(true)
	if m, _ := l.Root(); m != "sudo" {
		t.Errorf("a terminal has sudo: %s", m)
	}
	l, _ = lap(false, "pkexec")
	l.Getenv = func(k string) string {
		if k == "WAYLAND_DISPLAY" {
			return "wayland-1"
		}
		return ""
	}
	if m, _ := l.Root(); m != "pkexec" {
		t.Errorf("polkit on a desktop: %s", m)
	}
	l.Getenv = func(string) string { return "" }
	if m, why := l.Root(); m != "" || !strings.Contains(why, "no desktop session") {
		t.Errorf("%s %s", m, why)
	}
}

func TestInstalledButNotSignedInIsItsOwnState(t *testing.T) {
	l, r := lap(true, "ssh", "scp", "tailscale", "moonlight")
	r.Failing["tailscale"] = true
	s := Read(context.Background(), l)
	if s.TailscaleSignedIn == nil || *s.TailscaleSignedIn {
		t.Error("installed but not signed in is false, not null")
	}
	out, o, _ := outs()
	if ready := Report(context.Background(), l, out, false); ready {
		t.Error("not ready")
	}
	for _, want := range []string{"installed: OpenSSH (ssh, scp), Tailscale, Moonlight", "Tailscale is installed but not signed in, or not running",
		"cg check --fix installs and signs in what is missing, after asking"} {
		if !strings.Contains(o.String(), want) {
			t.Errorf("lacks %q:\n%s", want, o.String())
		}
	}
	l, _ = lap(true, "ssh", "scp", "moonlight")
	if s := Read(context.Background(), l); s.TailscaleSignedIn != nil {
		t.Error("no tailscale: null")
	}
}

func TestReportAfterFixSendsYouToDoItByHand(t *testing.T) {
	l, _ := lap(true, "pacman")
	out, o, _ := outs()
	if Report(context.Background(), l, out, true) {
		t.Error("not ready")
	}
	for _, want := range []string{"missing: OpenSSH (ssh, scp)", "install it yourself: your distro's OpenSSH client package",
		"missing: Moonlight", "install it yourself: https://github.com/moonlight-stream/moonlight-qt/releases"} {
		if !strings.Contains(o.String(), want) {
			t.Errorf("lacks %q:\n%s", want, o.String())
		}
	}
	if strings.Contains(o.String(), "cg check --fix installs") {
		t.Error("suggesting --fix again would only send you round in a loop")
	}
}

func TestRun(t *testing.T) {
	l, _ := lap(true, "ssh", "scp", "tailscale", "moonlight")
	out, o, _ := outs()
	if rc := Run(context.Background(), l, []string{"--json"}, false, out); rc != 0 || !strings.HasPrefix(o.String(), "{") {
		t.Errorf("rc %d %q", rc, o.String())
	}
	out, _, e := outs()
	if rc := Run(context.Background(), l, []string{"bogus"}, false, out); rc != 1 || !strings.Contains(e.String(), "usage: setup deps") {
		t.Errorf("rc %d %q", rc, e.String())
	}
	out, _, _ = outs()
	if rc := Run(context.Background(), l, nil, false, out); rc != 0 {
		t.Errorf("ready is 0, got %d", rc)
	}
}
