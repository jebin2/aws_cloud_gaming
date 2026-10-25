package watchdog

import (
	"context"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/eventbridge"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	"github.com/aws/smithy-go"
)

// The parts of each client the read side uses; the SDK clients satisfy them.
type (
	LambdaAPI interface {
		GetFunctionConfiguration(context.Context, *lambda.GetFunctionConfigurationInput, ...func(*lambda.Options)) (*lambda.GetFunctionConfigurationOutput, error)
		GetPolicy(context.Context, *lambda.GetPolicyInput, ...func(*lambda.Options)) (*lambda.GetPolicyOutput, error)
	}
	EventsAPI interface {
		DescribeRule(context.Context, *eventbridge.DescribeRuleInput, ...func(*eventbridge.Options)) (*eventbridge.DescribeRuleOutput, error)
		ListTargetsByRule(context.Context, *eventbridge.ListTargetsByRuleInput, ...func(*eventbridge.Options)) (*eventbridge.ListTargetsByRuleOutput, error)
	}
	IAMAPI interface {
		GetRolePolicy(context.Context, *iam.GetRolePolicyInput, ...func(*iam.Options)) (*iam.GetRolePolicyOutput, error)
	}
)

// Reader asks AWS about the watchdog. Nothing it does changes anything.
type Reader struct {
	Lambda LambdaAPI
	Events EventsAPI
	IAM    IAMAPI
	Logs   LogsAPI
	Now    func() time.Time

	Host, Region string
	Source       []byte                        // lambda/cloud_watchdog.py, as shipped
	Settings     func(account string) Settings // what it would be deployed with
}

// State is what the read-only round found.
type State struct {
	Installed  bool
	FnState    string // Lambda's State
	FnRuntime  string
	Rule       string   // the schedule's state; "" when there is none
	Drift      []string // what is not as this repo would make it
	LastMS     int64    // the last decision logged in the past hour; 0 when none
	LastMsg    string
	LogUnknown bool // the log could not be read, which is not the same as empty
	ArchiveMS  int64
	ArchiveMsg string
	Recent     []Event // up to the last 8 decisions of the past hour
}

// Event is one logged decision.
type Event struct {
	MS  int64
	Msg string
}

func code(err error) string {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		return ae.ErrorCode()
	}
	return ""
}

var accountOf = regexp.MustCompile(`^arn:aws:iam::([0-9]+):role/`)

// Current is one parallel round of read-only calls: is every piece there and
// as this repo would make it?
func (r *Reader) Current(ctx context.Context) State {
	name, stateRule := Name(r.Host), StateRule(r.Host)
	now := r.Now()
	var st State
	var wg sync.WaitGroup
	var fn *lambda.GetFunctionConfigurationOutput
	var rule, stateRuleState, policyJSON string
	var target, stateTarget, permission string
	var fnErr error
	var logErr error
	var events []Event

	run := func(f func()) { wg.Add(1); go func() { defer wg.Done(); f() }() }
	run(func() {
		fn, fnErr = r.Lambda.GetFunctionConfiguration(ctx, &lambda.GetFunctionConfigurationInput{FunctionName: aws.String(name)})
	})
	run(func() {
		if o, err := r.Events.DescribeRule(ctx, &eventbridge.DescribeRuleInput{Name: aws.String(name)}); err == nil {
			rule = string(o.State) + "\t" + aws.ToString(o.ScheduleExpression)
		}
	})
	run(func() { target = r.target(ctx, name) })
	run(func() {
		if o, err := r.Events.DescribeRule(ctx, &eventbridge.DescribeRuleInput{Name: aws.String(stateRule)}); err == nil {
			stateRuleState = string(o.State)
		}
	})
	run(func() { stateTarget = r.target(ctx, stateRule) })
	run(func() {
		if o, err := r.Lambda.GetPolicy(ctx, &lambda.GetPolicyInput{FunctionName: aws.String(name)}); err == nil {
			permission = aws.ToString(o.Policy)
		}
	})
	run(func() {
		if o, err := r.IAM.GetRolePolicy(ctx, &iam.GetRolePolicyInput{RoleName: aws.String(name), PolicyName: aws.String(PolicyName)}); err == nil {
			policyJSON, _ = url.QueryUnescape(aws.ToString(o.PolicyDocument))
		}
	})
	run(func() { events, logErr = r.events(ctx, "cg-watchdog:", time.Hour, now) })
	var arch []Event
	run(func() { arch, _ = r.events(ctx, "cg-watchdog: archive", 2*time.Hour, now) })
	zipBytes, sha := Zip(r.Source)
	_ = zipBytes
	wg.Wait()

	if fnErr == nil && fn != nil {
		st.Installed = true
		st.FnState, st.FnRuntime = string(fn.State), string(fn.Runtime)
	}
	st.Rule = strings.SplitN(rule, "\t", 2)[0]
	acct := ""
	if fn != nil && fnErr == nil {
		if m := accountOf.FindStringSubmatch(aws.ToString(fn.Role)); m != nil {
			acct = m[1]
		}
	}
	if fnErr != nil || fn == nil || aws.ToString(fn.CodeSha256) == "" || acct == "" {
		st.Drift = append(st.Drift, "no function")
	} else {
		want := r.Settings(acct)
		fnARN := "arn:aws:lambda:" + r.Region + ":" + acct + ":function:" + name
		add := func(ok bool, what string) {
			if !ok {
				st.Drift = append(st.Drift, what)
			}
		}
		add(aws.ToString(fn.CodeSha256) == sha, "code changed")
		add(strings.Contains(aws.ToString(fn.Description), "cfg="+want.Fingerprint(aws.ToString(fn.Role))), "settings changed")
		add(string(fn.State) == "Active" && string(fn.LastUpdateStatus) == "Successful", "function "+string(fn.State)+"/"+string(fn.LastUpdateStatus))
		add(rule == "ENABLED\trate("+Itoa(EveryMin)+" minutes)", "schedule not enabled")
		add(target == fnARN, "schedule has no target")
		// The closing quote matters: the schedule's ARN is a prefix of the
		// state-change rule's, and without it one permission passed for both.
		add(strings.Contains(permission, "arn:aws:events:"+r.Region+":"+acct+":rule/"+name+`"`), "schedule cannot invoke it")
		add(stateRuleState == "ENABLED", "state-change rule not enabled")
		add(stateTarget == fnARN, "state-change rule has no target")
		add(strings.Contains(permission, "arn:aws:events:"+r.Region+":"+acct+":rule/"+stateRule+`"`), "state-change rule cannot invoke it")
		add(PolicyMatches([]byte(policyJSON), want.Policy(r.Region)), "role policy changed")
		switch {
		case logErr == nil:
		case code(logErr) == "ResourceNotFoundException":
			st.Drift = append(st.Drift, "no log group")
		default:
			st.Drift = append(st.Drift, "log unreadable")
			st.LogUnknown = true
		}
	}
	if logErr != nil {
		st.LogUnknown = code(logErr) != "ResourceNotFoundException"
	}
	if n := len(events); n > 0 {
		st.LastMS, st.LastMsg = events[n-1].MS, strings.TrimPrefix(events[n-1].Msg, "cg-watchdog: ")
		st.Recent = events[max(0, n-8):]
	}
	for i := len(arch) - 1; i >= 0; i-- {
		if strings.HasPrefix(arch[i].Msg, "cg-watchdog: archive:") {
			st.ArchiveMS, st.ArchiveMsg = arch[i].MS, strings.TrimPrefix(arch[i].Msg, "cg-watchdog: archive: ")
			break
		}
	}
	return st
}

func (r *Reader) target(ctx context.Context, rule string) string {
	o, err := r.Events.ListTargetsByRule(ctx, &eventbridge.ListTargetsByRuleInput{Rule: aws.String(rule)})
	if err != nil || len(o.Targets) == 0 {
		return ""
	}
	return aws.ToString(o.Targets[0].Arn)
}

func (r *Reader) events(ctx context.Context, pattern string, window time.Duration, now time.Time) ([]Event, error) {
	return r.Since(ctx, pattern, now.Add(-window))
}

// Since reads every logged line matching the pattern since the time, oldest
// first.
func (r *Reader) Since(ctx context.Context, pattern string, since time.Time) ([]Event, error) {
	in := &cloudwatchlogs.FilterLogEventsInput{
		LogGroupName:  aws.String(LogGroup(r.Host)),
		StartTime:     aws.Int64(since.UnixMilli()),
		FilterPattern: aws.String(`"` + pattern + `"`),
	}
	var out []Event
	for {
		o, err := r.Logs.FilterLogEvents(ctx, in)
		if err != nil {
			return nil, err
		}
		for _, e := range o.Events {
			out = append(out, Event{aws.ToInt64(e.Timestamp), strings.TrimRight(aws.ToString(e.Message), "\n")})
		}
		if o.NextToken == nil || *o.NextToken == "" {
			return out, nil
		}
		in.NextToken = o.NextToken
	}
}

// Itoa formats a count of minutes.
func Itoa(n int) string { return strconv.Itoa(n) }
