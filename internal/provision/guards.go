package provision

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	budgetstypes "github.com/aws/aws-sdk-go-v2/service/budgets/types"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

// BudgetsAPI is what arming the budget uses.
type BudgetsAPI interface {
	DescribeBudget(context.Context, *budgets.DescribeBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeBudgetOutput, error)
	CreateBudget(context.Context, *budgets.CreateBudgetInput, ...func(*budgets.Options)) (*budgets.CreateBudgetOutput, error)
	UpdateBudget(context.Context, *budgets.UpdateBudgetInput, ...func(*budgets.Options)) (*budgets.UpdateBudgetOutput, error)
}

// Budget arms the monthly budget. It is not a layer: it stops nothing, it tells
// you. AWS Budgets rather than a CloudWatch EstimatedCharges alarm, which needs
// two things a fresh account does not have: "Receive Billing Alerts" switched on
// by the *root* user (no API for it), and an SNS subscription each recipient has
// to confirm by email. Miss either and the alarm sits in INSUFFICIENT_DATA
// forever - armed in appearance only. A budget emails its subscribers directly.
// The first two budgets are free.
type Budget struct {
	C       BudgetsAPI
	Account string
	Host    string
	// INR is the monthly limit in rupees; FX the plain exchange rate (nil: unknown).
	INR   float64
	FX    *float64
	Email string // comma-separated
	Out   func(string)
}

// Arm creates the budget, or updates its limit when it exists.
func (b Budget) Arm(ctx context.Context) error {
	b.Out("==> budget")
	// Your rupees at today's exchange rate, not a rate written down once: at 88
	// the Rs 5,000 budget was $57, which is Rs 5,413 - it emailed late. The plain
	// exchange rate, not the one with GST on it: AWS counts the tax inside the
	// budget, so Rs 5,000 paid is Rs 5,000 / rate dollars of it.
	if b.FX == nil {
		b.Out("    the exchange rate could not be read - the budget is left as it is")
		return nil
	}
	usd := fmt.Sprintf("%.2f", b.INR / *b.FX)
	var subs []budgetstypes.Subscriber
	for _, e := range strings.Split(b.Email, ",") {
		e = strings.ReplaceAll(e, " ", "")
		if e == "" {
			continue
		}
		subs = append(subs, budgetstypes.Subscriber{SubscriptionType: budgetstypes.SubscriptionTypeEmail, Address: aws.String(e)})
		b.Out("    alerts to " + e)
	}
	if len(subs) == 0 {
		b.Out("    no alert address given - skipping budget")
		return nil
	}
	name := b.Host + "-monthly"
	// IncludeCredit false: credits pay the bill, but they are spending all the
	// same. Counted after credits, AWS read $0 spent all month while $21 of usage
	// went on, and could never email.
	bud := &budgetstypes.Budget{BudgetName: aws.String(name), BudgetLimit: &budgetstypes.Spend{Amount: aws.String(usd), Unit: aws.String("USD")},
		TimeUnit: budgetstypes.TimeUnitMonthly, BudgetType: budgetstypes.BudgetTypeCost,
		CostTypes: &budgetstypes.CostTypes{IncludeCredit: aws.Bool(false), IncludeRefund: aws.Bool(false), IncludeTax: aws.Bool(true)}}
	if _, err := b.C.DescribeBudget(ctx, &budgets.DescribeBudgetInput{AccountId: aws.String(b.Account), BudgetName: aws.String(name)}); err == nil {
		if _, err := b.C.UpdateBudget(ctx, &budgets.UpdateBudgetInput{AccountId: aws.String(b.Account), NewBudget: bud}); err != nil {
			return err
		}
		b.Out("    updated existing budget")
	} else {
		// 80% of actual spend, and a forecast that the month will blow the limit -
		// the forecast is the one that gives useful warning rather than a post-mortem.
		if _, err := b.C.CreateBudget(ctx, &budgets.CreateBudgetInput{AccountId: aws.String(b.Account), Budget: bud, NotificationsWithSubscribers: []budgetstypes.NotificationWithSubscribers{
			{Notification: &budgetstypes.Notification{NotificationType: budgetstypes.NotificationTypeActual, ComparisonOperator: budgetstypes.ComparisonOperatorGreaterThan, Threshold: 80, ThresholdType: budgetstypes.ThresholdTypePercentage}, Subscribers: subs},
			{Notification: &budgetstypes.Notification{NotificationType: budgetstypes.NotificationTypeForecasted, ComparisonOperator: budgetstypes.ComparisonOperatorGreaterThan, Threshold: 100, ThresholdType: budgetstypes.ThresholdTypePercentage}, Subscribers: subs}}}); err != nil {
			return err
		}
		b.Out("    created")
	}
	b.Out(fmt.Sprintf("done. budget at $%s (~INR %.0f); warns at 80%% actual and 100%% forecast", usd, b.INR))
	return nil
}

// ShutdownAPI is what checking the shutdown behaviour uses.
type ShutdownAPI interface {
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
	ModifyInstanceAttribute(context.Context, *ec2.ModifyInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.ModifyInstanceAttributeOutput, error)
	DescribeInstanceAttribute(context.Context, *ec2.DescribeInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceAttributeOutput, error)
}

// ErrShutdown: what `shutdown -h` would do is not what the watchdog needs.
var ErrShutdown = errors.New("shutdown behaviour is wrong")

// CheckShutdown makes an in-guest `shutdown -h` do the right thing, or says it
// cannot. CRITICAL: if it is left as 'terminate' on demand, the watchdog deletes
// your machine and its disk.
//
// What `shutdown -h` must mean differs by purchase model:
//
//	on demand  -> stop.      A misfiring watchdog parks the box; you restart it.
//	spot       -> terminate. A stopped spot instance can NEVER start again (its
//	                         request is disabled by the stop) and would bill for its
//	                         root volume forever. Safe because the request is
//	                         one-time, so nothing relaunches, and because the games
//	                         are mirrored to S3 before shutdown completes.
//
// Spot instances refuse ModifyInstanceAttribute for this setting outright
// (UnsupportedOperation), so the value has to come from RunInstances. Skipping the
// call is therefore safe, but only if the attribute really is what it should be,
// so check rather than assume.
func CheckShutdown(ctx context.Context, c ShutdownAPI, id string, out func(string)) error {
	life := ""
	if o, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{id}}); err == nil && len(o.Reservations) > 0 && len(o.Reservations[0].Instances) > 0 {
		life = string(o.Reservations[0].Instances[0].InstanceLifecycle)
	}
	want := "stop"
	if life == "spot" {
		want = "terminate"
		out("==> confirming shutdown means terminate (one-time spot)")
		out("    set at launch; a spot instance's shutdown behaviour cannot be modified after")
	} else {
		out("==> enforcing stop-on-shutdown (on demand)")
		if _, err := c.ModifyInstanceAttribute(ctx, &ec2.ModifyInstanceAttributeInput{InstanceId: aws.String(id), InstanceInitiatedShutdownBehavior: &ec2types.AttributeValue{Value: aws.String("stop")}}); err != nil {
			return fmt.Errorf("could not set stop-on-shutdown: %s", firstLine(err))
		}
	}
	behavior := ""
	if o, err := c.DescribeInstanceAttribute(ctx, &ec2.DescribeInstanceAttributeInput{InstanceId: aws.String(id), Attribute: ec2types.InstanceAttributeNameInstanceInitiatedShutdownBehavior}); err == nil && o.InstanceInitiatedShutdownBehavior != nil {
		behavior = aws.ToString(o.InstanceInitiatedShutdownBehavior.Value)
	}
	out("    " + behavior)
	if behavior == want {
		return nil
	}
	lines := []string{fmt.Sprintf("    FATAL: shutdown behaviour is '%s', expected '%s'.", behavior, want)}
	if want == "stop" {
		lines = append(lines, "    The idle watchdog would TERMINATE this instance and delete its disk.")
	} else {
		lines = append(lines, "    The idle watchdog would STOP this spot instance, which can then never", "    start again while its root volume keeps billing.")
	}
	lines = append(lines, "    Do not leave it running. Destroy and rebuild:  cg destroy && cg init")
	for _, l := range lines {
		out(l)
	}
	return ErrShutdown
}
