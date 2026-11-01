//go:build !windows

package local

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

// Alive reports whether a process with this pid exists and can be signalled.
func Alive(pid int) bool { return syscall.Kill(pid, 0) == nil }

// Args is the process's command line. Linux keeps it in /proc; macOS has no
// /proc, and ps answers there.
func Args(pid int) (string, bool) {
	if b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid)); err == nil {
		return strings.TrimSpace(strings.ReplaceAll(string(b), "\x00", " ")), true
	}
	out, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", false
	}
	s := strings.TrimSpace(string(out))
	return s, s != ""
}

// Stop asks a process to end (TERM), or ends it (KILL) when force is set.
func Stop(pid int, force bool) {
	sig := syscall.SIGTERM
	if force {
		sig = syscall.SIGKILL
	}
	_ = syscall.Kill(pid, sig)
}

// StopChildren does the same to the process's children.
func StopChildren(pid int, force bool) {
	sig := "-TERM"
	if force {
		sig = "-KILL"
	}
	_ = exec.Command("pkill", sig, "-P", strconv.Itoa(pid)).Run()
}

// PidsByName lists the processes whose executable has exactly this name.
func PidsByName(name string) []int {
	out, err := exec.Command("pgrep", "-x", name).Output()
	if err != nil {
		return nil
	}
	var pids []int
	for _, f := range strings.Fields(string(out)) {
		if n, err := strconv.Atoi(f); err == nil {
			pids = append(pids, n)
		}
	}
	return pids
}
