package awscmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/ec2"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/inventory"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
	"github.com/jebin2/aws_cloud_gaming/internal/teardown"
)

type rig struct {
	out  *output.Out
	o, e *bytes.Buffer
	env  *config.Env
	ask  *ask.Asker
	file string
}

func newRig(t *testing.T, input, dotenv string) *rig {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, ".env"), []byte(dotenv), 0o600)
	env := config.Load(func(string) (string, bool) { return "", false }, dir)
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	return &rig{out: out, o: &o, e: &e, env: env, file: filepath.Join(dir, ".env"),
		ask: &ask.Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &bytes.Buffer{}, TTY: true}}
}

func (r *rig) region() string { b, _ := os.ReadFile(r.file); return string(b) }

func forgetter(r *rig, state string, games int, gamesErr error, other int, otherErr error) Forgetter {
	return Forgetter{Out: r.out, Env: r.env,
		BoxState:  func(context.Context) string { return state },
		Games:     func(context.Context) (int, error) { return games, gamesErr },
		Elsewhere: func(context.Context) (int, error) { return other, otherErr }}
}

func TestForgetOnlyRemovesTheRegionWhenNothingBills(t *testing.T) {
	r := newRig(t, "", "GAME_REGION=ap-south-1\nTAILSCALE_API_KEY=tskey-api-x\n")
	if rc := forgetter(r, "none", 0, nil, 0, nil).Run(context.Background(), nil); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e)
	}
	if strings.Contains(r.region(), "GAME_REGION") || !strings.Contains(r.region(), "TAILSCALE_API_KEY") {
		t.Errorf("only the region leaves .env: %q", r.region())
	}
	if !strings.Contains(r.o.String(), "this laptop no longer plays on AWS") || !strings.Contains(r.o.String(), "nothing in AWS was deleted; your access key stays in ~/.aws/credentials") {
		t.Error(r.o.String())
	}
	// Not set up at all: nothing to forget.
	r = newRig(t, "", "")
	if rc := forgetter(r, "none", 0, nil, 0, nil).Run(context.Background(), nil); rc != 0 || !strings.Contains(r.o.String(), "AWS is not set up on this laptop - nothing to forget") {
		t.Error(r.o.String())
	}
}

func TestForgetRefusesWhileAnythingStillBills(t *testing.T) {
	for name, c := range map[string]struct {
		f    func(*rig) Forgetter
		rc   int
		want string
	}{
		"a running machine": {func(r *rig) Forgetter { return forgetter(r, "running", 0, nil, 0, nil) }, 1, "a machine is still on AWS (running) - delete it first: cg destroy"},
		"a stopped machine": {func(r *rig) Forgetter { return forgetter(r, "stopped", 0, nil, 0, nil) }, 1, "a machine is still on AWS (stopped)"},
		"one saved game":    {func(r *rig) Forgetter { return forgetter(r, "none", 1, nil, 0, nil) }, 1, "1 game still saved in AWS - delete them first, or keep using AWS: cg library list"},
		"games elsewhere":   {func(r *rig) Forgetter { return forgetter(r, "terminated", 0, nil, 3, nil) }, 1, "3 games still saved in another AWS region - see cg library elsewhere"},
	} {
		r := newRig(t, "", "GAME_REGION=ap-south-1\n")
		if rc := c.f(r).Run(context.Background(), nil); rc != c.rc || !strings.Contains(r.e.String(), c.want) || !strings.Contains(r.region(), "GAME_REGION") {
			t.Errorf("%s: rc %d\n%s", name, rc, r.e)
		}
	}
}

func TestForgetSaysWhenAWSCouldNotBeAskedAndAnywayForgetsAll(t *testing.T) {
	for name, c := range map[string]struct {
		f    func(*rig) Forgetter
		want string
	}{
		"the machine":  {func(r *rig) Forgetter { return forgetter(r, "unknown", 0, nil, 0, nil) }, "AWS could not be asked whether a machine is still there"},
		"saved games":  {func(r *rig) Forgetter { return forgetter(r, "none", 0, errors.New("x"), 0, nil) }, "AWS could not be asked about your saved games"},
		"other places": {func(r *rig) Forgetter { return forgetter(r, "none", 0, nil, 0, errors.New("x")) }, "AWS could not be asked about games saved in other regions"},
	} {
		r := newRig(t, "", "GAME_REGION=ap-south-1\n")
		if rc := c.f(r).Run(context.Background(), nil); rc != 3 || !strings.Contains(r.e.String(), c.want) || !strings.Contains(r.region(), "GAME_REGION") {
			t.Errorf("%s: exit 3 means whether anything bills is not known: rc %d\n%s", name, rc, r.e)
		}
	}
	r := newRig(t, "", "GAME_REGION=ap-south-1\n")
	if rc := forgetter(r, "running", 5, nil, 5, nil).Run(context.Background(), []string{"--anyway"}); rc != 0 || strings.Contains(r.region(), "GAME_REGION") {
		t.Errorf("--anyway forgets it all the same: rc %d", rc)
	}
}

func TestCountElsewhere(t *testing.T) {
	msg := "x"
	if _, err := CountElsewhere(library.Elsewhere{Error: &msg}); err == nil {
		t.Error("an error is not zero")
	}
	if _, err := CountElsewhere(library.Elsewhere{}); err == nil {
		t.Error("no answer is not zero")
	}
	places := []library.Place{{Games: make([]library.Game, 2)}, {Games: make([]library.Game, 1)}}
	if n, err := CountElsewhere(library.Elsewhere{Places: &places}); n != 3 || err != nil {
		t.Errorf("%d %v", n, err)
	}
}

// regionFake records what is done in a region.
type regionFake struct {
	region string
	calls  *[]string
	failID string
}

func (f regionFake) DeregisterImage(context.Context, *ec2.DeregisterImageInput, ...func(*ec2.Options)) (*ec2.DeregisterImageOutput, error) {
	return &ec2.DeregisterImageOutput{}, nil
}
func (f regionFake) DeleteSnapshot(context.Context, *ec2.DeleteSnapshotInput, ...func(*ec2.Options)) (*ec2.DeleteSnapshotOutput, error) {
	return &ec2.DeleteSnapshotOutput{}, nil
}
func (f regionFake) DeleteVolume(context.Context, *ec2.DeleteVolumeInput, ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error) {
	return &ec2.DeleteVolumeOutput{}, nil
}
func (f regionFake) DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error) {
	return &ec2.DescribeSpotInstanceRequestsOutput{}, nil
}
func (f regionFake) CancelSpotInstanceRequests(context.Context, *ec2.CancelSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error) {
	return &ec2.CancelSpotInstanceRequestsOutput{}, nil
}
func (f regionFake) TerminateInstances(_ context.Context, in *ec2.TerminateInstancesInput, _ ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error) {
	if in.InstanceIds[0] == f.failID {
		return nil, errors.New("UnauthorizedOperation")
	}
	*f.calls = append(*f.calls, "end "+in.InstanceIds[0]+"@"+f.region)
	return &ec2.TerminateInstancesOutput{}, nil
}

type disc struct {
	*rig
	d       Disconnector
	calls   []string
	inv     []inventory.Result
	n       int
	destroy int
	failBkt string
	failEnd string
	scan    storage.Everywhere
}

func newDisc(t *testing.T, input string, inv ...inventory.Result) *disc {
	r := newRig(t, input, "GAME_REGION=ap-south-1\n")
	x := &disc{rig: r, inv: inv}
	x.d = Disconnector{Out: r.out, Ask: r.ask, Env: r.env,
		Inventory: func(context.Context) inventory.Result {
			i := x.n
			if i >= len(x.inv) {
				i = len(x.inv) - 1
			}
			x.n++
			return x.inv[i]
		},
		DestroyHere:    func(context.Context) int { x.calls = append(x.calls, "destroy --all --force"); return x.destroy },
		RemoveWatchdog: func(_ context.Context, region string) { x.calls = append(x.calls, "watchdog@"+region) },
		RoleLeft:       func(context.Context) bool { return true },
		RemoveRoleOnly: func(context.Context) { x.calls = append(x.calls, "role") },
		Teardown: teardown.Teardown{EC2: func(region string) teardown.RegionAPI {
			return regionFake{region: region, calls: &x.calls, failID: x.failEnd}
		},
			SSM: func(string) teardown.SSMAPI { return nil }, Say: r.out.Say, Log: r.out.Log, Fail: func(s string) { r.out.LogAs("fail", s) },
			Wait: func(context.Context, string, string) bool { return true }},
		Scan: func(context.Context) storage.Everywhere { return x.scan },
		DeleteBucket: func(_ context.Context, b, region string) error {
			if b == x.failBkt {
				return errors.New("BucketNotEmpty")
			}
			x.calls = append(x.calls, "bucket "+b+"@"+region)
			return nil
		},
	}
	return x
}

func item(kind, label, detail, region, id, bucket string) inventory.Item {
	return inventory.Item{Kind: kind, Label: label, Detail: detail, Region: region, ID: id, Bucket: bucket}
}

func full() inventory.Result {
	return inventory.Result{Region: "ap-south-1", Items: []inventory.Item{
		item("machine", "Machine", "g6.xlarge, running", "ap-south-1", "i-here", ""),
		item("machine", "Machine", "g4dn.xlarge, stopped in us-east-1", "us-east-1", "i-away", ""),
		item("games", "Saved games", "2 games, 160.0 GB", "ap-south-1", "", "cg-here"),
		item("games", "Saved games elsewhere", "1 game, 20.0 GB in us-east-1", "us-east-1", "", "cg-away"),
		{Kind: "watchdog", Label: "Cloud watchdog", Regions: []string{"ap-south-1", "us-east-1"}, Detail: "function"},
	}}
}

func TestDisconnectAsksForDELETEAndNeedsIt(t *testing.T) {
	x := newDisc(t, "yes\n", full())
	if rc := x.d.Run(context.Background()); rc != 1 || len(x.calls) != 0 || !strings.Contains(x.o.String(), "not confirmed - nothing was deleted") {
		t.Fatalf("rc %d %v\n%s", rc, x.calls, x.o)
	}
	for _, want := range []string{"==> this deletes everything cg has in AWS", "Machine                g6.xlarge, running", "Saved games elsewhere  1 game, 20.0 GB in us-east-1", "your saved games cannot be brought back; the account, its access key, region opt-ins and GPU quota stay"} {
		if !strings.Contains(x.o.String(), want) {
			t.Errorf("lacks %q in:\n%s", want, x.o)
		}
	}
	if !strings.Contains(x.region(), "GAME_REGION") {
		t.Error("still connected")
	}
}

func TestDisconnectDeletesEveryRegionThenLooksAndOnlyThenForgets(t *testing.T) {
	x := newDisc(t, "DELETE\n", full(), inventory.Result{Region: "ap-south-1", Items: []inventory.Item{}})
	if rc := x.d.Run(context.Background()); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, x.o, x.e)
	}
	want := "destroy --all --force,watchdog@us-east-1,role,end i-away@us-east-1,bucket cg-away@us-east-1"
	if strings.Join(x.calls, ",") != want {
		t.Errorf("here first, then the other regions; this region's bucket went with destroy:\n got %s\nwant %s", strings.Join(x.calls, ","), want)
	}
	if strings.Contains(x.region(), "GAME_REGION") {
		t.Error("only after the final look is clean does the laptop forget the region")
	}
	if !strings.Contains(x.o.String(), "AWS disconnected - nothing of cg is left billing, nor anything else of cg's") || !strings.Contains(x.o.String(), "==> checking nothing is left") {
		t.Error(x.o.String())
	}
}

func TestDisconnectKeepsAWSConfiguredWhenAnythingIsLeft(t *testing.T) {
	left := inventory.Result{Region: "ap-south-1", Items: []inventory.Item{item("games", "Saved games elsewhere", "1 game, 20.0 GB in us-east-1", "us-east-1", "", "cg-away")}}
	x := newDisc(t, "DELETE\n", full(), left)
	x.failBkt = "cg-away"
	x.destroy = 1
	if rc := x.d.Run(context.Background()); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	got := x.o.String()
	for _, want := range []string{"not everything here could be deleted - carrying on; the check at the end says what is left", "could not delete s3://cg-away",
		"still there: Saved games elsewhere - 1 game, 20.0 GB in us-east-1"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if !strings.Contains(x.e.String(), "not everything could be deleted - AWS is still set up here so it can be seen; try again") || !strings.Contains(x.region(), "GAME_REGION") {
		t.Errorf("a region still set is how it can still be seen and deleted:\n%s", x.e)
	}
	// One failure did not stop the others.
	if !strings.Contains(strings.Join(x.calls, ","), "end i-away@us-east-1") {
		t.Errorf("%v", x.calls)
	}
}

func TestDisconnectWhenAWSCannotBeAskedDeletesNothing(t *testing.T) {
	msg := "AWS could not be asked what is there"
	x := newDisc(t, "DELETE\n", inventory.Result{Error: &msg})
	if rc := x.d.Run(context.Background()); rc != 3 || len(x.calls) != 0 || !strings.Contains(x.e.String(), "AWS could not be asked what is there - nothing was deleted") {
		t.Errorf("rc %d %v\n%s", rc, x.calls, x.e)
	}
}

func TestAFailedRegionAndAMachineThatWontEndKeepsItListed(t *testing.T) {
	still := inventory.Result{Region: "ap-south-1", Items: []inventory.Item{item("machine", "Machine", "g4dn.xlarge, stopped in us-east-1", "us-east-1", "i-away", "")}}
	x := newDisc(t, "DELETE\n", full(), still)
	x.failEnd = "i-away"
	x.scan = storage.Everywhere{Failed: []string{"eu-west-1"}}
	if rc := x.d.Run(context.Background()); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	got := x.o.String()
	for _, want := range []string{"could not end i-away in us-east-1", "AWS would not say what is in: eu-west-1", "some of cg's disks, images or snapshots could not be deleted", "still there: Machine - g4dn.xlarge, stopped in us-east-1"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	// A look that itself cannot be made is not a clean one.
	msg := "AWS could not be asked what is there"
	x = newDisc(t, "DELETE\n", full(), inventory.Result{Error: &msg})
	if rc := x.d.Run(context.Background()); rc != 1 || !strings.Contains(x.o.String(), "still there: ? - AWS could not be asked what is there") {
		t.Errorf("rc %d\n%s", rc, x.o)
	}
}

func TestPlanChangesNothing(t *testing.T) {
	x := newDisc(t, "", full())
	if rc := x.d.Plan(context.Background(), true); rc != 0 || len(x.calls) != 0 || !strings.Contains(x.o.String(), `"kind": "machine"`) {
		t.Errorf("%s", x.o)
	}
}
