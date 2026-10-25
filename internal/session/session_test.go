package session

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

type fake struct {
	alive map[int]bool
	args  map[int]string
}

func (f fake) Alive(p int) bool          { return f.alive[p] }
func (f fake) Args(p int) (string, bool) { a, ok := f.args[p]; return a, ok }

func write(t *testing.T, body string) string {
	p := filepath.Join(t.TempDir(), "cg-session-1000.pid")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestARunningSession(t *testing.T) {
	f := fake{alive: map[int]bool{42: true}, args: map[int]string{42: "bash /home/u/cg open"}}
	l, ok := Running(write(t, "42 1000\n"), f)
	if !ok || l.PID != 42 || l.Started != 1000 {
		t.Fatalf("got %+v %v", l, ok)
	}
	age, known := l.Age(time.Unix(1090, 0))
	if !known || age != 90*time.Second {
		t.Errorf("age %v %v", age, known)
	}
}

func TestNothingHoldsIt(t *testing.T) {
	cases := map[string]struct {
		body string
		f    fake
	}{
		"a dead process":      {"42 1000", fake{alive: map[int]bool{}}},
		"a reused pid":        {"42 1000", fake{alive: map[int]bool{42: true}, args: map[int]string{42: "/usr/bin/firefox"}}},
		"not a number":        {"abc 1000", fake{}},
		"an empty file":       {"", fake{}},
		"no way to read args": {"42 1000", fake{alive: map[int]bool{42: true}}},
	}
	for name, c := range cases {
		if _, ok := Running(write(t, c.body), c.f); ok {
			t.Errorf("%s: reported a session", name)
		}
	}
	if _, ok := Running(filepath.Join(t.TempDir(), "none"), fake{}); ok {
		t.Error("a missing file reported a session")
	}
}

func TestFileLocation(t *testing.T) {
	get := func(m map[string]string) func(string) (string, bool) {
		return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
	}
	for _, c := range []struct {
		env  map[string]string
		want string
	}{
		{map[string]string{"XDG_RUNTIME_DIR": "/run/user/1000", "TMPDIR": "/t"}, "/run/user/1000/cg-session-1000.pid"},
		{map[string]string{"TMPDIR": "/t"}, "/t/cg-session-1000.pid"},
		{map[string]string{}, "/tmp/cg-session-1000.pid"},
	} {
		if got := File(get(c.env), 1000); got != c.want {
			t.Errorf("got %s want %s", got, c.want)
		}
	}
}
