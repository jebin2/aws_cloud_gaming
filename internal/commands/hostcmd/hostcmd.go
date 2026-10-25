// Package hostcmd is `cg host`: your own machines. Only the list is ported so
// far; adding, setting up and streaming from one come with the host phase.
package hostcmd

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/hosts"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
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

// Run is `cg host`.
func Run(s hosts.Store, args []string, jsonFlag bool, out *output.Out) int {
	sub := "list"
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	switch sub {
	case "list":
		for _, a := range args {
			jsonFlag = jsonFlag || a == "--json"
		}
		fmt.Fprint(out.Stdout, List(s, jsonFlag || out.JSON))
		return 0
	case "add", "setup", "status", "open", "remove":
		out.Die("host " + sub + " is not ported to Go yet")
		return 1
	}
	out.Die(usage)
	return 1
}
