package sunshine

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

// server behaves as Sunshine does: /welcome is 200 until an account exists,
// every other call wants that account, and a pairing request exists once
// Moonlight is waiting.
type server struct {
	mu          sync.Mutex
	user, pass  string
	waiting     bool // moonlight is waiting with a request
	pin         string
	clients     []string
	acceptPin   bool // the PIN is accepted but no client is saved when false after
	saveClient  bool
	welcomeCode int // 0: derived from whether an account exists
	hits        []string
}

func (s *server) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.hits = append(s.hits, r.Method+" "+r.URL.Path)
		if r.URL.Path == "/welcome" {
			switch {
			case s.welcomeCode != 0:
				w.WriteHeader(s.welcomeCode)
			case s.user == "":
				w.WriteHeader(200)
			default:
				w.WriteHeader(302)
			}
			return
		}
		if r.URL.Path == "/api/password" {
			var d map[string]string
			b, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(b, &d)
			s.user, s.pass = d["newUsername"], d["newPassword"]
			w.WriteHeader(200)
			return
		}
		u, p, ok := r.BasicAuth()
		if !ok || s.user == "" || u != s.user || p != s.pass {
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/api/clients/list":
			var certs []map[string]any
			for _, c := range s.clients {
				certs = append(certs, map[string]any{"uuid": c})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"named_certs": certs, "status": true})
		case "/api/pin":
			if r.Method == http.MethodGet {
				var ps []map[string]any
				if s.waiting {
					ps = append(ps, map[string]any{"id": "pid-1"})
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"pairings": ps})
				return
			}
			b, _ := io.ReadAll(r.Body)
			var d map[string]string
			_ = json.Unmarshal(b, &d)
			if d["pairing_id"] != "pid-1" || d["pin"] != s.pin {
				_, _ = io.WriteString(w, `{"status":false}`)
				return
			}
			if s.saveClient {
				s.clients = append(s.clients, "uuid-new")
			}
			_, _ = io.WriteString(w, `{"status":true}`)
		default:
			w.WriteHeader(404)
		}
	})
}

func newServer(t *testing.T) (*server, Client) {
	s := &server{saveClient: true}
	ts := httptest.NewTLSServer(s.handler(t))
	t.Cleanup(ts.Close)
	return s, Client{HTTP: ts.Client(), URL: func(ip, path string) string { return ts.URL + path }}
}

var noSleep = func(time.Duration) {}

func TestWaitTellsFirstRunFromConfiguredAndConfirmsBeforeTrusting(t *testing.T) {
	s, c := newServer(t)
	up, first := c.Wait(context.Background(), "ip", 5, noSleep)
	if !up || !first {
		t.Errorf("a fresh Sunshine: %v %v", up, first)
	}
	s.user, s.pass = "admin", "x"
	slept := 0
	up, first = c.Wait(context.Background(), "ip", 40, func(time.Duration) { slept++ })
	if !up || first || slept != 2 {
		t.Errorf("configured is confirmed three times, not run to exhaustion: up=%v first=%v slept=%d", up, first, slept)
	}
	// Nothing listening: waits every try, and is not up.
	c.URL = func(ip, path string) string { return "https://127.0.0.1:1" + path }
	slept = 0
	if up, _ := c.Wait(context.Background(), "ip", 4, func(time.Duration) { slept++ }); up || slept != 4 {
		t.Errorf("up=%v slept=%d", up, slept)
	}
}

func TestAFirstRunMakesAnAccountAndSavesItBeforeTheMachineHasIt(t *testing.T) {
	s, c := newServer(t)
	var saved []string
	l := &Login{}
	var said []string
	e := &Ensure{C: c, IP: "ip", Login: l, Save: func(k, v string) {
		// Saved HERE first: at the moment of saving, the machine has no account yet.
		s.mu.Lock()
		has := s.user != ""
		s.mu.Unlock()
		if has {
			t.Errorf("%s saved after the machine was given it", k)
		}
		saved = append(saved, k)
	}, Say: func(x string) { said = append(said, x) }, Sleep: noSleep}
	if !e.Run(context.Background(), true) {
		t.Fatal(said)
	}
	if l.User != "admin" || len(l.Pass) != 24 || s.user != "admin" || s.pass != l.Pass || strings.Join(saved, ",") != "SUNSHINE_USER,SUNSHINE_PASS" || said[0] != "created; credentials saved" {
		t.Errorf("%+v %v %v", l, saved, said)
	}
}

func TestAStaleLoginIsResetOnTheMachineItself(t *testing.T) {
	s, c := newServer(t)
	s.user, s.pass = "admin", "machines-own"
	l := &Login{User: "admin", Pass: "stale"}
	var said []string
	var ran string
	e := &Ensure{C: c, IP: "ip", Login: l, Save: func(string, string) {}, Say: func(x string) { said = append(said, x) }, Sleep: noSleep,
		OnMachine: func(_ context.Context, cmd string) error {
			ran = cmd
			// `sunshine --creds` on the machine sets the login it is given.
			s.mu.Lock()
			s.pass = l.Pass
			s.mu.Unlock()
			return nil
		}}
	if !e.Run(context.Background(), false) {
		t.Fatal(said)
	}
	if !strings.Contains(ran, "sunshine --creds 'admin' '"+l.Pass+"'") || l.Pass == "stale" || said[0] != "the machine's Sunshine login is not the one saved here - setting it again on the machine" || said[len(said)-1] != "reset; credentials saved" {
		t.Errorf("%q %v", ran, said)
	}
	// A login that already works is left alone.
	s.pass = "fine"
	l = &Login{User: "admin", Pass: "fine"}
	said = nil
	e = &Ensure{C: c, IP: "ip", Login: l, Save: func(string, string) { t.Error("saved a login that worked") }, Say: func(x string) { said = append(said, x) }, Sleep: noSleep}
	if !e.Run(context.Background(), false) || said[0] != "already configured, and the saved login works" {
		t.Errorf("%v", said)
	}
	// A machine that cannot be told: say where to do it by hand.
	s.pass = "other"
	l = &Login{User: "admin", Pass: "x"}
	said = nil
	e = &Ensure{C: c, IP: "1.2.3.4", Login: l, Save: func(string, string) {}, Say: func(x string) { said = append(said, x) }, Sleep: noSleep, Tries: 1}
	if e.Run(context.Background(), false) || !strings.Contains(said[len(said)-1], "do it in the browser at https://1.2.3.4:47990") {
		t.Errorf("%v", said)
	}
}

func pairer(c Client, r *fx.Runner) Pairer {
	return Pairer{C: c, R: r, Sleep: noSleep, Log: func(string) {}, PIN: func() string { return "1234" }, Hostname: func() string { return "laptop" },
		Stale: func() {}, Close: 10 * time.Millisecond, Tries: 3, Verify: 3}
}

func TestPairingSucceedsOnlyWhenAClientIsSaved(t *testing.T) {
	s, c := newServer(t)
	s.user, s.pass, s.pin, s.waiting = "admin", "pw", "1234", true
	r := &fx.Runner{Installed: map[string]bool{"moonlight": true}}
	var logs []string
	p := pairer(c, r)
	p.Log = func(x string) { logs = append(logs, x) }
	if !p.Pair(context.Background(), "ip", "admin", "pw") {
		t.Fatal(logs)
	}
	if !strings.Contains(strings.Join(r.Envs["moonlight pair --pin 1234 ip"], " "), "QT_QPA_PLATFORM=offscreen") {
		t.Errorf("windowless first: %v", r.Envs)
	}
	// Sunshine accepts the PIN and saves nothing: that is NOT paired.
	s2, c2 := newServer(t)
	s2.user, s2.pass, s2.pin, s2.waiting, s2.saveClient = "admin", "pw", "1234", true, false
	var logs2 []string
	p2 := pairer(c2, &fx.Runner{Installed: map[string]bool{"moonlight": true}})
	p2.Log = func(x string) { logs2 = append(logs2, x) }
	if p2.Pair(context.Background(), "ip", "admin", "pw") || logs2[len(logs2)-1] != "Sunshine accepted the PIN but saved no client - NOT paired" {
		t.Errorf("%v", logs2)
	}
}

func TestPairingFallsBackToAWindowAndGivesUpSaying(t *testing.T) {
	s, c := newServer(t)
	s.user, s.pass, s.pin = "admin", "pw", "1234" // nothing is ever waiting
	r := &fx.Runner{Installed: map[string]bool{"moonlight": true}, Hang: map[string]bool{"moonlight": true}}
	var logs []string
	p := pairer(c, r)
	p.Log = func(x string) { logs = append(logs, x) }
	if p.Pair(context.Background(), "ip", "admin", "pw") {
		t.Fatal("no request, no pairing")
	}
	if len(logs) != 2 || logs[0] != "no pairing request seen offscreen - retrying with a window" || logs[1] != "moonlight never registered a pairing request" {
		t.Errorf("%v", logs)
	}
	if len(r.Started) != 2 || !r.Started[0].Killed || !r.Started[1].Killed {
		t.Error("both attempts are closed, not left hung")
	}
	// A wrong PIN is rejected, said, and Moonlight is closed.
	s.waiting, s.pin = true, "9999"
	r = &fx.Runner{Installed: map[string]bool{"moonlight": true}, Hang: map[string]bool{"moonlight": true}}
	logs = nil
	p = pairer(c, r)
	p.Log = func(x string) { logs = append(logs, x) }
	if p.Pair(context.Background(), "ip", "admin", "pw") || logs[len(logs)-1] != "Sunshine rejected the PIN" || !r.Started[0].Killed {
		t.Errorf("%v", logs)
	}
	// Moonlight missing: said, not crashed.
	p = pairer(c, &fx.Runner{})
	logs = nil
	p.Log = func(x string) { logs = append(logs, x) }
	if p.Pair(context.Background(), "ip", "admin", "pw") || logs[0] != "moonlight could not be started" {
		t.Errorf("%v", logs)
	}
}
