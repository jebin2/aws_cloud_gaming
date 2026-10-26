package initcmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
	"github.com/aws/smithy-go"

	cg "github.com/jebin2/aws_cloud_gaming"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/check"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/provision"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// aws is a whole account in one fake: an EC2 that remembers, an S3 and an IAM
// that say yes, a budget that does not exist yet.
type acct struct {
	state, lifecycle string // of the one instance, "" when there is none
	id               string
	runs             int
	launchErr        error
	shutdown         string // what shutdown behaviour reads back
	launched         time.Time
	calls            []string
	profile          bool
}

func (a *acct) exists() bool { return a.state != "" }

func (a *acct) DescribeInstances(_ context.Context, in *ec2.DescribeInstancesInput, _ ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	if !a.exists() {
		if len(in.InstanceIds) > 0 {
			return nil, errors.New("InvalidInstanceID.NotFound")
		}
		return &ec2.DescribeInstancesOutput{}, nil
	}
	lt := a.launched
	i := ec2types.Instance{InstanceId: aws.String(a.id), State: &ec2types.InstanceState{Name: ec2types.InstanceStateName(a.state)}, InstanceLifecycle: ec2types.InstanceLifecycleType(a.lifecycle), LaunchTime: &lt}
	return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: []ec2types.Instance{i}}}}, nil
}
func (a *acct) RunInstances(_ context.Context, in *ec2.RunInstancesInput, _ ...func(*ec2.Options)) (*ec2.RunInstancesOutput, error) {
	a.runs++
	if a.launchErr != nil {
		return nil, a.launchErr
	}
	a.state, a.id = "running", "i-0new"
	if in.InstanceMarketOptions != nil {
		a.lifecycle = "spot"
		a.shutdown = "terminate"
	} else {
		a.shutdown = "stop"
	}
	return &ec2.RunInstancesOutput{Instances: []ec2types.Instance{{InstanceId: aws.String(a.id)}}}, nil
}
func (a *acct) StartInstances(context.Context, *ec2.StartInstancesInput, ...func(*ec2.Options)) (*ec2.StartInstancesOutput, error) {
	a.calls = append(a.calls, "start")
	a.state = "running"
	return &ec2.StartInstancesOutput{}, nil
}
func (a *acct) StopInstances(context.Context, *ec2.StopInstancesInput, ...func(*ec2.Options)) (*ec2.StopInstancesOutput, error) {
	return &ec2.StopInstancesOutput{}, nil
}
func (a *acct) TerminateInstances(context.Context, *ec2.TerminateInstancesInput, ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error) {
	return &ec2.TerminateInstancesOutput{}, nil
}
func (a *acct) DescribeSpotInstanceRequests(context.Context, *ec2.DescribeSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.DescribeSpotInstanceRequestsOutput, error) {
	return &ec2.DescribeSpotInstanceRequestsOutput{}, nil
}
func (a *acct) CancelSpotInstanceRequests(context.Context, *ec2.CancelSpotInstanceRequestsInput, ...func(*ec2.Options)) (*ec2.CancelSpotInstanceRequestsOutput, error) {
	return &ec2.CancelSpotInstanceRequestsOutput{}, nil
}
func (a *acct) CreateImage(context.Context, *ec2.CreateImageInput, ...func(*ec2.Options)) (*ec2.CreateImageOutput, error) {
	return &ec2.CreateImageOutput{}, nil
}
func (a *acct) DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error) {
	return &ec2.DescribeImagesOutput{}, nil
}
func (a *acct) DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	return &ec2.DescribeVolumesOutput{}, nil
}
func (a *acct) DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error) {
	return nil, &smithy.GenericAPIError{Code: "InvalidKeyPair.NotFound"}
}
func (a *acct) DeleteKeyPair(context.Context, *ec2.DeleteKeyPairInput, ...func(*ec2.Options)) (*ec2.DeleteKeyPairOutput, error) {
	return &ec2.DeleteKeyPairOutput{}, nil
}
func (a *acct) CreateKeyPair(context.Context, *ec2.CreateKeyPairInput, ...func(*ec2.Options)) (*ec2.CreateKeyPairOutput, error) {
	return &ec2.CreateKeyPairOutput{KeyMaterial: aws.String("PRIVATE")}, nil
}
func (a *acct) DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error) {
	return &ec2.DescribeSecurityGroupsOutput{SecurityGroups: []ec2types.SecurityGroup{{GroupId: aws.String("sg-1")}}}, nil
}
func (a *acct) CreateSecurityGroup(context.Context, *ec2.CreateSecurityGroupInput, ...func(*ec2.Options)) (*ec2.CreateSecurityGroupOutput, error) {
	return &ec2.CreateSecurityGroupOutput{GroupId: aws.String("sg-1")}, nil
}
func (a *acct) AuthorizeSecurityGroupIngress(context.Context, *ec2.AuthorizeSecurityGroupIngressInput, ...func(*ec2.Options)) (*ec2.AuthorizeSecurityGroupIngressOutput, error) {
	return &ec2.AuthorizeSecurityGroupIngressOutput{}, nil
}
func (a *acct) CreateTags(context.Context, *ec2.CreateTagsInput, ...func(*ec2.Options)) (*ec2.CreateTagsOutput, error) {
	return &ec2.CreateTagsOutput{}, nil
}
func (a *acct) DescribeIamInstanceProfileAssociations(context.Context, *ec2.DescribeIamInstanceProfileAssociationsInput, ...func(*ec2.Options)) (*ec2.DescribeIamInstanceProfileAssociationsOutput, error) {
	return &ec2.DescribeIamInstanceProfileAssociationsOutput{IamInstanceProfileAssociations: []ec2types.IamInstanceProfileAssociation{{}}}, nil
}
func (a *acct) AssociateIamInstanceProfile(context.Context, *ec2.AssociateIamInstanceProfileInput, ...func(*ec2.Options)) (*ec2.AssociateIamInstanceProfileOutput, error) {
	return &ec2.AssociateIamInstanceProfileOutput{}, nil
}
func (a *acct) ModifyInstanceAttribute(context.Context, *ec2.ModifyInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.ModifyInstanceAttributeOutput, error) {
	a.shutdown = "stop"
	return &ec2.ModifyInstanceAttributeOutput{}, nil
}
func (a *acct) DescribeInstanceAttribute(context.Context, *ec2.DescribeInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceAttributeOutput, error) {
	return &ec2.DescribeInstanceAttributeOutput{InstanceInitiatedShutdownBehavior: &ec2types.AttributeValue{Value: aws.String(a.shutdown)}}, nil
}

type s3ok struct{}

func (s3ok) HeadBucket(context.Context, *s3.HeadBucketInput, ...func(*s3.Options)) (*s3.HeadBucketOutput, error) {
	return &s3.HeadBucketOutput{}, nil
}
func (s3ok) CreateBucket(context.Context, *s3.CreateBucketInput, ...func(*s3.Options)) (*s3.CreateBucketOutput, error) {
	return &s3.CreateBucketOutput{}, nil
}
func (s3ok) PutPublicAccessBlock(context.Context, *s3.PutPublicAccessBlockInput, ...func(*s3.Options)) (*s3.PutPublicAccessBlockOutput, error) {
	return &s3.PutPublicAccessBlockOutput{}, nil
}
func (s3ok) PutBucketEncryption(context.Context, *s3.PutBucketEncryptionInput, ...func(*s3.Options)) (*s3.PutBucketEncryptionOutput, error) {
	return &s3.PutBucketEncryptionOutput{}, nil
}
func (s3ok) PutBucketLifecycleConfiguration(context.Context, *s3.PutBucketLifecycleConfigurationInput, ...func(*s3.Options)) (*s3.PutBucketLifecycleConfigurationOutput, error) {
	return &s3.PutBucketLifecycleConfigurationOutput{}, nil
}
func (s3ok) PutBucketTagging(context.Context, *s3.PutBucketTaggingInput, ...func(*s3.Options)) (*s3.PutBucketTaggingOutput, error) {
	return &s3.PutBucketTaggingOutput{}, nil
}

type iamok struct{}

func (iamok) GetRole(context.Context, *iam.GetRoleInput, ...func(*iam.Options)) (*iam.GetRoleOutput, error) {
	return &iam.GetRoleOutput{}, nil
}
func (iamok) CreateRole(context.Context, *iam.CreateRoleInput, ...func(*iam.Options)) (*iam.CreateRoleOutput, error) {
	return &iam.CreateRoleOutput{}, nil
}
func (iamok) PutRolePolicy(context.Context, *iam.PutRolePolicyInput, ...func(*iam.Options)) (*iam.PutRolePolicyOutput, error) {
	return &iam.PutRolePolicyOutput{}, nil
}
func (iamok) TagRole(context.Context, *iam.TagRoleInput, ...func(*iam.Options)) (*iam.TagRoleOutput, error) {
	return &iam.TagRoleOutput{}, nil
}
func (iamok) GetInstanceProfile(context.Context, *iam.GetInstanceProfileInput, ...func(*iam.Options)) (*iam.GetInstanceProfileOutput, error) {
	return nil, errors.New("NoSuchEntity")
}
func (iamok) CreateInstanceProfile(context.Context, *iam.CreateInstanceProfileInput, ...func(*iam.Options)) (*iam.CreateInstanceProfileOutput, error) {
	return &iam.CreateInstanceProfileOutput{}, nil
}
func (iamok) TagInstanceProfile(context.Context, *iam.TagInstanceProfileInput, ...func(*iam.Options)) (*iam.TagInstanceProfileOutput, error) {
	return &iam.TagInstanceProfileOutput{}, nil
}
func (iamok) AddRoleToInstanceProfile(context.Context, *iam.AddRoleToInstanceProfileInput, ...func(*iam.Options)) (*iam.AddRoleToInstanceProfileOutput, error) {
	return &iam.AddRoleToInstanceProfileOutput{}, nil
}

type budgetsok struct{ created int }

func (b *budgetsok) DescribeBudget(context.Context, *budgets.DescribeBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeBudgetOutput, error) {
	return nil, errors.New("NotFoundException")
}
func (b *budgetsok) CreateBudget(context.Context, *budgets.CreateBudgetInput, ...func(*budgets.Options)) (*budgets.CreateBudgetOutput, error) {
	b.created++
	return &budgets.CreateBudgetOutput{}, nil
}
func (b *budgetsok) UpdateBudget(context.Context, *budgets.UpdateBudgetInput, ...func(*budgets.Options)) (*budgets.UpdateBudgetOutput, error) {
	return &budgets.UpdateBudgetOutput{}, nil
}

type ssmok struct{}

func (ssmok) GetParameter(context.Context, *ssm.GetParameterInput, ...func(*ssm.Options)) (*ssm.GetParameterOutput, error) {
	return &ssm.GetParameterOutput{Parameter: &ssmtypes.Parameter{Value: aws.String("ami-ubuntu")}}, nil
}

type fakeUploader struct{ puts int }

func (u *fakeUploader) Put(context.Context, string, string, string, []byte) error {
	u.puts++
	return nil
}
func (u *fakeUploader) Presign(_ context.Context, b, r, k string, _ time.Duration) (string, error) {
	return "https://" + b + ".s3." + r + ".amazonaws.com/" + k + "?sig=1", nil
}
func (u *fakeUploader) List(context.Context, string, string, string) ([]provision.Object, error) {
	return nil, nil
}

type exitCode struct{ n int }

func (e *exitCode) Error() string { return "exit" }
func (e *exitCode) ExitCode() int { return e.n }

type rig struct {
	i        *Init
	a        *acct
	r        *fx.Runner
	o, e     *bytes.Buffer
	env      *config.Env
	dir      string
	notes    []string
	budgets  *budgetsok
	up       *fakeUploader
	joined   func() bool
	buildLog string
	ready    bool
}

func newRig(t *testing.T) *rig {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, ".env"), []byte("EMAIL_ALERTS=a@b.c\nTAILSCALE_AUTH_KEY=tskey-auth-xxxxxxxxxxxxxxxx\nGAME_SPOT=0\n"), 0o600)
	env := config.Load(func(string) (string, bool) { return "", false }, dir)
	a := &acct{launched: time.Date(2026, 10, 25, 8, 0, 0, 0, time.UTC), shutdown: "stop"}
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	rg := &rig{a: a, o: &o, e: &e, env: env, dir: dir, budgets: &budgetsok{}, up: &fakeUploader{}, buildLog: ">>> installing\n>>> ok: installing\n", ready: true}
	r := &fx.Runner{Installed: map[string]bool{"tailscale": true, "ssh": true, "sh": true, "moonlight": true, "ssh-keygen": true}}
	rg.r = r
	rg.joined = func() bool { return a.exists() }
	r.Hook = func(line string) (bool, string, error) {
		joined := rg.joined()
		switch {
		case line == "tailscale status --json":
			if joined {
				return true, `{"Peer":{"nodekey:new":{"DNSName":"gamevps.t.ts.net.","PublicKey":"nodekey:new"}}}`, nil
			}
			return true, `{"Peer":{"nodekey:phone":{"DNSName":"phone.t.ts.net.","PublicKey":"nodekey:phone"}}}`, nil
		case line == "tailscale status":
			if joined {
				return true, "100.64.0.7   gamevps   me@   linux   -\n100.64.0.2   phone   me@   android   -\n", nil
			}
			return true, "100.64.0.2   phone   me@   android   -\n", nil
		case strings.HasPrefix(line, "tailscale ip -4"):
			if joined {
				return true, "100.64.0.7\n", nil
			}
			return true, "", &exitCode{1}
		case strings.HasPrefix(line, "tailscale ping"):
			return true, "pong\n", nil
		case strings.Contains(line, "tail -n +"):
			return true, rg.buildLog, nil
		case strings.Contains(line, "test -f /var/lib/cloud-gaming-ready"):
			if rg.ready {
				return true, "", nil
			}
			return true, "", &exitCode{1}
		case strings.Contains(line, ".steam-prewarmed"):
			return true, "", nil
		case strings.Contains(line, `printf "%s|%s`):
			return true, "working|\n", nil
		case strings.HasPrefix(line, "moonlight list"):
			return true, "Desktop\n", nil
		case strings.Contains(line, "bash -s /scratch/steam"):
			return true, "login\tno\nlibrary\tyes\n", nil
		case strings.Contains(line, "install-watchdog.sh"):
			return true, "installed idle-watchdog.timer\n", nil
		case strings.Contains(line, "libraryfolders.vdf") && strings.Contains(line, "grep -q") && !strings.Contains(line, "echo"):
			return true, "", nil
		case strings.Contains(line, "echo \"    client:"):
			return true, "    client:  600M\n    library: /scratch/steam registered\n    dock:    pinned\n", nil
		}
		return false, "", nil
	}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		if q.URL.Path == "/welcome" {
			w.WriteHeader(302)
			return
		}
		if u, p, ok := q.BasicAuth(); ok && u == "admin" && p == "pw" {
			w.WriteHeader(200)
			return
		}
		w.WriteHeader(401)
	}))
	t.Cleanup(srv.Close)
	_ = env.Set("SUNSHINE_USER", "admin")
	_ = env.Set("SUNSHINE_PASS", "pw")
	sun := sunshine.Client{HTTP: srv.Client(), URL: func(ip, path string) string { return srv.URL + path }}
	tsSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) { w.WriteHeader(401) }))
	t.Cleanup(tsSrv.Close)
	fx2 := 90.0
	rg.i = &Init{
		Out: out, Env: env, R: r,
		Preflight: func(context.Context) (check.Result, int) {
			return check.Result{Type: "g6.xlarge", Region: "ap-south-2", VCPUs: 4, Spot: false, AuthKey: "tskey-auth-xxxxxxxxxxxxxxxx"}, 0
		},
		Lib: func(b string) provision.Library {
			return provision.Library{S3: s3ok{}, IAM: iamok{}, Account: "123456789012", Host: "gamevps", Region: "ap-south-2", Named: b, Sleep: func(time.Duration) {}}
		},
		BucketRegion: func(context.Context, string) (string, error) { return "ap-south-2", nil },
		Provisioner:  provision.Provisioner{EC2: a, SSM: ssmok{}, Up: rg.up, Src: cg.Files, Now: func() time.Time { return time.Date(2026, 10, 25, 9, 8, 7, 0, time.UTC) }, Sleep: func(time.Duration) {}},
		Budget: func(inr float64) provision.Budget {
			return provision.Budget{C: rg.budgets, Account: "123456789012", Host: "gamevps", INR: inr, FX: &fx2, Email: "a@b.c"}
		},
		Shutdown: a, EC2: a,
		TS:  func(token string) tskey.Client { return tskey.Client{Token: token, Base: tsSrv.URL} },
		Sun: sun, Pair: sunshine.Pairer{C: sun, R: r, Sleep: func(time.Duration) {}, Log: out.Log}, Moonlight: true,
		Notify: func(_ context.Context, title, msg, prio, tags string) {
			rg.notes = append(rg.notes, title+"|"+prio+"|"+tags)
		},
		WatchdogState: func(context.Context) (bool, int) { return true, 5 },
		Home:          dir, Cache: filepath.Join(dir, "cache"),
		Now:   func() time.Time { return time.Date(2026, 10, 25, 8, 12, 0, 0, time.UTC) },
		Sleep: func(time.Duration) {}, NodeTimeout: 3 * time.Minute,
	}

	_ = bufio.NewReader
	return rg
}

func TestAFreshBuildFromNothingToReady(t *testing.T) {
	r := newRig(t)
	if rc := r.i.Run(context.Background()); rc != 0 {
		t.Fatalf("rc %d\n%s\n%s", rc, r.o, r.e)
	}
	if r.a.runs != 1 {
		t.Errorf("one instance: %d", r.a.runs)
	}
	got := r.o.String()
	// The order the steps are said in is the order they happen.
	order := []string{"arming the budget before anything launches", "provisioning instance", "ensuring the S3 game library", "==> launching g6.xlarge", "confirming what shutdown does to this instance",
		"waiting for the box to join the tailnet", "turning off Tailscale key expiry for 'gamevps'", "building the box", "refreshing the on-host watchdog", "Sunshine account", "moonlight pairing", "waiting for Steam to finish installing", "Box          i-0new"}
	last := -1
	for _, want := range order {
		at := strings.Index(got, want)
		if at < 0 || at < last {
			t.Fatalf("%q missing or out of order (%d after %d) in:\n%s", want, at, last, got)
		}
		last = at
	}
	for k, want := range map[string]string{"GAME_INSTANCE_ID": "i-0new", "GAME_TS_NODE": "gamevps", "GAME_TS_HOST": "gamevps", "GAME_REGION": r.env.Region()} {
		if r.env.Get(k) != want {
			t.Errorf("%s = %q, want %q", k, r.env.Get(k), want)
		}
	}
	if r.env.Get("GAME_S3_BUCKET") == "" {
		t.Error("the bucket is remembered")
	}
	if !strings.Contains(got, "Tailscale    gamevps · 100.64.0.7 · key expiry ON - see below") {
		t.Errorf("the summary: %s", got)
	}
	if len(r.notes) != 1 || r.notes[0] != "box ready|default|video_game" {
		t.Errorf("%v", r.notes)
	}
	if _, err := os.Stat(filepath.Join(r.i.Cache, "built-i-0new")); err != nil {
		t.Error("the built marker: " + err.Error())
	}
	if b, _ := os.ReadFile(filepath.Join(r.i.Cache, "last-build-min")); string(b) != "12" {
		t.Errorf("minutes from launch to ready, rounded up: %q", b)
	}
	if r.budgets.created != 1 || r.up.puts != 1 {
		t.Errorf("budget %d bundle %d", r.budgets.created, r.up.puts)
	}
}

func TestARerunFindsTheSameBoxAndLaunchesNoSecond(t *testing.T) {
	r := newRig(t)
	if rc := r.i.Run(context.Background()); rc != 0 {
		t.Fatalf("%s\n%s", r.o, r.e)
	}
	r.o.Reset()
	r.notes = nil
	if rc := r.i.Run(context.Background()); rc != 0 {
		t.Fatalf("rc %d\n%s\n%s", rc, r.o, r.e)
	}
	if r.a.runs != 1 {
		t.Errorf("no second instance on a rerun: %d launches", r.a.runs)
	}
	got := r.o.String()
	for _, want := range []string{"reusing existing instance i-0new", "reusing the existing box, already on the tailnet as 'gamevps'", "path up"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "waiting for the box to join the tailnet") {
		t.Error("a reused box's node is adopted, not waited for - no new node can appear")
	}
}

func TestAStoppedBoxIsStartedBeforeWaitingForItsNode(t *testing.T) {
	r := newRig(t)
	r.a.state, r.a.id, r.a.shutdown = "stopped", "i-0old", "stop"
	r.joined = func() bool { return r.a.state == "running" }
	// The node is known from before, in .env and on the tailnet once the box runs.
	_ = r.env.Set("GAME_TS_NODE", "gamevps")
	if rc := r.i.Run(context.Background()); rc != 0 {
		t.Fatalf("%s\n%s", r.o, r.e)
	}
	if strings.Join(r.a.calls, ",") != "start" || !strings.Contains(r.o.String(), "==> starting the existing instance") || r.a.runs != 0 {
		t.Errorf("%v %d", r.a.calls, r.a.runs)
	}
}

func TestARefusedLaunchStopsWithTheCauseAndRecordsNothing(t *testing.T) {
	r := newRig(t)
	r.a.launchErr = &smithy.GenericAPIError{Code: "InsufficientInstanceCapacity", Message: "We currently do not have sufficient g6.xlarge capacity."}
	if rc := r.i.Run(context.Background()); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	if !strings.Contains(r.o.String(), "!! AWS has no spare g6.xlarge in ap-south-2 right now") || !strings.Contains(r.e.String(), "could not launch the instance - see the launch error above") {
		t.Errorf("%s\n%s", r.o, r.e)
	}
	if r.env.Get("GAME_INSTANCE_ID") != "" || len(r.notes) != 0 {
		t.Error("nothing was launched, so nothing is recorded")
	}
}

func TestAShutdownThatWouldDeleteTheDiskStopsTheBuild(t *testing.T) {
	r := newRig(t)
	prev := r.i.Shutdown
	_ = prev
	r.i.Shutdown = badShutdown{r.a}
	if rc := r.i.Run(context.Background()); rc != 1 || !strings.Contains(r.o.String(), "FATAL: shutdown behaviour is 'terminate', expected 'stop'.") || strings.Contains(r.o.String(), "waiting for the box to join") {
		t.Errorf("rc %d\n%s\n%s", rc, r.o, r.e)
	}
}

type badShutdown struct{ *acct }

func (badShutdown) DescribeInstanceAttribute(context.Context, *ec2.DescribeInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceAttributeOutput, error) {
	return &ec2.DescribeInstanceAttributeOutput{InstanceInitiatedShutdownBehavior: &ec2types.AttributeValue{Value: aws.String("terminate")}}, nil
}

func TestNoNewNodeSaysWhereToLook(t *testing.T) {
	r := newRig(t)
	r.joined = func() bool { return false }
	if rc := r.i.Run(context.Background()); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	if !strings.Contains(r.e.String(), "no new node joined after 30 min.") || !strings.Contains(r.e.String(), "aws ec2 get-console-output --region ap-south-2 --instance-id i-0new --output text | tail -40") {
		t.Errorf("%s", r.e)
	}
}

func TestABuildThatStopsLeavesTheBoxAndSaysItIsBilling(t *testing.T) {
	r := newRig(t)
	r.buildLog = ">>> FAILED: installing the driver\n"
	r.ready = false
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "cloud-gaming-bootstrap.rc") {
			return true, "exited|no\n", nil
		}
		return prev(line)
	}
	if rc := r.i.Run(context.Background()); rc != 1 {
		t.Fatalf("rc %d\n%s", rc, r.o)
	}
	if !strings.Contains(r.e.String(), "the build did not finish. The instance is still running and still") || !strings.Contains(r.e.String(), "stop it with cg stop once you have looked at the log.") {
		t.Errorf("%s", r.e)
	}
	if len(r.notes) != 1 || r.notes[0] != "build failed|high|warning" {
		t.Errorf("%v", r.notes)
	}
	if _, err := os.Stat(filepath.Join(r.i.Cache, "built-i-0new")); err == nil {
		t.Error("a build that did not finish is not built")
	}
}

func TestAnOfflineNodeFromAnEarlierBoxIsSaid(t *testing.T) {
	r := newRig(t)
	r.joined = func() bool { return r.a.exists() }
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if line == "tailscale status" && !r.a.exists() {
			return true, "100.64.0.9   gamevps   me@   linux   offline, last seen 3d ago\n", nil
		}
		return prev(line)
	}
	_ = r.i.Run(context.Background())
	if !strings.Contains(r.o.String(), "note: an offline 'gamevps' node is left from an earlier box - it is pruned before launch, so the new box takes the name") {
		t.Errorf("%s", r.o)
	}
}
