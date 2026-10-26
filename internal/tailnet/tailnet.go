// Package tailnet is this laptop's view of the tailnet: which nodes are there,
// and which one is new.
package tailnet

import (
	"context"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// Node is a peer: its key is its identity, its name is not.
type Node struct{ Key, Name string }

// Nodes are the peers `tailscale status --json` lists.
//
// The KEY is a node's identity; its name is not. The prune before a build deletes
// an offline node, which frees its name, and the new box then joins under exactly
// that name - so a list of names taken before the launch already contains the new
// box's name, and nothing new ever appears in it. That waited the full 30 minutes
// on a box that had joined in 47 seconds.
func Nodes(ctx context.Context, r local.Runner) []Node {
	out, err := r.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"status", "--json"}})
	if err != nil && len(out) == 0 {
		return nil
	}
	var d struct {
		Peer map[string]struct {
			DNSName   string
			HostName  string
			PublicKey string
		}
	}
	if json.Unmarshal(out, &d) != nil {
		return nil
	}
	var ns []Node
	for k, p := range d.Peer {
		name := strings.SplitN(p.DNSName, ".", 2)[0]
		if name == "" {
			name = p.HostName
		}
		if name == "" {
			continue
		}
		key := p.PublicKey
		if key == "" {
			key = k
		}
		ns = append(ns, Node{key, name})
	}
	sort.Slice(ns, func(i, j int) bool { return ns[i].Name < ns[j].Name })
	return ns
}

// Names are one hostname per node, as `tailscale status` shows them.
func Names(ctx context.Context, r local.Runner) []string {
	out, err := r.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"status"}})
	if err != nil && len(out) == 0 {
		return nil
	}
	var names []string
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) > 1 && strings.HasPrefix(f[0], "100.") {
			names = append(names, f[1])
		}
	}
	return names
}

// Offline: is a node of this name shown as offline.
func Offline(ctx context.Context, r local.Runner, host string) bool {
	out, _ := r.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"status"}})
	for _, l := range strings.Split(string(out), "\n") {
		if f := strings.Fields(l); len(f) > 1 && f[1] == host && strings.Contains(l, "offline") {
			return true
		}
	}
	return false
}

// New is the node that was not there before: matching on "a node key that was not
// there before" rather than on an expected name is what makes this immune to the
// suffix problem - and to the pruned-name problem. Only a name this host could
// take counts (host or host-N), so a phone joining the tailnet meanwhile is not
// mistaken for the box.
func New(now []Node, before map[string]bool, host string) string {
	pat := regexp.MustCompile(`^` + regexp.QuoteMeta(host) + `-[0-9]+$`)
	for _, n := range now {
		if before[n.Key] {
			continue
		}
		if host == "" || n.Name == host || pat.MatchString(n.Name) {
			return n.Name
		}
	}
	return ""
}

// Keys are the node keys of a snapshot.
func Keys(ns []Node) map[string]bool {
	m := map[string]bool{}
	for _, n := range ns {
		m[n.Key] = true
	}
	return m
}

// Wait waits for a new node to join. It reports the name and how long it took.
func Wait(ctx context.Context, r local.Runner, before map[string]bool, host string, timeout time.Duration, sleep func(time.Duration), log func(string)) (string, bool) {
	var beat time.Duration
	for waited := time.Duration(0); waited < timeout; waited += 10 * time.Second {
		if found := New(Nodes(ctx, r), before, host); found != "" {
			log("joined as '" + found + "' after " + itoa(int(waited/time.Second)) + "s")
			return found, true
		}
		if waited-beat >= 60*time.Second {
			log("still waiting for the box to join (" + itoa(int(waited/time.Second)) + "s)")
			beat = waited
		}
		sleep(10 * time.Second)
	}
	log("TIMEOUT after " + itoa(int(timeout/time.Minute)) + "m - no new node joined the tailnet")
	return "", false
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}
