// Package session is the local stream lock: `cg open` holds it for as long as
// Moonlight is on screen, `cg status` reports it, and `cg destroy` closes it
// before taking the box away. It is how an app knows a stream is already up,
// even if whatever started it has gone.
package session

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Lock is a held session.
type Lock struct {
	PID     int
	Started int64 // epoch seconds; 0 if the file did not say
}

// Age is how long the stream has been up, if known.
func (l Lock) Age(now time.Time) (time.Duration, bool) {
	if l.Started <= 0 {
		return 0, false
	}
	return now.Sub(time.Unix(l.Started, 0)), true
}

// Probe is how a pid is checked; tests replace it.
type Probe interface {
	Alive(pid int) bool
	Args(pid int) (string, bool)
}

// Proc is the real one, on /proc.
type Proc struct{}

func (Proc) Alive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func (Proc) Args(pid int) (string, bool) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(strings.ReplaceAll(string(b), "\x00", " ")), true
}

// File is where the lock lives: the runtime directory, else TMPDIR, else /tmp.
func File(get func(string) (string, bool), uid int) string {
	dir, _ := get("XDG_RUNTIME_DIR")
	if dir == "" {
		dir, _ = get("TMPDIR")
	}
	if dir == "" {
		dir = "/tmp"
	}
	return filepath.Join(dir, fmt.Sprintf("cg-session-%d.pid", uid))
}

// Running returns the lock if a live session holds it. A file whose process
// is gone, or whose pid was reused by something that is not cg, holds nothing.
func Running(path string, p Probe) (Lock, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Lock{}, false
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return Lock{}, false
	}
	pid, err := strconv.Atoi(f[0])
	if err != nil || pid <= 0 || !p.Alive(pid) {
		return Lock{}, false
	}
	args, ok := p.Args(pid)
	if !ok || !(strings.Contains(args, "cg") || strings.Contains(args, "game")) {
		return Lock{}, false // the pid was reused
	}
	l := Lock{PID: pid}
	if len(f) > 1 {
		l.Started, _ = strconv.ParseInt(f[1], 10, 64)
	}
	return l, true
}

// Claim takes the lock for this process. It is a pid file, not flock: the app and
// `cg status` want to SAY what is running, and a pid answers that. A lock that
// cannot be written is no lock, and no reason to refuse a stream.
func Claim(path string, now time.Time) {
	_ = os.WriteFile(path, []byte(fmt.Sprintf("%d %d\n", os.Getpid(), now.Unix())), 0o644)
}

// Release drops the lock now, and only if it is this process's. Not End: that
// ends whoever holds the lock, and when that is this process it would send TERM to
// itself - every `cg host open` ended killed, exit 143, and the app called a
// normal session a failed one.
func Release(path string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	if f := strings.Fields(string(b)); len(f) > 0 && f[0] == strconv.Itoa(os.Getpid()) {
		_ = os.Remove(path)
	}
}
