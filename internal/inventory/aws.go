package inventory

import (
	"context"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/budgets"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

// AWS is the real Cloud.
type AWS struct {
	Home string
	Host string

	mu  sync.Mutex
	cfg map[string]aws.Config
}

func (a *AWS) config(ctx context.Context, region string) (aws.Config, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if c, ok := a.cfg[region]; ok {
		return c, nil
	}
	c, err := awscfg.New(ctx, region)
	if err != nil {
		return aws.Config{}, err
	}
	if a.cfg == nil {
		a.cfg = map[string]aws.Config{}
	}
	a.cfg[region] = c
	return c, nil
}

func (a *AWS) Account(ctx context.Context) (string, error) {
	c, err := a.config(ctx, a.Home)
	if err != nil {
		return "", err
	}
	o, err := sts.NewFromConfig(c).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		return "", err
	}
	return aws.ToString(o.Account), nil
}

func (a *AWS) Regions(ctx context.Context) ([]string, error) {
	c, err := a.config(ctx, a.Home)
	if err != nil {
		return nil, err
	}
	o, err := ec2.NewFromConfig(c).DescribeRegions(ctx, &ec2.DescribeRegionsInput{})
	if err != nil {
		return nil, err
	}
	var out []string
	for _, r := range o.Regions {
		out = append(out, aws.ToString(r.RegionName))
	}
	return out, nil
}

func (a *AWS) Machines(ctx context.Context, region string) ([]Machine, error) {
	c, err := a.config(ctx, region)
	if err != nil {
		return nil, err
	}
	var out []Machine
	var token *string
	cl := ec2.NewFromConfig(c)
	for {
		o, err := cl.DescribeInstances(ctx, &ec2.DescribeInstancesInput{
			Filters: []ec2types.Filter{
				{Name: aws.String("tag:Name"), Values: []string{a.Host}},
				{Name: aws.String("instance-state-name"), Values: []string{"pending", "running", "stopping", "stopped"}}},
			NextToken: token})
		if err != nil {
			return nil, err
		}
		for _, r := range o.Reservations {
			for _, i := range r.Instances {
				m := Machine{ID: aws.ToString(i.InstanceId), Type: string(i.InstanceType)}
				if i.State != nil {
					m.State = string(i.State.Name)
				}
				out = append(out, m)
			}
		}
		if o.NextToken == nil || *o.NextToken == "" {
			return out, nil
		}
		token = o.NextToken
	}
}

func (a *AWS) Watchdog(ctx context.Context, region string) bool {
	c, err := a.config(ctx, region)
	if err != nil {
		return false
	}
	_, err = lambda.NewFromConfig(c).GetFunctionConfiguration(ctx, &lambda.GetFunctionConfigurationInput{FunctionName: aws.String(wd.Name(a.Host))})
	return err == nil
}

func (a *AWS) Role(ctx context.Context) bool {
	c, err := a.config(ctx, a.Home)
	if err != nil {
		return false
	}
	_, err = iam.NewFromConfig(c).GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String(wd.Name(a.Host))})
	return err == nil
}

func (a *AWS) Budget(ctx context.Context, account string) bool {
	c, err := a.config(ctx, "us-east-1")
	if err != nil {
		return false
	}
	_, err = budgets.NewFromConfig(c).DescribeBudget(ctx, &budgets.DescribeBudgetInput{AccountId: aws.String(account), BudgetName: aws.String(a.Host + "-monthly")})
	return err == nil
}

func (a *AWS) Settings(ctx context.Context, region string) []string {
	c, err := a.config(ctx, region)
	if err != nil {
		return nil
	}
	var out []string
	pg := ssm.NewGetParametersByPathPaginator(ssm.NewFromConfig(c), &ssm.GetParametersByPathInput{Path: aws.String("/cloud-gaming/" + a.Host), Recursive: aws.Bool(true)})
	for pg.HasMorePages() {
		o, err := pg.NextPage(ctx)
		if err != nil {
			return out
		}
		for _, p := range o.Parameters {
			out = append(out, aws.ToString(p.Name))
		}
	}
	return out
}
