package boxcmd

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/iam"

	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
	"github.com/jebin2/aws_cloud_gaming/internal/teardown"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

type budgetDel struct {
	deleted bool
	err     error
}

func (b *budgetDel) DeleteBudget(context.Context, *budgets.DeleteBudgetInput, ...func(*budgets.Options)) (*budgets.DeleteBudgetOutput, error) {
	if b.err != nil {
		return nil, b.err
	}
	b.deleted = true
	return &budgets.DeleteBudgetOutput{}, nil
}

type nopIAM struct{ calls *[]string }

func (n nopIAM) RemoveRoleFromInstanceProfile(context.Context, *iam.RemoveRoleFromInstanceProfileInput, ...func(*iam.Options)) (*iam.RemoveRoleFromInstanceProfileOutput, error) {
	*n.calls = append(*n.calls, "iam detach")
	return &iam.RemoveRoleFromInstanceProfileOutput{}, nil
}
func (n nopIAM) DeleteInstanceProfile(context.Context, *iam.DeleteInstanceProfileInput, ...func(*iam.Options)) (*iam.DeleteInstanceProfileOutput, error) {
	*n.calls = append(*n.calls, "iam profile")
	return &iam.DeleteInstanceProfileOutput{}, nil
}
func (n nopIAM) DeleteRolePolicy(context.Context, *iam.DeleteRolePolicyInput, ...func(*iam.Options)) (*iam.DeleteRolePolicyOutput, error) {
	*n.calls = append(*n.calls, "iam policy")
	return &iam.DeleteRolePolicyOutput{}, nil
}
func (n nopIAM) DeleteRole(context.Context, *iam.DeleteRoleInput, ...func(*iam.Options)) (*iam.DeleteRoleOutput, error) {
	*n.calls = append(*n.calls, "iam role")
	return &iam.DeleteRoleOutput{}, nil
}

// regionEC2 is the per-region API over the one fake account.
type regionEC2 struct{ *fakeEC2 }

type allRig struct {
	*rig
	x               DestroyDeps
	store           *library.MemStore
	bud             *budgetDel
	calls           *[]string
	watchdogRemoved int
	pem             string
	scan            storage.Everywhere
}

type failBucket struct{ *library.MemStore }

func (failBucket) DeleteBucket(context.Context, string, string) error {
	return errors.New("BucketNotEmpty")
}

func newAll(t *testing.T, input string) *allRig {
	r, x, _, s := destroyRig(t, input)
	r.e.state = "running"
	r.e.sg, r.e.key = "sg-1", "gamevps"
	r.e.gamesVol, r.e.gamesState = "vol-games", "available"
	_ = r.d.Env.Set("TAILSCALE_API_KEY", "tskey-api-abc123")
	pem := filepath.Join(t.TempDir(), "gamevps.pem")
	_ = os.WriteFile(pem, []byte("k"), 0o600)
	var calls []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		if q.Header.Get("Authorization") != "Bearer tskey-api-abc123" {
			w.WriteHeader(401)
			return
		}
		if q.Method == "GET" {
			_, _ = w.Write([]byte(`{"devices":[{"nodeId":"n1","hostname":"gamevps"},{"nodeId":"n2","hostname":"phone"}]}`))
			return
		}
		calls = append(calls, "tailnet "+q.URL.Path)
		w.WriteHeader(200)
	}))
	t.Cleanup(ts.Close)
	a := &allRig{rig: r, x: x, store: s, bud: &budgetDel{}, calls: &calls, pem: pem}
	td := teardown.Teardown{EC2: func(string) teardown.RegionAPI { return regionEC2{r.e} }, IAM: nopIAM{&calls}, Say: r.d.Out.Say, Log: r.d.Out.Log,
		Fail: func(s string) { r.d.Out.LogAs("fail", s) }, SSM: func(string) teardown.SSMAPI { return nil }, Wait: func(context.Context, string, string) bool { return true }}
	a.x.All = &AllDeps{EC2: r.e, Budgets: a.bud, Account: "123", W: s, Teardown: td,
		Scan:       func(context.Context) storage.Everywhere { return a.scan },
		RoleExists: func(context.Context) bool { return true }, WatchdogExists: func(context.Context) bool { return true },
		RemoveWatchdog: func(context.Context) { a.watchdogRemoved++ },
		TS:             func(token string) tskey.Client { return tskey.Client{Token: token, Base: ts.URL} }, Pem: pem}
	return a
}

func TestAllNeedsTheWordAndDeletesNothingWithoutIt(t *testing.T) {
	a := newAll(t, "no\n")
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all"}); rc != 1 {
		t.Fatalf("rc %d\n%s%s", rc, a.o, a.w)
	}
	got := a.o.String()
	for _, want := range []string{"--all deletes the box AND every game you have.", "game archive    s3://", "2 objects, 2.1KB", "THIS IS THE ONLY COPY - no versions, no snapshot, no undo",
		"old EBS volume  vol-games  160 GB", "instance role   gamevps-box, and its instance profile", "cloud watchdog  gamevps-cloud-watchdog", "aborted - nothing was deleted"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if len(a.e.calls) != 0 || a.bud.deleted || len(a.store.Objs) == 0 || a.watchdogRemoved != 0 {
		t.Errorf("nothing was touched: %v", a.e.calls)
	}
}

func TestAllDeletesEverythingAndForgetsTheBucketOnlyOnceItIsGone(t *testing.T) {
	a := newAll(t, "DESTROY-ALL\n")
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all"}); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, a.o, a.w)
	}
	if len(a.store.Objs) != 0 {
		t.Error("the archive and its bucket are gone")
	}
	if a.d.Env.Get("GAME_S3_BUCKET") != "" || a.d.Env.Get("GAME_INSTANCE_ID") != "" {
		t.Error("and so are the settings that pointed at them")
	}
	if a.d.Env.Get("GAME_REGION") != "ap-south-1" {
		t.Error("GAME_REGION is not state this box created")
	}
	if !a.bud.deleted || a.watchdogRemoved != 1 {
		t.Errorf("budget %v watchdog %d", a.bud.deleted, a.watchdogRemoved)
	}
	if _, err := os.Stat(a.pem); err == nil {
		t.Error("the local key goes with the key pair")
	}
	c := strings.Join(a.e.calls, ",")
	for _, want := range []string{"terminate", "delete-sg", "delete-key", "delete-volume vol-games"} {
		if !strings.Contains(c, want) {
			t.Errorf("lacks %q in %s", want, c)
		}
	}
	if strings.Join(*a.calls, ",") != "tailnet /device/n1,iam detach,iam profile,iam policy,iam role" {
		t.Errorf("only this host's tailnet node, then the role in the order IAM allows: %v", *a.calls)
	}
	got := a.o.String()
	for _, want := range []string{"==> removing the budget", "==> everything deleted", "deleted tailnet node 'gamevps'", "bucket deleted - storage charges stop now", "==> removing the cloud watchdog gamevps-cloud-watchdog",
		"deleted vol-games - storage charges stop now", "==> looking for cg's disks, images and snapshots in every region", "security group  sg-1", "key pair        gamevps  (and ~/.ssh/gamevps.pem)"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	// The mirror is not made first: the games are about to go.
	for _, l := range a.r.Ran {
		if strings.Contains(l, "cg-library") {
			t.Error("pushed an archive that is about to be deleted")
		}
	}
}

func TestAllWithForceAsksNothing(t *testing.T) {
	a := newAll(t, "")
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all", "--force"}); rc != 0 || len(a.store.Objs) != 0 {
		t.Fatalf("rc %d\n%s%s", rc, a.o, a.w)
	}
}

func TestAllCannotBeCombinedWithNoPush(t *testing.T) {
	a := newAll(t, "DESTROY-ALL\n")
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all", "--no-push"}); rc != 1 || !strings.Contains(a.w.String(), "--no-push cannot be combined with --all") || len(a.e.calls) != 0 || len(a.store.Objs) == 0 {
		t.Errorf("rc %d: the Bash accepted this and quietly ignored --no-push while deleting the archive\n%s", rc, a.w)
	}
}

func TestABucketThatWontGoStaysInEnvAndTheRestStillRuns(t *testing.T) {
	a := newAll(t, "")
	a.x.All.W = failBucket{a.store}
	bucketName := a.d.Env.Get("GAME_S3_BUCKET")
	_ = a.d.Env.Set("GAME_S3_BUCKET", "cg-stuck-bucket")
	_ = bucketName
	a.x.Lib.Bucket = "cg-stuck-bucket"
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all", "--force"}); rc != 1 {
		t.Fatalf("rc %d\n%s", rc, a.o)
	}
	if a.d.Env.Get("GAME_S3_BUCKET") != "cg-stuck-bucket" {
		t.Error("it still bills, so it stays where it is still seen")
	}
	got := a.o.String()
	if !strings.Contains(got, "could not delete the bucket s3://cg-stuck-bucket - it still bills, and stays in .env so it is still seen") || !strings.Contains(a.w.String(), "not everything could be deleted") {
		t.Errorf("%s\n%s", got, a.w)
	}
	// One failure does not stop the rest: the role, the watchdog, the disk and the sweep all ran.
	if a.watchdogRemoved != 1 || !strings.Contains(strings.Join(a.e.calls, ","), "delete-volume vol-games") || !strings.Contains(strings.Join(*a.calls, ","), "iam role") {
		t.Errorf("%v %v", a.e.calls, *a.calls)
	}
}

func TestAllSaysWhatItCouldNotFindAndWhatStaysBilling(t *testing.T) {
	a := newAll(t, "")
	a.scan = storage.Everywhere{Failed: []string{"eu-west-1"}}
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all", "--force"}); rc != 1 || !strings.Contains(a.o.String(), "AWS would not say what is in: eu-west-1") {
		t.Errorf("a region AWS would not answer for is not known to be clean: rc %d\n%s", rc, a.o)
	}
	// An expired token is said, not mistaken for a clean tailnet.
	a = newAll(t, "")
	_ = a.d.Env.Set("TAILSCALE_API_KEY", "tskey-api-expired")
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all", "--force"}); rc != 0 || !strings.Contains(a.o.String(), "TAILSCALE_API_KEY rejected (HTTP 401)") {
		t.Errorf("rc %d\n%s", rc, a.o)
	}
	// A security group still in use is said, not waited on forever, and is free.
	a = newAll(t, "")
	a.e.sgDeleteFails = 100
	if rc := a.d.DestroyBox(context.Background(), a.x, []string{"--all", "--force"}); rc != 0 || !strings.Contains(a.o.String(), "still in use - delete it manually later: sg-1") {
		t.Errorf("rc %d\n%s", rc, a.o)
	}
}
