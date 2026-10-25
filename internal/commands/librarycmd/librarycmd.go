// Package librarycmd is `cg library`, the reads that need no box: what is in the
// archive, what is saved somewhere else, and which Steam login a new box would
// use. The archive outlives every box, so these have to be answerable when there
// is none.
package librarycmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

const usage = "usage: cg library [list|status|push|pull [--apps <csv>]|account [status|push|pull|forget]|check|forget <appid> [--from <bucket>]|reset <appid> [--from <bucket>]|keep-for <days>|move <appid> --from <bucket>|elsewhere|clean|--bucket]"

// Reader is a library with everything it needs wired to AWS.
type Reader struct {
	Lib      library.Library
	Params   library.Params
	Prices   library.Prices
	Disk     library.Disk
	Expiry   int
	CacheDir string
	Bucket   string
	BucketOK bool
}

// New wires it up for the settings in force.
func New(ctx context.Context, env *config.Env, get config.Lookup) (*Reader, error) {
	region := env.Region()
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	us, err := awscfg.New(ctx, "us-east-1")
	if err != nil {
		return nil, err
	}
	products := pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}
	popts := pricing.Options{Getenv: env.Get, Source: pricing.AWSSource{API: products}}
	rates := pricing.Load(ctx, popts, region)
	acct := ""
	if id, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err == nil {
		acct = aws.ToString(id.Account)
	}
	home, _ := os.UserHomeDir()
	cache := filepath.Join(home, ".cache", "cg")
	if base, ok := get("XDG_CACHE_HOME"); ok && base != "" {
		cache = filepath.Join(base, "cg")
	}
	r := &Reader{
		Lib: library.Library{S3: &library.AWSStore{Home: region}, Host: env.Host(), Region: region, Account: acct,
			Bucket: env.Get("GAME_S3_BUCKET"), S3USD: rates.S3GBMonth, INR: rates.INRPerUSD},
		Params: library.SSMParams{Client: ssm.NewFromConfig(cfg)},
		Prices: func(ctx context.Context, region, key string) *float64 { return pricing.For(ctx, popts, region, key) },
		Expiry: env.Int("GAME_ARCHIVE_EXPIRY_DAYS"), CacheDir: cache,
	}
	r.Bucket, r.BucketOK = r.Lib.BucketName()
	t := env.Setting("GAME_INSTANCE_TYPE")
	r.Disk = diskFor(ctx, ec2.NewFromConfig(cfg), t, cache, env.Int("GAME_DISK_RESERVE_GB"))
	return r, nil
}

// diskFor is what the game disk of a machine type holds, in GiB: measured on a
// real one once one has run (cg status writes it, cached per type), else AWS's
// own figure for the type, which is in GB (10^9) and a little more than a
// formatted disk holds. Free, and cached too.
func diskFor(ctx context.Context, c *ec2.Client, t, cache string, reserve int) library.Disk {
	d := library.Disk{Type: t, ReserveGB: &reserve}
	mark := filepath.Join(cache, "scratch-"+t)
	if b, err := os.ReadFile(mark); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && n > 0 {
			d.GB, d.Measured = &n, true
			return d
		}
	}
	gb := -1
	if b, err := os.ReadFile(mark + ".aws"); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
			gb = n
		}
	}
	if gb < 0 {
		if o, err := c.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{InstanceTypes: []ec2types.InstanceType{ec2types.InstanceType(t)}}); err == nil &&
			len(o.InstanceTypes) > 0 && o.InstanceTypes[0].InstanceStorageInfo != nil && o.InstanceTypes[0].InstanceStorageInfo.TotalSizeInGB != nil {
			gb = int(*o.InstanceTypes[0].InstanceStorageInfo.TotalSizeInGB)
			if os.MkdirAll(cache, 0o755) == nil {
				_ = os.WriteFile(mark+".aws", []byte(strconv.Itoa(gb)), 0o644)
			}
		}
	}
	if gb >= 0 {
		g := int(float64(gb)*1e9/1073741824 + 0.5)
		d.GB = &g
	}
	return d
}

// fileCache remembers the logins' names against their ETag.
type fileCache struct{ dir string }

func (c fileCache) Get(tag string) ([]library.SteamAccount, bool) {
	b, err := os.ReadFile(filepath.Join(c.dir, "account-"+tag+".json"))
	if err != nil {
		return nil, false
	}
	var rows []library.SteamAccount
	return rows, json.Unmarshal(b, &rows) == nil && len(rows) > 0
}

func (c fileCache) Put(tag string, rows []library.SteamAccount) {
	if b, err := json.Marshal(rows); err == nil && os.MkdirAll(c.dir, 0o755) == nil {
		_ = os.WriteFile(filepath.Join(c.dir, "account-"+tag+".json"), b, 0o644)
	}
}

// Run is `cg library ...`.
func Run(ctx context.Context, env *config.Env, get config.Lookup, args []string, jsonFlag bool, out *output.Out) int {
	sub := "status"
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	switch sub {
	case "list", "elsewhere", "account", "login", "--bucket", "bucket":
	case "forget", "clean", "reset", "keep", "keep-for", "move":
	case "status", "", "push", "sync", "pull", "restore", "check":
		out.Die("library " + sub + " is not ported to Go yet")
		return 1
	default:
		out.Die(usage)
		return 1
	}
	r, err := New(ctx, env, get)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	switch sub {
	case "forget", "clean", "reset", "keep", "keep-for", "move":
		c, err := NewChanger(ctx, r, env, out)
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		switch sub {
		case "forget":
			return c.Forget(ctx, args)
		case "clean":
			return c.Clean(ctx)
		case "reset", "keep":
			return c.Reset(ctx, args)
		case "keep-for":
			return c.KeepFor(ctx, args)
		default:
			return c.Move(ctx, args)
		}
	case "--bucket", "bucket":
		if r.BucketOK {
			fmt.Fprintf(out.Stdout, "%s\n", r.Bucket)
		} else {
			fmt.Fprintf(out.Stdout, "(unknown - AWS did not answer)\n")
		}
		return 0
	case "list":
		if jsonFlag {
			l := r.Lib.List(ctx, r.Params, r.Disk, r.Expiry)
			if code := emit(l, out); l.Error != "" {
				return 1
			} else {
				return code
			}
		}
		text, ok := r.Lib.Human(ctx, r.Params, r.Disk)
		out.Report("Game archive", text)
		if !ok {
			return 1
		}
		return 0
	case "elsewhere":
		e := r.Lib.ReadElsewhere(ctx, r.Params, r.Prices, r.Expiry)
		if jsonFlag {
			return emit(e, out)
		}
		text, ok := library.ShowElsewhere(e, r.Lib.INR)
		out.Report("Saved somewhere else", text)
		if !ok {
			return 1
		}
		return 0
	default: // account, login
		for len(args) > 0 && strings.HasPrefix(args[0], "-") {
			jsonFlag = jsonFlag || args[0] == "--json"
			args = args[1:]
		}
		a := "status"
		if len(args) > 0 {
			a = args[0]
		}
		switch a {
		case "status", "":
		case "forget", "delete", "rm":
			c, err := NewChanger(ctx, r, env, out)
			if err != nil {
				out.Die(err.Error())
				return 1
			}
			return c.ForgetLogin(ctx, args[1:], fileCache{r.CacheDir})
		case "push", "pull", "restore":
			out.Die("library account " + a + " is not ported to Go yet")
			return 1
		default:
			out.Die("usage: cg library account [status|push|pull|forget]")
			return 1
		}
		b := r.Bucket
		region := r.Lib.Region
		if loc, err := r.Lib.S3.Location(ctx, b); err == nil && loc != "" {
			region = loc
		}
		login := r.Lib.AccountAt(ctx, b, region, fileCache{r.CacheDir})
		if jsonFlag {
			return emit(login, out)
		}
		out.Echo(ShowAccount(login))
		return 0
	}
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

// ShowAccount is `cg library account` for a person.
func ShowAccount(d library.Login) string {
	var b strings.Builder
	if !d.Present {
		b.WriteString("no archived Steam login - a new box would ask you to sign in\n")
		b.WriteString("  one is pushed automatically when a box shuts down, or now with:\n")
		b.WriteString("      cg library account push")
		return b.String()
	}
	fmt.Fprintf(&b, "archived login   %s  (%.1f KB)\n", d.Key, float64(*d.Bytes)/1024)
	if d.Modified != nil {
		fmt.Fprintf(&b, "pushed           %s\n", *d.Modified)
	}
	// A cost line, because every other archive view has one - and this one
	// exists mainly to say the number is nothing, so deleting it is not a saving.
	if d.USDMonth != nil {
		fmt.Fprintf(&b, "storage          $%.6f/month - effectively nothing\n", *d.USDMonth)
	}
	if d.Accounts == nil {
		b.WriteString("accounts         could not read them from the archive")
		return b.String()
	}
	b.WriteString("\n")
	fmt.Fprintf(&b, "  %-20s %-20s %-12s %s\n", "ACCOUNT", "PERSONA", "LAST USED", "")
	for _, r := range *d.Accounts {
		when := "-"
		if r.LastUsed != nil && *r.LastUsed > 0 {
			when = time.Unix(*r.LastUsed, 0).Format("2006-01-02")
		}
		mark := ""
		if r.MostRecent {
			mark = "<- a new box signs in as this one"
		}
		acct, persona := "?", "-"
		if r.Account != nil {
			acct = *r.Account
		}
		if r.Persona != nil {
			persona = *r.Persona
		}
		fmt.Fprintf(&b, "  %-20s %-20s %-12s %s\n", acct, persona, when, mark)
	}
	if len(*d.Accounts) > 1 {
		b.WriteString("\n  More than one account is archived. The tarball is restored whole, so\n")
		b.WriteString("  a new box gets all of them and signs in as the most recent. To keep\n")
		b.WriteString("  only one: sign in as it on the box, then cg library account push.")
	}
	return strings.TrimRight(b.String(), "\n")
}
