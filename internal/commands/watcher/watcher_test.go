package watcher

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/output"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

const host = "gamevps"

var now = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

func scenario(state, lifecycle string) *fx.Scenario {
	s := &fx.Scenario{Account: "123456789012", Budget: "57.0", Notifications: 2, ShutdownBehavior: "terminate",
		LogEvents: []fx.LogEvent{{At: now.Add(-5 * time.Minute), Msg: "cg-watchdog: box i-1 idle 4m\n"}},
		WD:        fx.WatchdogState{Installed: true, RuleState: "ENABLED"}}
	if state != "" {
		s.Instances = []fx.Instance{{ID: "i-1", State: state, Type: "g6.xlarge", Lifecycle: lifecycle, Name: host, RootVolume: "vol-r"}}
		s.Volumes = []fx.Volume{{ID: "vol-r", GB: 50, Instance: "i-1"}}
	}
	return s
}

func build(s *fx.Scenario, r *fx.Runner, instance string) *Watcher {
	reader := &wd.Reader{Lambda: fx.Lambda{S: s}, Events: fx.Events{S: s}, IAM: fx.RolePolicies{S: s}, Logs: fx.Logs{S: s},
		Now: func() time.Time { return now }, Host: host, Region: "ap-south-2", Source: []byte("x"),
		Settings: func(string) wd.Settings { return wd.Settings{Host: host} }}
	return &Watcher{EC2: fx.EC2{S: s}, Budgets: fx.Budgets{S: s}, STS: fx.STS{S: s}, Reader: reader, Runner: r,
		Host: host, Node: host, InstanceID: instance, Home: "/h", HostIdleLimit: 30, IdleMin: 30, StuckMin: 60, ExpiryDays: 14}
}

func reachable(active string) *fx.Runner {
	return &fx.Runner{Installed: map[string]bool{"tailscale": true, "ssh": true},
		Answers:  map[string]string{"tailscale ip -4 gamevps": "100.64.0.9\n"},
		Contains: map[string]string{"is-active": active + "\n", "journalctl": "idle 4m of 30\nstill here\n", "true": ""}}
}

func render(t *testing.T, w *Watcher, f Facts) string {
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e, Now: func() time.Time { return now }}
	w.Render(f, out)
	return o.String()
}

func jq(t *testing.T, w *Watcher, f Facts) map[string]any {
	b, err := w.JSON(f, now)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func guard(m map[string]any, i int) map[string]any { return m["guards"].([]any)[i].(map[string]any) }

func TestNoBox(t *testing.T) {
	w := build(scenario("", ""), &fx.Runner{}, "")
	f := w.Gather(context.Background())
	m := jq(t, w, f)
	if m["instance_state"] != "none" || guard(m, 1)["state"] != "no box" || guard(m, 1)["armed"] != nil {
		t.Errorf("%v", guard(m, 1))
	}
	if guard(m, 2)["armed"] != true || guard(m, 2)["state"] != "armed" || guard(m, 2)["last_decision"] != "box i-1 idle 4m" {
		t.Errorf("%v", guard(m, 2))
	}
	if guard(m, 2)["last_decision_age_s"] != 300.0 {
		t.Errorf("age %v", guard(m, 2)["last_decision_age_s"])
	}
	// Nothing is written down: the minutes are the settings' and the script's.
	if guard(m, 1)["idle_min"] != 30.0 || guard(m, 2)["idle_min"] != 30.0 || guard(m, 2)["stuck_min"] != 60.0 || guard(m, 2)["every_min"] != 5.0 {
		t.Errorf("%v %v", guard(m, 1), guard(m, 2))
	}
	if m["budget"].(map[string]any)["usd"] != 57.0 || m["budget"].(map[string]any)["alerts"] != 2.0 {
		t.Errorf("budget %v", m["budget"])
	}
	sa := m["shutdown_action"].(map[string]any)
	if sa["value"] != nil || sa["expected"] != nil || sa["ok"] != false {
		t.Errorf("shutdown %v", sa)
	}
	text := render(t, w, f)
	for _, want := range []string{"==> guards", "instance          none", "on-host watchdog  (box not reachable)",
		"cloud watchdog    ENABLED  (Lambda gamevps-cloud-watchdog, every 5 min)", "budget            57.0"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
}

func TestARunningSpotBoxWithTheRightShutdownAction(t *testing.T) {
	s := scenario("running", "spot")
	w := build(s, reachable("active"), "i-1")
	f := w.Gather(context.Background())
	m := jq(t, w, f)
	if guard(m, 1)["armed"] != true || guard(m, 1)["state"] != "armed" {
		t.Errorf("%v", guard(m, 1))
	}
	sa := m["shutdown_action"].(map[string]any)
	if sa["value"] != "terminate" || sa["expected"] != "terminate" || sa["ok"] != true {
		t.Errorf("a spot box terminates: %v", sa)
	}
	text := render(t, w, f)
	for _, want := range []string{"instance          running", "on-host watchdog  active",
		"shutdown action   terminate  <- must be 'terminate' (ok)", "      idle 4m of 30\n      still here\n"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
}

// What it MUST be depends on the purchase model; a correct setting must not be
// flagged as an error.
func TestOnDemandMustStopAndTheWrongOneIsFlagged(t *testing.T) {
	s := scenario("running", "")
	s.ShutdownBehavior = "stop"
	w := build(s, reachable("active"), "i-1")
	f := w.Gather(context.Background())
	if f.Want != "stop" || !strings.Contains(render(t, w, f), "must be 'stop' (ok)") {
		t.Errorf("on demand stops: %+v", f)
	}
	s.ShutdownBehavior = "terminate"
	f = w.Gather(context.Background())
	text := render(t, w, f)
	if !strings.Contains(text, "must be 'stop' (WRONG)") {
		t.Errorf("a wrong action must say so:\n%s", text)
	}
	if jq(t, w, f)["shutdown_action"].(map[string]any)["ok"] != false {
		t.Error("ok must be false")
	}
}

func TestAnInactiveOnHostWatchdogIsNotArmed(t *testing.T) {
	w := build(scenario("running", "spot"), reachable("inactive"), "i-1")
	f := w.Gather(context.Background())
	g := guard(jq(t, w, f), 1)
	if g["armed"] != false || g["state"] != "not armed" || g["note"] != "inactive" {
		t.Errorf("%v", g)
	}
	if !strings.Contains(render(t, w, f), "on-host watchdog  inactive") {
		t.Error("the row must say it")
	}
}

func TestRunningButUnreachable(t *testing.T) {
	r := &fx.Runner{Installed: map[string]bool{"tailscale": true, "ssh": true},
		Answers: map[string]string{"tailscale ip -4 gamevps": "100.64.0.9\n"}, Failing: map[string]bool{"ssh": true}}
	w := build(scenario("running", "spot"), r, "i-1")
	f := w.Gather(context.Background())
	g := guard(jq(t, w, f), 1)
	if g["state"] != "box not reachable" || g["armed"] != nil {
		t.Errorf("%v", g)
	}
	if !strings.Contains(render(t, w, f), "on-host watchdog  (box not reachable)") {
		t.Error("the row must say it")
	}
}

func TestAnAWSFailureIsUnknownNotNone(t *testing.T) {
	s := scenario("running", "spot")
	s.Fail = map[string]bool{"DescribeInstances": true}
	w := build(s, &fx.Runner{}, "i-1")
	f := w.Gather(context.Background())
	if f.State != "unknown" {
		t.Errorf("state %q", f.State)
	}
	if guard(jq(t, w, f), 1)["state"] != "box not reachable" {
		t.Error("an unknown box is not a missing one")
	}
}

func TestNoWatchdogAndNoBudget(t *testing.T) {
	s := scenario("", "")
	s.WD = fx.WatchdogState{NoLogGroup: true}
	s.Budget = ""
	w := build(s, &fx.Runner{}, "")
	f := w.Gather(context.Background())
	m := jq(t, w, f)
	if guard(m, 2)["armed"] != false || guard(m, 2)["state"] != "not installed" || m["budget"].(map[string]any)["usd"] != nil {
		t.Errorf("%v %v", guard(m, 2), m["budget"])
	}
	text := render(t, w, f)
	if !strings.Contains(text, "cloud watchdog    not installed") || !strings.Contains(text, "budget            absent") {
		t.Errorf("%s", text)
	}
}

func TestHostIdleLimitIsReadFromItsOwnScript(t *testing.T) {
	if got := HostIdleLimit([]byte("#!/bin/bash\nIDLE_LIMIT=\"${IDLE_LIMIT:-45}\"  # minutes\n")); got != 45 {
		t.Errorf("got %d", got)
	}
	if HostIdleLimit([]byte("nothing")) != 0 {
		t.Error("unreadable is zero")
	}
}
