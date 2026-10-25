package hostcmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	cg "github.com/jebin2/aws_cloud_gaming"
	"github.com/jebin2/aws_cloud_gaming/internal/build"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/check"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/ownhost"
	"github.com/jebin2/aws_cloud_gaming/internal/render"
	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
)

// remote reaches the machine as cg does: under sh, with cg's key.
type remote struct {
	c ownhost.Conn
	t string
}

func (r remote) SSH(ctx context.Context, cmd string) ([]byte, error) {
	return r.c.SSH(ctx, r.t, cmd, nil)
}

// died is an error the command stops on, with what to say.
type died string

func (d died) Error() string { return string(d) }

const startBuild = `rm -f /var/lib/cloud-gaming-ready /var/lib/cloud-gaming-bootstrap.rc /var/log/cloud-gaming-bootstrap.log; setsid nohup bash "$1" >/dev/null 2>&1 </dev/null &`

// tailnetName is the name this laptop's tailscale gives the node at an address.
func (d Deps) tailnetNode(ctx context.Context, ip string) (name string, ok bool) {
	if ip == "" {
		return "", false
	}
	out, err := d.Runner.Run(ctx, local.Cmd{Name: "tailscale", Args: []string{"status"}})
	if err != nil && len(out) == 0 {
		return "", false
	}
	for _, l := range strings.Split(string(out), "\n") {
		if f := strings.Fields(l); len(f) >= 2 && f[0] == ip {
			return f[1], true
		}
	}
	return "", false
}

func (d Deps) takes() string {
	if b, err := os.ReadFile(d.CacheDir + "/last-build-min"); err == nil {
		if m := strings.TrimSpace(string(b)); m != "" {
			return "the last one took " + m + " min"
		}
	}
	return "it takes a while"
}

// Setup is `cg host setup <name>`: the build every machine gets, run on yours.
// The same modules the AWS box boots with, here as a machine of yours: each step
// adds only what is missing, and the AWS box's own are left out. Then the same
// second half as the AWS box: its log followed, the Sunshine login, Moonlight
// paired, Steam. Safe to run again.
func (d Deps) Setup(ctx context.Context, args []string, out *output.Out) int {
	err := d.setup(ctx, args, out)
	var dd died
	switch {
	case err == nil:
		return 0
	case errors.As(err, &dd):
		out.Die(string(dd))
	default:
		out.Die(err.Error())
	}
	return 1
}

func (d Deps) setup(ctx context.Context, args []string, out *output.Out) error {
	var name string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			name = a
			break
		}
	}
	if name == "" {
		return died("usage: cg host setup <name>")
	}
	t := d.Store.Get(name).Field("ssh")
	if t == "" {
		return died(fmt.Sprintf("no machine called '%s' - add it: cg host add %s --ssh <user@address>", name, name))
	}
	// In, before anything: a machine whose key was taken off asks once for its
	// password here, rather than failing every step after.
	if !d.LetIn(ctx, t, out) {
		return died("") // LetIn has said why
	}
	out.Say("asking " + name + " what it is")
	facts := d.Conn.ReadFacts(ctx, t)
	if facts == nil {
		return died(t + " did not answer over ssh")
	}
	// A machine added before cg knew who machines are: learned now, so adding it
	// again by another address is caught.
	if mk := ownhost.MachineKey(facts); mk != "" && d.Store.Get(name).Field("machine") == "" {
		_ = d.Store.Set(name, "machine", mk)
	}
	if facts.Get("os") == "Windows" {
		return died("setting a Windows machine up is not built yet - see docs/own-machine-plan.md")
	}
	fam := ownhost.Family(facts)
	if fam == "unsupported" {
		return died(fmt.Sprintf("cg sets up Ubuntu, Debian, Arch and Fedora; %s is not one.", facts.Get("pretty")))
	}
	if facts.Get("arch") != "x86_64" {
		return died(fmt.Sprintf("x86_64 only - Steam and Proton need it (%s here)", facts.Get("arch")))
	}
	if fam == "ubuntu" && facts.Get("ubuntu_version") == "" {
		return died(fmt.Sprintf("%s is Ubuntu-based, but which Ubuntu release it is could not be read", facts.Get("pretty")))
	}
	out.Log(fmt.Sprintf("%s, signed in as %s", facts.Get("pretty"), facts.Get("user")))

	// The build runs as root: the sudo password, once, and checked before
	// anything runs, so a typo is said here and not halfway through.
	pw := ""
	if facts.Get("sudo") != "nopass" {
		out.Say("root on " + name + " - asked once, never saved")
		if !d.Ask.CanAsk() {
			return died("the machine wants a sudo password, and there is no one to ask - run this in a terminal")
		}
		pw = d.Ask.Secret("host-sudo", "  sudo password for "+t+": ")
		if pw == "" {
			return died("no sudo password given - nothing was changed on " + name)
		}
		if _, err := d.Conn.SSH(ctx, t, "sudo -S -p '' -v", strings.NewReader(pw+"\n")); err != nil {
			return died("sudo did not accept that password on " + name + " - nothing was changed")
		}
	}

	// The auth key only when it has to join; already on the tailnet, it stays as
	// it is. It is the AWS boxes' reusable, non-ephemeral key: an ephemeral one
	// would drop this machine whenever it slept. The stored one, one minted from
	// the API token, or - with neither - one asked for now, and saved.
	key := ""
	if facts.Get("ts_ip") == "" {
		stored := d.Env.Get("GAME_TS_AUTHKEY")
		if stored == "" {
			stored = d.Env.Get("TAILSCALE_AUTH_KEY")
		}
		key, _ = check.EnsureAuthKey(ctx, d.Env, out, d.TS, stored, name)
		if key == "" {
			if !d.Ask.CanAsk() {
				return died(name + " is not on your tailnet, and there is no Tailscale auth key to join it with - cg creds tailscale authkey saves one")
			}
			out.Log(name + " is not on your tailnet yet: it joins with a Tailscale auth key")
			if d.Creds.SetAuthKey(ctx) != 0 {
				return died("no usable auth key - nothing was changed on " + name)
			}
			key = d.Env.Get("TAILSCALE_AUTH_KEY")
		}
	}

	out.Say("starting the build on " + name)
	// Copied as a file readable by root alone - it may carry the auth key - and
	// deleted by the build as it starts.
	script, err := render.Bootstrap(cg.Files, map[string]string{"TS_AUTHKEY": key, "TS_HOST": name, "HOST_TGZ_URL": "", "S3_BUCKET": "", "CG_APPS": "",
		"CG_LOGIN": "", "CG_RESERVE_GB": "", "CG_TARGET": "host", "CG_USER": facts.Get("user"), "CG_FAMILY": fam})
	if err != nil {
		return died("could not assemble the build: " + err.Error())
	}
	path, err := d.Conn.SSH(ctx, t, `f=$(mktemp); cat > "$f"; chmod 600 "$f"; echo "$f"`, strings.NewReader(script))
	f := strings.TrimSpace(string(path))
	if err != nil || f == "" {
		return died("could not copy the build to " + name)
	}
	// Detached, so it outlives this ssh as user-data outlives nobody watching. The
	// last run's marker, result and log go first, so the laptop never follows - or
	// calls stopped - an old one.
	if pw != "" {
		_, err = d.Conn.SSH(ctx, t, fmt.Sprintf("sudo -S -p '' sh -c '%s' _ '%s'", startBuild, f), strings.NewReader(pw+"\n"))
	} else {
		_, err = d.Conn.SSH(ctx, t, fmt.Sprintf("sudo -n sh -c '%s' _ '%s'", startBuild, f), nil)
	}
	if err != nil {
		return died("the build could not be started on " + name)
	}

	// The second half, as every build. Reached as host_ssh reaches it - your ssh,
	// with cg's key; its tailnet address is read once it has joined.
	rec := d.Store.Get(name)
	login := &sunshine.Login{User: rec.Field("sunshine_user"), Pass: rec.Field("sunshine_pass")}
	save := func(k, v string) {
		switch k {
		case "SUNSHINE_USER":
			login.User = v
			_ = d.Store.Set(name, "sunshine_user", v)
		case "SUNSHINE_PASS":
			login.Pass = v
			_ = d.Store.Set(name, "sunshine_pass", v)
		}
	}
	keyFile := ""
	if _, err := os.Stat(d.Conn.Key); err == nil {
		keyFile = d.Conn.Key
	}
	var after error
	fin := &build.Finisher{
		Follow: build.Follower{R: remote{d.Conn, t}, Log: out.Log, Sleep: d.Sleep, Target: t, Key: keyFile},
		Sun:    d.Sun, Pair: d.Pair, Run: d.Runner, Login: login, Save: save, Name: name, Takes: d.takes(),
		Say: out.Say, Log: out.Log, Sleep: d.Sleep, HasMoonlight: d.Moonlight,
	}
	fin.AfterStream = func(ctx context.Context) (string, error) {
		facts = d.Conn.ReadFacts(ctx, t)
		// The machine's login, when another device has put one there: the one to
		// check first - a setup from here resets it only when that fails too.
		if u, p := ownhost.Login(facts); u != "" {
			save("SUNSHINE_USER", u)
			save("SUNSHINE_PASS", p)
		}
		ip, ok := d.tailnetNode(ctx, facts.Get("ts_ip"))
		_ = ip
		if !ok {
			after = died(name + " is on Tailscale, but not on the tailnet this laptop is on - sign it in to the same one")
			return "", after
		}
		addr := facts.Get("ts_ip")
		out.Log("on the tailnet at " + addr)
		_ = d.Store.Set(name, "ts_ip", addr)
		// Key expiry off, as for the AWS boxes - a home machine must not drop out
		// after 180 days. Needs the API token; without it, it is said, not skipped.
		node, _ := d.tailnetNode(ctx, addr)
		for _, l := range d.TS(d.Env.Get("TAILSCALE_API_KEY")).DisableExpiry(ctx, node).Lines {
			out.Log("    " + l)
		}
		return addr, nil
	}
	if err := fin.Finish(ctx); err != nil {
		if after != nil {
			return after
		}
		return died(fmt.Sprintf("the build on %s did not finish - its log is /var/log/cloud-gaming-bootstrap.log there", name))
	}
	// The login it ended with, kept on the machine for every other device.
	rec = d.Store.Get(name)
	if !d.Conn.ShareLogin(ctx, t, rec.Field("sunshine_user"), rec.Field("sunshine_pass")) {
		out.Log("note: could not keep the Sunshine login on " + name + " - other devices may need to run setup")
	}

	// What cg does not change, said rather than fixed.
	if facts.Get("session") == "" {
		out.Log("note: no desktop is signed in on " + name + " right now - Sunshine streams a signed-in desktop")
	}
	if facts.Get("nvidia") == "" && facts.Get("render") == "" {
		out.Log("note: no GPU video encoder found on " + name + " - the stream would fall back to the CPU")
	}
	_ = d.Store.Set(name, "ready", "yes")
	out.Log("ready: cg host open " + name)
	return nil
}
