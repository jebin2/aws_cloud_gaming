// Package watcher is `cg watcher`: every guard that ends a box nobody is
// using, whether each is armed, and what the last one decided. Layer 1 is the
// session (cg open ends it when Moonlight quits), layer 2 the watchdog on the
// box, layer 3 the cloud watchdog that keeps working when the box is gone.
package watcher

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/commands/status"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

// The clients the watcher uses; the SDK ones satisfy them.
type (
	EC2API interface {
		status.EC2API
		DescribeInstanceAttribute(context.Context, *ec2.DescribeInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceAttributeOutput, error)
	}
	BudgetsAPI interface {
		DescribeBudget(context.Context, *budgets.DescribeBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeBudgetOutput, error)
		DescribeNotificationsForBudget(context.Context, *budgets.DescribeNotificationsForBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeNotificationsForBudgetOutput, error)
	}
	STSAPI interface {
		GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error)
	}
)

// Watcher reads the guards.
type Watcher struct {
	EC2     EC2API
	Budgets BudgetsAPI
	STS     STSAPI
	Reader  *wd.Reader
	Runner  local.Runner
	Rates   pricing.Rates

	Host, Node, InstanceID, Home string
	HostIdleLimit                int // minutes the on-host watchdog waits, read from its own script; 0 if unreadable
	IdleMin, StuckMin            int
	ExpiryDays                   int
}

// Facts is everything the report and the JSON are drawn from.
type Facts struct {
	State       string // none, terminated, "unknown" when AWS could not be asked, else the instance's state
	Stranded    *status.Stranded
	Reachable   bool
	OnHost      string // is-active's answer, "" when it could not be asked
	Shutdown    string
	Want        string // what the shutdown action must be for this purchase model
	Journal     string // the on-host watchdog's last decisions
	Layer3      wd.State
	Budget      string // the limit as AWS wrote it; "" when none
	BudgetKnown bool
	Alerts      int
	Archive     string
}

var idleLimit = regexp.MustCompile(`(?m)^IDLE_LIMIT="\$\{IDLE_LIMIT:-([0-9]*)\}"`)

// HostIdleLimit reads the on-host watchdog's idle minutes from its own script,
// so none is written down here. 0 when it cannot be read.
func HostIdleLimit(script []byte) int {
	if m := idleLimit.FindSubmatch(script); m != nil {
		n, _ := strconv.Atoi(string(m[1]))
		return n
	}
	return 0
}

func (w *Watcher) sshTo(ctx context.Context, ip, command string) (string, error) {
	out, err := w.Runner.Output(ctx, "ssh", "-i", w.Home+"/.ssh/"+w.Host+".pem",
		"-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "ubuntu@"+ip, command)
	return string(out), err
}

func (w *Watcher) nodeIP(ctx context.Context) string {
	if !w.Runner.Has("tailscale") {
		return ""
	}
	out, err := w.Runner.Output(ctx, "tailscale", "ip", "-4", w.Node)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0])
}

// Gather asks everything. Nothing stops at a failed read.
func (w *Watcher) Gather(ctx context.Context) Facts {
	var f Facts
	f.State = "none"
	var inst *ec2types.Instance
	if w.InstanceID != "" {
		r, err := w.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{w.InstanceID}})
		switch {
		case err != nil:
			f.State = "unknown"
		case len(r.Reservations) > 0 && len(r.Reservations[0].Instances) > 0:
			inst = &r.Reservations[0].Instances[0]
			f.State = string(inst.State.Name)
		}
	}
	if inst != nil {
		sg := &status.Gatherer{EC2: w.EC2, Host: w.Host, Now: time.Now}
		f.Stranded = sg.StrandedFor(ctx, w.InstanceID)
	}
	// Layer 2, on the box.
	if f.State == "running" {
		if ip := w.nodeIP(ctx); ip != "" {
			if _, err := w.sshTo(ctx, ip, "true"); err == nil {
				f.Reachable = true
				if out, err := w.sshTo(ctx, ip, "systemctl is-active idle-watchdog.timer 2>/dev/null"); err == nil || out != "" {
					f.OnHost = strings.Map(func(r rune) rune {
						if r == '\r' || r == '\n' {
							return -1
						}
						return r
					}, out)
				}
				if a, err := w.EC2.DescribeInstanceAttribute(ctx, &ec2.DescribeInstanceAttributeInput{
					InstanceId: aws.String(w.InstanceID), Attribute: ec2types.InstanceAttributeNameInstanceInitiatedShutdownBehavior}); err == nil &&
					a.InstanceInitiatedShutdownBehavior != nil {
					f.Shutdown = aws.ToString(a.InstanceInitiatedShutdownBehavior.Value)
				}
				f.Want = "stop"
				if inst != nil && inst.InstanceLifecycle == ec2types.InstanceLifecycleTypeSpot {
					f.Want = "terminate"
				}
				f.Journal, _ = w.sshTo(ctx, ip, "journalctl -t idle-watchdog -n 8 --no-pager -o cat 2>/dev/null")
			}
		}
	}
	f.Layer3 = w.Reader.Current(ctx)
	f.Archive = watchdog.ArchiveText(f.Layer3, w.ExpiryDays, w.Reader.Now())
	// The budget.
	if id, err := w.STS.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err == nil {
		acct := aws.ToString(id.Account)
		name := w.Host + "-monthly"
		if b, err := w.Budgets.DescribeBudget(ctx, &budgets.DescribeBudgetInput{AccountId: aws.String(acct), BudgetName: aws.String(name)}); err == nil &&
			b.Budget != nil && b.Budget.BudgetLimit != nil {
			f.Budget, f.BudgetKnown = aws.ToString(b.Budget.BudgetLimit.Amount), true
		}
		if n, err := w.Budgets.DescribeNotificationsForBudget(ctx, &budgets.DescribeNotificationsForBudgetInput{
			AccountId: aws.String(acct), BudgetName: aws.String(name)}); err == nil {
			f.Alerts = len(n.Notifications)
		}
	}
	return f
}

// JSON is `cg watcher --json`: every guard as data - what it catches, whether
// it is armed, and what it last decided. The minutes each watchdog waits are
// as they are set, not as they were when this was written.
func (w *Watcher) JSON(f Facts, now time.Time) ([]byte, error) {
	ohw, state := f.OnHost, f.State
	var armed any
	if ohw != "" {
		armed = ohw == "active"
	}
	layer2State, layer2Note := "box not reachable", "box not reachable"
	switch {
	case ohw == "active":
		layer2State, layer2Note = "armed", ohw
	case ohw != "":
		layer2State, layer2Note = "not armed", ohw
	case state == "none" || state == "terminated" || state == "":
		layer2State, layer2Note = "no box", "installed during the build, armed while the box runs"
	}
	reaction := "idle"
	var idleMin any
	if w.HostIdleLimit > 0 {
		reaction, idleMin = fmt.Sprintf("%d min idle", w.HostIdleLimit), w.HostIdleLimit
	}
	rule := f.Layer3.Rule
	l3State := strings.ToLower(rule)
	if rule == "ENABLED" {
		l3State = "armed"
	}
	if l3State == "" {
		l3State = "not installed"
	}
	l3Note := rule
	if l3Note == "" {
		l3Note = "not installed"
	}
	var lastMsg, lastAge any
	if f.Layer3.LastMS > 0 {
		lastMsg, lastAge = f.Layer3.LastMsg, int64(now.Sub(time.UnixMilli(f.Layer3.LastMS)).Seconds())
	}
	var expected, value any
	if f.Shutdown != "" {
		value = f.Shutdown
	}
	if f.Want != "" {
		expected = f.Want
	}
	var budget any
	if f.BudgetKnown {
		if v, err := strconv.ParseFloat(f.Budget, 64); err == nil {
			budget = v
		}
	}
	out := map[string]any{
		"host": w.Host, "instance_state": state,
		"guards": []any{
			map[string]any{"layer": 1, "name": "session", "dies_with": "your laptop", "catches": "normal use",
				"reaction": "on Moonlight exit", "armed": nil, "state": "always on",
				"note": "cg open ends the session when Moonlight quits"},
			map[string]any{"layer": 2, "name": "on-host watchdog", "dies_with": "the box it protects",
				"catches": "a forgotten disconnect, a crashed client", "reaction": reaction, "idle_min": idleMin,
				"armed": armed, "state": layer2State, "note": layer2Note},
			map[string]any{"layer": 3, "name": "cloud watchdog", "dies_with": "a deleted schedule",
				"catches":  "a wedged box, one left running, one stuck going down",
				"reaction": fmt.Sprintf("%d min idle; forced after %d min stuck", w.IdleMin, w.StuckMin),
				"idle_min": w.IdleMin, "stuck_min": w.StuckMin, "every_min": wd.EveryMin,
				"armed": rule == "ENABLED", "state": l3State, "note": l3Note,
				"last_decision": lastMsg, "last_decision_age_s": lastAge},
		},
		"shutdown_action": map[string]any{"value": value, "expected": expected, "ok": f.Shutdown != "" && f.Shutdown == f.Want},
		"budget":          map[string]any{"usd": budget, "alerts": f.Alerts},
		"archive":         nz(f.Archive),
	}
	return json.MarshalIndent(out, "", "  ")
}

func nz(s string) any {
	if s == "" {
		return nil
	}
	return s
}
