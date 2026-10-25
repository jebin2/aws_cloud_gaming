package notify

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

func env(t *testing.T, line string) *config.Env {
	f := filepath.Join(t.TempDir(), ".env")
	_ = os.WriteFile(f, []byte(line+"\n"), 0o600)
	return config.Load(func(k string) (string, bool) {
		if k == "CG_ENV_FILE" {
			return f, true
		}
		return "", false
	}, "")
}

func outs() (*output.Out, *bytes.Buffer, *bytes.Buffer) {
	var o, e bytes.Buffer
	return &output.Out{Stdout: &o, Stderr: &e}, &o, &e
}

func TestSendsToTheTopicAndNeverPrintsIt(t *testing.T) {
	var got *http.Request
	var body string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		b := new(bytes.Buffer)
		_, _ = b.ReadFrom(r.Body)
		body = b.String()
	}))
	defer s.Close()
	out, o, e := outs()
	if rc := Send(context.Background(), nil, env(t, "GAME_NTFY_URL="+s.URL+"/secret-topic-123"), out); rc != 0 {
		t.Fatalf("rc %d %s", rc, e.String())
	}
	if got.Method != "POST" || got.URL.Path != "/secret-topic-123" || got.Header.Get("Title") != "gamevps: test" || got.Header.Get("Tags") != "bell" ||
		body != "Notifications from cloud_gaming reach this device." {
		t.Errorf("%v %q", got.Header, body)
	}
	all := o.String() + e.String()
	if strings.Contains(all, "secret-topic-123") || !strings.Contains(all, "sent to 127.0.0.1:") || !strings.Contains(all, "check the ntfy app") {
		t.Errorf("the topic is the secret: %s", all)
	}
}

func TestEveryRefusalIsSaidWithoutTheTopic(t *testing.T) {
	for line, want := range map[string]string{
		"GAME_NTFY_URL=":                                    "set GAME_NTFY_URL in .env",
		"GAME_NTFY_URL=not a topic!":                        "GAME_NTFY_URL is not a topic (letters, digits, - and _, up to 64) or an http(s)://host/topic URL",
		"GAME_NTFY_URL=http://127.0.0.1:1/secret-topic-123": "could not send to 127.0.0.1:1 - check the URL, and that this machine can reach it",
	} {
		out, o, e := outs()
		if rc := Send(context.Background(), nil, env(t, line), out); rc != 1 || !strings.Contains(e.String(), want) || strings.Contains(o.String()+e.String(), "secret-topic-123") {
			t.Errorf("%q: rc %d %s", line, rc, e.String())
		}
	}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }))
	defer s.Close()
	out, _, e := outs()
	if rc := Send(context.Background(), nil, env(t, "GAME_NTFY_URL="+s.URL+"/topic"), out); rc != 1 || !strings.Contains(e.String(), "could not send to") {
		t.Errorf("a server error is not a send: %d %s", rc, e.String())
	}
}
