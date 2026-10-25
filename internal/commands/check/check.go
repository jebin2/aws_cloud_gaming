// Package check is `cg check [--fix]`: everything a build needs, checked before
// anything is launched, in the order a failure is cheapest to find.
//
// It is NOT read-only. It can save settings to .env, and with a Tailscale API
// token it can mint, replace and delete the auth key the box joins with. It
// creates no EC2 resource.
package check

import (
	"context"
	"fmt"
	"math"
	"path/filepath"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/creds"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/deps"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/sshkey"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// Quota codes: spot and on-demand are governed by different quotas, and the
// approval of one says nothing about the other.
const (
	QuotaSpot     = "L-3819A6DF"
	QuotaOnDemand = "L-DB2E81BA"
)

// EC2 is what the preflight asks of EC2.
type EC2 interface {
	sshkey.EC2
	DescribeRegions(context.Context, *ec2.DescribeRegionsInput, ...func(*ec2.Options)) (*ec2.DescribeRegionsOutput, error)
	DescribeInstanceTypes(context.Context, *ec2.DescribeInstanceTypesInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error)
}

// Clients are the AWS clients, built once the credentials work.
type Clients struct {
	EC2    EC2
	Quotas interface {
		GetServiceQuota(context.Context, *servicequotas.GetServiceQuotaInput, ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error)
	}
	FreeTier interface {
		GetAccountPlanState(context.Context, *freetier.GetAccountPlanStateInput, ...func(*freetier.Options)) (*freetier.GetAccountPlanStateOutput, error)
	}
}

// Checker is one run of the preflight.
type Checker struct {
	Out       *output.Out
	Ask       *ask.Asker
	Env       *config.Env
	Laptop    laptop.Laptop
	Installer *laptop.Installer
	Setter    creds.Setter
	// Identify reads which AWS key is in force and whether AWS takes it. It is
	// called again after a key is saved, so it must read the files afresh.
	Identify func(ctx context.Context) creds.AWS
	Clients  func(ctx context.Context) (Clients, error)
	TS       func(token string) tskey.Client
	Rates    func(ctx context.Context) pricing.Rates
	// AdoptNtfy copies the ntfy address out of the deployed watchdog into .env
	// when .env does not mention one.
	AdoptNtfy func(ctx context.Context)
	Home      string
	Fix       bool
}

// Result is what a build needs to know once the preflight has passed.
type Result struct {
	Type    string
	Region  string
	VCPUs   int
	Spot    bool
	AuthKey string
}

func (c *Checker) die(text string) (Result, int) {
	c.Out.Die(text)
	return Result{}, 1
}

// Run is the whole preflight. It returns what it settled and an exit status.
func (c *Checker) Run(ctx context.Context) (Result, int) {
	c.Out.Say("preflight")
	region, typ, host := c.Env.Region(), c.Env.Setting("GAME_INSTANCE_TYPE"), c.Env.Host()

	// --- local tools: checked by name, all at once ---
	if c.Fix {
		deps.Fix(ctx, c.Laptop, c.Installer, c.Ask, c.Out)
	}
	if !deps.Report(ctx, c.Laptop, c.Out, c.Fix) {
		if c.Fix {
			return c.die("the laptop is still not ready - install what is left yourself (see above), then run cg check again.")
		}
		return c.die("the laptop is not ready - see above.")
	}

	// --- aws access ---
	// The access key is pasted (cg creds set, or the AWS credentials card in the
	// app), never found in a file in $HOME: a plaintext key lying in a home
	// directory is not a supported way to carry a credential.
	id := c.Identify(ctx)
	if id.Valid == nil || !*id.Valid {
		// --fix: the access key is the one thing it cannot install, so ask for
		// it. CanAsk, not a terminal: pasting a key needs someone to ask, and
		// writing a file uses no sudo.
		if c.Fix && c.Ask.CanAsk() {
			c.Setter.SetAWS(ctx, region)
			id = c.Identify(ctx)
		}
		if id.Valid == nil || !*id.Valid {
			return c.die("AWS credentials are not working.\n       Paste a key:  cg creds set    (checked with AWS before it is saved)\n       Or configure them yourself:  aws configure")
		}
	}
	cl, err := c.Clients(ctx)
	if err != nil {
		return c.die("AWS credentials are not working.\n       Paste a key:  cg creds set    (checked with AWS before it is saved)\n       Or configure them yourself:  aws configure")
	}

	// The account plan is a separate gate from service quotas, and it is
	// invisible until RunInstances fails. A Free Plan account cannot launch GPU
	// instances at all, whatever the quota says.
	plan := "UNKNOWN"
	if o, err := cl.FreeTier.GetAccountPlanState(ctx, &freetier.GetAccountPlanStateInput{}); err == nil {
		plan = string(o.AccountPlanType)
	}
	if plan == "FREE" {
		return c.die("this AWS account is on the Free Plan, which can only launch free-tier-eligible\n       instance types - no GPU instances at all, regardless of your quota.\n       Upgrade to a paid plan: https://console.aws.amazon.com/billing/\n       (root user; the upgrade is not reversible)")
	}
	source := "source not known"
	if id.Source != nil {
		source = *id.Source
	}
	c.Out.LogAs("ok", fmt.Sprintf("AWS credentials work (%s)", source))
	c.Out.Log("account plan: " + plan)

	// --- region, instance type, quota ---
	if _, err := cl.EC2.DescribeRegions(ctx, &ec2.DescribeRegionsInput{RegionNames: []string{region}}); err != nil {
		return c.die(fmt.Sprintf("'%s' is not a region you can use. Set GAME_REGION to a valid one.", region))
	}
	vcpus := 0
	if o, err := cl.EC2.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{InstanceTypes: []ec2types.InstanceType{ec2types.InstanceType(typ)}}); err == nil && len(o.InstanceTypes) > 0 && o.InstanceTypes[0].VCpuInfo != nil {
		vcpus = int(aws.ToInt32(o.InstanceTypes[0].VCpuInfo.DefaultVCpus))
	} else {
		return c.die(fmt.Sprintf("%s is not offered in %s.\n       Not every region has every GPU type - ap-south-2 has no g4dn at all, for one.\n       List what is available: cg machines %s", typ, region, region))
	}

	// Spot is the default: roughly a quarter of the on-demand price, and games
	// live on ephemeral storage anyway, so a reclaim costs about what a normal
	// stop does. But spot has its OWN quota, which is 0 on a new account and is
	// refused more often than the on-demand one - so defaulting to it blindly
	// would make a fresh clone fail its first run. When GAME_SPOT is not set,
	// pick spot only if the quota can actually cover the instance, and say so
	// when falling back. An explicit 0 or 1 is always honoured as written.
	quota := func(code string) float64 {
		o, err := cl.Quotas.GetServiceQuota(ctx, &servicequotas.GetServiceQuotaInput{ServiceCode: aws.String("ec2"), QuotaCode: aws.String(code)})
		if err != nil || o.Quota == nil || o.Quota.Value == nil {
			return 0
		}
		return *o.Quota.Value
	}
	spot := c.Env.Get("GAME_SPOT")
	if spot == "" || spot == "auto" {
		q := quota(QuotaSpot)
		if q >= float64(vcpus) {
			spot = "1"
		} else {
			spot = "0"
			c.Out.Log(fmt.Sprintf("spot quota %d vCPU cannot cover %s (%d) - using on-demand", whole(q), typ, vcpus))
			c.Out.Log("  spot is ~4x cheaper; request quota " + QuotaSpot + " to enable it")
		}
	}
	code, kind := QuotaOnDemand, "on-demand"
	if spot == "1" {
		code, kind = QuotaSpot, "spot"
	}
	q := quota(code)
	if q < float64(vcpus) {
		return c.die(fmt.Sprintf("%s GPU quota in %s is %d vCPU; %s needs %d.\n\n       Request an increase for quota %s in the AWS console, with a real\n       use case - a request filed from the CLI carries no justification and is\n       usually refused. It can take days.\n\n       https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/%s\n\n       Note spot and on-demand have separate quotas; approval of one says nothing\n       about the other. Drop GAME_SPOT to use the on-demand pool instead.",
			kind, region, whole(q), typ, vcpus, code, code))
	}
	c.Out.Log(fmt.Sprintf("%s quota %d vCPU covers %s (%d)", kind, whole(q), typ, vcpus))

	// --- ssh key ---
	pem := filepath.Join(c.Home, ".ssh", host+".pem")
	if rc := c.keyReport(ctx, cl.EC2, host, pem); rc != 0 {
		return Result{}, rc
	}

	// --- the .env settings: asked for when missing, and saved ---
	// The token that checks the box's key comes before the questions: they
	// would otherwise ask for an auth key this build then refuses to use.
	// --fix asks for the token itself, so it gets the chance to.
	if !c.Fix && c.needToken() {
		return Result{}, 1
	}
	key, ok := c.settings(ctx)
	if !ok {
		return Result{}, 1
	}
	// Every build, before anything is launched: a key that cannot be shown to
	// work is a box that never joins, found out half an hour into the bill.
	if !c.authKeyPreflight(ctx, key) {
		return Result{}, 1
	}
	return Result{Type: typ, Region: region, VCPUs: vcpus, Spot: spot == "1", AuthKey: key}, 0
}

func whole(f float64) int { return int(math.Trunc(f)) }

func (c *Checker) keyReport(ctx context.Context, e sshkey.EC2, host, pem string) int {
	short := "~/.ssh/" + filepath.Base(pem)
	st := sshkey.Check(ctx, e, host, pem)
	switch st {
	case sshkey.Match:
		c.Out.LogAs("ok", fmt.Sprintf("ssh key %s matches the key pair", short))
	case sshkey.None:
		c.Out.LogAs("info", fmt.Sprintf("no key pair yet - cg init creates one, saved as %s", short))
	case sshkey.Unknown:
		c.Out.LogAs("warn", fmt.Sprintf("could not compare %s with the key pair - it is used as it is", short))
	default:
		// Stops when a box exists that this laptop cannot log in to, since
		// replacing the pair would not change that box.
		if sshkey.BoxExists(ctx, e, host) {
			c.Out.Die(fmt.Sprintf("a box exists, but %s is %s, so this laptop cannot log in to it.\n       Copy %s from the laptop that built the box, then: chmod 600 %s\n       Or destroy the box from that laptop; cg init here then makes a new key.", short, sshkey.Words(st), short, short))
			return 1
		}
		c.Out.LogAs("warn", fmt.Sprintf("%s is %s - cg init replaces the key pair (free), and the .pem on any other laptop stops working", short, sshkey.Words(st)))
	}
	return 0
}
