package boxcmd

import (
	"context"
	"errors"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/iam"

	"github.com/jebin2/aws_cloud_gaming/internal/bucket"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
)

type iamFake struct {
	hasRole bool
	fail    bool
	puts    []string
}

func (i *iamFake) GetRole(context.Context, *iam.GetRoleInput, ...func(*iam.Options)) (*iam.GetRoleOutput, error) {
	if !i.hasRole {
		return nil, errors.New("NoSuchEntity")
	}
	return &iam.GetRoleOutput{}, nil
}
func (i *iamFake) PutRolePolicy(_ context.Context, in *iam.PutRolePolicyInput, _ ...func(*iam.Options)) (*iam.PutRolePolicyOutput, error) {
	if i.fail {
		return nil, errors.New("AccessDenied")
	}
	i.puts = append(i.puts, aws.ToString(in.PolicyDocument))
	return &iam.PutRolePolicyOutput{}, nil
}

func destroyRig(t *testing.T, input string) (*rig, DestroyDeps, *iamFake, *library.MemStore) {
	r := newRig(t, input)
	r.d.Env.Set("GAME_INSTANCE_ID", "i-0abc")
	r.d.Env.Set("SUNSHINE_USER", "admin")
	r.d.Env.Set("GAME_REGION", "ap-south-1")
	s := library.NewMemStore()
	name := bucket.Name("123", "gamevps", "ap-south-1")
	s.Add(name, "ap-south-1", "steam/index.json", 10)
	s.Add(name, "ap-south-1", "steam/steamapps/common/G/x", 2048)
	i := &iamFake{hasRole: true}
	x := DestroyDeps{EC2: r.e, IAM: i, Lib: library.Library{S3: s, Host: "gamevps", Region: "ap-south-1", Account: "123"}}
	return r, x, i, s
}

func TestDestroyMirrorsThenRemovesThenForgetsTheBoxButNotTheRegion(t *testing.T) {
	r, x, _, _ := destroyRig(t, "")
	r.e.state = "running"
	r.e.images = map[string]string{}
	if rc := r.d.DestroyBox(context.Background(), x, nil); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.w)
	}
	got := r.o.String()
	for _, want := range []string{"==> mirroring the game library to S3 before the box goes away", "This permanently deletes the box and everything listed here:", "instances       i-0abc",
		"keeping the budget gamevps-monthly - it guards the account, not the box", "==> box deleted - security group, key pair and tailnet node kept for cg init"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if !strings.Contains(strings.Join(r.e.calls, ","), "terminate") {
		t.Errorf("%v", r.e.calls)
	}
	// The mirror came before the terminate.
	push := -1
	for i, l := range r.r.Ran {
		if strings.Contains(l, "cg-library push") {
			push = i
		}
	}
	if push < 0 {
		t.Error("no mirror")
	}
	if r.d.Env.Get("GAME_INSTANCE_ID") != "" || r.d.Env.Get("SUNSHINE_USER") != "" {
		t.Error("the box's own settings go with it")
	}
	if r.d.Env.Get("GAME_REGION") != "ap-south-1" {
		t.Error("GAME_REGION is the person's choice, not state this box created - deleting it moved the rig to another region")
	}
}

func TestDestroyWontGoWhenTheMirrorFailsUnlessForced(t *testing.T) {
	fail := func(r *rig) {
		prev := r.r.Hook
		r.r.Hook = func(line string) (bool, string, error) {
			if strings.Contains(line, "cg-library push") {
				return true, "", &exitCode{1}
			}
			return prev(line)
		}
	}
	r, x, _, _ := destroyRig(t, "")
	fail(r)
	if rc := r.d.DestroyBox(context.Background(), x, nil); rc != 1 || strings.Contains(strings.Join(r.e.calls, ","), "terminate") || !strings.Contains(r.w.String(), "not mirrored from here - see above, then: cg destroy --force") {
		t.Fatalf("rc %d %v\n%s", rc, r.e.calls, r.w)
	}
	if !strings.Contains(r.o.String(), "mirrors the library as the machine shuts down. It needs no ssh.") {
		t.Error("the reassurance is that the box mirrors itself on shutdown")
	}
	r, x, _, _ = destroyRig(t, "")
	fail(r)
	if rc := r.d.DestroyBox(context.Background(), x, []string{"--force"}); rc != 0 || !strings.Contains(r.o.String(), "WARNING: proceeding without a mirror (--force) - games will be re-downloaded") {
		t.Errorf("rc %d\n%s", rc, r.o)
	}
}

func TestDestroyOfAStoppedBoxReportsTheArchiveInsteadOfPushing(t *testing.T) {
	r, x, _, _ := destroyRig(t, "")
	r.e.state = "stopped"
	if rc := r.d.DestroyBox(context.Background(), x, nil); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	got := r.o.String()
	if !strings.Contains(got, "box is stopped - nothing local to push") || !strings.Contains(got, "holds 2 objects, 2.1KB") || strings.Contains(got, "is EMPTY") {
		t.Errorf("%s", got)
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "cg-library") {
			t.Error("pushed from a box that is not running")
		}
	}
	// An empty archive says so, loudly.
	r, x, _, s := destroyRig(t, "")
	r.e.state = "stopped"
	s.Objs = map[string]map[string][]byte{}
	s.Region = map[string]string{}
	_ = r.d.DestroyBox(context.Background(), x, nil)
	if !strings.Contains(r.o.String(), "the archive is EMPTY - if you expected games in it, stop here") {
		t.Errorf("%s", r.o)
	}
}

func TestNoPushLocksTheArchiveBeforeAndUnlocksAfter(t *testing.T) {
	r, x, i, _ := destroyRig(t, "")
	if rc := r.d.DestroyBox(context.Background(), x, []string{"--no-push"}); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	if len(i.puts) != 2 || strings.Contains(i.puts[0], "s3:PutObject") || !strings.Contains(i.puts[1], "s3:PutObject") || !strings.Contains(i.puts[1], "s3:DeleteObject") {
		t.Errorf("read-only first, writable again after: %v", i.puts)
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "cg-library") {
			t.Error("--no-push must not push")
		}
	}
	got := r.o.String()
	for _, want := range []string{"destroying WITHOUT mirroring - the archive is left exactly as it is", "archive set read-only for gamevps-box - its shutdown mirror cannot write", "archive writable again for gamevps-box"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	// If the box's write access cannot be revoked, the destroy does not start: its own mirror could still overwrite the archive.
	r, x, i, _ = destroyRig(t, "")
	i.fail = true
	if rc := r.d.DestroyBox(context.Background(), x, []string{"--no-push"}); rc != 1 || strings.Contains(strings.Join(r.e.calls, ","), "terminate") || !strings.Contains(r.w.String(), "could not revoke the box's write access") {
		t.Errorf("rc %d %v\n%s", rc, r.e.calls, r.w)
	}
	// No role at all: nothing to lock, and the destroy goes ahead.
	r, x, i, _ = destroyRig(t, "")
	i.hasRole = false
	if rc := r.d.DestroyBox(context.Background(), x, []string{"--no-push"}); rc != 0 || len(i.puts) != 0 {
		t.Errorf("rc %d %v", rc, i.puts)
	}
}

func TestDestroyRefusesWhatItDoesNotKnow(t *testing.T) {
	r, x, _, _ := destroyRig(t, "")
	if rc := r.d.DestroyBox(context.Background(), x, []string{"--everything"}); rc != 1 || !strings.Contains(r.w.String(), "unknown option '--everything' for destroy (--all, --force, --no-push)") || len(r.e.calls) != 0 {
		t.Errorf("a typo must not quietly behave as a plain destroy: %s", r.w)
	}
}

func TestDestroyClosesAnOpenStreamFirst(t *testing.T) {
	r, x, _, _ := destroyRig(t, "y\n")
	r.e.state = "stopped"
	session.Claim(r.d.SessionFile, time.Now())
	r.d.Probe = alwaysCg{}
	ended := false
	x.Ender = &session.Ender{Path: r.d.SessionFile, Probe: probeOnce{&ended}, Sleep: func(time.Duration) {}, Signal: func(int, syscallSignal) { ended = true }, Children: func(int, syscallSignal) {}}
	if rc := r.d.DestroyBox(context.Background(), x, nil); rc != 0 {
		t.Fatalf("%s", r.w)
	}
	if !strings.Contains(r.o.String(), "a stream is open from this laptop (pid ") || !strings.Contains(r.o.String(), "stream closed") || !ended {
		t.Errorf("%s", r.o)
	}
}

type syscallSignal = syscall.Signal

// probeOnce sees a live cg until it has been signalled.
type probeOnce struct{ ended *bool }

func (p probeOnce) Alive(int) bool          { return !*p.ended }
func (p probeOnce) Args(int) (string, bool) { return "cg open", true }
