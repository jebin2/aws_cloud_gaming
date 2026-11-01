package box

import (
	"strings"
	"testing"
)

// Windows has no sh: a streamed command ran `sh`, failed to start, and exited 1 with
// not one word said (cg library push on a real Windows PC).
func TestStreamingNeedsNoShellOnWindows(t *testing.T) {
	ssh := []string{"-i", "k", "ubuntu@1.2.3.4", "echo hi"}
	if name, args := streamCommand("windows", ssh); name != "ssh" || strings.Join(args, " ") != strings.Join(ssh, " ") {
		t.Errorf("%s %v", name, args)
	}
	if name, args := streamCommand("linux", ssh); name != "sh" || args[0] != "-c" || !strings.Contains(strings.Join(args, " "), "2>&1") || args[len(args)-1] != "echo hi" {
		t.Errorf("%s %v", name, args)
	}
}
