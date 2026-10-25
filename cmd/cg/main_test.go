package main

import (
	"os/exec"
	"strings"
	"testing"
)

// The built binary, run as the app runs it.
func build(t *testing.T) string {
	t.Helper()
	bin := t.TempDir() + "/cg"
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	return bin
}

func TestVersionAndUnknowns(t *testing.T) {
	bin := build(t)
	out, err := exec.Command(bin, "--version").Output()
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) != 2 || !strings.HasPrefix(lines[0], "cg ") || lines[1] != "events 1" {
		t.Errorf("--version printed %q", out)
	}
	c := exec.Command(bin, "--nope")
	c.Stderr = nil
	if err := c.Run(); err == nil {
		t.Error("an unknown flag should fail")
	}
	c = exec.Command(bin, "frobnicate")
	if err := c.Run(); err == nil {
		t.Error("an unknown command should fail")
	}
}

func TestCostRefusesAnUnknownOption(t *testing.T) {
	bin := build(t)
	out, err := exec.Command(bin, "cost", "--nope").CombinedOutput()
	if err == nil || !strings.Contains(string(out), "unknown option '--nope'") {
		t.Errorf("got %v %q", err, out)
	}
}
