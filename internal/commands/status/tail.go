package status

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/ec2"
)

// Tail is what `cg status` appends after the report, and only for the
// plain view: the disks of the box in .env, the game library as the box sees
// it, and this boot's traffic. All of it is asked of the box over the tailnet,
// which is free, and any of it can be missing - a stopped box answers nothing,
// and that is said, never guessed.
func (g *Gatherer) Tail(ctx context.Context, instanceID string, egressCache string) string {
	var b strings.Builder
	if instanceID != "" {
		fmt.Fprintf(&b, "instance: %s\n", g.instanceState(ctx, instanceID))
		b.WriteString("disk:\n")
		b.WriteString(g.disks(ctx))
	}
	ip := g.nodeIP(ctx)
	if ip != "" {
		out, err := g.ssh(ctx, ip, 10, "/usr/local/bin/cg-library status")
		b.WriteString("\ngame library\n")
		if err == nil && strings.TrimSpace(string(out)) != "" {
			b.WriteString(strings.TrimRight(string(out), "\n") + "\n")
		} else {
			b.WriteString("  box not reachable - the archive is listed by: cg library list\n")
		}
		b.WriteString(g.traffic(ctx, ip, egressCache))
	}
	return b.String()
}

// nodeIP is the node's tailnet address, or "" when it is on no tailnet.
// `tailscale ip` succeeds for a node that is registered but OFFLINE, so it does
// not mean the box answers.
func (g *Gatherer) nodeIP(ctx context.Context) string {
	if !g.Runner.Has("tailscale") {
		return ""
	}
	out, err := g.Runner.Output(ctx, "tailscale", "ip", "-4", g.Node)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0])
}

func (g *Gatherer) ssh(ctx context.Context, ip string, timeout int, command string) ([]byte, error) {
	return g.Runner.Output(ctx, "ssh", "-i", filepath.Join(g.Home, ".ssh", g.Host+".pem"),
		"-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout="+strconv.Itoa(timeout),
		"-o", "BatchMode=yes", "ubuntu@"+ip, command)
}

func (g *Gatherer) instanceState(ctx context.Context, id string) string {
	r, err := g.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{InstanceIds: []string{id}})
	if err != nil || len(r.Reservations) == 0 || len(r.Reservations[0].Instances) == 0 {
		return ""
	}
	if st := r.Reservations[0].Instances[0].State; st != nil {
		return string(st.Name)
	}
	return ""
}

// disks: root cannot be shrunk once grown, so its usage is the number worth
// watching; /scratch is local NVMe and holds the games, and is wiped on every
// stop - the S3 mirror is what makes that survivable.
func (g *Gatherer) disks(ctx context.Context) string {
	ip := g.nodeIP(ctx)
	if ip != "" {
		if out, err := g.ssh(ctx, ip, 10, `df -h --output=target,used,size,pcent / /scratch 2>/dev/null | sed "s/^/  /"`); err == nil {
			return strings.TrimRight(string(out), "\n") + "\n"
		}
	}
	return "  (host unreachable - box stopped?)\n"
}

func (g *Gatherer) traffic(ctx context.Context, ip, egressCache string) string {
	out, err := g.ssh(ctx, ip, 8, `
    ts=$(cat /sys/class/net/tailscale0/statistics/tx_bytes 2>/dev/null || echo 0)
    nic=$(ip route show default 2>/dev/null | awk "{print \$5; exit}")
    wan=$(cat "/sys/class/net/$nic/statistics/tx_bytes" 2>/dev/null || echo 0)
    win=$(cat "/sys/class/net/$nic/statistics/rx_bytes" 2>/dev/null || echo 0)
    up=$(cut -d. -f1 /proc/uptime)
    printf "%s %s %s %s\n" "$ts" "$wan" "$win" "$up"`)
	f := strings.Fields(string(out))
	if err != nil || len(f) < 4 {
		return ""
	}
	n := make([]float64, 4)
	for i := range n {
		n[i], _ = strconv.ParseFloat(f[i], 64)
	}
	ts, wan, win, up := n[0], n[1], n[2], n[3]
	const gb = 1073741824
	var b strings.Builder
	b.WriteString("\nTRAFFIC (this boot only - see cg cost for the billed month)\n")
	fmt.Fprintf(&b, "  stream out      %.2f GB", ts/gb)
	if up > 0 {
		fmt.Fprintf(&b, "   avg %.1f Mbps over %.1f h", ts*8/up/1000000, up/3600)
	}
	b.WriteString("\n")
	fmt.Fprintf(&b, "  total out       %.2f GB   <- what AWS bills (adds wireguard overhead, ssh, apt)\n", wan/gb)
	fmt.Fprintf(&b, "  total in        %.2f GB   (free - game downloads land here)\n", win/gb)
	// NOT a monthly figure: these are NIC counters since THIS box booted, and
	// every session is a new box. The month lives in cg cost, from Cost Explorer.
	b.WriteString("  (above is this boot only)\n")
	b.WriteString(EgressMonth(egressCache, g.Now()))
	return b.String()
}

// EgressMonth is what `cg cost` last paid Cost Explorer for, shown free and
// stamped with its age so it is never mistaken for live.
func EgressMonth(path string, now time.Time) string {
	body, err := os.ReadFile(path)
	if err != nil {
		return "  monthly egress  unknown - run: cg cost\n"
	}
	f := strings.Fields(string(body))
	if len(f) == 0 {
		return ""
	}
	ts, err := strconv.ParseInt(f[0], 10, 64)
	if err != nil {
		return ""
	}
	used, free := 0.0, 100.0
	if len(f) > 1 {
		used, _ = strconv.ParseFloat(f[1], 64)
	}
	if len(f) > 2 {
		if v, err := strconv.ParseFloat(f[2], 64); err == nil {
			free = v
		}
	}
	age := (now.Unix() - ts) / 60
	left := free - used
	if left < 0 {
		left = 0
	}
	var when string
	switch {
	case age < 90:
		when = fmt.Sprintf("%d min ago", age)
	case age < 2880:
		when = fmt.Sprintf("%.0f h ago", float64(age)/60.0)
	default:
		when = fmt.Sprintf("%.0f days ago", float64(age)/1440.0)
	}
	s := fmt.Sprintf("  monthly egress  %.1f GB used, ~%.0f GB of %.0f GB free left  (as of %s)\n", used, left, free, when)
	if age > 1440 {
		s += "                  stale - refresh with: cg cost\n"
	}
	return s
}
