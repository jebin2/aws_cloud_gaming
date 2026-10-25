// Package hostcmd is `cg host`: your own machines. List, add, status and remove
// are ported; setting up and streaming from one come with the build and stream
// code they share with the AWS box.
package hostcmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/hosts"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/ownhost"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
)

const usage = "usage: cg host [list|add [name] --ssh <user@address>|setup <name>|status <name>|open <name>|remove <name>]"

// List is `cg host list`: the machines as data (without any password), or as a
// table for a person.
func List(s hosts.Store, jsonOut bool) string {
	names := s.Names()
	if jsonOut {
		rows := []hosts.Record{}
		for _, n := range names {
			rows = append(rows, s.Get(n).Public(n))
		}
		b, _ := json.Marshal(rows)
		return string(b) + "\n"
	}
	if len(names) == 0 {
		return "  no machines of your own yet - add one: cg host add <name> --ssh <user@address>\n"
	}
	var b strings.Builder
	for _, n := range names {
		r := s.Get(n)
		fmt.Fprintf(&b, "  %-16s %-28s %s\n", n, r.Field("ssh"), r.Field("os"))
	}
	return b.String()
}

// Deps is what the machine commands need besides the file.
type Deps struct {
	Store     hosts.Store
	Conn      ownhost.Conn
	Ask       *ask.Asker
	Sun       sunshine.Client
	Runner    local.Runner
	AWSHost   string // the name cg gives its AWS boxes, which a machine of yours may not take
	Moonlight bool
}

// New is Deps for this computer.
func New(get config.Lookup, env *config.Env, out *output.Out) Deps {
	r := local.Exec{}
	return Deps{Store: hosts.Store{Path: hosts.PathFor(get)},
		Conn: ownhost.Conn{R: r, Key: ownhost.KeyPath(get), Hostname: func() string {
			if h, err := os.Hostname(); err == nil && h != "" {
				return h
			}
			return "laptop"
		}},
		Ask: ask.New(out, os.Getenv("CG_YES") == "1"), Sun: sunshine.Client{}, Runner: r,
		AWSHost: env.Host(), Moonlight: r.Has("moonlight")}
}

// Run is `cg host`.
func Run(ctx context.Context, d Deps, args []string, jsonFlag bool, out *output.Out) int {
	sub := "list"
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	switch sub {
	case "list":
		for _, a := range args {
			jsonFlag = jsonFlag || a == "--json"
		}
		fmt.Fprint(out.Stdout, List(d.Store, jsonFlag || out.JSON))
		return 0
	case "add":
		return d.Add(ctx, args, out)
	case "remove":
		return d.Remove(ctx, args, out)
	case "status":
		for _, a := range args {
			jsonFlag = jsonFlag || a == "--json"
		}
		return d.Status(ctx, args, jsonFlag || out.JSON, out)
	case "setup", "open":
		out.Die("host " + sub + " is not ported to Go yet")
		return 1
	}
	out.Die(usage)
	return 1
}
