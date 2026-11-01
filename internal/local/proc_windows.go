//go:build windows

package local

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Alive reports whether a process with this pid exists: on Windows, FindProcess
// opens it and fails when it is gone.
func Alive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	_ = p.Release()
	return true
}

// Args is the process's command line, from the system's process table.
func Args(pid int) (string, bool) {
	out, err := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command",
		"(Get-CimInstance Win32_Process -Filter 'ProcessId="+strconv.Itoa(pid)+"').CommandLine").Output()
	if err != nil {
		return "", false
	}
	s := strings.TrimSpace(string(out))
	return s, s != ""
}

// Stop ends the process and its children. Without force, taskkill asks a window
// to close - which is what ends a Moonlight stream cleanly.
func Stop(pid int, force bool) {
	args := []string{"/PID", strconv.Itoa(pid), "/T"}
	if force {
		args = append(args, "/F")
	}
	_ = exec.Command("taskkill", args...).Run()
}

// StopChildren does nothing here: Stop already takes the whole tree.
func StopChildren(pid int, force bool) {}

// PidsByName lists the processes running an executable called name.exe.
func PidsByName(name string) []int {
	out, err := exec.Command("tasklist", "/FI", "IMAGENAME eq "+name+".exe", "/FO", "CSV", "/NH").Output()
	if err != nil {
		return nil
	}
	var pids []int
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Split(strings.TrimSpace(line), `","`)
		if len(f) >= 2 {
			if n, err := strconv.Atoi(strings.Trim(f[1], `"`)); err == nil {
				pids = append(pids, n)
			}
		}
	}
	return pids
}
