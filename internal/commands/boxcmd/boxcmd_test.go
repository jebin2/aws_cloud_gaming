package boxcmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/jebin2/ayis/internal/ask"
	"github.com/jebin2/ayis/internal/box"
	"github.com/jebin2/ayis/internal/config"
	"github.com/jebin2/ayis/internal/output"
	"github.com/jebin2/ayis/internal/session"
	"github.com/jebin2/ayis/internal/stream"
	"github.com/jebin2/ayis/internal/sunshine"
	fx "github.com/jebin2/ayis/internal/testfixture"
)

// fakeEC2 is one instance, and what is done to it.
type fakeEC2 struct {
	state                 string
	slowTerminate         bool // TerminateInstances leaves it shutting-down
	terminateErr          error
	imagesErr             error // DescribeImages fails
	stopStays             bool  // StopInstances is accepted but the box stays "stopping"
	lifecycle             string
	spotState             string
	describeErr           error
	startErr              error
	stoppingPolls         int // reads that still say "stopping" before it is stopped
	calls                 []string
	images                map[string]string // id -> state
	snaps                 map[string][]string
	failSnap              map[string]bool
	imageCreated          int
	gamesVol, gamesState  string
	sg, key               string
	sgDeleteFails         int
	keyDeleted, sgDeleted bool
}

func (f *fakeEC2) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	if f.describeErr != nil {
		return nil, f.describeErr
	}
	if f.state == "stopping" && f.stoppingPolls > 0 {
		if f.stoppingPolls--; f.stoppingPolls == 0 {
			f.state = "stopped"
		}
	}
	in := ec2types.Instance{InstanceId: aws.String("i-0abc"), State: &ec2types.InstanceState{Name: ec2types.InstanceStateName(f.state)}, InstanceLifecycle: ec2types.InstanceLifecycleType(f.lifecycle),
		BlockDeviceMappings: []ec2types.InstanceBlockDeviceMapping{{Ebs: &ec2types.EbsInstanceBlockDevice{VolumeId: aws.String("vol-1")}}}}
	return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: []ec2types.Instance{in}}}}, nil
}
func (f *fakeEC2) DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error) {
	if f.spotState == "" {
		return &ec2.DescribeSpotInstanceRequestsOutput{}, nil
	}
	return &ec2.DescribeSpotInstanceRequestsOutput{SpotInstanceRequests: []ec2types.SpotInstanceRequest{{SpotInstanceRequestId: aws.String("sir-1"), State: ec2types.SpotInstanceState(f.spotState)}}}, nil
}
func (f *fakeEC2) StartInstances(context.Context, *ec2.StartInstancesInput, ...func(*ec2.Options)) (*ec2.StartInstancesOutput, error) {
	f.calls = append(f.calls, "start")
	if f.startErr != nil {
		return nil, f.startErr
	}
	f.state = "running"
	return &ec2.StartInstancesOutput{}, nil
}
func (f *fakeEC2) StopInstances(context.Context, *ec2.StopInstancesInput, ...func(*ec2.Options)) (*ec2.StopInstancesOutput, error) {
	f.calls = append(f.calls, "stop")
	f.state = "stopped"
	if f.stopStays {
		f.state = "stopping"
	}
	return &ec2.StopInstancesOutput{}, nil
}
func (f *fakeEC2) TerminateInstances(context.Context, *ec2.TerminateInstancesInput, ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error) {
	f.calls = append(f.calls, "terminate")
	if f.terminateErr != nil {
		return nil, f.terminateErr
	}
	f.state = "terminated"
	if f.slowTerminate {
		f.state = "shutting-down" // a spot box stays here for 6-7 minutes
	}
	return &ec2.TerminateInstancesOutput{}, nil
}
func (f *fakeEC2) CancelSpotInstanceRequests(context.Context, *ec2.CancelSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error) {
	f.calls = append(f.calls, "cancel-spot")
	return &ec2.CancelSpotInstanceRequestsOutput{}, nil
}
func (f *fakeEC2) CreateImage(_ context.Context, in *ec2.CreateImageInput, _ ...func(*ec2.Options)) (*ec2.CreateImageOutput, error) {
	f.calls = append(f.calls, "create-image "+aws.ToString(in.Name))
	f.imageCreated++
	if f.images == nil {
		f.images = map[string]string{}
	}
	f.images["ami-new"] = "available"
	return &ec2.CreateImageOutput{ImageId: aws.String("ami-new")}, nil
}
func (f *fakeEC2) DescribeImages(_ context.Context, in *ec2.DescribeImagesInput, _ ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error) {
	if f.imagesErr != nil {
		return nil, f.imagesErr
	}
	var out []ec2types.Image
	for _, id := range in.ImageIds {
		st, ok := f.images[id]
		if !ok {
			continue
		}
		im := ec2types.Image{ImageId: aws.String(id), State: ec2types.ImageState(st)}
		for _, s := range f.snaps[id] {
			im.BlockDeviceMappings = append(im.BlockDeviceMappings, ec2types.BlockDeviceMapping{Ebs: &ec2types.EbsBlockDevice{SnapshotId: aws.String(s)}})
		}
		out = append(out, im)
	}
	return &ec2.DescribeImagesOutput{Images: out}, nil
}
func (f *fakeEC2) DescribeVolumes(_ context.Context, in *ec2.DescribeVolumesInput, _ ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	for _, id := range in.VolumeIds {
		if id == f.gamesVol {
			return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{{VolumeId: aws.String(id), Size: aws.Int32(160), State: ec2types.VolumeState(f.gamesState)}}}, nil
		}
	}
	for _, fl := range in.Filters {
		for _, v := range fl.Values {
			if strings.HasSuffix(v, "-games") && f.gamesVol != "" {
				return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{{VolumeId: aws.String(f.gamesVol), Size: aws.Int32(160), State: ec2types.VolumeState(f.gamesState)}}}, nil
			}
		}
	}
	if len(in.VolumeIds) == 0 {
		return &ec2.DescribeVolumesOutput{}, nil
	}
	return &ec2.DescribeVolumesOutput{Volumes: []ec2types.Volume{{Size: aws.Int32(50)}}}, nil
}
func (f *fakeEC2) DeleteVolume(_ context.Context, in *ec2.DeleteVolumeInput, _ ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error) {
	f.calls = append(f.calls, "delete-volume "+aws.ToString(in.VolumeId))
	return &ec2.DeleteVolumeOutput{}, nil
}
func (f *fakeEC2) DeregisterImage(_ context.Context, in *ec2.DeregisterImageInput, _ ...func(*ec2.Options)) (*ec2.DeregisterImageOutput, error) {
	f.calls = append(f.calls, "deregister "+aws.ToString(in.ImageId))
	return &ec2.DeregisterImageOutput{}, nil
}
func (f *fakeEC2) DeleteSnapshot(_ context.Context, in *ec2.DeleteSnapshotInput, _ ...func(*ec2.Options)) (*ec2.DeleteSnapshotOutput, error) {
	id := aws.ToString(in.SnapshotId)
	if f.failSnap[id] {
		return nil, errors.New("InvalidSnapshot.InUse")
	}
	f.calls = append(f.calls, "delete-snapshot "+id)
	return &ec2.DeleteSnapshotOutput{}, nil
}

type exitCode struct{ n int }

func (e *exitCode) Error() string { return "exit" }
func (e *exitCode) ExitCode() int { return e.n }

type rig struct {
	d         Deps
	e         *fakeEC2
	r         *fx.Runner
	o, w      *bytes.Buffer
	slept     time.Duration
	destroyed int
}

// newRig is a box that is on the tailnet at 100.64.0.7, with the ssh answers a
// healthy one gives. input is what the person types.
func newRig(t *testing.T, input string) *rig {
	e := &fakeEC2{state: "running"}
	r := &fx.Runner{Installed: map[string]bool{"tailscale": true, "ssh": true, "sh": true, "moonlight": true, "pgrep": true}}
	r.Hook = func(line string) (bool, string, error) {
		switch {
		case line == "tailscale ip -4 ayis":
			return true, "100.64.0.7\n", nil
		case strings.HasPrefix(line, "tailscale ping -c 1 --timeout"):
			return true, "pong\n", nil
		case line == "tailscale ping -c 1 ayis":
			return true, "pong from ayis (100.64.0.7) via 203.0.113.9:41641 in 31ms\n", nil
		case strings.Contains(line, "df -h"):
			return true, "  /   12G 50G 24%\n  /scratch 100G 250G 40%\n", nil
		}
		return false, "", nil
	}
	var o, w bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &w}
	a := &ask.Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &bytes.Buffer{}, TTY: true}
	dir := t.TempDir()
	env := config.Load(func(string) (string, bool) { return "", false }, dir)
	rg := &rig{e: e, r: r, o: &o, w: &w}
	rg.d = Deps{
		Box: box.Box{EC2: e, ID: "i-0abc", Host: "ayis", Node: "ayis", Key: filepath.Join(dir, "ayis.pem"), R: r,
			Sleep: func(d time.Duration) { rg.slept += d }, Log: out.Log},
		Out: out, Ask: a, Env: env, R: r, Sun: sunshine.Client{}, SessionFile: filepath.Join(dir, "session.pid"), Probe: session.Proc{},
		Now: func() time.Time { return time.Unix(1700000000, 0) }, Sleep: func(d time.Duration) { rg.slept += d }, Moonlight: true,
		Takes: func() string { return "the last one took 12 min" },
		Dial:  func(string, time.Duration) error { return nil },
		// No real connections from a test: the machine's ssh port does not answer
		// unless a case says it does.
		Reach: func(string, time.Duration) error { return errors.New("refused") },
		Player: stream.Player{R: r, Get: env.Get, CacheDir: dir, Root: dir, Echo: out.Echo, Log: out.Log, Warn: out.Log,
			Now: func() time.Time { return time.Unix(1700000000, 0) }},
		Destroy: func(context.Context) int { rg.destroyed++; return 0 },
	}
	return rg
}

func sshLines(r *fx.Runner) string {
	var b []string
	for _, l := range r.Ran {
		if strings.HasPrefix(l, "sh -c") || strings.HasPrefix(l, "ssh ") {
			b = append(b, l)
		}
	}
	return strings.Join(b, "\n")
}

func TestLibraryOnTheBoxQuotesEveryWordAndNeedsTheBox(t *testing.T) {
	r := newRig(t, "")
	r.r.Hook = func(line string) (bool, string, error) {
		if line == "tailscale ip -4 ayis" {
			return true, "", &exitCode{1}
		}
		return false, "", nil
	}
	if rc := r.d.Library(context.Background(), "push", nil); rc != 1 || !strings.Contains(r.w.String(), "'ayis' is not on the tailnet. Is the box running? Try: ayis status") {
		t.Fatalf("%s", r.w)
	}
	r = newRig(t, "")
	if rc := r.d.Library(context.Background(), "pull", []string{"--apps", "1091500,2; rm -rf /"}); rc != 0 {
		t.Fatal(r.w)
	}
	got := sshLines(r.r)
	// Each word is one word on the box: what was typed cannot become a second command.
	if !strings.Contains(got, "/usr/local/bin/ayis-library pull --apps '1091500,2; rm -rf /'") {
		t.Errorf("%s", got)
	}
	r = newRig(t, "")
	_ = r.d.Library(context.Background(), "account", []string{"restore"})
	if !strings.Contains(sshLines(r.r), "ayis-library account pull") {
		t.Errorf("restore is pull: %s", sshLines(r.r))
	}
	if rc := newRig(t, "").d.Library(context.Background(), "nonsense", nil); rc != 1 {
		t.Error("usage")
	}
}

func TestLibraryFailureKeepsTheBoxsExitStatus(t *testing.T) {
	r := newRig(t, "")
	r.r.Hook = func(line string) (bool, string, error) {
		if line == "tailscale ip -4 ayis" {
			return true, "100.64.0.7\n", nil
		}
		if strings.Contains(line, "ayis-library push") {
			return true, "", &exitCode{3}
		}
		return false, "", nil
	}
	if rc := r.d.Library(context.Background(), "push", nil); rc != 3 {
		t.Errorf("rc %d", rc)
	}
}

func TestStopMirrorsThenStopsAndSaysBillingEnded(t *testing.T) {
	r := newRig(t, "")
	if rc := r.d.Stop(context.Background(), nil); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	got := r.o.String()
	for _, want := range []string{"==> Saving your games and Steam login to Saved games", "stopped after ", "billing has ended"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if strings.Join(r.e.calls, ",") != "stop" {
		t.Errorf("%v", r.e.calls)
	}
	// The mirror came first.
	push, stop := -1, -1
	for i, l := range r.r.Ran {
		if strings.Contains(l, "ayis-library push") {
			push = i
		}
	}
	_ = stop
	if push < 0 {
		t.Error("no mirror")
	}
}

// Unticked at Stop machine: the machine gets the script that can skip, and the
// list for this boot, before anything is saved.
func TestStopSkipTellsTheMachineFirst(t *testing.T) {
	r := newRig(t, "")
	var order []string
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		switch {
		case strings.Contains(line, "tee /usr/local/bin/ayis-library"):
			order = append(order, "script")
		case strings.Contains(line, "/var/lib/ayis-library/skip"):
			order = append(order, "skip")
			if !strings.Contains(line, "730,1057090") {
				t.Errorf("the list is not written: %s", line)
			}
		case strings.Contains(line, "ayis-library push"):
			order = append(order, "push")
		}
		return prev(line)
	}
	if rc := r.d.Stop(context.Background(), []string{"--yes", "--skip", "730,1057090"}); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.w)
	}
	if got := strings.Join(order, ","); got != "script,skip,push" {
		t.Errorf("order %s", got)
	}
	if rc := newRig(t, "").d.Stop(context.Background(), []string{"--skip", "730;rm -rf /"}); rc != 1 {
		t.Error("a list that is not appids is refused")
	}
}

// If the machine cannot be told, nothing is stopped: the games would be saved after all.
func TestStopSkipThatCannotBeWrittenStopsNothing(t *testing.T) {
	r := newRig(t, "")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "/var/lib/ayis-library/skip") {
			return true, "", errors.New("exit 1")
		}
		return prev(line)
	}
	if rc := r.d.Stop(context.Background(), []string{"--yes", "--skip", "730"}); rc != 1 || len(r.e.calls) != 0 {
		t.Errorf("rc %d calls %v", rc, r.e.calls)
	}
}

// The app asks before it stops a machine; ayis must not ask a second time.
func TestStopYesDoesNotAskAgain(t *testing.T) {
	r := newRig(t, "")
	if rc := r.d.Stop(context.Background(), []string{"--yes"}); rc != 0 || strings.Join(r.e.calls, ",") != "stop" {
		t.Fatalf("rc %d %v\n%s", rc, r.e.calls, r.o)
	}
	if strings.Contains(r.w.String()+r.o.String(), "stop instance now?") {
		t.Error("it asked anyway")
	}
}

func TestStopRefusesWhenTheMirrorFailsUnlessForced(t *testing.T) {
	failPush := func(r *rig) {
		prev := r.r.Hook
		r.r.Hook = func(line string) (bool, string, error) {
			if strings.Contains(line, "ayis-library push") {
				return true, "", &exitCode{1}
			}
			return prev(line)
		}
	}
	r := newRig(t, "")
	failPush(r)
	if rc := r.d.Stop(context.Background(), nil); rc != 1 || len(r.e.calls) != 0 || !strings.Contains(r.w.String(), "not mirrored from here - see above, then: ayis stop --force") {
		t.Fatalf("rc %d %v\n%s", rc, r.e.calls, r.w)
	}
	if !strings.Contains(r.o.String(), "mirrors from ON the box as it shuts") {
		t.Error("the explanation is given")
	}
	r = newRig(t, "")
	failPush(r)
	if rc := r.d.Stop(context.Background(), []string{"--force"}); rc != 0 || strings.Join(r.e.calls, ",") != "stop" || !strings.Contains(r.o.String(), "WARNING: stopping without a mirror (--force) - games will be re-downloaded") {
		t.Errorf("rc %d %v\n%s", rc, r.e.calls, r.o)
	}
	if rc := newRig(t, "").d.Stop(context.Background(), []string{"--now"}); rc != 1 {
		t.Error("only --force")
	}
	// The box is not on the tailnet at all.
	r = newRig(t, "")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if line == "tailscale ip -4 ayis" {
			return true, "", &exitCode{1}
		}
		return prev(line)
	}
	if rc := r.d.Stop(context.Background(), nil); rc != 1 || !strings.Contains(r.o.String(), "box is not reachable over the tailnet - cannot mirror the library") {
		t.Errorf("%s", r.o)
	}
}

func TestAStoppedBoxIsNotMirroredAgain(t *testing.T) {
	r := newRig(t, "")
	r.e.state = "stopped"
	if rc := r.d.Stop(context.Background(), nil); rc != 0 || !strings.Contains(r.o.String(), "already stopped") {
		t.Errorf("%s", r.o)
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "ayis-library") {
			t.Error("mirrored a box that is not running")
		}
	}
}

func TestStopOnASpotBoxOffersDestroyNotStop(t *testing.T) {
	r := newRig(t, "d\n")
	r.e.lifecycle = "spot"
	if rc := r.d.Stop(context.Background(), nil); rc != 0 || r.destroyed != 1 || len(r.e.calls) != 0 {
		t.Fatalf("rc %d destroyed %d %v", rc, r.destroyed, r.e.calls)
	}
	if !strings.Contains(r.o.String(), "This is a SPOT instance, so there is nothing useful to stop:") || !strings.Contains(r.o.String(), "destroying costs a rebuild (the last one took 12 min)") {
		t.Errorf("%s", r.o)
	}
	r = newRig(t, "n\n")
	r.e.lifecycle = "spot"
	if rc := r.d.Stop(context.Background(), nil); rc != 0 || r.destroyed != 0 || !strings.Contains(r.o.String(), "left running - it is STILL BILLING by the hour") {
		t.Errorf("%s", r.o)
	}
}

func TestOpenStartsAStoppedBoxWaitsAndStreams(t *testing.T) {
	r := newRig(t, "")
	r.e.state = "stopped"
	if rc := r.d.Open(context.Background()); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.w)
	}
	got := r.o.String()
	for _, want := range []string{"starting i-0abc ...", "running after ", "waiting for tailscale ok", "pong from ayis (100.64.0.7) via 203.0.113.9:41641 in 31ms", "waiting for sunshine ok", "disk:", "/scratch 100G 250G 40%",
		"session ended - the machine is still running and billing until auto-stop ends it when idle, or delete it now: ayis destroy"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if strings.Join(r.e.calls, ",") != "start" || !strings.Contains(strings.Join(r.r.Ran, "\n"), "moonlight stream 100.64.0.7 Desktop") {
		t.Errorf("%v", r.e.calls)
	}
	if _, held := session.Running(r.d.SessionFile, session.Proc{}); held {
		t.Error("the lock is released when the stream ends")
	}
	// Already running: not started again.
	r = newRig(t, "")
	if rc := r.d.Open(context.Background()); rc != 0 || len(r.e.calls) != 0 || !strings.Contains(r.o.String(), "instance already running") {
		t.Errorf("%v\n%s", r.e.calls, r.o)
	}
}

func TestOpenWarnsOfARelayedPath(t *testing.T) {
	r := newRig(t, "")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if line == "tailscale ping -c 1 ayis" {
			return true, "pong from ayis (100.64.0.7) via DERP(mumbai) in 120ms\n", nil
		}
		return prev(line)
	}
	_ = r.d.Open(context.Background())
	if !strings.Contains(r.o.String(), "WARNING: relayed, not direct - latency will suffer") {
		t.Error(r.o.String())
	}
}

func TestOpenSaysWhyThereIsNothingToStart(t *testing.T) {
	r := newRig(t, "")
	r.e.state = "terminated"
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "there is no machine to start - it was deleted") || len(r.e.calls) != 0 {
		t.Errorf("%s", r.w)
	}
	r = newRig(t, "")
	r.e.describeErr = errors.New("operation error EC2: DescribeInstances, InvalidInstanceID.NotFound")
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "there is no machine to start") {
		t.Errorf("%s", r.w)
	}
	r = newRig(t, "")
	r.e.describeErr = errors.New("operation error EC2: DescribeInstances, RequestExpired\nsecond line")
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "could not read the machine from AWS: operation error EC2: DescribeInstances, RequestExpired") {
		t.Errorf("%s", r.w)
	}
}

func TestASpotBoxWhoseRequestIsDisabledIsExplainedNotStarted(t *testing.T) {
	r := newRig(t, "")
	r.e.state, r.e.lifecycle, r.e.spotState = "stopped", "spot", "disabled"
	if rc := r.d.Open(context.Background()); rc != 1 || len(r.e.calls) != 0 || !strings.Contains(r.w.String(), "spot request is 'disabled'") {
		t.Fatalf("%v\n%s", r.e.calls, r.w)
	}
	for _, want := range []string{"It is a SPOT instance and its spot request is 'disabled'.", "ayis destroy && ayis init          # rebuild (the last one took 12 min), games restored", "ayis destroy && GAME_SPOT=0 ayis init"} {
		if !strings.Contains(r.o.String(), want) {
			t.Errorf("lacks %q in:\n%s", want, r.o)
		}
	}
	// An active request starts normally.
	r = newRig(t, "")
	r.e.state, r.e.lifecycle, r.e.spotState = "stopped", "spot", "active"
	if rc := r.d.Open(context.Background()); rc != 0 || strings.Join(r.e.calls, ",") != "start" {
		t.Errorf("%v", r.e.calls)
	}
	// AWS refusing the start says its first error line.
	r = newRig(t, "")
	r.e.state, r.e.startErr = "stopped", errors.New("operation error EC2: StartInstances, IncorrectSpotRequestState")
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "AWS would not start the machine: operation error EC2: StartInstances, IncorrectSpotRequestState") {
		t.Errorf("%s", r.w)
	}
}

func TestASecondStreamIsRefusedAndSaysWhere(t *testing.T) {
	r := newRig(t, "")
	session.Claim(r.d.SessionFile, time.Unix(1700000000-125, 0))
	r.d.Probe = alwaysAyis{}
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "a session is already running (pid ") || len(r.e.calls) != 0 {
		t.Fatalf("%s", r.w)
	}
	if !strings.Contains(r.o.String(), "A stream from this laptop is already running (started 2m 05s ago).") {
		t.Errorf("%s", r.o)
	}
}

type alwaysAyis struct{}

func (alwaysAyis) Alive(int) bool          { return true }
func (alwaysAyis) Args(int) (string, bool) { return "ayis open", true }

func TestNoSunshineIsDiagnosedFromTheBox(t *testing.T) {
	r := newRig(t, "")
	r.d.Dial = func(string, time.Duration) error { return errors.New("refused") }
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "test -x /usr/bin/sunshine") {
			return true, "sunshine=no\nmarker=no\n12:00 >>> FAILED: installing the driver\n", nil
		}
		return prev(line)
	}
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "sunshine never answered on 100.64.0.7:47989") {
		t.Fatalf("%s", r.w)
	}
	for _, want := range []string{"Sunshine is not installed on this box, so nothing can connect to it.", "It stopped at:  installing the driver", "ssh -i ~/.ssh/ayis.pem ubuntu@100.64.0.7"} {
		if !strings.Contains(r.o.String(), want) {
			t.Errorf("lacks %q in:\n%s", want, r.o)
		}
	}
	// Sunshine installed: only the plain timeout, no claim about the build.
	r = newRig(t, "")
	r.d.Dial = func(string, time.Duration) error { return errors.New("refused") }
	prev = r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "test -x /usr/bin/sunshine") {
			return true, "sunshine=yes\nmarker=yes\n", nil
		}
		return prev(line)
	}
	_ = r.d.Open(context.Background())
	if strings.Contains(r.o.String(), "never finished building") {
		t.Error("claimed the build failed when it did not")
	}
}

func TestMoonlightGetsSystemKeyCaptureOnlyWhenAbsent(t *testing.T) {
	r := newRig(t, "")
	conf := filepath.Join(t.TempDir(), "Moonlight.conf")
	r.d.MoonlightConf = conf
	_ = os.WriteFile(conf, []byte("[General]\nfoo=1\n"), 0o644)
	r.d.moonlightSyskeys(context.Background())
	if b, _ := os.ReadFile(conf); string(b) != "[General]\ncapturesyskeys=2\nfoo=1\n" || !strings.Contains(r.o.String(), "enabled Moonlight system-key capture") {
		t.Errorf("%q", b)
	}
	// Someone who set it deliberately keeps that.
	_ = os.WriteFile(conf, []byte("[General]\ncapturesyskeys=0\n"), 0o644)
	r.d.moonlightSyskeys(context.Background())
	if b, _ := os.ReadFile(conf); string(b) != "[General]\ncapturesyskeys=0\n" {
		t.Errorf("%q", b)
	}
	// Never while Moonlight runs: it rewrites the file on exit.
	_ = os.WriteFile(conf, []byte("[General]\n"), 0o644)
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.HasPrefix(line, "pgrep -x moonlight") {
			return true, "4242\n", nil
		}
		return false, "", nil
	}
	r.d.moonlightSyskeys(context.Background())
	if b, _ := os.ReadFile(conf); string(b) != "[General]\n" {
		t.Errorf("%q", b)
	}
}

func TestCleanNeverTouchesTheInstalledGames(t *testing.T) {
	r := newRig(t, "")
	if rc := r.d.Clean(context.Background()); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	got := sshLines(r.r)
	// The Bash ayis clean removed every folder directly under /scratch - the games included.
	for _, bad := range []string{"find /scratch", "rm -rf /scratch/*", "rm -rf /scratch/steam", "-exec rm"} {
		if strings.Contains(got, bad) {
			t.Errorf("a command that can delete the library: %q in\n%s", bad, got)
		}
	}
	for _, want := range []string{"sudo apt-get clean", "journalctl --vacuum-size=100M", "sudo rm -rf /scratch/tmp /scratch/downloads", "mount-scratch.sh"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in\n%s", want, got)
		}
	}
	for _, want := range []string{"==> before", "==> reclaiming", "==> after"} {
		if !strings.Contains(r.o.String(), want) {
			t.Errorf("lacks %q in:\n%s", want, r.o)
		}
	}
	r = newRig(t, "")
	r.e.state = "stopped"
	if rc := r.d.Clean(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "box is not running; ayis open first, or use: ayis destroy && ayis init") {
		t.Errorf("%s", r.w)
	}
	for _, l := range r.r.Ran {
		if strings.Contains(l, "apt-get") {
			t.Error("cleaned a box that is not running")
		}
	}
	r = newRig(t, "")
	r.d.Box.ID = ""
	if rc := r.d.Clean(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "no instance in .env") {
		t.Error(r.w.String())
	}
}

func TestPairIsANoOpWhenPairedAndOtherwisePairs(t *testing.T) {
	r := newRig(t, "")
	_ = r.d.Env.Set("SUNSHINE_USER", "admin")
	_ = r.d.Env.Set("SUNSHINE_PASS", "pw")
	r.r.Answers = map[string]string{"moonlight list 100.64.0.7": "Desktop\n"}
	if rc := r.d.PairMoonlight(context.Background()); rc != 0 || !strings.Contains(r.o.String(), "already paired with ayis (100.64.0.7)") {
		t.Errorf("%s", r.o)
	}
	for _, l := range r.r.Ran {
		if strings.HasPrefix(l, "moonlight pair") {
			t.Error("paired again")
		}
	}
	r = newRig(t, "")
	if rc := r.d.PairMoonlight(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "no Sunshine credentials in .env - they are written by ayis init") {
		t.Errorf("%s", r.w)
	}
	r = newRig(t, "")
	_ = r.d.Env.Set("SUNSHINE_USER", "admin")
	_ = r.d.Env.Set("SUNSHINE_PASS", "pw")
	r.d.Moonlight = false
	if rc := r.d.PairMoonlight(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "moonlight is not installed") {
		t.Errorf("%s", r.w)
	}
	// Pairing that fails says where to do it by hand.
	r = newRig(t, "")
	_ = r.d.Env.Set("SUNSHINE_USER", "admin")
	_ = r.d.Env.Set("SUNSHINE_PASS", "pw")
	r.d.Pair = sunshine.Pairer{C: sunshine.Client{URL: func(ip, p string) string { return "https://127.0.0.1:1" + p }}, R: r.r, Sleep: func(time.Duration) {}, Log: func(string) {},
		Stale: func() {}, Tries: 1, Verify: 1, Close: time.Millisecond, PIN: func() string { return "1111" }}
	if rc := r.d.PairMoonlight(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "pairing failed. The web UI is https://100.64.0.7:47990 (credentials in .env)") {
		t.Errorf("%s", r.w)
	}
}

func TestSnapshotCreateImagesTheBoxAndWaits(t *testing.T) {
	r := newRig(t, "")
	if rc := r.d.SnapshotCreate(context.Background()); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	got := r.o.String()
	for _, want := range []string{"note: imaging a running instance; stop it first for a consistent image", "creating image ayis-20231114-221320 (several minutes)", "ami-new", "available after 0s", "ready - ayis init will restore from it instead of rebuilding"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	r = newRig(t, "")
	r.e.state = "stopped"
	_ = r.d.SnapshotCreate(context.Background())
	if strings.Contains(r.o.String(), "note: imaging") {
		t.Error("a stopped box is the consistent image")
	}
	r = newRig(t, "")
	r.d.Box.ID = ""
	if rc := r.d.SnapshotCreate(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "no instance in .env - nothing to snapshot") || r.e.imageCreated != 0 {
		t.Error(r.w.String())
	}
}

func TestSnapshotDeleteTakesTheBackingSnapshotsToo(t *testing.T) {
	r := newRig(t, "")
	r.e.images = map[string]string{"ami-1": "available"}
	r.e.snaps = map[string][]string{"ami-1": {"snap-a", "snap-b"}}
	r.e.failSnap = map[string]bool{"snap-b": true}
	// snap-b stays behind and still bills, so this is a failure, not a quiet 0.
	if rc := r.d.SnapshotDelete(context.Background(), "ami-1", r.e); rc != 1 || !strings.Contains(r.w.String(), "1 snapshot(s) could not be deleted and still bill") {
		t.Fatalf("rc %d %s", rc, r.w)
	}
	if strings.Join(r.e.calls, ",") != "deregister ami-1,delete-snapshot snap-a" {
		t.Errorf("%v", r.e.calls)
	}
	if !strings.Contains(r.o.String(), "deregistered ami-1") || !strings.Contains(r.o.String(), "deleted snapshot snap-a") || !strings.Contains(r.o.String(), "could not delete snapshot snap-b (in use by another image?)") {
		t.Errorf("%s", r.o)
	}
	if rc := r.d.SnapshotDelete(context.Background(), "", r.e); rc != 1 || !strings.Contains(r.w.String(), "which image? see: ayis snapshot --list") {
		t.Error(r.w.String())
	}
}

func (f *fakeEC2) DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error) {
	if f.sg == "" || f.sgDeleted {
		return &ec2.DescribeSecurityGroupsOutput{}, nil
	}
	return &ec2.DescribeSecurityGroupsOutput{SecurityGroups: []ec2types.SecurityGroup{{GroupId: aws.String(f.sg)}}}, nil
}
func (f *fakeEC2) DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error) {
	if f.key == "" || f.keyDeleted {
		return &ec2.DescribeKeyPairsOutput{}, nil
	}
	return &ec2.DescribeKeyPairsOutput{KeyPairs: []ec2types.KeyPairInfo{{KeyName: aws.String(f.key)}}}, nil
}
func (f *fakeEC2) DeleteSecurityGroup(context.Context, *ec2.DeleteSecurityGroupInput, ...func(*ec2.Options)) (*ec2.DeleteSecurityGroupOutput, error) {
	if f.sgDeleteFails > 0 {
		f.sgDeleteFails--
		return nil, errors.New("DependencyViolation")
	}
	f.sgDeleted = true
	f.calls = append(f.calls, "delete-sg")
	return &ec2.DeleteSecurityGroupOutput{}, nil
}
func (f *fakeEC2) DeleteKeyPair(context.Context, *ec2.DeleteKeyPairInput, ...func(*ec2.Options)) (*ec2.DeleteKeyPairOutput, error) {
	f.keyDeleted = true
	f.calls = append(f.calls, "delete-key")
	return &ec2.DeleteKeyPairOutput{}, nil
}

// A waiting loop has to notice Ctrl-C and SIGTERM: it used to run its whole
// 60 tries (minutes) after the context was cancelled, and `timeout` could not
// stop `ayis open`.
func TestWaitForStopsWhenInterrupted(t *testing.T) {
	rg := newRig(t, "")
	ctx, cancel := context.WithCancel(context.Background())
	tries := 0
	ok := rg.d.waitFor(ctx, "t.wait", "waiting", 60, func() bool {
		tries++
		if tries == 2 {
			cancel()
		}
		return false
	})
	if ok || tries != 2 {
		t.Fatalf("ok=%v tries=%d, want it to stop right after the cancel", ok, tries)
	}
	if !strings.Contains(rg.o.String(), "interrupted") {
		t.Fatalf("output %q does not say it was interrupted", rg.o.String())
	}
}

func TestSnapshotNoWaitStartsTheImageAndReturns(t *testing.T) {
	r := newRig(t, "")
	if rc := r.d.SnapshotCreateWith(context.Background(), false); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	got := r.o.String()
	if !strings.Contains(got, "ami-new") || !strings.Contains(got, "ayis snapshot --list") || strings.Contains(got, "available after") || strings.Contains(got, "ready - ayis init") {
		t.Errorf("--no-wait must start the image and not wait for it:\n%s", got)
	}
}

func TestInterruptedSnapshotSaysAwsIsStillMakingIt(t *testing.T) {
	r := newRig(t, "")
	r.e.images = map[string]string{"ami-new": "pending"}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if rc := r.d.SnapshotCreateWith(ctx, true); rc != 1 || !strings.Contains(r.o.String()+r.w.String(), "stopped waiting - AWS is still making") {
		t.Errorf("rc=%d\n%s%s", rc, r.o, r.w)
	}
}

// An image whose snapshots cannot be read must not be deregistered: they would be
// unreachable afterwards and bill for ever.
func TestSnapshotDeleteDoesNotDeregisterWhatItCannotRead(t *testing.T) {
	r := newRig(t, "")
	r.e.images = map[string]string{"ami-1": "available"}
	r.e.snaps = map[string][]string{"ami-1": {"snap-a"}}
	r.e.imagesErr = errors.New("RequestLimitExceeded: slow down")
	if rc := r.d.SnapshotDelete(context.Background(), "ami-1", r.e); rc != 1 || strings.Contains(strings.Join(r.e.calls, ","), "deregister") {
		t.Errorf("rc %d %v", rc, r.e.calls)
	}
	if !strings.Contains(r.w.String(), "not deregistering it, because they would be left behind billing") {
		t.Errorf("%s", r.w)
	}
}

// "Billing has ended" is said when it has, not when the request was accepted.
func TestStopDoesNotClaimBillingEndedForABoxThatIsNotStopped(t *testing.T) {
	r := newRig(t, "")
	r.e.stopStays = true
	r.d.Force = true
	if rc := r.d.down(context.Background()); rc != 1 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.w)
	}
	if strings.Contains(r.o.String(), "billing has ended") || !strings.Contains(r.w.String(), "not confirmed stopped") {
		t.Errorf("%s%s", r.o, r.w)
	}
	r = newRig(t, "")
	r.d.Force = true
	if rc := r.d.down(context.Background()); rc != 0 || !strings.Contains(r.o.String(), "billing has ended") {
		t.Errorf("rc %d\n%s%s", rc, r.o, r.w)
	}
}

func TestOpenStopsWhenTheBoxNeverAnswersOverTailscale(t *testing.T) {
	r := newRig(t, "")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.HasPrefix(line, "tailscale ping -c 1 --timeout") {
			return true, "", errors.New("no reply")
		}
		return prev(line)
	}
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "ayis never answered over Tailscale") || strings.Contains(r.o.String(), "waiting for sunshine") {
		t.Errorf("%s%s", r.o, r.w)
	}
}

// A machine built before games were chosen at Play copies every game at boot.
// Open says so, waits for it rather than racing it, and sets the config so the
// next boot copies nothing.
func TestOpenWaitsForTheBootCopyOfEveryGameAndSetsItToNothing(t *testing.T) {
	r := newRig(t, "")
	prev := r.r.Hook
	polls, sed := 0, false
	r.r.Hook = func(line string) (bool, string, error) {
		switch {
		case strings.Contains(line, "systemctl is-active ayis-library-restore.service"):
			polls++
			if polls <= 3 {
				return true, "activating\n", nil
			}
			return true, "active\n", nil
		case strings.Contains(line, "AYIS_APPS=none"):
			sed = true
			return true, "", nil
		}
		return prev(line)
	}
	r.d.Open(context.Background())
	out := r.o.String() + r.w.String()
	if !sed {
		t.Error("the config was not set to restore nothing")
	}
	for _, want := range []string{"first finishing a copy of every game", "the machine's own copy of every game has finished"} {
		if !strings.Contains(out, want) {
			t.Errorf("lacks %q in\n%s", want, out)
		}
	}
}

// A laptop whose pings get nothing still gets through by a real connection: the
// machine's ssh port, which is what made Play pressed a second time work.
func TestTailscaleWaitGetsThroughByARealConnection(t *testing.T) {
	r := newRig(t, "")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.HasPrefix(line, "tailscale ping -c 1 --timeout") {
			return true, "ping timed out", errors.New("exit 1")
		}
		return prev(line)
	}
	var tried []string
	r.d.Reach = func(addr string, _ time.Duration) error { tried = append(tried, addr); return nil }
	r.d.Open(context.Background())
	if len(tried) == 0 || tried[0] != "100.64.0.7:22" || !strings.Contains(r.o.String()+r.w.String(), "its ssh port answered") || !strings.Contains(r.o.String(), "waiting for sunshine") {
		t.Errorf("tried %v\n%s%s", tried, r.o, r.w)
	}
}

// A wait that goes on says why: what the ping answered, the machine's state, and
// this laptop's own line for it - not "waiting for tailscale" and nothing else.
func TestAWaitingTailscaleSaysWhy(t *testing.T) {
	r := newRig(t, "")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		switch {
		case strings.HasPrefix(line, "tailscale ping -c 1 --timeout"):
			return true, "ping \"ayis\" timed out\n", errors.New("exit 1")
		case line == "tailscale status":
			return true, "100.64.0.7  ayis  jebin@  linux  offline\n", nil
		}
		return prev(line)
	}
	r.d.Open(context.Background())
	out := r.o.String() + r.w.String()
	for _, want := range []string{"tailscale ping ayis: ping \"ayis\" timed out", "machine state at AWS: running", "this laptop's tailscale: 100.64.0.7 ayis jebin@ linux offline"} {
		if !strings.Contains(out, want) {
			t.Errorf("lacks %q in\n%s", want, out)
		}
	}
}

// Under the app a wait is events, not dots: raw dots on stdout are not an event, and
// the screen saw nothing until the wait was over.
func TestAWaitIsEventsInTheAppAndDotsOnATerminal(t *testing.T) {
	rg := newRig(t, "")
	rg.d.Out.JSON = true
	tries := 0
	if !rg.d.waitFor(context.Background(), "open.sunshine", "waiting for sunshine", 60, func() bool { tries++; return tries == 3 }) {
		t.Fatal("it came up on the third try")
	}
	if strings.Contains(rg.o.String(), ".") || strings.Contains(rg.o.String(), "waiting for sunshine") {
		t.Errorf("nothing but events in app mode, stdout: %q", rg.o.String())
	}
	var states []string
	for _, l := range strings.Split(strings.TrimSpace(rg.w.String()), "\n") {
		var e struct {
			T, ID, State string
			Secs, Of     int
		}
		if err := json.Unmarshal([]byte(l), &e); err != nil || e.T != "wait" || e.ID != "open.sunshine" {
			t.Fatalf("not a wait event: %q", l)
		}
		states = append(states, e.State)
		// No limit in seconds: a try can take longer than its 2 s pause, so the
		// seconds are the real ones and the limit is not guessed at.
		if e.Of != 0 {
			t.Errorf("no made-up limit: %q", l)
		}
	}
	if strings.Join(states, ",") != "waiting,waiting,done" {
		t.Errorf("%v", states)
	}
	// On a terminal it is the dots, and no event.
	rg = newRig(t, "")
	tries = 0
	rg.d.waitFor(context.Background(), "open.sunshine", "waiting for sunshine", 60, func() bool { tries++; return tries == 3 })
	if rg.o.String() != "waiting for sunshine.. ok\n" || rg.w.String() != "" {
		t.Errorf("%q %q", rg.o.String(), rg.w.String())
	}
}

// A wait on the box's state reports itself as data every poll and once at the end.
func TestWaitStateReportsEveryPollAndHowItEnded(t *testing.T) {
	rg := newRig(t, "")
	var got []string
	rg.d.Box.Beat = func(id, state, text string, secs, of int) {
		got = append(got, fmt.Sprintf("%s %s %s %d/%d", id, state, text, secs, of))
	}
	rg.e.state = "pending"
	if rg.d.Box.WaitState(context.Background(), "running", 6*time.Second) {
		t.Fatal("it never got there")
	}
	if strings.Join(got, "|") != "box.running waiting pending 0/6|box.running waiting pending 3/6|box.running timeout pending 6/6" {
		t.Errorf("%v", got)
	}
	got = nil
	rg.e.state = "running"
	if !rg.d.Box.WaitState(context.Background(), "running", 60*time.Second) || strings.Join(got, "|") != "box.running done running 0/60" {
		t.Errorf("%v", got)
	}
}

// The wait for Tailscale ends each look with one line in words, for the screen.
func TestTailscaleWordsSayWhereTheConnectionIs(t *testing.T) {
	for _, c := range []struct {
		state string
		p     peerState
		want  string
	}{
		{"pending", peerState{}, "still starting at AWS (pending)"},
		{"running", peerState{}, "It is not on your tailnet yet"},
		{"running", peerState{known: true}, "It is not on your tailnet yet"},
		{"running", peerState{known: true, online: true}, "Your laptop is making the connection"},
		{"running", peerState{known: true, online: true, handshake: true}, "not answering yet"},
	} {
		if got := tailscaleWords(c.state, c.p); !strings.Contains(got, c.want) {
			t.Errorf("%s %+v: %q", c.state, c.p, got)
		}
	}
	js := []byte(`{"Peer":{"k":{"HostName":"ayis","DNSName":"ayis.x.ts.net.","Online":true,"Relay":"bom","LastHandshake":"0001-01-01T00:00:00Z"}}}`)
	if p, ok := peerFacts(js, "ayis"); !ok || !p.online || p.handshake || !strings.Contains(p.line, "last_handshake=never") {
		t.Errorf("%+v %v", p, ok)
	}
}

// Play puts the chosen idle minutes on the machine, with the script that reads them.
func TestPlaySyncsTheIdleMinutes(t *testing.T) {
	r := newRig(t, "")
	var put []string
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "idle-watchdog.sh") || strings.Contains(line, "ayis-idle.conf") {
			put = append(put, line)
		}
		return prev(line)
	}
	r.d.Open(context.Background())
	all := strings.Join(put, "\n")
	if !strings.Contains(all, "tee /usr/local/bin/idle-watchdog.sh") || !strings.Contains(all, "IDLE_LIMIT=15 | sudo tee /etc/ayis-idle.conf") {
		t.Errorf("not synced:\n%s", all)
	}
}

// Every Stop puts the current saving script on the machine before saving, games
// unticked or not: it is what lets the save on the way down skip itself when
// nothing has changed. A plain stop goes on if that fails.
func TestEveryStopRefreshesTheSavingScript(t *testing.T) {
	r := newRig(t, "")
	var order []string
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		switch {
		case strings.Contains(line, "tee /usr/local/bin/ayis-library"):
			order = append(order, "script")
		case strings.Contains(line, "/var/lib/ayis-library/skip"):
			order = append(order, "skip")
		case strings.Contains(line, "ayis-library push"):
			order = append(order, "push")
		}
		return prev(line)
	}
	if rc := r.d.Stop(context.Background(), []string{"--yes"}); rc != 0 || strings.Join(order, ",") != "script,push" {
		t.Errorf("rc %d order %v", rc, order)
	}
	r = newRig(t, "")
	prev = r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "tee /usr/local/bin/ayis-library") {
			return true, "", errors.New("exit 1")
		}
		return prev(line)
	}
	if rc := r.d.Stop(context.Background(), []string{"--yes"}); rc != 0 || strings.Join(r.e.calls, ",") != "stop" {
		t.Errorf("a plain stop goes on without the new script: rc %d calls %v", rc, r.e.calls)
	}
}
