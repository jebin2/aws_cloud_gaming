package tskey

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

// server answers as Tailscale does, for a token and the keys it knows.
func server(t *testing.T, routes map[string]func(w http.ResponseWriter, r *http.Request)) Client {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if f, ok := routes[r.Method+" "+r.URL.Path]; ok {
			f(w, r)
			return
		}
		w.WriteHeader(404)
	}))
	t.Cleanup(s.Close)
	return Client{Base: s.URL, Token: "tskey-api-abc123", Now: func() time.Time { return now }}
}

func reply(code int, body string) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tskey-api-abc123" {
			w.WriteHeader(401)
			return
		}
		w.WriteHeader(code)
		_, _ = io.WriteString(w, body)
	}
}

func TestAuthID(t *testing.T) {
	for in, want := range map[string]string{"tskey-auth-kABC123CNTRL-secretpart": "kABC123CNTRL", "tskey-api-xyz-rest": "xyz", "tskey-client-q-w": "q", "tskey-plain-id": "plain", "": ""} {
		if got := AuthID(in); got != want {
			t.Errorf("%q: got %q want %q", in, got, want)
		}
	}
}

func TestTokenStates(t *testing.T) {
	c := server(t, map[string]func(http.ResponseWriter, *http.Request){"GET /tailnet/-/devices": reply(200, "{}")})
	if s, _ := c.CheckToken(context.Background()); s != "ok" {
		t.Errorf("%s", s)
	}
	c.Token = "wrong"
	if s, d := c.CheckToken(context.Background()); s != "rejected" || d != "401" {
		t.Errorf("%s %s", s, d)
	}
	c.Token = ""
	if s, _ := c.CheckToken(context.Background()); s != "absent" {
		t.Errorf("%s", s)
	}
}

func TestMint(t *testing.T) {
	var sent string
	c := server(t, map[string]func(http.ResponseWriter, *http.Request){"POST /tailnet/-/keys": func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		sent = string(b)
		reply(200, `{"key":"tskey-auth-new-123"}`)(w, r)
	}})
	m := c.Mint(context.Background(), "gamevps")
	if m.Key != "tskey-auth-new-123" || m.Code != 200 {
		t.Fatalf("%+v", m)
	}
	// Not ephemeral (this box goes offline every time the watchdog stops it),
	// preauthorized (nobody is at the box), and it says whose it is.
	for _, want := range []string{`"ephemeral":false`, `"preauthorized":true`, `"description":"cg gamevps"`, `"expirySeconds":3600`} {
		if !strings.Contains(sent, want) {
			t.Errorf("lacks %s in %s", want, sent)
		}
	}
	c = server(t, map[string]func(http.ResponseWriter, *http.Request){"POST /tailnet/-/keys": reply(400, "requested tags [] are invalid or not permitted\n")})
	if m := c.Mint(context.Background(), "gamevps"); m.Key != "" || m.Code != 400 || m.Err != "requested tags [] are invalid or not permitted" {
		t.Errorf("%+v", m)
	}
	c = server(t, map[string]func(http.ResponseWriter, *http.Request){"POST /tailnet/-/keys": reply(200, `{}`)})
	if m := c.Mint(context.Background(), "gamevps"); m.Err != "the API answered without a key" {
		t.Errorf("%+v", m)
	}
	c.Base = "http://127.0.0.1:1"
	if m := c.Mint(context.Background(), "gamevps"); m.Code != 0 || m.Key != "" {
		t.Errorf("no answer: %+v", m)
	}
	if m := (Client{}).Mint(context.Background(), "x"); m.Key != "" {
		t.Error("no token, no key")
	}
}

func TestProbe(t *testing.T) {
	key := "tskey-auth-kid1-secret"
	exp := func(d time.Duration) string { return `{"expires":"` + now.Add(d).Format(time.RFC3339) + `"}` }
	for name, c := range map[string]struct {
		code int
		body string
		want string
	}{
		"fine":                {200, exp(48 * time.Hour), "ok"},
		"never expires":       {200, `{}`, "ok"},
		"dies within an hour": {200, exp(30 * time.Minute), "expired"},
		"revoked":             {200, `{"revoked":"2026-10-01T00:00:00Z"}`, "expired"},
		"invalid":             {200, `{"invalid":true}`, "expired"},
		"gone":                {404, "", "gone"},
		"token refused":       {403, "", "unknown refused"},
		"server error":        {502, "", "unknown unreachable 502"},
		"not json":            {200, "<html>", "unknown unreadable"},
		"odd date":            {200, `{"expires":"soon"}`, "unknown"},
	} {
		cl := server(t, map[string]func(http.ResponseWriter, *http.Request){"GET /tailnet/-/keys/kid1": reply(c.code, c.body)})
		if got := cl.Probe(context.Background(), key); got != c.want {
			t.Errorf("%s: got %q want %q", name, got, c.want)
		}
	}
	cl := Client{Now: func() time.Time { return now }}
	if cl.Probe(context.Background(), key) != "unknown no-token" {
		t.Error("no token")
	}
	cl.Token = "t"
	if cl.Probe(context.Background(), "") != "unknown no-key" {
		t.Error("no key")
	}
	cl.Base = "http://127.0.0.1:1"
	if got := cl.Probe(context.Background(), key); got != "unknown unreachable 000" {
		t.Errorf("%s", got)
	}
	if cl.State(context.Background(), key) != "unknown" {
		t.Error("state is the first word")
	}
}

func TestDelete(t *testing.T) {
	deleted := ""
	c := server(t, map[string]func(http.ResponseWriter, *http.Request){"DELETE /tailnet/-/keys/kid1": func(w http.ResponseWriter, r *http.Request) { deleted = r.URL.Path; w.WriteHeader(200) }})
	if !c.Delete(context.Background(), "tskey-auth-kid1-secret") || deleted != "/tailnet/-/keys/kid1" {
		t.Errorf("%q", deleted)
	}
	if c.Delete(context.Background(), "") || (Client{}).Delete(context.Background(), "tskey-auth-k-s") {
		t.Error("nothing to delete with")
	}
}
