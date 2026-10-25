package sunshine

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// Pairing is Moonlight <-> Sunshine, on its own so it can be re-run.
//
// Success is a NEW CLIENT IN SUNSHINE'S LIST, nothing less. On 2026-09-14 this
// returned success because Sunshine accepted the PIN - `cg init` printed
// "paired" - while Sunshine had saved no client at all, and Moonlight then
// refused to stream. Accepting the PIN is the request; a saved client is the
// result.
type Pairer struct {
	C        Client
	R        local.Runner
	Sleep    func(time.Duration)
	Log      func(string)
	Tries    int // waits for Moonlight's request to appear; 20 by default
	Verify   int // waits for the client to be saved; 10 by default
	PIN      func() string
	Hostname func() string
	// Stale kills an abandoned pairing process; nil uses the real one.
	Stale func()
	// Close is how long Moonlight gets to close its own window; 15s by default.
	Close time.Duration
}

// pending is the id of the pairing request Moonlight has open, or "". Live shape
// (Sunshine, 2026-09-14): {"pairings":[{"id":...}]}.
func (p Pairer) pending(ctx context.Context, ip, user, pass string) string {
	_, b := p.C.do(ctx, http.MethodGet, ip, "/api/pin", 10*time.Second, user, pass, "")
	var d struct{ Pairings []struct{ ID any } }
	if json.Unmarshal(b, &d) != nil || len(d.Pairings) == 0 {
		return ""
	}
	switch v := d.Pairings[0].ID.(type) {
	case string:
		return v
	case float64:
		return fmt.Sprint(int64(v))
	}
	return ""
}

// clients are the uuids Sunshine has saved. Live shape:
// {"named_certs":[{"name","uuid","enabled"}],"status":true}.
func (p Pairer) clients(ctx context.Context, ip, user, pass string) []string {
	_, b := p.C.do(ctx, http.MethodGet, ip, "/api/clients/list", 10*time.Second, user, pass, "")
	var d struct {
		NamedCerts []struct{ UUID string } `json:"named_certs"`
	}
	_ = json.Unmarshal(b, &d)
	var out []string
	for _, c := range d.NamedCerts {
		out = append(out, c.UUID)
	}
	sort.Strings(out)
	return out
}

func (p Pairer) wait(ctx context.Context, ip, user, pass string, max int) string {
	for i := 0; i < max; i++ {
		if id := p.pending(ctx, ip, user, pass); id != "" {
			return id
		}
		p.Sleep(2 * time.Second)
	}
	return ""
}

// killStale: an abandoned pairing process makes Sunshine reject the next attempt
// with 409 "a pairing session with this uniqueid already exists". It matches on
// the actual moonlight binary and inspects its argv - matching the command line
// text also hits any shell whose command line merely contains it.
func killStale(ctx context.Context, r local.Runner) {
	out, err := r.Run(ctx, local.Cmd{Name: "pgrep", Args: []string{"-x", "moonlight"}})
	if err != nil {
		return
	}
	for _, pid := range strings.Fields(string(out)) {
		b, err := os.ReadFile("/proc/" + pid + "/cmdline")
		if err != nil || !strings.Contains(strings.ReplaceAll(string(b), "\x00", " "), " pair ") {
			continue
		}
		if n, err := strconv.Atoi(pid); err == nil {
			if proc, err := os.FindProcess(n); err == nil {
				_ = proc.Signal(syscall.SIGTERM)
			}
		}
	}
}

// Pair pairs, and says why when it could not.
func (p Pairer) Pair(ctx context.Context, ip, user, pass string) bool {
	tries, verify := p.Tries, p.Verify
	if tries == 0 {
		tries = 20
	}
	if verify == 0 {
		verify = 10
	}
	pin := ""
	if p.PIN != nil {
		pin = p.PIN()
	} else {
		var b [2]byte
		f, _ := os.Open("/dev/urandom")
		if f != nil {
			_, _ = f.Read(b[:])
			f.Close()
		}
		pin = fmt.Sprintf("%04d", (int(b[0])<<8|int(b[1]))%10000)
	}
	if p.Stale != nil {
		p.Stale()
	} else {
		killStale(ctx, p.R)
	}
	p.Sleep(2 * time.Second)

	// What is already saved, so "a client appeared" means THIS pairing and not a
	// leftover from an earlier one.
	before := p.clients(ctx, ip, user, pass)

	// Moonlight must be waiting before Sunshine has a request to approve.
	// QT_QPA_PLATFORM=offscreen because `moonlight pair` is the full Qt app and
	// otherwise flashes a window up. If no request reaches Sunshine that way, try
	// again the normal way rather than leaving you to pair by hand over a
	// cosmetic improvement.
	start := func(env ...string) (local.Proc, error) {
		return p.R.Start(ctx, local.Cmd{Name: "moonlight", Args: []string{"pair", "--pin", pin, ip}, Env: env})
	}
	proc, err := start("QT_QPA_PLATFORM=offscreen")
	if err != nil {
		p.Log("moonlight could not be started")
		return false
	}
	id := p.wait(ctx, ip, user, pass, tries)
	if id == "" {
		proc.Kill()
		p.Log("no pairing request seen offscreen - retrying with a window")
		if proc, err = start(); err != nil {
			p.Log("moonlight could not be started")
			return false
		}
		id = p.wait(ctx, ip, user, pass, tries)
	}
	if id == "" {
		proc.Kill()
		p.Log("moonlight never registered a pairing request")
		return false
	}
	host := "laptop"
	if p.Hostname != nil {
		host = p.Hostname()
	} else if h, err := os.Hostname(); err == nil {
		host = h
	}
	body, _ := json.Marshal(map[string]string{"pairing_id": id, "pin": pin, "name": host})
	_, resp := p.C.do(ctx, http.MethodPost, ip, "/api/pin", 20*time.Second, user, pass, string(body))
	if !strings.Contains(string(resp), `"status":true`) {
		proc.Kill()
		p.Log("Sunshine rejected the PIN")
		return false
	}

	// Wait for the client to be SAVED, with Moonlight still running - the
	// handshake finishes on Moonlight's side, so it is not closed until the
	// result is in.
	have := map[string]bool{}
	for _, u := range before {
		have[u] = true
	}
	saved := false
	for i := 0; i < verify && !saved; i++ {
		for _, u := range p.clients(ctx, ip, user, pass) {
			if u != "" && !have[u] {
				saved = true
			}
		}
		if !saved {
			p.Sleep(2 * time.Second)
		}
	}

	// `moonlight pair` runs the full Qt GUI and does not always close itself once
	// the handshake completes, so it sits there looking hung.
	closeAfter := p.Close
	if closeAfter == 0 {
		closeAfter = 15 * time.Second
	}
	select {
	case <-proc.Done():
	case <-time.After(closeAfter):
		proc.Kill()
		p.Log("closed the moonlight pairing window")
	}
	if !saved {
		p.Log("Sunshine accepted the PIN but saved no client - NOT paired")
		return false
	}
	return true
}
