package build

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

type exit127 struct{}

func (exit127) Error() string { return "exit status 127" }
func (exit127) ExitCode() int { return 127 }

// A box whose supervisor keeps a numbered record. Until it exists, the command is
// not found, as on a box in its first minutes; before that only the log is there.
type evRemote struct {
	log        []string
	events     []event
	supervisor int // the polls after which cg-build exists (1: from the start)
	polls      int
	ready      bool
	dropAt     int // this poll's connection fails
}

func (r *evRemote) SSH(_ context.Context, cmd string) ([]byte, error) {
	switch {
	case strings.HasPrefix(cmd, "cg-build events --since "):
		r.polls++
		if r.dropAt > 0 && r.polls == r.dropAt {
			return nil, errors.New("connection reset")
		}
		if r.polls < r.supervisor {
			return nil, exit127{}
		}
		var since int
		_, _ = fmt.Sscanf(cmd, "cg-build events --since %d", &since)
		var b strings.Builder
		for _, e := range r.events {
			if e.Seq > since {
				j, _ := json.Marshal(e)
				b.Write(j)
				b.WriteString("\n")
			}
		}
		return []byte(b.String()), nil
	case strings.HasPrefix(cmd, "tail -n +"):
		var n int
		_, _ = fmtSscan(cmd, &n)
		if n-1 >= len(r.log) {
			return nil, nil
		}
		return []byte(strings.Join(r.log[n-1:], "\n") + "\n"), nil
	case cmd == "test -f /var/lib/cloud-gaming-ready":
		if r.ready {
			return nil, nil
		}
		return nil, errors.New("exit 1")
	case strings.HasPrefix(cmd, "tail -n 8"):
		return []byte("last line one\nlast line two\n"), nil
	}
	return nil, nil
}

func evFollower(r *evRemote) (Follower, *[]string, *[]string, *[]string) {
	var logs, parts, done []string
	f := Follower{R: r, Supervised: true, Target: "me@pc", Sleep: func(time.Duration) {},
		Log: func(s string) { logs = append(logs, s) }, Part: func(id string) { parts = append(parts, id) },
		PartDone: func(id string) { done = append(done, id) }}
	return f, &logs, &parts, &done
}

func ev(seq int, kind, stage, text string) event {
	return event{Seq: seq, Kind: kind, Stage: stage, Text: text}
}

func TestTheSupervisorsRecordIsShownOnceAndInOrder(t *testing.T) {
	r := &evRemote{supervisor: 1, ready: true, events: []event{
		ev(1, "marker", "nvidia", "installing nvidia driver"), ev(2, "ok", "nvidia", "nvidia driver 610 or newer installed"),
		ev(3, "done", "nvidia", ""), ev(4, "marker", "desktop", "installing desktop (several minutes)"),
		ev(5, "done", "scratch", ""), ev(6, "summary", "", "where the time went: nvidia 160s"),
	}}
	f, logs, parts, done := evFollower(r)
	if err := f.Stream(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(*logs, "|")
	for _, want := range []string{"installing nvidia driver", "  ok  nvidia driver 610 or newer installed", "installing desktop (several minutes)", "where the time went: nvidia 160s", "build complete"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in %s", want, got)
		}
	}
	if strings.Count(got, "installing nvidia driver") != 1 {
		t.Errorf("each line once: %s", got)
	}
	if strings.Join(*parts, ",") != "nvidia,desktop" {
		t.Errorf("the pieces that started: %v", *parts)
	}
	if strings.Join(*done, ",") != "nvidia,disk" {
		t.Errorf("the pieces that finished (a stage's name is not its piece's): %v", *done)
	}
}

func TestBeforeTheSupervisorExistsTheLogIsRead(t *testing.T) {
	r := &evRemote{supervisor: 3, log: []string{">>> installing tailscale", ">>> starting the build supervisor"},
		events: []event{ev(1, "marker", "base", "installing base packages")}}
	f, logs, _, _ := evFollower(r)
	r.ready = false
	calls := 0
	f.Sleep = func(time.Duration) {
		calls++
		if calls >= 4 {
			r.ready = true
		}
	}
	if err := f.Stream(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(*logs, "|")
	if !strings.Contains(got, "installing tailscale") || !strings.Contains(got, "starting the build supervisor") || !strings.Contains(got, "installing base packages") {
		t.Errorf("the log first, then the record: %s", got)
	}
	if strings.Count(got, "installing tailscale") != 1 {
		t.Errorf("not read twice: %s", got)
	}
}

func TestADroppedConnectionLosesNothingAndRepeatsNothing(t *testing.T) {
	r := &evRemote{supervisor: 1, dropAt: 2, events: []event{ev(1, "marker", "a", "first"), ev(2, "marker", "b", "second")}}
	f, logs, _, _ := evFollower(r)
	n := 0
	f.Sleep = func(time.Duration) {
		n++
		if n == 1 {
			r.events = append(r.events, ev(3, "marker", "c", "third"))
		}
		if n >= 4 {
			r.ready = true
		}
	}
	if err := f.Stream(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(*logs, "|"); !strings.Contains(got, "first|second|third") || strings.Count(got, "first") != 1 {
		t.Errorf("%s", got)
	}
}

func TestAFailedStageIsSaidWithItsLogAndTheBuildStops(t *testing.T) {
	r := &evRemote{supervisor: 1, events: []event{
		ev(1, "marker", "desktop", "installing desktop (several minutes)"),
		{Seq: 2, Kind: "retry", Stage: "desktop", Text: "exited with 100"},
		{Seq: 3, Kind: "fail", Stage: "desktop", Text: "exited with 100", Tail: "E: Unable to locate package xfce4\nE: done"},
		{Seq: 4, Kind: "blocked", Stage: "autologin", Text: "waits on desktop, which did not finish"},
		{Seq: 5, Kind: "failed", Text: "failed: desktop; not run: autologin, finish"},
	}}
	f, logs, _, _ := evFollower(r)
	if err := f.Stream(context.Background()); !errors.Is(err, ErrStopped) {
		t.Fatalf("%v", err)
	}
	got := strings.Join(*logs, "|")
	for _, want := range []string{"desktop did not finish (exited with 100) - trying again", "FAILED: desktop exited with 100", "E: Unable to locate package xfce4",
		"autologin was not run: it waits on desktop", "the build STOPPED here: desktop exited with 100"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in %s", want, got)
		}
	}
}

func TestAMachineWithNoSupervisorIsReadAsAlways(t *testing.T) {
	r := &evRemote{supervisor: 1 << 30, log: []string{">>> installing base"}, ready: true}
	f, logs, _, _ := evFollower(r)
	if err := f.Stream(context.Background()); err != nil || !strings.Contains(strings.Join(*logs, "|"), "installing base") {
		t.Errorf("%v %v", err, *logs)
	}
}
