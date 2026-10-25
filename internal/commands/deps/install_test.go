package deps

import (
	"context"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

func installer(l laptop.Laptop, _ any) *laptop.Installer {
	return &laptop.Installer{L: l, Say: func(string, string) {},
		Fetch: func(context.Context, string) ([]byte, error) { return []byte("echo hi"), nil }}
}

func TestInstallRefreshesOnceAndInstallsWhatIsMissing(t *testing.T) {
	l, r := lap(true, "ssh", "scp", "pacman", "sh")
	l.LookPath = func(n string) (string, error) { return "/usr/bin/" + n, nil }
	out, _, e := outs()
	out.Stdout = e // Log goes to the same place the assertions read
	if rc := Install(context.Background(), l, installer(l, out), nil, out); rc != 0 {
		t.Fatalf("rc %d: %s", rc, e)
	}
	ran := strings.Join(r.Ran, "\n")
	if strings.Count(ran, "pacman -Sy --noconfirm") != 1 {
		t.Errorf("refresh once:\n%s", ran)
	}
	if !strings.Contains(ran, "/usr/bin/sudo /usr/bin/pacman -S --needed --noconfirm moonlight-qt") {
		t.Errorf("moonlight not installed:\n%s", ran)
	}
	// Tailscale comes from its own script, not a package, on pacman it IS a package.
	if !strings.Contains(ran, "--noconfirm tailscale") {
		t.Errorf("tailscale:\n%s", ran)
	}
}

func TestInstallOnlyWhatWasNamedAndTellsWhatIsHere(t *testing.T) {
	l, r := lap(true, "ssh", "scp", "pacman", "sh")
	out, o, _ := outs()
	if Install(context.Background(), l, installer(l, out), []string{"ssh", "moonlight"}, out) != 0 {
		t.Fatal(o)
	}
	if !strings.Contains(o.String(), "OpenSSH (ssh, scp) is already here") || strings.Contains(strings.Join(r.Ran, "\n"), "tailscale") && strings.Contains(strings.Join(r.Ran, "\n"), "-S --needed --noconfirm tailscale") {
		t.Errorf("%s\n%v", o, r.Ran)
	}
}

func TestInstallByHandWithoutAPackageManager(t *testing.T) {
	l, _ := lap(true, "ssh", "scp")
	out, o, _ := outs()
	if Install(context.Background(), l, installer(l, out), nil, out) != 1 || !strings.Contains(o.String(), "no supported package manager") ||
		!strings.Contains(o.String(), "https://tailscale.com/download") {
		t.Errorf("%s", o)
	}
}

func TestInstallFailureSaysHowToDoItByHand(t *testing.T) {
	l, r := lap(true, "ssh", "scp", "tailscale", "pacman", "sh")
	r.Failing["sh"] = true
	out, o, _ := outs()
	if Install(context.Background(), l, installer(l, out), nil, out) != 1 {
		t.Fatal("should fail")
	}
	for _, want := range []string{"could not install Moonlight", "sudo pacman -Syu", "by hand: https://github.com/moonlight-stream"} {
		if !strings.Contains(o.String(), want) {
			t.Errorf("lacks %q:\n%s", want, o)
		}
	}
}

func TestNothingToInstallSignsInWhenSignedOut(t *testing.T) {
	l, _ := lap(false, "ssh", "scp", "tailscale", "moonlight")
	l.Runner.(*fx.Runner).Failing["tailscale status"] = true
	out, o, _ := outs()
	if Install(context.Background(), l, installer(l, out), nil, out) != 1 || !strings.Contains(o.String(), "signing in needs a terminal:  sudo tailscale up") {
		t.Errorf("%s", o)
	}
}
