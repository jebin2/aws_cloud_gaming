package sweep

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

func envInt(get config.Lookup, key string, def int) int {
	if v, ok := get(key); ok {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envList(get config.Lookup, key string) []string {
	v, _ := get(key)
	return strings.Fields(v)
}

// Run is `cg sweep [--all] [--cached] [--json]`.
func Run(ctx context.Context, env *config.Env, get config.Lookup, args []string, jsonFlag bool, out *output.Out) int {
	all, cached := false, false
	for _, a := range args {
		switch a {
		case "--all", "all", "1":
			all = true
		case "--cached":
			cached = true
		case "--json":
			jsonFlag = true
		case "--watch":
		default:
			out.Die(fmt.Sprintf("unknown option '%s' (see: cg help)", a))
			return 1
		}
	}
	dir := ""
	if v, ok := get("CG_CACHE_DIR"); ok && v != "" {
		dir = v
	} else if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		dir = filepath.Join(base, "cg")
	} else {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".cache", "cg")
	}
	name := "sweep.json"
	if v, ok := get("CG_SWEEP_CACHE"); ok && v != "" {
		name = v
	}
	store := Store{Dir: dir, Name: name}

	// --cached never scans: it is what an opening screen reads, so the table has
	// rows instantly and rescans only when asked.
	if cached {
		if !jsonFlag {
			out.Die("cg sweep --cached is for the app; run cg sweep to scan")
			return 1
		}
		return printJSON(store.Cached(), out)
	}

	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	region := env.Region()
	products := pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}
	rates := pricing.Load(ctx, pricing.Options{Getenv: env.Get, Source: pricing.AWSSource{API: products}}, region)
	maxMS := float64(envInt(get, "CG_SWEEP_MAX_MS", 80))
	opts := Options{Configured: region, Types: envList(get, "CG_SWEEP_TYPES"), Fallbacks: envList(get, "CG_SWEEP_FALLBACKS"),
		MaxMS: maxMS, Samples: envInt(get, "CG_SWEEP_SAMPLES", 5), Parallel: envInt(get, "CG_SWEEP_PAR", 10), INRPerUSD: rates.INRPerUSD}
	opts.From, _ = get("CG_SWEEP_FROM")
	be := &AWS{Home: region, Get: get, Products: products}
	res := store.Save(Scan(ctx, be, opts))
	if res.Error != "" {
		// An error answer is not remembered as a scan.
		res.ScannedAt, res.Cached, res.AgeSeconds = nil, nil, nil
	}
	if jsonFlag {
		return printJSON(res, out)
	}
	out.Report("Regions", Show(res, all))
	return 0
}

func printJSON(v any, out *output.Out) int {
	b, err := json.Marshal(v)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	fmt.Fprintf(out.Stdout, "%s\n", b)
	return 0
}
