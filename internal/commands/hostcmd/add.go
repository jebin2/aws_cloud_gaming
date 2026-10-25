package hostcmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/ownhost"
)

const addUsage = "usage: cg host add [name] --ssh <user@address>"

// LetIn makes cg's key work on the machine, asking its password once when it
// does not: the first time a machine is added, and again whenever the key has
// gone from it - taken off by removing a second entry for the same machine, or
// by hand. Setup used to need the key already there, so a machine that lost it
// could only be removed and added again. It reports whether cg can get in; it
// has said why when not.
func (d Deps) LetIn(ctx context.Context, target string, out *output.Out) bool {
	if err := d.Conn.EnsureKey(ctx); err != nil {
		out.Die("could not make cg's ssh key (" + d.Conn.Key + ")")
		return false
	}
	if _, err := d.Conn.Raw(ctx, target, "exit", nil); err == nil {
		return true
	}
	if !d.Ask.CanAsk() {
		out.Die(fmt.Sprintf("ssh %s did not connect with a key, and there is no one to ask for its password -\n       run this in a terminal, or make 'ssh %s' work with a key first (ssh-copy-id %s)", target, target, target))
		return false
	}
	out.Log("cg's key does not let it in: its password, once, puts the key on it, and is not kept")
	pw := d.Ask.Secret("host-ssh-password", "  password for "+target+": ")
	if pw == "" {
		out.Die("no password given - nothing was changed on " + target)
		return false
	}
	switch rc := d.Conn.InstallKey(ctx, target, pw); rc {
	case 0:
	case 3:
		out.Die(fmt.Sprintf("logged in to %s, but cg's key did not stay in its ~/.ssh/authorized_keys - is that file or folder not yours to write?", target))
		return false
	default:
		out.Die(fmt.Sprintf("%s did not let cg in with that password. Check the address, user and password -\n       or, if it takes keys only, make 'ssh %s' work first (ssh-copy-id %s)", target, target, target))
		return false
	}
	if _, err := d.Conn.Raw(ctx, target, "exit", nil); err != nil {
		out.Die(fmt.Sprintf("cg's key is on %s, but it still does not let cg in with it - is PubkeyAuthentication off in its sshd_config?", target))
		return false
	}
	out.Log("cg's key is on " + target + ": no password from now on")
	return true
}

// Add is `cg host add [name] --ssh <target>`.
func (d Deps) Add(ctx context.Context, args []string, out *output.Out) int {
	name, target := "", ""
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--ssh":
			// --ssh with nothing after it must say how to use it, not loop.
			if i+1 >= len(args) {
				out.Die(addUsage)
				return 1
			}
			i++
			target = args[i]
		case strings.HasPrefix(a, "-"):
		default:
			name = a
		}
	}
	if target == "" {
		out.Die(addUsage)
		return 1
	}
	// The same address: known before anything is asked, a password least of all.
	if why := ownhost.AddedAs(d.Store, "", target); why != "" {
		out.Die(fmt.Sprintf("%s is already added, as '%s'", target, why))
		return 1
	}
	if name != "" {
		if why := ownhost.NameOK(name, d.AWSHost); why != "" {
			out.Die(why)
			return 1
		}
		if d.Store.Get(name).Field("ssh") != "" {
			out.Die(fmt.Sprintf("there is already a machine called '%s'", name))
			return 1
		}
	}
	out.Say("reaching " + target + " over ssh")
	if !d.LetIn(ctx, target, out) {
		return 1
	}
	facts := d.Conn.ReadFacts(ctx, target)
	if facts == nil {
		out.Die(fmt.Sprintf("connected, but %s did not say what it is", target))
		return 1
	}
	// The same machine by another address - its IP once, its tailnet name now -
	// added twice was two cards, two setups and two of cg's keys on one machine.
	key := ownhost.MachineKey(facts)
	if why := ownhost.AddedAs(d.Store, key, target); why != "" {
		out.Die(fmt.Sprintf("%s is a machine already added, as '%s' - the same machine, by another address", target, why))
		return 1
	}
	if name == "" {
		name = ownhost.NameFrom(facts.Get("hostname"))
		if why := ownhost.NameOK(name, d.AWSHost); why != "" {
			out.Die(fmt.Sprintf("its own name, '%s', will not do (%s) - give it one", name, why))
			return 1
		}
		if d.Store.Get(name).Field("ssh") != "" {
			out.Die(fmt.Sprintf("there is already a machine called '%s' - give this one another name", name))
			return 1
		}
	}
	if err := d.Store.Set(name, "ssh", target, "os", facts.Get("os"), "machine", key); err != nil {
		out.Die("could not save the machine: " + err.Error())
		return 1
	}
	if facts.Get("os") == "Windows" {
		out.Log("Windows - added. Setting a Windows machine up is not built yet (docs/own-machine-plan.md).")
		return 0
	}
	fam := ownhost.Family(facts)
	_ = d.Store.Set(name, "family", fam, "user", facts.Get("user"))
	out.Log(fmt.Sprintf("%s (%s), signed in as %s", facts.Get("pretty"), facts.Get("arch"), facts.Get("user")))
	gpu := facts.Get("nvidia")
	if gpu == "" {
		gpu = facts.Get("gpu")
	}
	out.Log("GPU: " + gpu)
	if fam == "unsupported" {
		out.Log("note: cg sets up Ubuntu, Debian, Arch (and its family) and Fedora - this one it can only stream from once you install Sunshine yourself")
	}
	out.Log(fmt.Sprintf("added '%s'. Next: cg host setup %s", name, name))
	return 0
}

// Remove is `cg host remove <name>`: cg's key off the machine, then the machine
// forgotten; nothing else on it is touched.
func (d Deps) Remove(ctx context.Context, args []string, out *output.Out) int {
	if len(args) == 0 || d.Store.Get(args[0]).Field("ssh") == "" {
		out.Die("usage: cg host remove <name>")
		return 1
	}
	name := args[0]
	if err := d.Conn.RemoveKey(ctx, d.Store.Get(name).Field("ssh")); err == nil {
		out.Log("took cg's key off it")
	} else {
		out.LogAs("warn", "could not reach it to take cg's key off - that one line stays in its ~/.ssh/authorized_keys")
	}
	if err := d.Store.Forget(name); err != nil {
		out.Die("could not forget '" + name + "': " + err.Error())
		return 1
	}
	out.Log(fmt.Sprintf("forgot '%s' - nothing else on the machine was changed", name))
	return 0
}
