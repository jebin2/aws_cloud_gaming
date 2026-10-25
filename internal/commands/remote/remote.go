// Package remote is the commands that talk to the box over the tailnet and
// change nothing: cg ping, cg log and cg ssh.
package remote

import (
	"context"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Box is the machine and how to reach it.
type Box struct {
	Runner local.Runner
	Host   string // names the key: ~/.ssh/<host>.pem
	Node   string // its name on the tailnet
	Home   string
}

// IP is the node's tailnet address. It fails the way the Bash did: a node that
// is on no tailnet is not a box that answers.
func (b Box) IP(ctx context.Context) (string, error) {
	if b.Runner.Has("tailscale") {
		if out, err := b.Runner.Output(ctx, "tailscale", "ip", "-4", b.Node); err == nil {
			if ip := strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0]); ip != "" {
				return ip, nil
			}
		}
	}
	return "", fmt.Errorf("'%s' is not on the tailnet. Is the box running? Try: cg status", b.Node)
}

// sshArgs is ssh to the box: no prompt, a ten second connect timeout.
// SSHArgs is ssh to the box with a command.
func (b Box) SSHArgs(ip string, command ...string) []string { return b.sshArgs(ip, command...) }

func (b Box) sshArgs(ip string, command ...string) []string {
	a := []string{"-i", b.Home + "/.ssh/" + b.Host + ".pem", "-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "ubuntu@" + ip}
	return append(a, command...)
}

// Log is `cg log [what] [--watch]`: the build, Steam's prewarm, the watchdog,
// the disk monitor or Sunshine, on the box.
func (b Box) Log(ctx context.Context, what string, watch bool, w io.Writer, out *output.Out) int {
	cmds := map[string][2]string{ // what -> {once, follow}
		"build":    {"sudo tail -n 200 /var/log/cloud-gaming-bootstrap.log", "sudo tail -f /var/log/cloud-gaming-bootstrap.log"},
		"steam":    {"tail -n 200 ~/steam-prewarm.log", "tail -f ~/steam-prewarm.log"},
		"watchdog": {"journalctl -t idle-watchdog -n 50 --no-pager", "journalctl -t idle-watchdog -f"},
		"disk":     {"journalctl -t disk-monitor -n 50 --no-pager", "journalctl -t disk-monitor -f"},
		"sunshine": {"journalctl --user -u app-dev.lizardbyte.app.Sunshine -n 80 --no-pager", "journalctl --user -u app-dev.lizardbyte.app.Sunshine -f"},
	}
	c, ok := cmds[what]
	if !ok {
		out.Die("usage: cg log [build|steam|watchdog|disk|sunshine] [--watch]")
		return 1
	}
	command := c[0]
	if watch {
		command = c[1]
	}
	ip, err := b.IP(ctx)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	if err := b.Runner.Stream(ctx, w, "ssh", b.sshArgs(ip, command)...); err != nil && ctx.Err() == nil {
		return 1
	}
	return 0
}

// SSH is `cg ssh [command...]`: a shell on the box, or one command, with the
// remote's exit status. OpenSSH joins the arguments with spaces, as before.
func (b Box) SSH(ctx context.Context, args []string, out *output.Out) int {
	ip, err := b.IP(ctx)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	if len(args) > 0 {
		return b.Runner.Passthrough(ctx, "ssh", b.sshArgs(ip, args...)...)
	}
	return b.Runner.Passthrough(ctx, "ssh", "-i", b.Home+"/.ssh/"+b.Host+".pem", "-o", "StrictHostKeyChecking=accept-new", "ubuntu@"+ip)
}

var (
	reDERP   = regexp.MustCompile(`via DERP`)
	reDirect = regexp.MustCompile(`via [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+`)
	reMS     = regexp.MustCompile(`in ([0-9]+)ms`)
)

// Path is what the replies say about the route. Latency alone does not explain
// a bad session; whether the path is direct or relayed through DERP usually
// does, and nothing else surfaces it. Direct wins if both are seen.
func Path(output string) string {
	path := "unknown"
	if reDERP.MatchString(output) {
		path = "DERP relay (slower - UDP 41641 may be blocked)"
	}
	if reDirect.MatchString(output) {
		path = "direct"
	}
	return path
}

// MedianMS is the lower median of the replies' times, or -1 with none.
func MedianMS(output string) int {
	var ms []int
	for _, m := range reMS.FindAllStringSubmatch(output, -1) {
		n, _ := strconv.Atoi(m[1])
		ms = append(ms, n)
	}
	if len(ms) == 0 {
		return -1
	}
	sort.Ints(ms)
	return ms[(len(ms)+1)/2-1]
}

// Ping is `cg ping [--json] [--watch]`.
func (b Box) Ping(ctx context.Context, jsonOut, watch bool, w io.Writer, out *output.Out) int {
	ip, err := b.IP(ctx)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	if watch {
		if err := b.Runner.Stream(ctx, w, "tailscale", "ping", "--until-direct=false", b.Node); err != nil && ctx.Err() == nil {
			return 1
		}
		return 0
	}
	// The exit status is not the answer: a node that does not reply makes
	// tailscale fail, and "no reply" is a result to report.
	raw, _ := b.Runner.Output(ctx, "tailscale", "ping", "-c", "5", "--timeout", "3s", b.Node)
	path, ms := Path(string(raw)), MedianMS(string(raw))
	if jsonOut {
		median := "null"
		if ms >= 0 {
			median = strconv.Itoa(ms)
		}
		fmt.Fprintf(w, `{"node":"%s","path":"%s","median_ms":%s}`+"\n", b.Node, strings.SplitN(path, " ", 2)[0], median)
		return 0
	}
	var t strings.Builder
	fmt.Fprintf(&t, "\n  node    %s (%s)\n", b.Node, ip)
	fmt.Fprintf(&t, "  path    %s\n", path)
	if ms >= 0 {
		fmt.Fprintf(&t, "  latency %dms median\n\n", ms)
	} else {
		t.WriteString("  latency no reply\n\n")
	}
	if strings.HasPrefix(path, "DERP") {
		t.WriteString("  A relayed path adds latency and costs bandwidth both ways.\n  Check the security group still allows inbound UDP 41641.\n\n")
	}
	out.Report("connection to "+b.Node, t.String())
	return 0
}
