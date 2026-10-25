package regions

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/account"
	"github.com/aws/aws-sdk-go-v2/service/ec2"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Run is `cg regions [optin|enable <region>]`.
func Run(ctx context.Context, env *config.Env, args []string, jsonFlag bool, out *output.Out) int {
	sub := ""
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	if sub == "--json" {
		sub, jsonFlag = "", true
	}
	cfg, err := awscfg.New(ctx, env.Region())
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	us, err := awscfg.New(ctx, "us-east-1") // the Account API is global
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	acct := account.NewFromConfig(us)
	switch sub {
	case "optin":
		for _, a := range args {
			jsonFlag = jsonFlag || a == "--json"
		}
		o := ReadOptIn(ctx, acct)
		if jsonFlag {
			return emit(o, out)
		}
		fmt.Fprint(out.Stdout, ShowOptIn(o))
		return 0
	case "enable":
		if len(args) == 0 || args[0] == "" {
			out.Die("usage: cg regions enable <region>")
			return 1
		}
		return Enabler{Account: acct, Say: out.Say, LogAs: out.LogAs, Log: out.Log, Sleep: time.Sleep}.Enable(ctx, args[0])
	case "":
		l := Enabled(ctx, ec2.NewFromConfig(cfg), env.Region())
		if jsonFlag {
			b, _ := json.Marshal(l)
			fmt.Fprintf(out.Stdout, "%s\n", b)
			return 0
		}
		out.Report("Regions", Show(l))
		return 0
	}
	out.Die("usage: cg regions [optin|enable <region>]")
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
