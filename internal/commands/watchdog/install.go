package watchdog

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/eventbridge"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

// NewInstaller wires the installer to AWS for the settings in force.
func NewInstaller(ctx context.Context, env *config.Env, r *wd.Reader, out *output.Out) (*wd.Installer, error) {
	region := env.Region()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	id, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		return nil, errors.New("cannot reach AWS")
	}
	account := aws.ToString(id.Account)
	return &wd.Installer{
		Lambda: lambda.NewFromConfig(cfg), Events: eventbridge.NewFromConfig(cfg), IAM: iam.NewFromConfig(cfg),
		Logs: cloudwatchlogs.NewFromConfig(cfg), SSM: ssm.NewFromConfig(cfg),
		Host: env.Host(), Region: region, Account: account, Source: r.Source, Settings: r.Settings(account), TagKey: config.TagKey,
		LambdaIn: func(ctx context.Context, other string) (bool, error) {
			c, err := awscfg.New(ctx, other)
			if err != nil {
				return false, err
			}
			_, err = lambda.NewFromConfig(c).GetFunctionConfiguration(ctx, &lambda.GetFunctionConfigurationInput{FunctionName: aws.String(wd.Name(env.Host()))})
			if err == nil {
				return true, nil
			}
			if wd.IsNotFound(err) {
				return false, nil
			}
			return false, err // could not be asked: unknown, not "no"
		},
		Regions: func(ctx context.Context) ([]string, error) {
			o, err := ec2.NewFromConfig(cfg).DescribeRegions(ctx, &ec2.DescribeRegionsInput{})
			if err != nil {
				return nil, err
			}
			var rs []string
			for _, x := range o.Regions {
				rs = append(rs, aws.ToString(x.RegionName))
			}
			return rs, nil
		},
		Log: out.Log, Sleep: time.Sleep,
	}, nil
}

// adoptNtfy copies the ntfy address out of the deployed watchdog into .env when
// .env does not mention it at all. A laptop with no GAME_NTFY_URL - a new one,
// say - redeployed the watchdog without it, silently turning notifications off for
// the whole rig. An empty GAME_NTFY_URL= is a choice to go without, and is left
// alone. The address is never printed.
func adoptNtfy(ctx context.Context, env *config.Env, r *wd.Reader, out *output.Out) {
	if env.Has("GAME_NTFY_URL") {
		return
	}
	o, err := r.Lambda.GetFunctionConfiguration(ctx, &lambda.GetFunctionConfigurationInput{FunctionName: aws.String(wd.Name(r.Host))})
	if err != nil || o.Environment == nil {
		return
	}
	v := o.Environment.Variables["CG_NTFY_URL"]
	if v == "" || v == "None" {
		return
	}
	if env.Set("GAME_NTFY_URL", v) != nil {
		return
	}
	out.LogAs("ok", "notifications: copied the ntfy address from the cloud watchdog into .env")
}

// AdoptNtfy is adoptNtfy for a caller that has no reader of its own: `cg check`,
// which does it before it asks for the address. Any trouble reading the
// watchdog is the same as there being nothing to adopt.
func AdoptNtfy(ctx context.Context, env *config.Env, out *output.Out) {
	if env.Has("GAME_NTFY_URL") {
		return
	}
	if r, err := NewReader(ctx, env); err == nil {
		adoptNtfy(ctx, env, r, out)
	}
}

func mutate(ctx context.Context, env *config.Env, r *wd.Reader, sub string, out *output.Out) int {
	switch sub {
	case "install":
		out.Say("installing the cloud watchdog")
		adoptNtfy(ctx, env, r, out)
	case "remove":
		out.Say("removing the cloud watchdog")
	}
	r.Settings = func(account string) wd.Settings { return SettingsFor(env, ratesOf(ctx, env), account) }
	i, err := NewInstaller(ctx, env, r, out)
	if err != nil {
		if sub == "install" {
			out.Log("cannot reach AWS - the cloud watchdog was not installed")
			out.Die("the cloud watchdog was not installed")
		} else {
			out.Die(err.Error())
		}
		return 1
	}
	switch sub {
	case "install":
		if err := i.Install(ctx); err != nil {
			out.Die("the cloud watchdog was not installed")
			return 1
		}
		i.Report(i.Prove(ctx))
	case "check":
		i.Report(i.Prove(ctx))
	case "remove":
		i.Remove(ctx)
	}
	return 0
}

// Reinstall redeploys the cloud watchdog with the settings now in force, as
// `cg watchdog install` does. It is what a setting that the watchdog carries -
// how long saved games are kept - needs to take effect.
func Reinstall(ctx context.Context, env *config.Env, out *output.Out) int {
	r, err := NewReader(ctx, env)
	if err != nil {
		out.Log("cannot reach AWS - the cloud watchdog was not installed")
		out.Die("the cloud watchdog was not installed")
		return 1
	}
	return mutate(ctx, env, r, "install", out)
}

// Ensure is what `cg init` does before anything launches: the cloud watchdog
// watches by TAG, so it does not need the instance to exist - and the point of an
// independent guard is that it is already watching when the box appears. When
// nothing changed this is one round of read-only calls: no redeploy, and no new
// check. Never fatal: a missing guard must not stop you building a box.
func Ensure(ctx context.Context, env *config.Env, out *output.Out) {
	r, err := NewReader(ctx, env)
	if err != nil {
		out.Log("cloud watchdog not installed - the on-host watchdog and the budget still apply")
		return
	}
	adoptNtfy(ctx, env, r, out)
	r.Settings = func(account string) wd.Settings { return SettingsFor(env, ratesOf(ctx, env), account) }
	st := r.Current(ctx)
	if len(st.Drift) == 0 {
		now := r.Now()
		if st.LastMS == 0 {
			out.Log("cloud watchdog: up to date, but it has logged nothing in the last hour - check: cg watchdog status")
			return
		}
		out.Log(fmt.Sprintf("cloud watchdog: up to date - last check %s ago: %s", wd.Age(st.LastMS, now), strings.TrimPrefix(st.LastMsg, "cg-watchdog: ")))
		if now.Unix()-st.LastMS/1000 > 900 {
			out.Log(fmt.Sprintf("  ^ nothing for %d min but it runs every 5 - it is not running. Check: cg watchdog status", (now.Unix()-st.LastMS/1000)/60))
		}
		if m := st.LastMsg; strings.Contains(m, "CANNOT QUERY AWS") || strings.Contains(m, "DENIED") || strings.Contains(m, "FAILED") {
			out.Log("  ^ it cannot act on your account - fix this or layer 3 is decoration")
		}
		out.Log("game archive: " + wd.ArchiveDecision(ctx, r.Logs, r.Host, env.Int("GAME_ARCHIVE_EXPIRY_DAYS"), now))
		return
	}
	if len(st.Drift) == 1 && st.Drift[0] == "no function" {
		out.Say("arming the cloud watchdog before anything launches")
	} else {
		out.Say("updating the cloud watchdog: " + strings.Join(st.Drift, ", "))
	}
	i, err := NewInstaller(ctx, env, r, out)
	if err != nil || i.Install(ctx) != nil {
		out.Log("cloud watchdog not installed - the on-host watchdog and the budget still apply")
		return
	}
	i.Report(i.Prove(ctx))
}
