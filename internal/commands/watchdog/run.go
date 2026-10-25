package watchdog

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go-v2/service/eventbridge"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"

	cg "github.com/jebin2/aws_cloud_gaming"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/bucket"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

// Reader builds the read-only watchdog reader for the settings in force: the
// settings decide what "as this repo would make it" means.
func NewReader(ctx context.Context, env *config.Env) (*wd.Reader, error) {
	region := env.Region()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		return nil, err
	}
	src, err := cg.Files.ReadFile("lambda/cloud_watchdog.py")
	if err != nil {
		return nil, err
	}
	rates := ratesFrom(ctx, env, us)
	host := env.Host()
	return &wd.Reader{
		Lambda: lambda.NewFromConfig(cfg), Events: eventbridge.NewFromConfig(cfg), IAM: iam.NewFromConfig(cfg),
		Logs: cloudwatchlogs.NewFromConfig(cfg), Now: time.Now, Host: host, Region: region, Source: src,
		Settings: func(account string) wd.Settings { return SettingsFor(env, rates, account) },
	}, nil
}

func ratesFrom(ctx context.Context, env *config.Env, us aws.Config) pricing.Rates {
	return pricing.Load(ctx, pricing.Options{Getenv: env.Get,
		Source: pricing.AWSSource{API: pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}}}, env.Region())
}

func ratesOf(ctx context.Context, env *config.Env) pricing.Rates {
	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		return pricing.Rates{}
	}
	return ratesFrom(ctx, env, us)
}

// SettingsFor is what the watchdog is deployed with, from .env and the prices
// as cg has them today. The prices are written the way the shell wrote them
// (6 significant digits for AWS's, 10 for the rupee), because the text is
// hashed into the description of every function already deployed.
func SettingsFor(env *config.Env, rates pricing.Rates, account string) wd.Settings {
	host, region := env.Host(), env.Region()
	b := env.Get("GAME_S3_BUCKET")
	if b == "" {
		b = bucket.Name(account, host, region)
	}
	s := wd.Settings{Host: host, Account: account, Bucket: b,
		IdleMinutes: env.Int("GAME_WATCHDOG_IDLE_MIN"), StuckMinutes: env.Int("GAME_WATCHDOG_STUCK_MIN"),
		ExpiryDays: env.Int("GAME_ARCHIVE_EXPIRY_DAYS"), NtfyURL: config.NtfyURL(env.Get("GAME_NTFY_URL"))}
	if rates.S3GBMonth != nil {
		s.S3GBMonth = fmt.Sprintf("%.6g", *rates.S3GBMonth)
	}
	if rates.INRPerUSD != nil {
		s.INRPerUSD = fmt.Sprintf("%.10g", *rates.INRPerUSD)
	}
	return s
}

// Run is `cg watchdog`.
func Run(ctx context.Context, env *config.Env, args []string, watch bool, out *output.Out) int {
	sub := "status"
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	for _, a := range args {
		if a == "--watch" {
			watch = true
		}
	}
	switch sub {
	case "status", "logs", "check", "install", "remove":
	default:
		out.Die("usage: cg watchdog [status|check|logs [--watch]|install|remove]")
		return 1
	}
	r, err := NewReader(ctx, env)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	if sub == "check" || sub == "install" || sub == "remove" {
		return mutate(ctx, env, r, sub, out)
	}
	if sub == "logs" {
		return Logs(ctx, r, watch, out.Stdout)
	}
	out.Report("Cloud watchdog", Status(ctx, r, env.Int("GAME_ARCHIVE_EXPIRY_DAYS")))
	return 0
}

// Logs prints what the schedule decided in the last three hours, and with
// watch keeps following it.
func Logs(ctx context.Context, r *wd.Reader, watch bool, w interface{ Write([]byte) (int, error) }) int {
	since := r.Now().Add(-3 * time.Hour)
	seen := map[string]bool{}
	for {
		evs, err := r.Since(ctx, "cg-watchdog:", since)
		if err != nil {
			fmt.Fprintf(os.Stderr, "could not read %s: %v\n", wd.LogGroup(r.Host), err)
			return 1
		}
		for _, e := range evs {
			key := fmt.Sprintf("%d %s", e.MS, e.Msg)
			if seen[key] {
				continue
			}
			seen[key] = true
			fmt.Fprintf(w, "%s %s\n", time.UnixMilli(e.MS).UTC().Format("2006-01-02T15:04:05"), strings.TrimRight(e.Msg, "\n"))
			if t := time.UnixMilli(e.MS); t.After(since) {
				since = t
			}
		}
		if !watch {
			return 0
		}
		select {
		case <-ctx.Done():
			return 130
		case <-time.After(2 * time.Second):
		}
	}
}
