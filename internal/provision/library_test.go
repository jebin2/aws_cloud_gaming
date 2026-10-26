package provision

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type s3Fake struct {
	exists     bool
	createFail int // creates that fail before one works
	created    []string
	region     string
	calls      []string
	failBlock  bool
}

func (s *s3Fake) HeadBucket(context.Context, *s3.HeadBucketInput, ...func(*s3.Options)) (*s3.HeadBucketOutput, error) {
	if s.exists {
		return &s3.HeadBucketOutput{}, nil
	}
	return nil, errors.New("NotFound")
}
func (s *s3Fake) CreateBucket(_ context.Context, in *s3.CreateBucketInput, _ ...func(*s3.Options)) (*s3.CreateBucketOutput, error) {
	if s.createFail > 0 {
		s.createFail--
		return nil, errors.New("OperationAborted: A conflicting conditional operation is currently in progress")
	}
	s.created = append(s.created, aws.ToString(in.Bucket))
	if in.CreateBucketConfiguration != nil {
		s.region = string(in.CreateBucketConfiguration.LocationConstraint)
	}
	return &s3.CreateBucketOutput{}, nil
}
func (s *s3Fake) PutPublicAccessBlock(context.Context, *s3.PutPublicAccessBlockInput, ...func(*s3.Options)) (*s3.PutPublicAccessBlockOutput, error) {
	s.calls = append(s.calls, "block")
	if s.failBlock {
		return nil, errors.New("AccessDenied")
	}
	return &s3.PutPublicAccessBlockOutput{}, nil
}
func (s *s3Fake) PutBucketEncryption(context.Context, *s3.PutBucketEncryptionInput, ...func(*s3.Options)) (*s3.PutBucketEncryptionOutput, error) {
	s.calls = append(s.calls, "encryption")
	return &s3.PutBucketEncryptionOutput{}, nil
}
func (s *s3Fake) PutBucketLifecycleConfiguration(_ context.Context, in *s3.PutBucketLifecycleConfigurationInput, _ ...func(*s3.Options)) (*s3.PutBucketLifecycleConfigurationOutput, error) {
	s.calls = append(s.calls, "lifecycle")
	if aws.ToInt32(in.LifecycleConfiguration.Rules[0].AbortIncompleteMultipartUpload.DaysAfterInitiation) != 3 {
		panic("multipart rule must be 3 days")
	}
	return &s3.PutBucketLifecycleConfigurationOutput{}, nil
}
func (s *s3Fake) PutBucketTagging(context.Context, *s3.PutBucketTaggingInput, ...func(*s3.Options)) (*s3.PutBucketTaggingOutput, error) {
	s.calls = append(s.calls, "tagging")
	return &s3.PutBucketTaggingOutput{}, nil
}

type iamFake struct {
	role, profile, wrapped bool
	policy                 string
	calls                  []string
}

func (i *iamFake) GetRole(context.Context, *iam.GetRoleInput, ...func(*iam.Options)) (*iam.GetRoleOutput, error) {
	if i.role {
		return &iam.GetRoleOutput{}, nil
	}
	return nil, errors.New("NoSuchEntity")
}
func (i *iamFake) CreateRole(context.Context, *iam.CreateRoleInput, ...func(*iam.Options)) (*iam.CreateRoleOutput, error) {
	i.role = true
	i.calls = append(i.calls, "create-role")
	return &iam.CreateRoleOutput{}, nil
}
func (i *iamFake) PutRolePolicy(_ context.Context, in *iam.PutRolePolicyInput, _ ...func(*iam.Options)) (*iam.PutRolePolicyOutput, error) {
	i.policy = aws.ToString(in.PolicyDocument)
	i.calls = append(i.calls, "put-policy")
	return &iam.PutRolePolicyOutput{}, nil
}
func (i *iamFake) TagRole(context.Context, *iam.TagRoleInput, ...func(*iam.Options)) (*iam.TagRoleOutput, error) {
	return &iam.TagRoleOutput{}, nil
}
func (i *iamFake) GetInstanceProfile(context.Context, *iam.GetInstanceProfileInput, ...func(*iam.Options)) (*iam.GetInstanceProfileOutput, error) {
	if !i.profile {
		return nil, errors.New("NoSuchEntity")
	}
	p := &iamtypes.InstanceProfile{}
	if i.wrapped {
		p.Roles = []iamtypes.Role{{RoleName: aws.String("gamevps-box")}}
	}
	return &iam.GetInstanceProfileOutput{InstanceProfile: p}, nil
}
func (i *iamFake) CreateInstanceProfile(context.Context, *iam.CreateInstanceProfileInput, ...func(*iam.Options)) (*iam.CreateInstanceProfileOutput, error) {
	i.profile = true
	i.calls = append(i.calls, "create-profile")
	return &iam.CreateInstanceProfileOutput{}, nil
}
func (i *iamFake) TagInstanceProfile(context.Context, *iam.TagInstanceProfileInput, ...func(*iam.Options)) (*iam.TagInstanceProfileOutput, error) {
	return &iam.TagInstanceProfileOutput{}, nil
}
func (i *iamFake) AddRoleToInstanceProfile(context.Context, *iam.AddRoleToInstanceProfileInput, ...func(*iam.Options)) (*iam.AddRoleToInstanceProfileOutput, error) {
	i.wrapped = true
	i.calls = append(i.calls, "add-role")
	return &iam.AddRoleToInstanceProfileOutput{}, nil
}

func lib(s *s3Fake, i *iamFake) (Library, *[]string, *time.Duration) {
	var notes []string
	var slept time.Duration
	return Library{S3: s, IAM: i, Account: "123456789012", Host: "gamevps", Region: "ap-south-1",
		Note: func(x string) { notes = append(notes, x) }, Sleep: func(d time.Duration) { slept += d }}, &notes, &slept
}

func TestEnsureMakesEverythingOnAFreshAccount(t *testing.T) {
	s, i := &s3Fake{}, &iamFake{}
	l, notes, _ := lib(s, i)
	b, err := l.Ensure(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if b != l.Bucket() || len(s.created) != 1 || s.created[0] != b || s.region != "ap-south-1" {
		t.Errorf("%s %v %s", b, s.created, s.region)
	}
	if strings.Join(s.calls, ",") != "block,encryption,lifecycle,tagging" {
		t.Errorf("%v", s.calls)
	}
	if strings.Join(i.calls, ",") != "create-role,put-policy,create-profile,add-role" {
		t.Errorf("%v", i.calls)
	}
	// The policy is this one bucket and nothing else in the account.
	if !strings.Contains(i.policy, "arn:aws:s3:::"+b+"/*") || strings.Count(i.policy, "arn:aws:s3:::") != 2 || strings.Contains(i.policy, `"*"`) {
		t.Errorf("%s", i.policy)
	}
	if !strings.Contains(strings.Join(*notes, "\n"), "creating bucket "+b+" in ap-south-1") {
		t.Errorf("%v", *notes)
	}
}

func TestEnsureOnAnExistingSetupIsAnIdempotentRepair(t *testing.T) {
	s, i := &s3Fake{exists: true}, &iamFake{role: true, profile: true, wrapped: true}
	l, notes, _ := lib(s, i)
	if _, err := l.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(s.created) != 0 || strings.Join(i.calls, ",") != "put-policy" {
		t.Errorf("nothing is created twice, the policy is rewritten: %v %v", s.created, i.calls)
	}
	// Encryption, the public-access block and the multipart rule are applied to a bucket that already existed too.
	if strings.Join(s.calls, ",") != "block,encryption,lifecycle,tagging" {
		t.Errorf("%v", s.calls)
	}
	if !strings.Contains(strings.Join(*notes, "\n"), "exists") {
		t.Errorf("%v", *notes)
	}
	// us-east-1 takes no location constraint.
	s = &s3Fake{}
	l, _, _ = lib(s, &iamFake{})
	l.Region = "us-east-1"
	if _, err := l.Ensure(context.Background()); err != nil || s.region != "" {
		t.Errorf("%v %q", err, s.region)
	}
}

func TestEnsureWaitsOutTheNameBeingHeldAfterADeleteAndGivesUpSaying(t *testing.T) {
	s := &s3Fake{createFail: 3}
	l, notes, slept := lib(s, &iamFake{})
	if _, err := l.Ensure(context.Background()); err != nil || *slept != 45*time.Second {
		t.Fatalf("%v slept %v", err, *slept)
	}
	if !strings.Contains(strings.Join(*notes, "\n"), "S3 has not released the name yet (attempt 3) - waiting 15s") {
		t.Errorf("%v", *notes)
	}
	s = &s3Fake{createFail: 100}
	l, _, _ = lib(s, &iamFake{})
	_, err := l.Ensure(context.Background())
	if err == nil || !strings.Contains(err.Error(), "after 8 attempts") || !strings.Contains(err.Error(), "cg destroy --all") {
		t.Errorf("%v", err)
	}
	// A hardening that cannot be set is said and does not stop the build.
	s = &s3Fake{failBlock: true}
	l, notes, _ = lib(s, &iamFake{})
	if _, err := l.Ensure(context.Background()); err != nil || !strings.Contains(strings.Join(*notes, "\n"), "could not set the public access block (not fatal)") {
		t.Errorf("%v %v", err, *notes)
	}
	// A named bucket is used as named.
	l.Named = "my-bucket"
	if l.Bucket() != "my-bucket" {
		t.Error("GAME_S3_BUCKET wins")
	}
}

type budgetsFake struct {
	exists  bool
	created *budgets.CreateBudgetInput
	updated *budgets.UpdateBudgetInput
}

func (b *budgetsFake) DescribeBudget(context.Context, *budgets.DescribeBudgetInput, ...func(*budgets.Options)) (*budgets.DescribeBudgetOutput, error) {
	if b.exists {
		return &budgets.DescribeBudgetOutput{}, nil
	}
	return nil, errors.New("NotFoundException")
}
func (b *budgetsFake) CreateBudget(_ context.Context, in *budgets.CreateBudgetInput, _ ...func(*budgets.Options)) (*budgets.CreateBudgetOutput, error) {
	b.created = in
	return &budgets.CreateBudgetOutput{}, nil
}
func (b *budgetsFake) UpdateBudget(_ context.Context, in *budgets.UpdateBudgetInput, _ ...func(*budgets.Options)) (*budgets.UpdateBudgetOutput, error) {
	b.updated = in
	return &budgets.UpdateBudgetOutput{}, nil
}

func TestBudgetIsInRupeesAtTodaysRateAndAlertsEveryone(t *testing.T) {
	fx := 94.0
	c := &budgetsFake{}
	var out []string
	b := Budget{C: c, Account: "123", Host: "gamevps", INR: 5000, FX: &fx, Email: "a@b.c, d@e.f ,", Out: func(s string) { out = append(out, s) }}
	if err := b.Arm(context.Background()); err != nil {
		t.Fatal(err)
	}
	bud := c.created.Budget
	if aws.ToString(bud.BudgetName) != "gamevps-monthly" || aws.ToString(bud.BudgetLimit.Amount) != "53.19" || aws.ToBool(bud.CostTypes.IncludeCredit) || !aws.ToBool(bud.CostTypes.IncludeTax) {
		t.Errorf("%+v %+v", bud, bud.CostTypes)
	}
	n := c.created.NotificationsWithSubscribers
	if len(n) != 2 || n[0].Notification.Threshold != 80 || string(n[0].Notification.NotificationType) != "ACTUAL" || n[1].Notification.Threshold != 100 || string(n[1].Notification.NotificationType) != "FORECASTED" || len(n[0].Subscribers) != 2 {
		t.Errorf("%+v", n)
	}
	want := []string{"==> budget", "    alerts to a@b.c", "    alerts to d@e.f", "    created", "done. budget at $53.19 (~INR 5000); warns at 80% actual and 100% forecast"}
	if strings.Join(out, "|") != strings.Join(want, "|") {
		t.Errorf("%q", out)
	}
	// An existing budget has its limit updated and its subscribers left alone.
	c = &budgetsFake{exists: true}
	b.C, out = c, nil
	_ = b.Arm(context.Background())
	if c.updated == nil || c.created != nil || out[len(out)-2] != "    updated existing budget" {
		t.Errorf("%v", out)
	}
	// No exchange rate, or no address: left as it is, and said.
	b.FX, out, c = nil, nil, &budgetsFake{}
	b.C = c
	_ = b.Arm(context.Background())
	if c.created != nil || out[1] != "    the exchange rate could not be read - the budget is left as it is" {
		t.Errorf("%v", out)
	}
	b.FX, b.Email, out = &fx, " , ", nil
	_ = b.Arm(context.Background())
	if c.created != nil || out[len(out)-1] != "    no alert address given - skipping budget" {
		t.Errorf("%v", out)
	}
}

type shutdownFake struct {
	life, behavior string
	modified       string
	modifyErr      error
}

func (s *shutdownFake) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	return &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: []ec2types.Instance{{InstanceLifecycle: ec2types.InstanceLifecycleType(s.life)}}}}}, nil
}
func (s *shutdownFake) ModifyInstanceAttribute(_ context.Context, in *ec2.ModifyInstanceAttributeInput, _ ...func(*ec2.Options)) (*ec2.ModifyInstanceAttributeOutput, error) {
	if s.modifyErr != nil {
		return nil, s.modifyErr
	}
	s.modified = aws.ToString(in.InstanceInitiatedShutdownBehavior.Value)
	s.behavior = s.modified
	return &ec2.ModifyInstanceAttributeOutput{}, nil
}
func (s *shutdownFake) DescribeInstanceAttribute(context.Context, *ec2.DescribeInstanceAttributeInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceAttributeOutput, error) {
	return &ec2.DescribeInstanceAttributeOutput{InstanceInitiatedShutdownBehavior: &ec2types.AttributeValue{Value: aws.String(s.behavior)}}, nil
}

func TestShutdownMustMeanStopOnDemandAndTerminateOnSpot(t *testing.T) {
	var out []string
	say := func(s string) { out = append(out, s) }
	// On demand: enforced, then confirmed.
	f := &shutdownFake{behavior: "terminate"}
	if err := CheckShutdown(context.Background(), f, "i-1", say); err != nil || f.modified != "stop" || out[0] != "==> enforcing stop-on-shutdown (on demand)" || out[1] != "    stop" {
		t.Errorf("%v %q", err, out)
	}
	// Spot: cannot be modified, so it is checked and never changed.
	out = nil
	f = &shutdownFake{life: "spot", behavior: "terminate"}
	if err := CheckShutdown(context.Background(), f, "i-1", say); err != nil || f.modified != "" || out[0] != "==> confirming shutdown means terminate (one-time spot)" {
		t.Errorf("%v %q", err, out)
	}
	// A spot box that would only STOP is the dead-but-billing one: fatal, with why.
	out = nil
	f = &shutdownFake{life: "spot", behavior: "stop"}
	err := CheckShutdown(context.Background(), f, "i-1", say)
	if !errors.Is(err, ErrShutdown) || !strings.Contains(strings.Join(out, "\n"), "FATAL: shutdown behaviour is 'stop', expected 'terminate'.") || !strings.Contains(strings.Join(out, "\n"), "can then never") {
		t.Errorf("%v %q", err, out)
	}
	// On demand that cannot be set to stop is as bad the other way.
	out = nil
	f = &shutdownFake{behavior: "terminate", modifyErr: errors.New("UnauthorizedOperation")}
	if err := CheckShutdown(context.Background(), f, "i-1", say); err == nil {
		t.Error("a watchdog that would delete the disk must stop the build")
	}
}
