package laptop

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const tailscaleScript = "https://tailscale.com/install.sh"

// Installer installs what is missing. It remembers that the package database was
// refreshed, so installing three tools refreshes it once.
type Installer struct {
	L     Laptop
	Say   Say
	Fetch func(ctx context.Context, url string) ([]byte, error) // nil downloads
	fresh bool
}

func fetch(ctx context.Context, url string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, &httpError{resp.StatusCode}
	}
	return io.ReadAll(io.LimitReader(resp.Body, 4<<20))
}

type httpError struct{ code int }

func (e *httpError) Error() string { return "HTTP " + http.StatusText(e.code) }

// Install installs one tool. It reports false when it could not, having said why.
func (i *Installer) Install(ctx context.Context, pm, tool string) bool {
	if pkg := Package(pm, tool); pkg != "" {
		return i.pkg(ctx, pm, pkg)
	}
	if tool == "tailscale" {
		return i.tailscaleScript(ctx)
	}
	return false
}

func (i *Installer) pkg(ctx context.Context, pm, pkg string) bool {
	as, why := i.L.Root()
	if as == "" {
		i.Say("log", "cannot install from here: "+why)
		i.Say("log", "  in a terminal:  cg deps install")
		return false
	}
	run := func(args ...string) bool {
		return i.L.RootRun(ctx, as, i.Say, pm, args...) == nil
	}
	switch pm {
	case "pacman":
		// -Sy first, once, for the same reason apt-get gets an update: a machine
		// that has never synced has no database to look in, and pacman's answer
		// to that is "target not found: <package>" - which reads as "there is no
		// such package" rather than "I have not looked". A fresh Omarchy VM is
		// exactly that machine.
		if !i.fresh {
			i.Say("log", "refreshing the package database")
			if !run("-Sy", "--noconfirm") {
				return false
			}
			i.fresh = true
		}
		return run("-S", "--needed", "--noconfirm", pkg)
	case "apt-get":
		if !i.fresh {
			if !run("update", "-qq") {
				return false
			}
			i.fresh = true
		}
		return run("install", "-y", pkg)
	case "dnf":
		return run("install", "-y", pkg)
	case "zypper":
		return run("--non-interactive", "install", pkg)
	}
	return false
}

// tailscaleScript runs Tailscale's own installer, which asks for sudo itself.
// It is downloaded to a file first rather than piped into a shell, so a dropped
// connection cannot leave a half-read script running.
func (i *Installer) tailscaleScript(ctx context.Context) bool {
	get := i.Fetch
	if get == nil {
		get = fetch
	}
	b, err := get(ctx, tailscaleScript)
	if err != nil {
		i.Say("fail", "could not download "+tailscaleScript+": "+err.Error())
		return false
	}
	dir, err := os.MkdirTemp("", "cg-ts-")
	if err != nil {
		return false
	}
	defer os.RemoveAll(dir)
	f := filepath.Join(dir, "install.sh")
	if os.WriteFile(f, b, 0o600) != nil {
		return false
	}
	w := &lineWriter{say: i.Say}
	err = i.L.Runner.Stream(ctx, w, "sh", "-c", `exec "$@" 2>&1`, "sh", "sh", f)
	w.flush()
	return err == nil
}
