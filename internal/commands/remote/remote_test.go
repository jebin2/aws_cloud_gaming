package remote

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/output"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

const direct = `pong from gamevps (100.64.0.9) via 13.1.1.1:41641 in 28ms
pong from gamevps (100.64.0.9) via 13.1.1.1:41641 in 31ms
pong from gamevps (100.64.0.9) via 13.1.1.1:41641 in 29ms
pong from gamevps (100.64.0.9) via 13.1.1.1:41641 in 120ms
pong from gamevps (100.64.0.9) via 13.1.1.1:41641 in 30ms
`

const derp = `pong from gamevps (100.64.0.9) via DERP(blr) in 45ms
pong from gamevps (100.64.0.9) via DERP(blr) in 47ms
`

func newBox(answers map[string]string) (Box, *fx.Runner) {
	r := &fx.Runner{Installed: map[string]bool{"tailscale": true, "ssh": true},
		Answers: map[string]string{"tailscale ip -4 gamevps": "100.64.0.9\n"}, Contains: map[string]string{}}
	for k, v := range answers {
		r.Contains[k] = v
	}
	return Box{Runner: r, Host: "gamevps", Node: "gamevps", Home: "/h"}, r
}

func outs() (*output.Out, *bytes.Buffer, *bytes.Buffer) {
	var o, e bytes.Buffer
	return &output.Out{Stdout: &o, Stderr: &e}, &o, &e
}

func TestPathAndMedian(t *testing.T) {
	if Path(direct) != "direct" || MedianMS(direct) != 30 {
		t.Errorf("direct: %s %d", Path(direct), MedianMS(direct))
	}
	if !strings.HasPrefix(Path(derp), "DERP relay") || MedianMS(derp) != 45 {
		t.Errorf("derp: %s %d", Path(derp), MedianMS(derp))
	}
	// Direct wins when both are seen: a path that found the direct route is direct.
	if Path(derp+direct) != "direct" {
		t.Errorf("mixed: %s", Path(derp+direct))
	}
	if Path("") != "unknown" || MedianMS("") != -1 {
		t.Error("no reply")
	}
	// The lower median of an even count, as the awk took it.
	if MedianMS("in 10ms in 20ms in 30ms in 40ms") != 20 {
		t.Errorf("%d", MedianMS("in 10ms in 20ms in 30ms in 40ms"))
	}
}

func TestPingJSONAndReport(t *testing.T) {
	b, _ := newBox(map[string]string{"ping -c 5": direct})
	out, o, _ := outs()
	if rc := b.Ping(context.Background(), true, false, o, out); rc != 0 {
		t.Fatal(rc)
	}
	if o.String() != `{"node":"gamevps","path":"direct","median_ms":30}`+"\n" {
		t.Errorf("%q", o.String())
	}
	b, _ = newBox(map[string]string{"ping -c 5": derp})
	out, o, _ = outs()
	b.Ping(context.Background(), false, false, o, out)
	for _, want := range []string{"\n  node    gamevps (100.64.0.9)\n", "  path    DERP relay (slower - UDP 41641 may be blocked)\n",
		"  latency 45ms median\n", "Check the security group still allows inbound UDP 41641."} {
		if !strings.Contains(o.String(), want) {
			t.Errorf("lacks %q:\n%s", want, o.String())
		}
	}
	// No reply is null, never zero.
	b, r := newBox(map[string]string{"ping -c 5": ""})
	r.Failing = map[string]bool{"tailscale ping -c 5 --timeout 3s gamevps": true}
	out, o, _ = outs()
	b.Ping(context.Background(), true, false, o, out)
	if !strings.Contains(o.String(), `"path":"unknown","median_ms":null`) {
		t.Errorf("%q", o.String())
	}
	out, o, _ = outs()
	b.Ping(context.Background(), false, false, o, out)
	if !strings.Contains(o.String(), "latency no reply") {
		t.Errorf("%q", o.String())
	}
}

func TestNotOnTheTailnet(t *testing.T) {
	b, r := newBox(nil)
	r.Failing = map[string]bool{"tailscale": true}
	out, _, e := outs()
	if rc := b.Ping(context.Background(), false, false, out.Stdout, out); rc != 1 {
		t.Errorf("rc %d", rc)
	}
	if !strings.Contains(e.String(), "'gamevps' is not on the tailnet. Is the box running? Try: cg status") {
		t.Errorf("%q", e.String())
	}
}

func TestLogCommandsAreTheBoxsOwn(t *testing.T) {
	for what, want := range map[string]string{
		"build":    "sudo tail -n 200 /var/log/cloud-gaming-bootstrap.log",
		"steam":    "tail -n 200 ~/steam-prewarm.log",
		"watchdog": "journalctl -t idle-watchdog -n 50 --no-pager",
		"disk":     "journalctl -t disk-monitor -n 50 --no-pager",
		"sunshine": "journalctl --user -u app-dev.lizardbyte.app.Sunshine -n 80 --no-pager",
	} {
		b, r := newBox(map[string]string{want: "the log\n"})
		out, o, _ := outs()
		if rc := b.Log(context.Background(), what, false, o, out); rc != 0 || o.String() != "the log\n" {
			t.Errorf("%s: rc %d out %q", what, rc, o.String())
		}
		if last := r.Ran[len(r.Ran)-1]; !strings.Contains(last, "ubuntu@100.64.0.9 "+want) || !strings.Contains(last, "BatchMode=yes") {
			t.Errorf("%s: ran %q", what, last)
		}
	}
	b, r := newBox(map[string]string{"-f": "follow\n"})
	out, o, _ := outs()
	b.Log(context.Background(), "watchdog", true, o, out)
	if !strings.Contains(r.Ran[len(r.Ran)-1], "journalctl -t idle-watchdog -f") {
		t.Errorf("%v", r.Ran)
	}
	out, _, e := outs()
	if rc := b.Log(context.Background(), "nope", false, out.Stdout, out); rc != 1 || !strings.Contains(e.String(), "usage: cg log [build|steam|watchdog|disk|sunshine] [--watch]") {
		t.Errorf("rc %d %q", rc, e.String())
	}
}

func TestSSH(t *testing.T) {
	b, r := newBox(nil)
	out, _, _ := outs()
	if rc := b.SSH(context.Background(), []string{"uptime"}, out); rc != 0 {
		t.Errorf("rc %d", rc)
	}
	if !strings.HasSuffix(r.Ran[len(r.Ran)-1], "ubuntu@100.64.0.9 uptime") {
		t.Errorf("%v", r.Ran)
	}
	b.SSH(context.Background(), nil, out)
	if got := r.Ran[len(r.Ran)-1]; got != "ssh -i /h/.ssh/gamevps.pem -o StrictHostKeyChecking=accept-new ubuntu@100.64.0.9" {
		t.Errorf("a shell: %q", got)
	}
	// The remote's exit status is cg's.
	r.Failing = map[string]bool{"ssh": true}
	if rc := b.SSH(context.Background(), []string{"false"}, out); rc != 255 {
		t.Errorf("rc %d", rc)
	}
}
