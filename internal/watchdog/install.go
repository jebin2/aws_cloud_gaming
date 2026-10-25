package watchdog

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/eventbridge"
	ebtypes "github.com/aws/aws-sdk-go-v2/service/eventbridge/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	lambdatypes "github.com/aws/aws-sdk-go-v2/service/lambda/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

// Everything the installer changes, as far as it uses it; the SDK clients
// satisfy them. Nothing here is fatal to `cg init`: a missing guard must not stop
// a build; it says so, and the other layers still apply.
type (
	LambdaWriter interface {
		LambdaAPI
		CreateFunction(context.Context, *lambda.CreateFunctionInput, ...func(*lambda.Options)) (*lambda.CreateFunctionOutput, error)
		UpdateFunctionCode(context.Context, *lambda.UpdateFunctionCodeInput, ...func(*lambda.Options)) (*lambda.UpdateFunctionCodeOutput, error)
		UpdateFunctionConfiguration(context.Context, *lambda.UpdateFunctionConfigurationInput, ...func(*lambda.Options)) (*lambda.UpdateFunctionConfigurationOutput, error)
		DeleteFunction(context.Context, *lambda.DeleteFunctionInput, ...func(*lambda.Options)) (*lambda.DeleteFunctionOutput, error)
		TagResource(context.Context, *lambda.TagResourceInput, ...func(*lambda.Options)) (*lambda.TagResourceOutput, error)
		AddPermission(context.Context, *lambda.AddPermissionInput, ...func(*lambda.Options)) (*lambda.AddPermissionOutput, error)
		RemovePermission(context.Context, *lambda.RemovePermissionInput, ...func(*lambda.Options)) (*lambda.RemovePermissionOutput, error)
		Invoke(context.Context, *lambda.InvokeInput, ...func(*lambda.Options)) (*lambda.InvokeOutput, error)
	}
	EventsWriter interface {
		EventsAPI
		PutRule(context.Context, *eventbridge.PutRuleInput, ...func(*eventbridge.Options)) (*eventbridge.PutRuleOutput, error)
		PutTargets(context.Context, *eventbridge.PutTargetsInput, ...func(*eventbridge.Options)) (*eventbridge.PutTargetsOutput, error)
		RemoveTargets(context.Context, *eventbridge.RemoveTargetsInput, ...func(*eventbridge.Options)) (*eventbridge.RemoveTargetsOutput, error)
		DeleteRule(context.Context, *eventbridge.DeleteRuleInput, ...func(*eventbridge.Options)) (*eventbridge.DeleteRuleOutput, error)
	}
	IAMWriter interface {
		GetRole(context.Context, *iam.GetRoleInput, ...func(*iam.Options)) (*iam.GetRoleOutput, error)
		CreateRole(context.Context, *iam.CreateRoleInput, ...func(*iam.Options)) (*iam.CreateRoleOutput, error)
		TagRole(context.Context, *iam.TagRoleInput, ...func(*iam.Options)) (*iam.TagRoleOutput, error)
		PutRolePolicy(context.Context, *iam.PutRolePolicyInput, ...func(*iam.Options)) (*iam.PutRolePolicyOutput, error)
		DeleteRolePolicy(context.Context, *iam.DeleteRolePolicyInput, ...func(*iam.Options)) (*iam.DeleteRolePolicyOutput, error)
		DeleteRole(context.Context, *iam.DeleteRoleInput, ...func(*iam.Options)) (*iam.DeleteRoleOutput, error)
	}
	LogsWriter interface {
		CreateLogGroup(context.Context, *cloudwatchlogs.CreateLogGroupInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.CreateLogGroupOutput, error)
		PutRetentionPolicy(context.Context, *cloudwatchlogs.PutRetentionPolicyInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.PutRetentionPolicyOutput, error)
		TagResource(context.Context, *cloudwatchlogs.TagResourceInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.TagResourceOutput, error)
		DeleteLogGroup(context.Context, *cloudwatchlogs.DeleteLogGroupInput, ...func(*cloudwatchlogs.Options)) (*cloudwatchlogs.DeleteLogGroupOutput, error)
	}
	SSMWriter interface {
		DeleteParameters(context.Context, *ssm.DeleteParametersInput, ...func(*ssm.Options)) (*ssm.DeleteParametersOutput, error)
	}
)

// Installer deploys, proves and removes the cloud watchdog.
type Installer struct {
	Lambda LambdaWriter
	Events EventsWriter
	IAM    IAMWriter
	Logs   LogsWriter
	SSM    SSMWriter

	Host, Region string
	Account      string
	Source       []byte // lambda/cloud_watchdog.py
	Settings     Settings
	TagKey       string

	// OtherRegions says whether another region has this function: yes, no, or
	// unknown (err). The role is global; the function is regional.
	LambdaIn func(ctx context.Context, region string) (bool, error)
	Regions  func(ctx context.Context) ([]string, error)

	Log   func(string)
	Sleep func(time.Duration) // retry/poll waits; tests make them instant
}

func (i *Installer) log(s string) {
	if i.Log != nil {
		i.Log(s)
	}
}

func (i *Installer) sleep(d time.Duration) {
	if i.Sleep != nil {
		i.Sleep(d)
	}
}

const assumeLambda = `{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}`

// StatePattern is EC2's own events: state changes, so the watchdog can confirm a
// box is gone, and spot interruption warnings.
const StatePattern = `{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification","EC2 Spot Instance Interruption Warning"]}`

// ErrNotInstalled is returned when installing failed; the reason was logged.
var ErrNotInstalled = errors.New("the cloud watchdog was not installed")

// waitFunction polls until the function is active and its last update done.
// A configuration update while a code update is in progress is refused with
// ResourceConflictException, so each step waits for the one before.
func (i *Installer) waitFunction(ctx context.Context) {
	for n := 0; n < 60; n++ {
		o, err := i.Lambda.GetFunctionConfiguration(ctx, &lambda.GetFunctionConfigurationInput{FunctionName: aws.String(Name(i.Host))})
		if err == nil && o.State == lambdatypes.StateActive && o.LastUpdateStatus != lambdatypes.LastUpdateStatusInProgress {
			return
		}
		i.sleep(2 * time.Second)
	}
}

// Install makes the watchdog exactly what this repo would make it, repairing
// whatever has drifted. Every piece is idempotent.
func (i *Installer) Install(ctx context.Context) error {
	name, logs := Name(i.Host), LogGroup(i.Host)
	roleARN := "arn:aws:iam::" + i.Account + ":role/" + name
	tag := i.TagKey
	if tag == "" {
		tag = "cg:host"
	}

	if _, err := i.IAM.GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String(name)}); err != nil {
		i.log("creating the role " + name)
		if _, err := i.IAM.CreateRole(ctx, &iam.CreateRoleInput{RoleName: aws.String(name),
			Description:              aws.String("cloud_gaming layer 3: end the idle " + i.Host + " instance"),
			AssumeRolePolicyDocument: aws.String(assumeLambda)}); err != nil {
			i.log("could not create the role " + name + " (needs iam:CreateRole)")
			return ErrNotInstalled
		}
	}
	// cg's tag, apart from creating it and never fatal.
	_, _ = i.IAM.TagRole(ctx, &iam.TagRoleInput{RoleName: aws.String(name), Tags: []iamtypes.Tag{{Key: aws.String(tag), Value: aws.String(i.Host)}}})
	// put-role-policy overwrites, so this also repairs a policy edited by hand.
	doc, _ := json.Marshal(i.Settings.Policy(i.Region))
	if _, err := i.IAM.PutRolePolicy(ctx, &iam.PutRolePolicyInput{RoleName: aws.String(name), PolicyName: aws.String(PolicyName), PolicyDocument: aws.String(string(doc))}); err != nil {
		i.log("could not attach the policy to " + name)
		return ErrNotInstalled
	}

	// Created here rather than by Lambda, so it gets a retention: Lambda's own
	// log groups keep everything forever.
	_, _ = i.Logs.CreateLogGroup(ctx, &cloudwatchlogs.CreateLogGroupInput{LogGroupName: aws.String(logs)})
	if _, err := i.Logs.PutRetentionPolicy(ctx, &cloudwatchlogs.PutRetentionPolicyInput{LogGroupName: aws.String(logs), RetentionInDays: aws.Int32(14)}); err != nil {
		i.log("could not set the log retention (not fatal)")
	}

	zip, sha := Zip(i.Source)
	fp := i.Settings.Fingerprint(roleARN)
	desc := "cloud_gaming layer 3 idle watchdog cfg=" + fp
	env := &lambdatypes.Environment{Variables: i.Settings.EnvMap()}
	cur, err := i.Lambda.GetFunctionConfiguration(ctx, &lambda.GetFunctionConfigurationInput{FunctionName: aws.String(name)})
	if err == nil {
		if aws.ToString(cur.CodeSha256) != sha {
			i.log("updating the function code")
			if _, err := i.Lambda.UpdateFunctionCode(ctx, &lambda.UpdateFunctionCodeInput{FunctionName: aws.String(name), ZipFile: zip}); err != nil {
				i.log("could not update " + name)
				return ErrNotInstalled
			}
			i.waitFunction(ctx)
		}
		if !strings.Contains(aws.ToString(cur.Description), "cfg="+fp) {
			i.log("updating the function settings")
			if _, err := i.Lambda.UpdateFunctionConfiguration(ctx, &lambda.UpdateFunctionConfigurationInput{FunctionName: aws.String(name),
				Runtime: lambdatypes.Runtime(RuntimeName), Handler: aws.String(Handler), Role: aws.String(roleARN),
				Timeout: aws.Int32(TimeoutSec), MemorySize: aws.Int32(MemoryMB), Environment: env, Description: aws.String(desc)}); err != nil {
				i.log("could not update the settings of " + name)
				return ErrNotInstalled
			}
			i.waitFunction(ctx)
		}
	} else {
		i.log("creating the function " + name)
		created := false
		for n := 1; n <= 12; n++ {
			_, err := i.Lambda.CreateFunction(ctx, &lambda.CreateFunctionInput{FunctionName: aws.String(name),
				Runtime: lambdatypes.Runtime(RuntimeName), Handler: aws.String(Handler), Role: aws.String(roleARN),
				Timeout: aws.Int32(TimeoutSec), MemorySize: aws.Int32(MemoryMB), Environment: env, Description: aws.String(desc),
				Code: &lambdatypes.FunctionCode{ZipFile: zip}})
			if err == nil {
				created = true
				break
			}
			// A role created moments ago is not yet assumable, and Lambda says so
			// as InvalidParameterValue. Waited out, not surfaced.
			if strings.Contains(err.Error(), "InvalidParameterValue") && n < 12 {
				i.sleep(5 * time.Second)
				continue
			}
			i.log("could not create " + name + ": " + strings.Join(strings.Fields(err.Error()), " "))
			return ErrNotInstalled
		}
		if created {
			i.waitFunction(ctx)
		}
	}

	fnARN := "arn:aws:lambda:" + i.Region + ":" + i.Account + ":function:" + name
	// cg's tag on the function and its logs - never fatal, as above.
	_, _ = i.Lambda.TagResource(ctx, &lambda.TagResourceInput{Resource: aws.String(fnARN), Tags: map[string]string{tag: i.Host}})
	_, _ = i.Logs.TagResource(ctx, &cloudwatchlogs.TagResourceInput{ResourceArn: aws.String("arn:aws:logs:" + i.Region + ":" + i.Account + ":log-group:" + logs), Tags: map[string]string{tag: i.Host}})

	// The schedule, and the rule for EC2's own events, both pointed at the function
	// and both allowed to invoke it.
	for _, r := range []struct {
		name, desc, schedule, pattern, statement, failRule, failPoint, failInvoke string
	}{
		{name, "Runs the cloud_gaming idle watchdog", fmt.Sprintf("rate(%d minutes)", EveryMin), "", "cg-schedule",
			"could not create the schedule " + name, "could not point the schedule at " + name, "could not let the schedule invoke " + name},
		{StateRule(i.Host), "EC2 state changes and spot interruption warnings, for the cloud_gaming watchdog", "", StatePattern, "cg-state",
			"could not create the rule " + StateRule(i.Host), "could not point " + StateRule(i.Host) + " at " + name, "could not let " + StateRule(i.Host) + " invoke " + name},
	} {
		in := &eventbridge.PutRuleInput{Name: aws.String(r.name), State: ebtypes.RuleStateEnabled, Description: aws.String(r.desc)}
		if r.schedule != "" {
			in.ScheduleExpression = aws.String(r.schedule)
		} else {
			in.EventPattern = aws.String(r.pattern)
		}
		pr, err := i.Events.PutRule(ctx, in)
		if err != nil {
			i.log(r.failRule)
			return ErrNotInstalled
		}
		ruleARN := aws.ToString(pr.RuleArn)
		pt, err := i.Events.PutTargets(ctx, &eventbridge.PutTargetsInput{Rule: aws.String(r.name),
			Targets: []ebtypes.Target{{Id: aws.String("watchdog"), Arn: aws.String(fnARN)}}})
		if err != nil || pt.FailedEntryCount != 0 {
			i.log(r.failPoint)
			return ErrNotInstalled
		}
		pol, _ := i.Lambda.GetPolicy(ctx, &lambda.GetPolicyInput{FunctionName: aws.String(name)})
		if pol == nil || !strings.Contains(aws.ToString(pol.Policy), ruleARN+`"`) {
			_, _ = i.Lambda.RemovePermission(ctx, &lambda.RemovePermissionInput{FunctionName: aws.String(name), StatementId: aws.String(r.statement)})
			if _, err := i.Lambda.AddPermission(ctx, &lambda.AddPermissionInput{FunctionName: aws.String(name), StatementId: aws.String(r.statement),
				Action: aws.String("lambda:InvokeFunction"), Principal: aws.String("events.amazonaws.com"), SourceArn: aws.String(ruleARN)}); err != nil {
				i.log(r.failInvoke)
				return ErrNotInstalled
			}
		}
	}
	i.log(fmt.Sprintf("armed: %s runs every %d minutes, and hears when a box stops or terminates", name, EveryMin))
	return nil
}

var markerRE = regexp.MustCompile(`cg-watchdog: .*`)

// Proved is the dry run's outcome.
type Proved struct {
	Lines  []string
	Failed string // Lambda's FunctionError, "" when it ran
	Err    error  // it could not be run at all
}

// Prove runs it once as a DRY RUN and reports what it decided. "Installed" is not
// evidence: it reads the account with its own role, and for a running box proves
// it may end it, without doing so. It keeps no state, so this costs nothing
// towards ending a box.
func (i *Installer) Prove(ctx context.Context) Proved {
	var p Proved
	for n := 1; n <= 3; n++ {
		o, err := i.Lambda.Invoke(ctx, &lambda.InvokeInput{FunctionName: aws.String(Name(i.Host)), Payload: []byte(`{"dry_run":true}`), LogType: lambdatypes.LogTypeTail})
		if err != nil {
			return Proved{Err: err}
		}
		p = Proved{Failed: aws.ToString(o.FunctionError)}
		if raw, err := base64.StdEncoding.DecodeString(aws.ToString(o.LogResult)); err == nil {
			for _, line := range strings.Split(string(raw), "\n") {
				if m := markerRE.FindString(line); m != "" {
					p.Lines = append(p.Lines, strings.TrimPrefix(m, "cg-watchdog: "))
				}
			}
		}
		// A role created moments ago can be refused by EC2 for a few seconds.
		blind := strings.Contains(strings.Join(p.Lines, "\n"), "CANNOT QUERY AWS")
		if p.Failed == "" && !blind {
			break
		}
		if n < 3 {
			i.sleep(10 * time.Second)
		}
	}
	return p
}

// Report says what Prove found.
func (i *Installer) Report(p Proved) {
	if p.Err != nil {
		i.log("cloud watchdog: could not run a check: " + strings.Join(strings.Fields(p.Err.Error()), " "))
		return
	}
	if len(p.Lines) == 0 {
		i.log("cloud watchdog: the check logged nothing - see: cg watchdog logs")
	}
	for _, l := range p.Lines {
		if strings.TrimSpace(l) != "" {
			i.log("cloud watchdog: " + l)
		}
	}
	if p.Failed != "" {
		i.log("  ^ the check FAILED (" + p.Failed + ") - see: cg watchdog logs")
	}
	if all := strings.Join(p.Lines, "\n"); strings.Contains(all, "CANNOT QUERY AWS") || strings.Contains(all, "DENIED") || strings.Contains(all, "FAILED") {
		i.log("  ^ it cannot act on your account - fix this or layer 3 is decoration")
	}
}

// roleUsedElsewhere is tri-state: used, not used, or could not tell. The role is
// GLOBAL; the function, the rules, the logs and the marks are regional. Deleting
// the role while ANOTHER region still has a function that assumes it would break
// that function instead of this one - and a region move leaves exactly that
// arrangement behind. So the role goes only when it is confirmed to be the last
// one using it: a region that could not be asked counts as using it.
func (i *Installer) roleUsedElsewhere(ctx context.Context) (used bool, unknown bool) {
	regions, err := i.Regions(ctx)
	if err != nil {
		return false, true
	}
	for _, r := range regions {
		if r == i.Region {
			continue
		}
		in, err := i.LambdaIn(ctx, r)
		switch {
		case err != nil:
			unknown = true
		case in:
			return true, false
		}
	}
	return false, unknown
}

// Remove deletes every regional piece, and the role if it is the last user. The
// schedule goes first, so nothing invokes a half-removed function. Every part is
// attempted whatever happened to the one before, and the outcome is said on every
// path - including "there was nothing".
func (i *Installer) Remove(ctx context.Context) {
	name, logs, stateRule := Name(i.Host), LogGroup(i.Host), StateRule(i.Host)
	any := false
	for _, r := range []struct{ rule, said string }{{name, "the schedule " + name}, {stateRule, "the rule " + stateRule}} {
		if _, err := i.Events.RemoveTargets(ctx, &eventbridge.RemoveTargetsInput{Rule: aws.String(r.rule), Ids: []string{"watchdog"}}); err == nil {
			any = true
		}
		if _, err := i.Events.DeleteRule(ctx, &eventbridge.DeleteRuleInput{Name: aws.String(r.rule)}); err == nil {
			any = true
			i.log("deleted " + r.said)
		}
	}
	if _, err := i.Lambda.DeleteFunction(ctx, &lambda.DeleteFunctionInput{FunctionName: aws.String(name)}); err == nil {
		any = true
		i.log("deleted the function " + name)
	}
	if _, err := i.Logs.DeleteLogGroup(ctx, &cloudwatchlogs.DeleteLogGroupInput{LogGroupName: aws.String(logs)}); err == nil {
		any = true
		i.log("deleted its logs")
	}
	// Its marks. Not counted as "something removed": deleting absent parameters succeeds.
	p := "/cloud-gaming/" + i.Host + "/"
	_, _ = i.SSM.DeleteParameters(ctx, &ssm.DeleteParametersInput{Names: []string{p + "archive-last-seen", p + "archive-warned", p + "archive-deleted"}})

	used, unknown := i.roleUsedElsewhere(ctx)
	switch {
	case used:
		i.log("kept the role " + name + " - a watchdog in another region still uses it")
	case unknown:
		i.log("kept the role " + name + " - could not check whether a watchdog in another region still uses it")
	default:
		if _, err := i.IAM.DeleteRolePolicy(ctx, &iam.DeleteRolePolicyInput{RoleName: aws.String(name), PolicyName: aws.String(PolicyName)}); err == nil {
			any = true
		}
		if _, err := i.IAM.DeleteRole(ctx, &iam.DeleteRoleInput{RoleName: aws.String(name)}); err == nil {
			any = true
			i.log("deleted the role " + name)
		}
	}
	if !any {
		i.log("cloud watchdog: nothing to remove")
	}
}
