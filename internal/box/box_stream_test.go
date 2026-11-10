package box

import (
	"strings"
	"testing"
)

// Windows has no sh: a streamed command ran `sh`, failed to start, and exited 1 with
// not one word said (ayis library push on a real Windows PC).
func TestStreamingNeedsNoShellOnWindows(t *testing.T) {
	ssh := []string{"-i", "k", "ubuntu@1.2.3.4", "echo hi"}
	if name, args := streamCommand("windows", ssh); name != "ssh" || strings.Join(args, " ") != strings.Join(ssh, " ") {
		t.Errorf("%s %v", name, args)
	}
	if name, args := streamCommand("linux", ssh); name != "sh" || args[0] != "-c" || !strings.Contains(strings.Join(args, " "), "2>&1") || args[len(args)-1] != "echo hi" {
		t.Errorf("%s %v", name, args)
	}
}

// A command streamed from a box that disappears mid-run (spot reclaim, a destroy from
// another window) waited on a dead TCP connection for hours: ConnectTimeout only
// covers connecting. Every ssh to the box now notices a silent connection within a
// minute (15 s x 4).
func TestEverySSHToTheBoxNoticesADeadConnection(t *testing.T) {
	args := strings.Join(Box{Key: "k"}.sshArgs("1.2.3.4", "10", "echo hi"), " ")
	for _, want := range []string{"ServerAliveInterval=15", "ServerAliveCountMax=4", "BatchMode=yes", "ConnectTimeout=10"} {
		if !strings.Contains(args, want) {
			t.Errorf("lacks %s: %s", want, args)
		}
	}
}
