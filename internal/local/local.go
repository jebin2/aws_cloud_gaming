// Package local runs programs on this computer - tailscale, ssh, moonlight -
// behind an interface, with an argument slice and a context, never a shell
// string. Tests put a fake in its place.
package local

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
)

// Runner runs a program and returns what it printed.
type Runner interface {
	// Output runs name with args and returns its standard output. A program
	// that exits non-zero returns its output (if any) and an error.
	Output(ctx context.Context, name string, args ...string) ([]byte, error)
	// Stream runs name with args and copies its standard output to w as it
	// arrives, until it exits or the context ends.
	Stream(ctx context.Context, w io.Writer, name string, args ...string) error
	// Passthrough runs name attached to this terminal - stdin, stdout and
	// stderr - and returns its exit status, 127 if it cannot be run.
	Passthrough(ctx context.Context, name string, args ...string) int
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

func (Exec) Stream(ctx context.Context, w io.Writer, name string, args ...string) error {
	c := exec.CommandContext(ctx, name, args...)
	c.Stdout, c.Stderr = w, os.Stderr
	return c.Run()
}

func (Exec) Passthrough(ctx context.Context, name string, args ...string) int {
	c := exec.CommandContext(ctx, name, args...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	err := c.Run()
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return 127
}
