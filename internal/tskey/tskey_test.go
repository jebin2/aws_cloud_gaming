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
	for _, want := range []string{`"ephemeral":false`, `"preauthorized":true`, `"description":"cg gamevps"`, `"expirySeconds":10800`} {
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
		// What Mint asks for: a key made a moment ago must pass the check that
		// follows it, or every replacement is refused as expired.
		"just minted":   {200, exp(mintLife - time.Minute), "ok"},
		"revoked":       {200, `{"revoked":"2026-10-01T00:00:00Z"}`, "expired"},
		"invalid":       {200, `{"invalid":true}`, "expired"},
		"gone":          {404, "", "gone"},
		"token refused": {403, "", "unknown refused"},
		"server error":  {502, "", "unknown unreachable 502"},
		"not json":      {200, "<html>", "unknown unreadable"},
		"odd date":      {200, `{"expires":"soon"}`, "unknown"},
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

func TestDisableExpiryTouchesOnlyTheConnectedNodeOfThatName(t *testing.T) {
	post := ""
	disabled := false
	devs := func(w http.ResponseWriter, r *http.Request) {
		flag := "false"
		if disabled {
			flag = "true"
		}
		reply(200, `{"devices":[
		 {"id":"old","name":"my-pc.tail1.ts.net","created":"2026-01-01T00:00:00Z","connectedToControl":false,"keyExpiryDisabled":false},
		 {"id":"mid","name":"my-pc-1.tail1.ts.net","created":"2026-05-01T00:00:00Z","connectedToControl":true,"keyExpiryDisabled":false},
		 {"id":"new","name":"my-pc.tail1.ts.net","created":"2026-09-01T00:00:00Z","connectedToControl":true,"keyExpiryDisabled":`+flag+`}]}`)(w, r)
	}
	c := server(t, map[string]func(http.ResponseWriter, *http.Request){
		"GET /tailnet/-/devices": devs,
		"POST /device/new/key": func(w http.ResponseWriter, r *http.Request) {
			b, _ := io.ReadAll(r.Body)
			post = string(b)
			disabled = true
			w.WriteHeader(200)
		},
	})
	e := c.DisableExpiry(context.Background(), "my-pc")
	if !e.Off || post != `{"keyExpiryDisabled": true}` || e.Lines[0] != "key expiry off for 'my-pc' - it will not drop off the tailnet" {
		t.Errorf("%+v %q", e, post)
	}
	// Already off: nothing is posted.
	post = ""
	if e := c.DisableExpiry(context.Background(), "my-pc"); !e.Off || post != "" || e.Lines[0] != "key expiry already off for 'my-pc'" {
		t.Errorf("%+v", e)
	}
	if e := c.DisableExpiry(context.Background(), "nobody"); e.Off || e.Lines[0] != "no connected tailnet node named 'nobody' - key expiry left on" {
		t.Errorf("%+v", e)
	}
	if e := (Client{}).DisableExpiry(context.Background(), "x"); !e.NoToken || e.Off {
		t.Errorf("%+v", e)
	}
	c.Token = "wrong"
	if e := c.DisableExpiry(context.Background(), "my-pc"); e.Off || e.Lines[0] != "tailnet token rejected (401) - key expiry left on" || len(e.Lines) != 2 {
		t.Errorf("%+v", e)
	}
	c.Base = "http://127.0.0.1:1"
	c.Token = "tskey-api-abc123"
	if e := c.DisableExpiry(context.Background(), "my-pc"); e.Off || !strings.Contains(e.Lines[0], "could not reach api.tailscale.com (000)") {
		t.Errorf("%+v", e)
	}
}

func TestPruneTouchesOnlyOfflineNodesOfThisHost(t *testing.T) {
	deleted := []string{}
	c := server(t, map[string]func(http.ResponseWriter, *http.Request){
		"GET /tailnet/-/devices": reply(200, `{"devices":[
		 {"id":"1","hostname":"gamevps","connectedToControl":false,"lastSeen":"2026-10-20T10:11:12Z"},
		 {"id":"2","hostname":"gamevps-1","connectedToControl":true},
		 {"id":"3","hostname":"gamevps-2"},
		 {"id":"4","hostname":"gamevpsx","connectedToControl":false},
		 {"id":"5","hostname":"phone","connectedToControl":false}]}`),
		"DELETE /device/1": func(w http.ResponseWriter, r *http.Request) {
			deleted = append(deleted, r.URL.Path)
			w.WriteHeader(200)
		},
	})
	got := c.PruneStale(context.Background(), "gamevps")
	if len(got) != 1 || got[0] != "    pruned stale tailnet node 'gamevps' (last seen 2026-10-20T10:11:12)" || len(deleted) != 1 {
		t.Errorf("an online node, one with no field, another name: all left alone: %v %v", got, deleted)
	}
	c.Token = "wrong"
	if got := c.PruneStale(context.Background(), "gamevps"); got[0] != "    tailnet token rejected (401) - stale nodes will not be pruned" {
		t.Errorf("%v", got)
	}
	if got := (Client{}).PruneStale(context.Background(), "gamevps"); got != nil {
		t.Error("nothing to do without a token")
	}
}

func TestDeleteNodesTakesEveryNodeOfThisHostAndNothingElse(t *testing.T) {
	deleted := []string{}
	del := func(w http.ResponseWriter, r *http.Request) {
		deleted = append(deleted, r.URL.Path)
		w.WriteHeader(200)
	}
	c := server(t, map[string]func(http.ResponseWriter, *http.Request){
		"GET /tailnet/-/devices": reply(200, `{"devices":[
		 {"id":"1","nodeId":"nA","hostname":"gamevps","connectedToControl":true},
		 {"id":"2","nodeId":"nB","hostname":"gamevps-3.tail.ts.net"},
		 {"id":"3","nodeId":"nC","hostname":"gamevpsx"},
		 {"id":"4","nodeId":"nD","hostname":"phone"}]}`),
		"DELETE /device/nA": del, "DELETE /device/nB": del,
	})
	got := c.DeleteNodes(context.Background(), "gamevps")
	if strings.Join(got, "|") != "deleted tailnet node 'gamevps'|deleted tailnet node 'gamevps-3'" || strings.Join(deleted, ",") != "/device/nA,/device/nB" {
		t.Errorf("online nodes go too; a node of another name never: %v %v", got, deleted)
	}
	c = server(t, map[string]func(http.ResponseWriter, *http.Request){"GET /tailnet/-/devices": reply(200, `{"devices":[{"nodeId":"n","hostname":"phone"}]}`)})
	if got := c.DeleteNodes(context.Background(), "gamevps"); got[0] != "no gamevps nodes on the tailnet - nothing to remove" {
		t.Errorf("%v", got)
	}
	c.Token = "wrong"
	if got := c.DeleteNodes(context.Background(), "gamevps"); !strings.HasPrefix(got[0], "TAILSCALE_API_KEY rejected (HTTP 401)") {
		t.Errorf("an expired token is not a clean tailnet: %v", got)
	}
	if got := (Client{}).DeleteNodes(context.Background(), "gamevps"); !strings.Contains(strings.Join(got, "\n"), "free name (gamevps-1, -2, ...)") {
		t.Errorf("%v", got)
	}
	c.Token, c.Base = "tskey-api-abc123", "http://127.0.0.1:1"
	if got := c.DeleteNodes(context.Background(), "gamevps"); got[0] != "could not reach api.tailscale.com - tailnet nodes left in place" {
		t.Errorf("%v", got)
	}
}
