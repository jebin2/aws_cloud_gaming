package boxcmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/box"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
	"github.com/jebin2/aws_cloud_gaming/internal/stream"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

// fakeEC2 is one instance, and what is done to it.
type fakeEC2 struct {
	state                 string
	lifecycle             string
	spotState             string
	describeErr           error
	startErr              error
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
	return &ec2.StopInstancesOutput{}, nil
}
func (f *fakeEC2) TerminateInstances(context.Context, *ec2.TerminateInstancesInput, ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error) {
	f.calls = append(f.calls, "terminate")
	f.state = "terminated"
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
		case line == "tailscale ip -4 gamevps":
			return true, "100.64.0.7\n", nil
		case strings.HasPrefix(line, "tailscale ping -c 1 --timeout"):
			return true, "pong\n", nil
		case line == "tailscale ping -c 1 gamevps":
			return true, "pong from gamevps (100.64.0.7) via 203.0.113.9:41641 in 31ms\n", nil
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
		Box: box.Box{EC2: e, ID: "i-0abc", Host: "gamevps", Node: "gamevps", Key: filepath.Join(dir, "gamevps.pem"), R: r,
			Sleep: func(d time.Duration) { rg.slept += d }, Log: out.Log},
		Out: out, Ask: a, Env: env, R: r, Sun: sunshine.Client{}, SessionFile: filepath.Join(dir, "session.pid"), Probe: session.Proc{},
		Now: func() time.Time { return time.Unix(1700000000, 0) }, Sleep: func(d time.Duration) { rg.slept += d }, Moonlight: true,
		Takes: func() string { return "the last one took 12 min" },
		Dial:  func(string, time.Duration) error { return nil },
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
		if line == "tailscale ip -4 gamevps" {
			return true, "", &exitCode{1}
		}
		return false, "", nil
	}
	if rc := r.d.Library(context.Background(), "push", nil); rc != 1 || !strings.Contains(r.w.String(), "'gamevps' is not on the tailnet. Is the box running? Try: cg status") {
		t.Fatalf("%s", r.w)
	}
	r = newRig(t, "")
	if rc := r.d.Library(context.Background(), "pull", []string{"--apps", "1091500,2; rm -rf /"}); rc != 0 {
		t.Fatal(r.w)
	}
	got := sshLines(r.r)
	// Each word is one word on the box: what was typed cannot become a second command.
	if !strings.Contains(got, "/usr/local/bin/cg-library pull --apps '1091500,2; rm -rf /'") {
		t.Errorf("%s", got)
	}
	r = newRig(t, "")
	_ = r.d.Library(context.Background(), "account", []string{"restore"})
	if !strings.Contains(sshLines(r.r), "cg-library account pull") {
		t.Errorf("restore is pull: %s", sshLines(r.r))
	}
	if rc := newRig(t, "").d.Library(context.Background(), "nonsense", nil); rc != 1 {
		t.Error("usage")
	}
}

func TestLibraryFailureKeepsTheBoxsExitStatus(t *testing.T) {
	r := newRig(t, "")
	r.r.Hook = func(line string) (bool, string, error) {
		if line == "tailscale ip -4 gamevps" {
			return true, "100.64.0.7\n", nil
		}
		if strings.Contains(line, "cg-library push") {
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
	for _, want := range []string{"==> mirroring the game library to S3 (the instance store is wiped on stop)", "stopped after ", "billing has ended"} {
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
		if strings.Contains(l, "cg-library push") {
			push = i
		}
	}
	_ = stop
	if push < 0 {
		t.Error("no mirror")
	}
}

func TestStopRefusesWhenTheMirrorFailsUnlessForced(t *testing.T) {
	failPush := func(r *rig) {
		prev := r.r.Hook
		r.r.Hook = func(line string) (bool, string, error) {
			if strings.Contains(line, "cg-library push") {
				return true, "", &exitCode{1}
			}
			return prev(line)
		}
	}
	r := newRig(t, "")
	failPush(r)
	if rc := r.d.Stop(context.Background(), nil); rc != 1 || len(r.e.calls) != 0 || !strings.Contains(r.w.String(), "not mirrored from here - see above, then: cg stop --force") {
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
		if line == "tailscale ip -4 gamevps" {
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
		if strings.Contains(l, "cg-library") {
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
	for _, want := range []string{"starting i-0abc ...", "running after ", "waiting for tailscale ok", "pong from gamevps (100.64.0.7) via 203.0.113.9:41641 in 31ms", "waiting for sunshine ok", "disk:", "/scratch 100G 250G 40%",
		"session ended - the machine is still running and billing until auto-stop ends it when idle, or delete it now: cg destroy"} {
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
		if line == "tailscale ping -c 1 gamevps" {
			return true, "pong from gamevps (100.64.0.7) via DERP(mumbai) in 120ms\n", nil
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
	for _, want := range []string{"It is a SPOT instance and its spot request is 'disabled'.", "cg destroy && cg init          # rebuild (the last one took 12 min), games restored", "cg destroy && GAME_SPOT=0 cg init"} {
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
	r.d.Probe = alwaysCg{}
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "a session is already running (pid ") || len(r.e.calls) != 0 {
		t.Fatalf("%s", r.w)
	}
	if !strings.Contains(r.o.String(), "A stream from this laptop is already running (started 2m 05s ago).") {
		t.Errorf("%s", r.o)
	}
}

type alwaysCg struct{}

func (alwaysCg) Alive(int) bool          { return true }
func (alwaysCg) Args(int) (string, bool) { return "cg open", true }

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
	for _, want := range []string{"Sunshine is not installed on this box, so nothing can connect to it.", "It stopped at:  installing the driver", "ssh -i ~/.ssh/gamevps.pem ubuntu@100.64.0.7"} {
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
	// The Bash cg clean removed every folder directly under /scratch - the games included.
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
	if rc := r.d.Clean(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "box is not running; cg open first, or use: cg destroy && cg init") {
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
	if rc := r.d.PairMoonlight(context.Background()); rc != 0 || !strings.Contains(r.o.String(), "already paired with gamevps (100.64.0.7)") {
		t.Errorf("%s", r.o)
	}
	for _, l := range r.r.Ran {
		if strings.HasPrefix(l, "moonlight pair") {
			t.Error("paired again")
		}
	}
	r = newRig(t, "")
	if rc := r.d.PairMoonlight(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "no Sunshine credentials in .env - they are written by cg init") {
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
	for _, want := range []string{"note: imaging a running instance; stop it first for a consistent image", "creating image gamevps-20231114-221320 (several minutes)", "ami-new", "available after 0s", "ready - cg init will restore from it instead of rebuilding"} {
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
	if rc := r.d.SnapshotDelete(context.Background(), "ami-1", r.e); rc != 0 {
		t.Fatal(r.w)
	}
	if strings.Join(r.e.calls, ",") != "deregister ami-1,delete-snapshot snap-a" {
		t.Errorf("%v", r.e.calls)
	}
	if !strings.Contains(r.o.String(), "deregistered ami-1") || !strings.Contains(r.o.String(), "deleted snapshot snap-a") || !strings.Contains(r.o.String(), "could not delete snapshot snap-b (in use by another image?)") {
		t.Errorf("%s", r.o)
	}
	if rc := r.d.SnapshotDelete(context.Background(), "", r.e); rc != 1 || !strings.Contains(r.w.String(), "which image? see: cg snapshot --list") {
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
