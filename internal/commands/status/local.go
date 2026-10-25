package status

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// localFacts reads this computer: Tailscale, Moonlight, the SSH key, and the
// node on the tailnet. Being on no tailnet is a normal state and reports as one.
func (g *Gatherer) localFacts(ctx context.Context, out *Facts) {
	var listing []byte
	if g.Runner.Has("tailscale") {
		b, err := g.Runner.Output(ctx, "tailscale", "status")
		out.Tailscale = err == nil
		listing = b
	}
	out.Moonlight = g.Runner.Has("moonlight")
	out.SSHKey = exists(filepath.Join(g.Home, ".ssh", g.Host+".pem"))
	// Column 1 is the address, column 2 the machine name. The first line that
	// has our node as a whole word wins.
	for _, line := range strings.Split(string(listing), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		for _, w := range fields[1:] {
			if w == g.Node {
				out.Node.Found = true
				out.Node.IP, out.Node.Name = fields[0], fields[1]
				out.Node.Online = !strings.Contains(line, "offline")
				return
			}
		}
	}
}

// ready says whether the machine has finished setting itself up, not just
// whether it runs. "running" is true three minutes into a twenty-minute build.
// The box says it is ready by the marker its last build step leaves. Once seen,
// it is remembered for that instance, so only a build in progress costs an ssh
// - free, over the tailnet. Not on the tailnet yet is not ready; online but not
// answering is unknown, never a guess either way.
//
// The same one ssh also measures the game disk, once per machine type: what
// /scratch holds is what the next build of that type can restore.
func (g *Gatherer) ready(ctx context.Context, b *Box, online bool, ip string) {
	readyMark := filepath.Join(g.CacheDir, "ready-"+b.ID)
	scratchMark := filepath.Join(g.CacheDir, "scratch-"+b.Type)
	r := "no"
	switch {
	case exists(readyMark) && fileSize(scratchMark) > 0:
		r = "yes"
	case online && ip != "" && exists(filepath.Join(g.Home, ".ssh", g.Host+".pem")):
		out, err := g.Runner.Output(ctx, "ssh", "-i", filepath.Join(g.Home, ".ssh", g.Host+".pem"),
			"-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
			"ubuntu@"+ip,
			`r=no; test -f /var/lib/cloud-gaming-ready && r=yes
echo "$r $(mountpoint -q /scratch && df -B1 --output=used,avail /scratch | tail -1 | awk "{print \$1+\$2}")"`)
		if err != nil {
			r = ""
		} else {
			f := strings.Fields(string(out))
			if len(f) > 0 {
				r = f[0]
			}
			if r == "yes" {
				writeMark(readyMark, "")
			}
			if len(f) > 1 && b.Type != "" {
				if sz, err := strconv.ParseInt(f[1], 10, 64); err == nil && sz > 0 {
					writeMark(scratchMark, strconv.FormatInt(sz/1073741824, 10))
				}
			}
		}
	}
	// Ready once seen stays ready, answering or not; never seen, the answer
	// stands - and an ssh that did not answer is unknown (empty), not "no".
	if exists(readyMark) {
		r = "yes"
	}
	switch r {
	case "yes":
		b.Ready = ok(true)
	case "no":
		b.Ready = ok(false)
	}
}

func fileSize(p string) int64 {
	st, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return st.Size()
}

func writeMark(p, body string) {
	if os.MkdirAll(filepath.Dir(p), 0o755) != nil {
		return
	}
	_ = os.WriteFile(p, []byte(body), 0o644)
}
