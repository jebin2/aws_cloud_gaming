package check

import (
	"context"
	"os"

	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"

	"github.com/jebin2/ayis/internal/ask"
	"github.com/jebin2/ayis/internal/awscfg"
	"github.com/jebin2/ayis/internal/commands/creds"
	"github.com/jebin2/ayis/internal/commands/watchdog"
	"github.com/jebin2/ayis/internal/config"
	"github.com/jebin2/ayis/internal/laptop"
	"github.com/jebin2/ayis/internal/local"
	"github.com/jebin2/ayis/internal/output"
	"github.com/jebin2/ayis/internal/pricing"
	"github.com/jebin2/ayis/internal/tskey"
)

// New is a Checker for this computer and the settings in force.
func New(env *config.Env, fix bool, out *output.Out) *Checker {
	home, _ := os.UserHomeDir()
	l := laptop.New(local.Exec{})
	a := ask.New(out, os.Getenv("AYIS_YES") == "1")
	say := func(kind, text string) {
		if kind == "log" {
			out.Log(text)
		} else {
			out.LogAs(kind, text)
		}
	}
	return &Checker{
		Out: out, Ask: a, Env: env, Laptop: l, Installer: &laptop.Installer{L: l, Say: say},
		Setter: creds.Setter{Out: out, Ask: a, Env: env, Verify: creds.VerifyKey, Home: home, Getenv: os.Getenv,
			TS: func(t string) tskey.Client { return tskey.Client{Token: t} }},
		Identify: func(ctx context.Context) creds.AWS { return creds.AWSFacts(ctx, env) },
		Clients: func(ctx context.Context) (Clients, error) {
			cfg, err := awscfg.New(ctx, env.Region())
			if err != nil {
				return Clients{}, err
			}
			us, err := awscfg.New(ctx, "us-east-1") // the account plan is asked in us-east-1
			if err != nil {
				return Clients{}, err
			}
			return Clients{EC2: ec2.NewFromConfig(cfg), Quotas: servicequotas.NewFromConfig(cfg), FreeTier: freetier.NewFromConfig(us)}, nil
		},
		TS: func(t string) tskey.Client { return tskey.Client{Token: t} },
		Rates: func(ctx context.Context) pricing.Rates {
			us, err := awscfg.New(ctx, "us-east-1")
			if err != nil {
				return pricing.Rates{}
			}
			return pricing.Load(ctx, pricing.Options{Getenv: env.Get,
				Source: pricing.AWSSource{API: pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}}}, env.Region())
		},
		AdoptNtfy: func(ctx context.Context) { watchdog.AdoptNtfy(ctx, env, out) },
		Home:      home, Fix: fix,
	}
}

// Run is `ayis check [--fix]`.
func Run(ctx context.Context, env *config.Env, args []string, out *output.Out) int {
	fix := false
	for _, a := range args {
		if a != "--fix" {
			out.Die("usage: setup [check [--fix]|deps [install]|creds [set]|status|cost [--daily]|clean|rebuild|destroy]")
			return 1
		}
		fix = true
	}
	if _, rc := New(env, fix, out).Run(ctx); rc != 0 {
		return rc
	}
	// Events, not bare echo: a program driving ayis should not have to read the
	// two lines saying the check passed out of raw output.
	if out.JSON {
		out.LogAs("ok", "preflight passed - nothing was created.")
		out.LogAs("info", "Run ayis init to actually build the box.")
		return 0
	}
	out.Gap()
	out.Echo("preflight passed - nothing was created.")
	out.Echo("Run ayis init to actually build the box.")
	return 0
}
