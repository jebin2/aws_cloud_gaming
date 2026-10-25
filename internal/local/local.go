// Package local runs programs on this computer - tailscale, ssh, moonlight -
// behind an interface, with an argument slice and a context, never a shell
// string. Tests put a fake in its place.
package local

import (
	"context"
	"os/exec"
)

// Runner runs a program and returns what it printed.
type Runner interface {
	// Output runs name with args and returns its standard output. A program
	// that exits non-zero returns its output (if any) and an error.
	Output(ctx context.Context, name string, args ...string) ([]byte, error)
	// Has reports whether name is installed.
	Has(name string) bool
}

// Exec is the real Runner.
type Exec struct{}

func (Exec) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

func (Exec) Has(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
