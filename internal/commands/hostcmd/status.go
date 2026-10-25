package hostcmd

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/ownhost"
)

// State is every fact the Machine page needs. Free.
type State struct {
	Name      string  `json:"name"`
	SSH       string  `json:"ssh"`
	OS        *string `json:"os"`
	OSName    *string `json:"os_name"`
	Family    *string `json:"family"`
	TailnetIP *string `json:"tailnet_ip"`
	Reachable bool    `json:"reachable"`
	Online    bool    `json:"online"`
	Sunshine  bool    `json:"sunshine"`
	LoginOK   bool    `json:"login_ok"`
	Paired    bool    `json:"paired"`
	SetUp     bool    `json:"set_up"`
	Desktop   *string `json:"desktop"`
	// Steam is null when the machine could not be asked.
	Steam *bool   `json:"steam"`
	GPU   *string `json:"gpu"`
}

func nz(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Read probes the machine: ssh, the tailnet, Sunshine, its login, the pairing.
func (d Deps) Read(ctx context.Context, name string) State {
	r := d.Store.Get(name)
	t, ip := r.Field("ssh"), r.Field("ts_ip")
	facts := d.Conn.ReadFacts(ctx, t)
	s := State{Name: name, SSH: t, OS: nz(r.Field("os")), Family: nz(r.Field("family")), TailnetIP: nz(ip),
		Reachable: facts != nil, SetUp: r.Field("ready") == "yes", OSName: nz(facts.Get("pretty")), Desktop: nz(facts.Get("session"))}
	if s.Reachable {
		b := facts.Get("steam") != ""
		s.Steam = &b
	}
	gpu := facts.Get("nvidia")
	if gpu == "" {
		// The NVIDIA name when there is one; otherwise what lspci calls the card.
		gpu, _, _ = strings.Cut(facts.Get("gpu"), ";")
	}
	s.GPU = nz(gpu)
	if ip == "" {
		return s
	}
	pctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	_, err := d.Runner.Run(pctx, local.Cmd{Name: "tailscale", Args: []string{"ping", "-c", "1", "--timeout", "3s", ip}})
	cancel()
	s.Online = err == nil
	if !d.Sun.Answers(ctx, ip) {
		return s
	}
	s.Sunshine = true
	// Its tailnet address answered, which nothing but the tailnet reaches: on it,
	// whatever one ping said - a single tailscale ping can go unanswered on a path
	// that streams fine, and the card said "not connected" beside Play.
	s.Online = true
	lu, lp := r.Field("sunshine_user"), r.Field("sunshine_pass")
	su, sp := ownhost.Login(facts)
	switch {
	case d.Sun.LoginOK(ctx, ip, lu, lp):
		s.LoginOK = true
		// This device holds the one that works: kept on the machine, so the others find it.
		if s.Reachable && (su != lu || sp != lp) {
			d.Conn.ShareLogin(ctx, t, lu, lp)
		}
	case su != "" && d.Sun.LoginOK(ctx, ip, su, sp):
		// Another device's, which works: this one takes it.
		s.LoginOK = true
		_ = d.Store.Set(name, "sunshine_user", su, "sunshine_pass", sp)
	}
	if d.Moonlight {
		mctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		out, _ := d.Runner.Run(mctx, local.Cmd{Name: "moonlight", Args: []string{"list", ip}})
		cancel()
		s.Paired = len(strings.TrimSpace(string(out))) > 0
	}
	return s
}

// Status is `cg host status <name> [--json]`.
func (d Deps) Status(ctx context.Context, args []string, jsonOut bool, out *output.Out) int {
	var name string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			name = a
			break
		}
	}
	if name == "" {
		out.Die("usage: cg host status <name>")
		return 1
	}
	if d.Store.Get(name).Field("ssh") == "" {
		out.Die(fmt.Sprintf("no machine called '%s'", name))
		return 1
	}
	s := d.Read(ctx, name)
	if jsonOut {
		b, _ := json.MarshalIndent(s, "", "  ")
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	mark := func(b bool) string {
		if b {
			return "✓"
		}
		return "✗"
	}
	osName := ""
	if s.OS != nil {
		osName = *s.OS
	}
	at := ""
	if s.TailnetIP != nil {
		at = " at " + *s.TailnetIP
	}
	fmt.Fprintf(out.Stdout, "  %s %s (%s)\n", s.Name, s.SSH, osName)
	fmt.Fprintf(out.Stdout, "  %s ssh\n  %s on the tailnet%s\n  %s Sunshine\n  %s Sunshine login\n  %s paired with Moonlight\n",
		mark(s.Reachable), mark(s.Online), at, mark(s.Sunshine), mark(s.LoginOK), mark(s.Paired))
	if s.Reachable && s.Desktop == nil {
		fmt.Fprintln(out.Stdout, "  ! no desktop signed in - Sunshine streams a signed-in desktop")
	}
	return 0
}
