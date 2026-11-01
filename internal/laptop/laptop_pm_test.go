package laptop

import "testing"

func TestMacAndWindowsInstallApplicationsNotPackages(t *testing.T) {
	for _, c := range []struct{ pm, tool, pkg, plan string }{
		{"brew", "tailscale", "tailscale", "brew install --cask tailscale"},
		{"brew", "moonlight", "moonlight", "brew install --cask moonlight"},
		{"winget", "tailscale", "Tailscale.Tailscale", "winget install --id Tailscale.Tailscale -e"},
		{"winget", "moonlight", "MoonlightGameStreamingProject.Moonlight", "winget install --id MoonlightGameStreamingProject.Moonlight -e"},
		// Both ship an OpenSSH client; there is nothing to install, and no script to run.
		{"brew", "ssh", "", ""},
		{"winget", "ssh", "", ""},
	} {
		if got := Package(c.pm, c.tool); got != c.pkg {
			t.Errorf("%s %s: package %q, want %q", c.pm, c.tool, got, c.pkg)
		}
		if got := Plan(c.pm, c.tool); got != c.plan {
			t.Errorf("%s %s: plan %q, want %q", c.pm, c.tool, got, c.plan)
		}
	}
	// Linux is as it was.
	if Package("apt-get", "moonlight") != "moonlight-qt" || Plan("apt-get", "tailscale") == "" {
		t.Error("the Linux plans changed")
	}
}
