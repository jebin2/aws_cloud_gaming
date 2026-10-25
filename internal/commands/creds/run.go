package creds

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"

	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// Run is `cg creds [status|--json]` and `cg creds tailscale [status|--json]`.
// Setting a key is a separate port.
func Run(ctx context.Context, env *config.Env, args []string, jsonFlag bool, out *output.Out) int {
	sub := "status"
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	if sub == "--json" {
		jsonFlag, sub = true, "status"
	}
	l := laptop.New(local.Exec{})
	switch sub {
	case "status", "":
		a := AWSFacts(ctx, env)
		if jsonFlag {
			return emit(a, out)
		}
		ok := ShowAWS(a, out)
		out.Gap()
		if !ShowTS(tsFacts(ctx, env, l), out) {
			ok = false
		}
		return rc(ok)
	case "tailscale":
		tsub := "status"
		if len(args) > 0 {
			tsub = args[0]
		}
		switch tsub {
		case "--json":
			jsonFlag = true
		case "status", "":
		case "set":
			return setter(env, out).SetToken(ctx)
		case "authkey":
			return setter(env, out).SetAuthKey(ctx)
		case "signin", "up":
			return signin(ctx, l, out)
		default:
			out.Die("usage: setup creds tailscale [status|signin|set|authkey|--json]")
			return 1
		}
		t := tsFacts(ctx, env, l)
		if jsonFlag {
			return emit(t, out)
		}
		return rc(ShowTS(t, out))
	case "set":
		which := "aws"
		if len(args) > 0 {
			which = args[0]
		}
		switch which {
		case "aws", "":
			return setter(env, out).SetAWS(ctx, env.Region())
		case "tailscale", "ts":
			return setter(env, out).SetToken(ctx)
		}
		out.Die("usage: setup creds set [aws|tailscale]")
		return 1
	}
	out.Die("usage: setup creds [status|set [aws|tailscale]|tailscale ...|--json]")
	return 1
}

func setter(env *config.Env, out *output.Out) Setter {
	home, _ := os.UserHomeDir()
	return Setter{Out: out, Ask: ask.New(out, os.Getenv("CG_YES") == "1"), Env: env, Verify: VerifyKey, Home: home, Getenv: os.Getenv,
		TS: func(token string) tskey.Client { return tskey.Client{Token: token} }}
}

// signin is `cg creds tailscale signin`.
func signin(ctx context.Context, l laptop.Laptop, out *output.Out) int {
	if l.Runner.Has("tailscale") && !l.TailscaleDown(ctx) {
		out.LogAs("ok", "already signed in")
		return 0
	}
	out.Say("tailscale sign-in")
	return rc(l.TailscaleUp(ctx, func(kind, text string) {
		if kind == "log" {
			out.Log(text)
		} else {
			out.LogAs(kind, text)
		}
	}))
}

func rc(ok bool) int {
	if ok {
		return 0
	}
	return 1
}

func emit(v any, out *output.Out) int {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	fmt.Fprintf(out.Stdout, "%s\n", b)
	return 0
}

// AWSFacts reads which AWS key is in force and whether AWS takes it.
func AWSFacts(ctx context.Context, env *config.Env) AWS {
	cfg, err := awscfg.New(ctx, env.Region())
	if err != nil {
		reason, msg := "no-key", err.Error()
		return AWS{CLI: true, Reason: &reason, Error: &msg}
	}
	home, _ := os.UserHomeDir()
	return ReadAWS(ctx, cfg.Credentials, sts.NewFromConfig(cfg), home, os.Getenv("AWS_PROFILE"))
}

func tsFacts(ctx context.Context, env *config.Env, l laptop.Laptop) TS {
	stored := env.Get("TAILSCALE_AUTH_KEY") != "" || env.Get("GAME_TS_AUTHKEY") != ""
	return ReadTS(ctx, l, http.DefaultClient, env.Get("TAILSCALE_API_KEY"), stored)
}
