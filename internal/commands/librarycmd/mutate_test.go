package librarycmd

import (
	"bufio"
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/bucket"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

type marks map[string]string

func (k marks) Put(_ context.Context, n, v string) error { k[n] = v; return nil }
func (k marks) Delete(_ context.Context, n string) error { delete(k, n); return nil }

const bkt = "cg-acct-gamevps-hash"
const idx = `{"apps":[{"appid":1091500,"name":"Cyberpunk","installdir":"Cyberpunk 2077","bytes":107374182400},{"appid":2,"name":"Diablo IV","installdir":"Diablo IV","bytes":50}]}`

type rig struct {
	c          *Changer
	s          *library.MemStore
	k          marks
	o, e       *bytes.Buffer
	set        map[string]string
	redeployed int
}

func newRig(t *testing.T, input string, dotenv string) *rig {
	s := library.NewMemStore()
	s.Add(bkt, "ap-south-1", "steam/index.json", 0)
	s.Objs[bkt]["steam/index.json"] = []byte(idx)
	for _, k := range []string{"steam/steamapps/common/Cyberpunk 2077/a", "steam/steamapps/compatdata/1091500/p", "steam/steamapps/common/Diablo IV/d", "steam/steamapps/compatdata/2/p"} {
		s.Add(bkt, "ap-south-1", k, 10)
	}
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, ".env"), []byte(dotenv), 0o600)
	env := config.Load(func(string) (string, bool) { return "", false }, dir)
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	a := &ask.Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &bytes.Buffer{}, TTY: true}
	k := marks{}
	usd, inr := 0.025, 90.0
	r := &rig{s: s, k: k, o: &o, e: &e, set: map[string]string{}}
	r.c = &Changer{
		M: library.Mutator{Library: library.Library{S3: s, Host: "gamevps", Region: "ap-south-1", Account: "123", Bucket: bkt, S3USD: &usd, INR: &inr},
			W: s, Marks: k, Now: func() time.Time { return time.Date(2026, 10, 25, 1, 2, 3, 0, time.UTC) }},
		Ask: a, Out: out, Env: env,
		Price:     func(context.Context, string, string) *float64 { x := 0.02; return &x },
		Reinstall: func(context.Context) int { r.redeployed++; return 0 },
		Set:       func(key, v string) error { r.set[key] = v; return nil },
	}
	return r
}

const withBucket = "GAME_S3_BUCKET=" + bkt + "\n"

func TestForgetNeedsTheWordAndOnlyThenDeletes(t *testing.T) {
	r := newRig(t, "nope\n", withBucket)
	if rc := r.c.Forget(context.Background(), []string{"1091500"}); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	if !strings.Contains(r.o.String(), "aborted - nothing was deleted") || len(r.s.Objs[bkt]) != 5 {
		t.Errorf("wrong word must delete nothing:\n%s\n%d", r.o, len(r.s.Objs[bkt]))
	}
	if !strings.Contains(r.o.String(), "This permanently deletes Cyberpunk (1091500, 100.0 GB) from the archive in ap-south-1.") ||
		!strings.Contains(r.o.String(), "roughly 2.4 hours") {
		t.Errorf("%s", r.o)
	}
	r = newRig(t, "FORGET\n", withBucket)
	if rc := r.c.Forget(context.Background(), []string{"1091500"}); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e)
	}
	if !strings.Contains(r.o.String(), "forgot Cyberpunk (1091500) - 100.0 GB stops billing") || !strings.Contains(r.o.String(), "==> deleting Cyberpunk from ap-south-1") {
		t.Errorf("%s", r.o)
	}
	for k := range r.s.Objs[bkt] {
		if strings.Contains(k, "Cyberpunk") {
			t.Errorf("left: %s", k)
		}
	}
}

func TestForgetSaysWhyItCannot(t *testing.T) {
	r := newRig(t, "", "")
	if rc := r.c.Forget(context.Background(), []string{"1091500"}); rc != 1 || !strings.Contains(r.e.String(), "no bucket configured") {
		t.Errorf("a derived name is fine to read, not to delete in: %s", r.e)
	}
	r = newRig(t, "", withBucket)
	r.e.Reset()
	if rc := r.c.Forget(context.Background(), nil); rc != 1 || !strings.Contains(r.e.String(), "which game? see: cg library list") {
		t.Error(r.e.String())
	}
	r.e.Reset()
	if rc := r.c.Forget(context.Background(), []string{"777"}); rc != 1 || !strings.Contains(r.e.String(), "appid 777 is not in the archive (see: cg library list)") {
		t.Error(r.e.String())
	}
	r.e.Reset()
	if rc := r.c.Forget(context.Background(), []string{"1", "--from", "somebody-elses"}); rc != 1 || !strings.Contains(r.e.String(), "no such bucket, or AWS did not answer: somebody-elses") {
		t.Error(r.e.String())
	}
}

func TestResetWritesTheMarkAndSaysWhenItEnds(t *testing.T) {
	r := newRig(t, "", withBucket+"GAME_ARCHIVE_EXPIRY_DAYS=30\n")
	if rc := r.c.Reset(context.Background(), []string{"1091500"}); rc != 0 {
		t.Fatalf("%s", r.e)
	}
	if r.k["/cloud-gaming/gamevps/kept/"+bkt+"/1091500"] != "2026-10-25T01:02:03Z" || !strings.Contains(r.o.String(), "kept: 1091500 is counted from today - 30 days with no machine before it is deleted") {
		t.Errorf("%v\n%s", r.k, r.o)
	}
	if r.c.Reset(context.Background(), []string{"abc"}) != 1 {
		t.Error("an appid is a number")
	}
}

func TestKeepForSavesThenRedeploysSoTheDateIsTheOneAWSActsOn(t *testing.T) {
	r := newRig(t, "", withBucket)
	if rc := r.c.KeepFor(context.Background(), []string{"7"}); rc != 0 || r.set["GAME_ARCHIVE_EXPIRY_DAYS"] != "7" || r.redeployed != 1 {
		t.Fatalf("rc %d %v %d", rc, r.set, r.redeployed)
	}
	if !strings.Contains(r.o.String(), "saved games are deleted 7 days after a machine was last running") {
		t.Error(r.o.String())
	}
	r = newRig(t, "", withBucket)
	if rc := r.c.KeepFor(context.Background(), []string{"forever"}); rc != 0 || r.set["GAME_ARCHIVE_EXPIRY_DAYS"] != "0" || !strings.Contains(r.o.String(), "kept until you forget them") {
		t.Errorf("%v %s", r.set, r.o)
	}
	for _, bad := range [][]string{nil, {"-3"}, {"soon"}} {
		if r.c.KeepFor(context.Background(), bad) != 1 {
			t.Errorf("%v", bad)
		}
	}
	// A watchdog that could not be redeployed: the setting is saved and the user is told what is stale.
	r = newRig(t, "", withBucket)
	r.c.Reinstall = func(context.Context) int { return 1 }
	if rc := r.c.KeepFor(context.Background(), []string{"7"}); rc != 1 || !strings.Contains(r.e.String(), "saved, but the cloud watchdog still counts the old days - run: cg watchdog install") {
		t.Error(r.e.String())
	}
}

func TestCleanListsWhatNoGameUsesAndDeletesOnlyOnTheWord(t *testing.T) {
	r := newRig(t, "no\n", withBucket)
	r.s.Add(bkt, "ap-south-1", "steam/steamapps/common/Dead Download/x", 3<<30)
	if rc := r.c.Clean(context.Background()); rc != 1 {
		t.Fatalf("rc %d\n%s", rc, r.o)
	}
	for _, want := range []string{"a push that never finished:", "      3.0GB  common/Dead Download", "3.0 GB, costing $0.08/month (INR 7)", "aborted - nothing was deleted"} {
		if !strings.Contains(r.o.String(), want) {
			t.Errorf("lacks %q in:\n%s", want, r.o)
		}
	}
	if _, ok := r.s.Objs[bkt]["steam/steamapps/common/Dead Download/x"]; !ok {
		t.Error("deleted without the word")
	}
	r = newRig(t, "CLEAN\n", withBucket)
	r.s.Add(bkt, "ap-south-1", "steam/steamapps/common/Dead Download/x", 5)
	if rc := r.c.Clean(context.Background()); rc != 0 || !strings.Contains(r.o.String(), "deleted common/Dead Download") || !strings.Contains(r.o.String(), "storage charges for those stop now") {
		t.Errorf("rc %d\n%s", rc, r.o)
	}
	if len(r.s.Objs[bkt]) != 5 {
		t.Errorf("only the orphan went: %d", len(r.s.Objs[bkt]))
	}
	r = newRig(t, "", withBucket)
	if rc := r.c.Clean(context.Background()); rc != 0 || !strings.Contains(r.o.String(), "no orphaned objects - everything in the archive is indexed") {
		t.Error(r.o.String())
	}
}

func TestIEC(t *testing.T) {
	for in, want := range map[int64]string{500: "500B", 1024: "1.0KB", 1500: "1.5KB", 3 << 30: "3.0GB", 82_000_000_000: "77GB", 1<<20 + 1: "1.1MB"} {
		if got := iec(in); got != want {
			t.Errorf("%d: %s want %s", in, got, want)
		}
	}
}

func TestMoveBringsAGameToTheMachineAfterTheWord(t *testing.T) {
	r := newRig(t, "MOVE\n", withBucket)
	src := "cg-old"
	r.s.Add(src, "us-east-1", "steam/index.json", 0)
	r.s.Objs[src]["steam/index.json"] = []byte(`{"apps":[{"appid":9,"name":"Moved","installdir":"Moved Game","bytes":10737418240}]}`)
	for _, k := range []string{"steam/steamapps/common/Moved Game/a", "steam/steamapps/compatdata/9/p"} {
		r.s.Add(src, "us-east-1", k, 10)
	}
	// A bucket is "ours" only under the name cg derives for its own region.
	derived := derivedFor(t, "123", "gamevps", "us-east-1")
	r.s.Objs[derived], r.s.Region[derived] = r.s.Objs[src], "us-east-1"
	delete(r.s.Objs, src)
	delete(r.s.Region, src)
	if rc := r.c.Move(context.Background(), []string{"9", "--from", derived}); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e)
	}
	got := r.o.String()
	for _, want := range []string{"This copies Moved (10.0 GB) from us-east-1 to ap-south-1, checks every file, then deletes it from us-east-1.", "AWS charges about INR 18 once to copy between regions.",
		"==> copying Moved (part 1 of 3)", "==> checking the copy", "==> deleting it from us-east-1", "moved Moved to ap-south-1 - a build there downloads it free"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if _, ok := r.s.Objs[bkt]["steam/steamapps/common/Moved Game/a"]; !ok {
		t.Error("the game is where the machine is")
	}
	if _, ok := r.s.Objs[derived]; ok {
		t.Error("nothing is left billing at the source")
	}
	// Without the word nothing is copied.
	r = newRig(t, "\n", withBucket)
	r.s.Add(derived, "us-east-1", "steam/index.json", 0)
	r.s.Objs[derived]["steam/index.json"] = []byte(`{"apps":[{"appid":9,"name":"Moved","installdir":"Moved Game","bytes":10}]}`)
	before := len(r.s.Objs[bkt])
	if rc := r.c.Move(context.Background(), []string{"9", "--from", derived}); rc != 1 || len(r.s.Objs[bkt]) != before || !strings.Contains(r.o.String(), "aborted - nothing was copied") {
		t.Errorf("rc %d\n%s", rc, r.o)
	}
	if r.c.Move(context.Background(), []string{"9"}) != 1 || !strings.Contains(r.e.String(), "usage: cg library move <appid> --from <bucket>") {
		t.Error(r.e.String())
	}
	r.e.Reset()
	if r.c.Move(context.Background(), []string{"9", "--from", bkt}) != 1 || !strings.Contains(r.e.String(), "that game is already where your machine is built") {
		t.Error(r.e.String())
	}
}

func TestForgetLoginIsAllOrNothingAndNeedsTheWord(t *testing.T) {
	r := newRig(t, "wrong\n", withBucket)
	r.s.Add(bkt, "ap-south-1", library.AccountKey, 22000)
	if rc := r.c.ForgetLogin(context.Background(), nil, nil); rc != 1 || !strings.Contains(r.o.String(), "aborted - nothing was deleted") {
		t.Fatalf("rc %d\n%s", rc, r.o)
	}
	if _, ok := r.s.Objs[bkt][library.AccountKey]; !ok {
		t.Error("deleted without the word")
	}
	r = newRig(t, "FORGET\n", withBucket)
	r.s.Add(bkt, "ap-south-1", library.AccountKey, 22000)
	if rc := r.c.ForgetLogin(context.Background(), nil, nil); rc != 0 {
		t.Fatalf("%s", r.e)
	}
	if _, ok := r.s.Objs[bkt][library.AccountKey]; ok || !strings.Contains(r.o.String(), "the next box will ask you to sign in; it is re-archived on shutdown") {
		t.Errorf("%s", r.o)
	}
	r = newRig(t, "", withBucket)
	if rc := r.c.ForgetLogin(context.Background(), nil, nil); rc != 0 || !strings.Contains(r.o.String(), "there is no archived Steam login - nothing to delete") {
		t.Error(r.o.String())
	}
}

func derivedFor(t *testing.T, account, host, region string) string {
	return bucket.Name(account, host, region)
}
