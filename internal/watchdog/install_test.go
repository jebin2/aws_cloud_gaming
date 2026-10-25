package watchdog

import (
	"context"
	"encoding/base64"
	"errors"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/eventbridge"
	ebtypes "github.com/aws/aws-sdk-go-v2/service/eventbridge/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	lambdatypes "github.com/aws/aws-sdk-go-v2/service/lambda/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

// cloud is one stateful fake of everything the installer touches, so that what it
// writes is what the reader then reads: an install must read as current.
type cloud struct {
	mu          sync.Mutex
	roles       map[string]string // role -> inline policy document
	fn          *lambda.GetFunctionConfigurationOutput
	rules       map[string]*ebtypes.Rule
	ruleStates  map[string]ebtypes.RuleState
	targets     map[string]string
	permissions map[string]string // statement id -> source arn
	groups      map[string]bool
	retention   int32
	params      []string
	calls       []string
	failOn      map[string]error
	createFails int // CreateFunction fails this many times with InvalidParameterValue first
	invoke      *lambda.InvokeOutput
	account     string
	region      string
	others      map[string]bool // other regions that have the function
	regionsErr  error
	otherErr    map[string]error
	failedEntry bool
}

func newCloud() *cloud {
	return &cloud{roles: map[string]string{}, rules: map[string]*ebtypes.Rule{}, ruleStates: map[string]ebtypes.RuleState{}, targets: map[string]string{},
		permissions: map[string]string{}, groups: map[string]bool{}, failOn: map[string]error{}, account: "123456789012", region: "ap-south-1",
		others: map[string]bool{}, otherErr: map[string]error{}}
}

func (c *cloud) hit(name string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls = append(c.calls, name)
	return c.failOn[name]
}

func (c *cloud) called(name string) int {
	n := 0
	for _, x := range c.calls {
		if x == name {
			n++
		}
	}
	return n
}

// IAM
func (c *cloud) GetRole(_ context.Context, in *iam.GetRoleInput, _ ...func(*iam.Options)) (*iam.GetRoleOutput, error) {
	if err := c.hit("GetRole"); err != nil {
		return nil, err
	}
	if _, ok := c.roles[aws.ToString(in.RoleName)]; !ok {
		return nil, errors.New("NoSuchEntity")
	}
	return &iam.GetRoleOutput{}, nil
}
func (c *cloud) CreateRole(_ context.Context, in *iam.CreateRoleInput, _ ...func(*iam.Options)) (*iam.CreateRoleOutput, error) {
	if err := c.hit("CreateRole"); err != nil {
		return nil, err
	}
	c.roles[aws.ToString(in.RoleName)] = ""
	return &iam.CreateRoleOutput{}, nil
}
func (c *cloud) TagRole(context.Context, *iam.TagRoleInput, ...func(*iam.Options)) (*iam.TagRoleOutput, error) {
	return &iam.TagRoleOutput{}, c.hit("TagRole")
}
func (c *cloud) PutRolePolicy(_ context.Context, in *iam.PutRolePolicyInput, _ ...func(*iam.Options)) (*iam.PutRolePolicyOutput, error) {
	if err := c.hit("PutRolePolicy"); err != nil {
		return nil, err
	}
	c.roles[aws.ToString(in.RoleName)] = aws.ToString(in.PolicyDocument)
	return &iam.PutRolePolicyOutput{}, nil
}
func (c *cloud) GetRolePolicy(_ context.Context, in *iam.GetRolePolicyInput, _ ...func(*iam.Options)) (*iam.GetRolePolicyOutput, error) {
	return &iam.GetRolePolicyOutput{PolicyDocument: aws.String(url.QueryEscape(c.roles[aws.ToString(in.RoleName)]))}, nil
}
func (c *cloud) DeleteRolePolicy(_ context.Context, in *iam.DeleteRolePolicyInput, _ ...func(*iam.Options)) (*iam.DeleteRolePolicyOutput, error) {
	if err := c.hit("DeleteRolePolicy"); err != nil {
		return nil, err
	}
	if _, ok := c.roles[aws.ToString(in.RoleName)]; !ok {
		return nil, errors.New("NoSuchEntity")
	}
	c.roles[aws.ToString(in.RoleName)] = ""
	return &iam.DeleteRolePolicyOutput{}, nil
}
func (c *cloud) DeleteRole(_ context.Context, in *iam.DeleteRoleInput, _ ...func(*iam.Options)) (*iam.DeleteRoleOutput, error) {
	if err := c.hit("DeleteRole"); err != nil {
		return nil, err
	}
	if _, ok := c.roles[aws.ToString(in.RoleName)]; !ok {
		return nil, errors.New("NoSuchEntity")
	}
	delete(c.roles, aws.ToString(in.RoleName))
	return &iam.DeleteRoleOutput{}, nil
}

// Logs
func (c *cloud) CreateLogGroup(_ context.Context, in *cloudwatchlogs.CreateLogGroupInput, _ ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.CreateLogGroupOutput, error) {
	c.groups[aws.ToString(in.LogGroupName)] = true
	return &cloudwatchlogs.CreateLogGroupOutput{}, c.hit("CreateLogGroup")
}
func (c *cloud) PutRetentionPolicy(_ context.Context, in *cloudwatchlogs.PutRetentionPolicyInput, _ ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.PutRetentionPolicyOutput, error) {
	if err := c.hit("PutRetentionPolicy"); err != nil {
		return nil, err
	}
	c.retention = aws.ToInt32(in.RetentionInDays)
	return &cloudwatchlogs.PutRetentionPolicyOutput{}, nil
}
func (c *cloud) DeleteLogGroup(_ context.Context, in *cloudwatchlogs.DeleteLogGroupInput, _ ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.DeleteLogGroupOutput, error) {
	if err := c.hit("DeleteLogGroup"); err != nil {
		return nil, err
	}
	if !c.groups[aws.ToString(in.LogGroupName)] {
		return nil, errors.New("ResourceNotFoundException")
	}
	delete(c.groups, aws.ToString(in.LogGroupName))
	return &cloudwatchlogs.DeleteLogGroupOutput{}, nil
}
func (c *cloud) FilterLogEvents(context.Context, *cloudwatchlogs.FilterLogEventsInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.FilterLogEventsOutput, error) {
	return &cloudwatchlogs.FilterLogEventsOutput{}, nil
}

// The logs client has its own TagResource, so it is its own type.
type logsClient struct{ c *cloud }

func (l logsClient) CreateLogGroup(ctx context.Context, in *cloudwatchlogs.CreateLogGroupInput, o ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.CreateLogGroupOutput, error) {
	return l.c.CreateLogGroup(ctx, in, o...)
}
func (l logsClient) PutRetentionPolicy(ctx context.Context, in *cloudwatchlogs.PutRetentionPolicyInput, o ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.PutRetentionPolicyOutput, error) {
	return l.c.PutRetentionPolicy(ctx, in, o...)
}
func (l logsClient) DeleteLogGroup(ctx context.Context, in *cloudwatchlogs.DeleteLogGroupInput, o ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.DeleteLogGroupOutput, error) {
	return l.c.DeleteLogGroup(ctx, in, o...)
}
func (l logsClient) TagResource(context.Context, *cloudwatchlogs.TagResourceInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.TagResourceOutput, error) {
	return &cloudwatchlogs.TagResourceOutput{}, l.c.hit("LogsTagResource")
}

// Lambda
func (c *cloud) GetFunctionConfiguration(_ context.Context, _ *lambda.GetFunctionConfigurationInput, _ ...func(*lambda.Options)) (*lambda.GetFunctionConfigurationOutput, error) {
	if err := c.hit("GetFunctionConfiguration"); err != nil {
		return nil, err
	}
	if c.fn == nil {
		return nil, errors.New("ResourceNotFoundException")
	}
	return c.fn, nil
}
func (c *cloud) CreateFunction(_ context.Context, in *lambda.CreateFunctionInput, _ ...func(*lambda.Options)) (*lambda.CreateFunctionOutput, error) {
	if err := c.hit("CreateFunction"); err != nil {
		return nil, err
	}
	if c.createFails > 0 {
		c.createFails--
		return nil, errors.New("InvalidParameterValueException: The role defined for the function cannot be assumed by Lambda")
	}
	c.fn = &lambda.GetFunctionConfigurationOutput{CodeSha256: aws.String(shaOf(in.Code.ZipFile)), State: lambdatypes.StateActive, LastUpdateStatus: lambdatypes.LastUpdateStatusSuccessful,
		Role: in.Role, Description: in.Description, Runtime: in.Runtime}
	return &lambda.CreateFunctionOutput{}, nil
}
func (c *cloud) UpdateFunctionCode(_ context.Context, in *lambda.UpdateFunctionCodeInput, _ ...func(*lambda.Options)) (*lambda.UpdateFunctionCodeOutput, error) {
	if err := c.hit("UpdateFunctionCode"); err != nil {
		return nil, err
	}
	c.fn.CodeSha256 = aws.String(shaOf(in.ZipFile))
	return &lambda.UpdateFunctionCodeOutput{}, nil
}
func shaOf(zip []byte) string {
	// The reader compares against Zip(source); the fake stores what it was given,
	// which already is that zip - so hash it the way Zip does.
	return sha256b64(zip)
}
func (c *cloud) UpdateFunctionConfiguration(_ context.Context, in *lambda.UpdateFunctionConfigurationInput, _ ...func(*lambda.Options)) (*lambda.UpdateFunctionConfigurationOutput, error) {
	if err := c.hit("UpdateFunctionConfiguration"); err != nil {
		return nil, err
	}
	c.fn.Description, c.fn.Role = in.Description, in.Role
	return &lambda.UpdateFunctionConfigurationOutput{}, nil
}
func (c *cloud) DeleteFunction(context.Context, *lambda.DeleteFunctionInput, ...func(*lambda.Options)) (*lambda.DeleteFunctionOutput, error) {
	if err := c.hit("DeleteFunction"); err != nil {
		return nil, err
	}
	if c.fn == nil {
		return nil, errors.New("ResourceNotFoundException")
	}
	c.fn = nil
	return &lambda.DeleteFunctionOutput{}, nil
}
func (c *cloud) TagResource(context.Context, *lambda.TagResourceInput, ...func(*lambda.Options)) (*lambda.TagResourceOutput, error) {
	return &lambda.TagResourceOutput{}, c.hit("LambdaTagResource")
}
func (c *cloud) GetPolicy(context.Context, *lambda.GetPolicyInput, ...func(*lambda.Options)) (*lambda.GetPolicyOutput, error) {
	var b strings.Builder
	for _, arn := range c.permissions {
		b.WriteString(`{"Condition":{"ArnLike":{"AWS:SourceArn":"` + arn + `"}}}`)
	}
	return &lambda.GetPolicyOutput{Policy: aws.String(b.String())}, nil
}
func (c *cloud) AddPermission(_ context.Context, in *lambda.AddPermissionInput, _ ...func(*lambda.Options)) (*lambda.AddPermissionOutput, error) {
	if err := c.hit("AddPermission"); err != nil {
		return nil, err
	}
	c.permissions[aws.ToString(in.StatementId)] = aws.ToString(in.SourceArn)
	return &lambda.AddPermissionOutput{}, nil
}
func (c *cloud) RemovePermission(_ context.Context, in *lambda.RemovePermissionInput, _ ...func(*lambda.Options)) (*lambda.RemovePermissionOutput, error) {
	delete(c.permissions, aws.ToString(in.StatementId))
	return &lambda.RemovePermissionOutput{}, c.hit("RemovePermission")
}
func (c *cloud) Invoke(context.Context, *lambda.InvokeInput, ...func(*lambda.Options)) (*lambda.InvokeOutput, error) {
	if err := c.hit("Invoke"); err != nil {
		return nil, err
	}
	return c.invoke, nil
}

// EventBridge
func (c *cloud) PutRule(_ context.Context, in *eventbridge.PutRuleInput, _ ...func(*eventbridge.Options)) (*eventbridge.PutRuleOutput, error) {
	if err := c.hit("PutRule:" + aws.ToString(in.Name)); err != nil {
		return nil, err
	}
	n := aws.ToString(in.Name)
	c.rules[n] = &ebtypes.Rule{ScheduleExpression: in.ScheduleExpression, EventPattern: in.EventPattern}
	c.ruleStates[n] = in.State
	return &eventbridge.PutRuleOutput{RuleArn: aws.String("arn:aws:events:" + c.region + ":" + c.account + ":rule/" + n)}, nil
}
func (c *cloud) PutTargets(_ context.Context, in *eventbridge.PutTargetsInput, _ ...func(*eventbridge.Options)) (*eventbridge.PutTargetsOutput, error) {
	if err := c.hit("PutTargets"); err != nil {
		return nil, err
	}
	if c.failedEntry {
		return &eventbridge.PutTargetsOutput{FailedEntryCount: 1}, nil
	}
	c.targets[aws.ToString(in.Rule)] = aws.ToString(in.Targets[0].Arn)
	return &eventbridge.PutTargetsOutput{}, nil
}
func (c *cloud) RemoveTargets(_ context.Context, in *eventbridge.RemoveTargetsInput, _ ...func(*eventbridge.Options)) (*eventbridge.RemoveTargetsOutput, error) {
	if _, ok := c.targets[aws.ToString(in.Rule)]; !ok {
		return nil, errors.New("ResourceNotFoundException")
	}
	delete(c.targets, aws.ToString(in.Rule))
	return &eventbridge.RemoveTargetsOutput{}, nil
}
func (c *cloud) DeleteRule(_ context.Context, in *eventbridge.DeleteRuleInput, _ ...func(*eventbridge.Options)) (*eventbridge.DeleteRuleOutput, error) {
	n := aws.ToString(in.Name)
	if _, ok := c.rules[n]; !ok {
		return nil, errors.New("ResourceNotFoundException")
	}
	delete(c.rules, n)
	return &eventbridge.DeleteRuleOutput{}, nil
}
func (c *cloud) DescribeRule(_ context.Context, in *eventbridge.DescribeRuleInput, _ ...func(*eventbridge.Options)) (*eventbridge.DescribeRuleOutput, error) {
	n := aws.ToString(in.Name)
	r, ok := c.rules[n]
	if !ok {
		return nil, errors.New("ResourceNotFoundException")
	}
	return &eventbridge.DescribeRuleOutput{State: c.ruleStates[n], ScheduleExpression: r.ScheduleExpression}, nil
}
func (c *cloud) ListTargetsByRule(_ context.Context, in *eventbridge.ListTargetsByRuleInput, _ ...func(*eventbridge.Options)) (*eventbridge.ListTargetsByRuleOutput, error) {
	a, ok := c.targets[aws.ToString(in.Rule)]
	if !ok {
		return &eventbridge.ListTargetsByRuleOutput{}, nil
	}
	return &eventbridge.ListTargetsByRuleOutput{Targets: []ebtypes.Target{{Arn: aws.String(a)}}}, nil
}

// SSM
func (c *cloud) DeleteParameters(_ context.Context, in *ssm.DeleteParametersInput, _ ...func(*ssm.Options)) (*ssm.DeleteParametersOutput, error) {
	c.params = append(c.params, in.Names...)
	return &ssm.DeleteParametersOutput{}, c.hit("DeleteParameters")
}

func installer(t *testing.T, c *cloud) (*Installer, *[]string) {
	src, err := os.ReadFile("../../lambda/cloud_watchdog.py")
	if err != nil {
		t.Fatal(err)
	}
	var said []string
	return &Installer{
		Lambda: c, Events: c, IAM: c, Logs: logsClient{c}, SSM: c,
		Host: "gamevps", Region: c.region, Account: c.account, Source: src,
		Settings: Settings{Host: "gamevps", Account: c.account, Bucket: "cg-library-x", IdleMinutes: 30, StuckMinutes: 60, ExpiryDays: 14, S3GBMonth: "0.025"},
		LambdaIn: func(_ context.Context, r string) (bool, error) { return c.others[r], c.otherErr[r] },
		Regions: func(context.Context) ([]string, error) {
			return []string{"us-east-1", c.region, "eu-west-1"}, c.regionsErr
		},
		Log: func(s string) { said = append(said, s) }, Sleep: func(time.Duration) {},
	}, &said
}

func reader(t *testing.T, c *cloud, i *Installer) *Reader {
	return &Reader{Lambda: c, Events: c, IAM: c, Logs: c, Now: time.Now, Host: i.Host, Region: i.Region, Source: i.Source,
		Settings: func(string) Settings { return i.Settings }}
}

func TestAFreshInstallReadsAsCurrent(t *testing.T) {
	c := newCloud()
	i, said := installer(t, c)
	if err := i.Install(context.Background()); err != nil {
		t.Fatalf("%v\n%v", err, *said)
	}
	st := reader(t, c, i).Current(context.Background())
	if len(st.Drift) != 0 {
		t.Fatalf("what the installer wrote does not read as current: %v", st.Drift)
	}
	if !strings.Contains(strings.Join(*said, "\n"), "creating the role gamevps-cloud-watchdog") ||
		!strings.Contains(strings.Join(*said, "\n"), "armed: gamevps-cloud-watchdog runs every 5 minutes, and hears when a box stops or terminates") {
		t.Errorf("%v", *said)
	}
	if c.retention != 14 || c.called("LambdaTagResource") != 1 || c.called("LogsTagResource") != 1 || c.permissions["cg-schedule"] == "" || c.permissions["cg-state"] == "" {
		t.Errorf("retention %d permissions %v", c.retention, c.permissions)
	}
}

func TestInstallingAgainChangesNothing(t *testing.T) {
	c := newCloud()
	i, _ := installer(t, c)
	_ = i.Install(context.Background())
	c.calls = nil
	i2, said := installer(t, c)
	if err := i2.Install(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"CreateRole", "CreateFunction", "UpdateFunctionCode", "UpdateFunctionConfiguration", "AddPermission"} {
		if c.called(n) != 0 {
			t.Errorf("%s was called on a current install", n)
		}
	}
	if strings.Contains(strings.Join(*said, "\n"), "updating") {
		t.Errorf("%v", *said)
	}
}

func TestADriftedFunctionIsRepairedAndOnlyThatPiece(t *testing.T) {
	c := newCloud()
	i, _ := installer(t, c)
	_ = i.Install(context.Background())
	// Code changed.
	c.fn.CodeSha256 = aws.String("stale")
	c.calls = nil
	i2, said := installer(t, c)
	_ = i2.Install(context.Background())
	if c.called("UpdateFunctionCode") != 1 || c.called("UpdateFunctionConfiguration") != 0 || !strings.Contains(strings.Join(*said, "|"), "updating the function code") {
		t.Errorf("%v %v", c.calls, *said)
	}
	// A setting changed (a different idle time): the fingerprint no longer matches.
	i3, said := installer(t, c)
	i3.Settings.IdleMinutes = 45
	c.calls = nil
	_ = i3.Install(context.Background())
	if c.called("UpdateFunctionConfiguration") != 1 || c.called("UpdateFunctionCode") != 0 || !strings.Contains(strings.Join(*said, "|"), "updating the function settings") {
		t.Errorf("%v %v", c.calls, *said)
	}
	if st := reader(t, c, i3).Current(context.Background()); len(st.Drift) != 0 {
		t.Errorf("after repair: %v", st.Drift)
	}
	// A policy edited by hand is put back.
	c.roles["gamevps-cloud-watchdog"] = `{"Statement":[]}`
	_ = i3.Install(context.Background())
	if st := reader(t, c, i3).Current(context.Background()); len(st.Drift) != 0 {
		t.Errorf("policy: %v", st.Drift)
	}
}

// A role created moments ago is not yet assumable, and Lambda says so; it is
// waited out, not surfaced.
func TestARoleThatIsNotYetAssumableIsWaitedOut(t *testing.T) {
	c := newCloud()
	c.createFails = 3
	i, said := installer(t, c)
	if err := i.Install(context.Background()); err != nil || c.called("CreateFunction") != 4 {
		t.Fatalf("%v calls %d\n%v", err, c.called("CreateFunction"), *said)
	}
	c = newCloud()
	c.createFails = 20
	i, said = installer(t, c)
	if err := i.Install(context.Background()); !errors.Is(err, ErrNotInstalled) || c.called("CreateFunction") != 12 || !strings.Contains(strings.Join(*said, "|"), "could not create gamevps-cloud-watchdog: InvalidParameterValueException") {
		t.Errorf("%v %d %v", err, c.called("CreateFunction"), *said)
	}
}

func TestEachFailureIsNamedAndStopsTheInstall(t *testing.T) {
	for name, c := range map[string]struct {
		set  func(*cloud)
		want string
	}{
		"role":       {func(c *cloud) { c.failOn["CreateRole"] = errors.New("denied") }, "could not create the role gamevps-cloud-watchdog (needs iam:CreateRole)"},
		"policy":     {func(c *cloud) { c.failOn["PutRolePolicy"] = errors.New("denied") }, "could not attach the policy to gamevps-cloud-watchdog"},
		"schedule":   {func(c *cloud) { c.failOn["PutRule:gamevps-cloud-watchdog"] = errors.New("denied") }, "could not create the schedule gamevps-cloud-watchdog"},
		"target":     {func(c *cloud) { c.failedEntry = true }, "could not point the schedule at gamevps-cloud-watchdog"},
		"permission": {func(c *cloud) { c.failOn["AddPermission"] = errors.New("denied") }, "could not let the schedule invoke gamevps-cloud-watchdog"},
		"state rule": {func(c *cloud) { c.failOn["PutRule:gamevps-cloud-watchdog-state"] = errors.New("denied") }, "could not create the rule gamevps-cloud-watchdog-state"},
	} {
		cl := newCloud()
		c.set(cl)
		i, said := installer(t, cl)
		if err := i.Install(context.Background()); !errors.Is(err, ErrNotInstalled) || !strings.Contains(strings.Join(*said, "|"), c.want) {
			t.Errorf("%s: %v %v", name, err, *said)
		}
	}
	// The retention is not fatal.
	cl := newCloud()
	cl.failOn["PutRetentionPolicy"] = errors.New("denied")
	i, said := installer(t, cl)
	if err := i.Install(context.Background()); err != nil || !strings.Contains(strings.Join(*said, "|"), "could not set the log retention (not fatal)") {
		t.Errorf("%v %v", err, *said)
	}
}

func logResult(lines ...string) *string {
	s := base64.StdEncoding.EncodeToString([]byte(strings.Join(lines, "\n")))
	return &s
}

func TestProve(t *testing.T) {
	c := newCloud()
	i, said := installer(t, c)
	c.invoke = &lambda.InvokeOutput{LogResult: logResult("START RequestId: x", "2026 cg-watchdog: no running instance tagged gamevps - nothing to do", "2026 cg-watchdog: archive: kept - ok", "END")}
	p := i.Prove(context.Background())
	i.Report(p)
	if len(p.Lines) != 2 || p.Lines[0] != "no running instance tagged gamevps - nothing to do" {
		t.Fatalf("%+v", p)
	}
	if got := strings.Join(*said, "\n"); !strings.Contains(got, "cloud watchdog: no running instance tagged gamevps - nothing to do") || strings.Contains(got, "FAILED") {
		t.Errorf("%s", got)
	}
	// It logged nothing.
	c.invoke = &lambda.InvokeOutput{LogResult: logResult("START", "END")}
	*said = nil
	i.Report(i.Prove(context.Background()))
	if !strings.Contains(strings.Join(*said, "\n"), "the check logged nothing - see: cg watchdog logs") {
		t.Errorf("%v", *said)
	}
	// It failed.
	c.invoke = &lambda.InvokeOutput{FunctionError: aws.String("Unhandled"), LogResult: logResult("cg-watchdog: boom")}
	*said = nil
	i.Report(i.Prove(context.Background()))
	if !strings.Contains(strings.Join(*said, "\n"), "  ^ the check FAILED (Unhandled) - see: cg watchdog logs") {
		t.Errorf("%v", *said)
	}
	// It cannot act on the account: tried three times (a new role takes a moment), then said.
	c.invoke = &lambda.InvokeOutput{LogResult: logResult("cg-watchdog: CANNOT QUERY AWS: denied")}
	c.calls = nil
	*said = nil
	i.Report(i.Prove(context.Background()))
	if c.called("Invoke") != 3 || !strings.Contains(strings.Join(*said, "\n"), "it cannot act on your account - fix this or layer 3 is decoration") {
		t.Errorf("%d %v", c.called("Invoke"), *said)
	}
	// It could not be run at all.
	c.failOn["Invoke"] = errors.New("AccessDenied: lambda:InvokeFunction")
	*said = nil
	i.Report(i.Prove(context.Background()))
	if !strings.Contains(strings.Join(*said, "\n"), "cloud watchdog: could not run a check: AccessDenied") {
		t.Errorf("%v", *said)
	}
}

func installed(t *testing.T) (*cloud, *Installer, *[]string) {
	c := newCloud()
	i, said := installer(t, c)
	if err := i.Install(context.Background()); err != nil {
		t.Fatal(err)
	}
	*said = nil
	return c, i, said
}

func TestRemoveEverythingThereWas(t *testing.T) {
	c, i, said := installed(t)
	i.Remove(context.Background())
	got := strings.Join(*said, "\n")
	for _, want := range []string{"deleted the schedule gamevps-cloud-watchdog", "deleted the rule gamevps-cloud-watchdog-state", "deleted the function gamevps-cloud-watchdog", "deleted its logs", "deleted the role gamevps-cloud-watchdog"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q:\n%s", want, got)
		}
	}
	if c.fn != nil || len(c.rules) != 0 || len(c.roles) != 0 || len(c.params) != 3 {
		t.Errorf("fn %v rules %v roles %v params %v", c.fn, c.rules, c.roles, c.params)
	}
	// Removing what is not there says so, and is not an error.
	*said = nil
	i.Remove(context.Background())
	if got := strings.Join(*said, "\n"); !strings.Contains(got, "cloud watchdog: nothing to remove") {
		t.Errorf("%s", got)
	}
}

// The role is global; the function is regional. Deleting it while another region
// still runs the function would break that one instead of this.
func TestTheRoleOutlivesAWatchdogElsewhere(t *testing.T) {
	c, i, said := installed(t)
	c.others["eu-west-1"] = true
	i.Remove(context.Background())
	if _, ok := c.roles["gamevps-cloud-watchdog"]; !ok || !strings.Contains(strings.Join(*said, "|"), "kept the role gamevps-cloud-watchdog - a watchdog in another region still uses it") {
		t.Errorf("%v %v", c.roles, *said)
	}
}

// A region that could not be asked counts as using it: unknown is not "no".
func TestTheRoleIsKeptWhenAnotherRegionCannotBeAsked(t *testing.T) {
	c, i, said := installed(t)
	c.otherErr["us-east-1"] = errors.New("denied")
	i.Remove(context.Background())
	if _, ok := c.roles["gamevps-cloud-watchdog"]; !ok || !strings.Contains(strings.Join(*said, "|"), "could not check whether a watchdog in another region still uses it") {
		t.Errorf("%v %v", c.roles, *said)
	}
	c, i, said = installed(t)
	c.regionsErr = errors.New("denied")
	i.Remove(context.Background())
	if _, ok := c.roles["gamevps-cloud-watchdog"]; !ok {
		t.Errorf("a region list that failed must not delete the role: %v", *said)
	}
}
