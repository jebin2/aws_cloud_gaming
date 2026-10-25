package build

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/sunshine"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

// remote is a machine whose log grows as it is read.
type remote struct {
	log      []string // lines of the build log
	ready    bool
	state    string
	steamAt  int // the steam marker appears on this many checks
	steamChk int
	phase    string
	sshErr   error
	calls    []string
	grow     func(n int) // called each time the log is read
	reads    int
}

type stderrErr struct{ msg, stderr string }

func (e *stderrErr) Error() string      { return e.msg }
func (e *stderrErr) StderrText() string { return e.stderr }

func (r *remote) SSH(_ context.Context, cmd string) ([]byte, error) {
	r.calls = append(r.calls, cmd)
	switch {
	case strings.HasPrefix(cmd, "tail -n +"):
		if r.sshErr != nil {
			return nil, r.sshErr
		}
		r.reads++
		if r.grow != nil {
			r.grow(r.reads)
		}
		var n int
		_, _ = fmtSscan(cmd, &n)
		if n-1 >= len(r.log) {
			return nil, nil
		}
		return []byte(strings.Join(r.log[n-1:], "\n") + "\n"), nil
	case cmd == "test -f /var/lib/cloud-gaming-ready":
		if r.ready {
			return nil, nil
		}
		return nil, errors.New("exit 1")
	case cmd == stateCmd:
		return []byte(r.state + "\n"), nil
	case strings.HasPrefix(cmd, "tail -n 8"):
		return []byte("last line one\nlast line two\n"), nil
	case cmd == "test -f ~/.steam-prewarmed":
		r.steamChk++
		if r.steamAt > 0 && r.steamChk >= r.steamAt {
			return nil, nil
		}
		return nil, errors.New("exit 1")
	case strings.HasPrefix(cmd, "printf"):
		return []byte(r.phase), nil
	}
	return nil, nil
}

func fmtSscan(cmd string, n *int) (int, error) {
	s := strings.TrimPrefix(cmd, "tail -n +")
	s, _, _ = strings.Cut(s, " ")
	v := 0
	for _, c := range s {
		v = v*10 + int(c-'0')
	}
	*n = v
	return 1, nil
}

func follower(r *remote) (Follower, *[]string, *time.Duration) {
	var logs []string
	var slept time.Duration
	return Follower{R: r, Log: func(s string) { logs = append(logs, s) }, Sleep: func(d time.Duration) { slept += d }, Target: "me@pc"}, &logs, &slept
}

func TestAbortedFollowsTheBuildsOwnWord(t *testing.T) {
	for _, c := range []struct {
		seen  bool
		state string
		want  bool
	}{
		{false, "exited|no", true}, // a machine of yours: set -e stops it without a FAILED line
		{false, "error|no", false},
		{true, "error|no", true},
		{true, "error|yes", false}, // it reached the end, however it got there
		{true, "", false},
		{true, "running|no", false},
		{false, "", false},
	} {
		if got := Aborted(c.seen, c.state); got != c.want {
			t.Errorf("%v %q: %v", c.seen, c.state, got)
		}
	}
}

func TestProgressIsFilteredAndCompletionSaid(t *testing.T) {
	r := &remote{log: []string{
		">>> installing base", "Unpacking libfoo", "Setting up libgpg-error0", "E: Unable to locate package x",
		">>> ok: base", "ls: cannot access", "just noise", ">>> FAILED: the nvidia driver",
	}, ready: true}
	f, logs, _ := follower(r)
	if err := f.Stream(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"installing base", "! E: Unable to locate package x", "  ok  base", "FAILED: the nvidia driver", "build complete after 0m"}
	if strings.Join(*logs, "|") != strings.Join(want, "|") {
		t.Errorf("got %q", *logs)
	}
}

func TestOnlyTheNewPartOfTheLogIsReadEachTime(t *testing.T) {
	r := &remote{log: []string{">>> one", ">>> two"}}
	r.grow = func(n int) {
		if n == 2 {
			r.log = append(r.log, ">>> three")
			r.ready = true
		}
	}
	f, logs, slept := follower(r)
	if err := f.Stream(context.Background()); err != nil {
		t.Fatal(err)
	}
	if strings.Join(*logs, "|") != "one|two|three|build complete after 0m" || *slept != 10*time.Second {
		t.Errorf("%q slept %v", *logs, *slept)
	}
	if !strings.Contains(strings.Join(r.calls, "\n"), "tail -n +3 /var/log") {
		t.Errorf("a line already printed is not replayed:\n%s", strings.Join(r.calls, "\n"))
	}
}

func TestAMachineThatSaysItExitedStopsTheWaitAtOnce(t *testing.T) {
	r := &remote{log: []string{">>> step"}, state: "exited|no"}
	f, logs, _ := follower(r)
	f.Key = "/k"
	if err := f.Stream(context.Background()); !errors.Is(err, ErrStopped) {
		t.Fatalf("%v", err)
	}
	got := strings.Join(*logs, "\n")
	for _, want := range []string{"the build STOPPED before it finished - the end of its log:", "    last line two", "nothing after that step ran.", "ssh -i /k me@pc", "sudo tail -50 /var/log/cloud-gaming-bootstrap.log"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	// And one that failed at a named step says which.
	r = &remote{log: []string{">>> FAILED: installing the driver"}, state: "error|no"}
	f, logs, _ = follower(r)
	if err := f.Stream(context.Background()); !errors.Is(err, ErrStopped) || !strings.Contains(strings.Join(*logs, "\n"), "the build STOPPED here: installing the driver") {
		t.Errorf("%v %q", err, *logs)
	}
}

func TestAChangedHostKeyIsNotCalledAReboot(t *testing.T) {
	r := &remote{sshErr: &stderrErr{"exit 255", "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"}}
	f, logs, _ := follower(r)
	if err := f.Stream(context.Background()); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
	if (*logs)[0] != "ssh refused: the host key for this name changed" || (*logs)[2] != "    ssh-keygen -R pc" {
		t.Errorf("%q", *logs)
	}
}

func TestRebootIsSaidOnceAfterFiveMinutesOfNoAnswer(t *testing.T) {
	r := &remote{sshErr: errors.New("connection refused")}
	f, logs, slept := follower(r)
	f.Timeout = 10 * time.Minute
	if err := f.Stream(context.Background()); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
	n := 0
	for _, l := range *logs {
		if l == "host rebooting - reconnecting" {
			n++
		}
	}
	if n != 1 || *slept != 10*time.Minute || !strings.Contains(strings.Join(*logs, "\n"), "TIMEOUT after 10m. Check on the box:") {
		t.Errorf("%d %v %q", n, *slept, *logs)
	}
}

func TestSteamWaitReportsPhasesNotJustSizes(t *testing.T) {
	r := &remote{steamAt: 6, phase: "downloading|300M\n"}
	f, logs, _ := follower(r)
	if !f.WaitSteam(context.Background(), 30*time.Minute) {
		t.Fatal(*logs)
	}
	if strings.Join(*logs, "|") != "downloading (300M)|downloading (60s)|steam ready after 1m" {
		t.Errorf("an unchanging number is a heartbeat each minute, not a line each check: %q", *logs)
	}
	r = &remote{phase: "working|\n"}
	f, logs, _ = follower(r)
	if f.WaitSteam(context.Background(), 2*time.Minute) || !strings.Contains((*logs)[len(*logs)-1], "steam did not finish within 2m") {
		t.Errorf("%q", *logs)
	}
}

func TestFinishRunsTheSecondHalfInOrder(t *testing.T) {
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/welcome" {
			w.WriteHeader(302)
			return
		}
		if u, p, ok := r.BasicAuth(); ok && u == "admin" && p == "pw" {
			w.WriteHeader(200)
			return
		}
		w.WriteHeader(401)
	}))
	defer ts.Close()
	r := &remote{log: []string{">>> step"}, ready: true, steamAt: 1}
	fo, logs, _ := follower(r)
	var steps []string
	run := &fx.Runner{Installed: map[string]bool{"moonlight": true}, Answers: map[string]string{"moonlight list 100.64.0.9": "Desktop\n"}}
	fin := &Finisher{Follow: fo, Run: run, Login: &sunshine.Login{User: "admin", Pass: "pw"}, Save: func(string, string) { t.Error("saved a login that worked") },
		Sun:  sunshine.Client{HTTP: ts.Client(), URL: func(ip, path string) string { return ts.URL + path }},
		Name: "pc", Takes: "it takes a while", HasMoonlight: true,
		Say: func(s string) { steps = append(steps, s) }, Log: func(s string) { *logs = append(*logs, s) }, Sleep: func(time.Duration) {},
		AfterStream: func(context.Context) (string, error) { return "100.64.0.9", nil }}
	if err := fin.Finish(context.Background()); err != nil {
		t.Fatal(err)
	}
	if strings.Join(steps, "|") != "building pc - live progress below (it takes a while)|Sunshine account|moonlight pairing|waiting for Steam to finish installing" {
		t.Errorf("%q", steps)
	}
	if !fin.Paired || !fin.SteamOK || fin.SteamMsg != "installed. Sign in and it is ready." {
		t.Errorf("%+v", fin)
	}
	g := strings.Join(*logs, "\n")
	if !strings.Contains(g, "already configured, and the saved login works") || !strings.Contains(g, "already paired") {
		t.Errorf("%s", g)
	}
	// A build that does not finish stops before anything else is asked.
	r2 := &remote{log: []string{">>> FAILED: x"}, state: "error|no"}
	fo2, _, _ := follower(r2)
	steps = nil
	fin2 := &Finisher{Follow: fo2, Say: func(s string) { steps = append(steps, s) }, Log: func(string) {}}
	if err := fin2.Finish(context.Background()); !errors.Is(err, ErrStopped) || len(steps) != 1 {
		t.Errorf("%v %q", err, steps)
	}
}
