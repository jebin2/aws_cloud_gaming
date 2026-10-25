package deps

import (
	"context"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Fix is what `cg check --fix` does about the laptop: install what is missing
// and sign Tailscale in, after asking. It reports true when nothing is left.
func Fix(ctx context.Context, l laptop.Laptop, in *laptop.Installer, a *ask.Asker, out *output.Out) bool {
	missing := l.Missing()
	if len(missing) == 0 && !l.TailscaleDown(ctx) {
		out.Log("laptop: everything is installed")
		return true
	}
	pm := ""
	if len(missing) > 0 {
		if pm = l.PackageManager(); pm == "" {
			out.Log("no supported package manager (pacman, apt, dnf, zypper) - install these by hand:")
			for _, t := range missing {
				out.Log("  " + laptop.Label(t) + ": " + laptop.Manual(t))
			}
			return false
		}
	}
	if !l.TTY() {
		out.Log("--fix installs with sudo, which needs a terminal to ask for your password")
		out.Log("  run this in a terminal:  cg check --fix")
		out.Log("  the access key does not need sudo: cg creds set, or Settings > AWS credentials")
		return false
	}
	out.Log("--fix will:")
	for _, t := range missing {
		out.Log("  install " + laptop.Label(t) + " - " + laptop.Plan(pm, t))
	}
	out.Log("  sign this laptop in to Tailscale if it is not, with sudo tailscale up (prints a login link)")
	if !a.Confirm("fix-go-ahead", "    go ahead? [Y/n] ", "Y") {
		out.Log("nothing changed")
		return false
	}
	for _, t := range missing {
		out.Log("installing " + laptop.Label(t))
		if !in.Install(ctx, pm, t) {
			out.Log("could not install " + laptop.Label(t))
		}
	}
	if l.TailscaleDown(ctx) {
		out.Log("signing in to Tailscale")
		if !l.TailscaleUp(ctx, sayTo(out)) {
			out.Log("the Tailscale sign-in did not finish")
		}
	}
	return len(l.Missing()) == 0 && !l.TailscaleDown(ctx)
}
