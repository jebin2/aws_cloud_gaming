package testfixture

import (
	"context"
	"errors"
	"io"
	"strings"
)

// Runner is a fake local.Runner: programs that are "installed", what each
// prints, and a record of what was run.
type Runner struct {
	Installed map[string]bool
	Answers   map[string]string // "name arg arg" -> stdout
	Failing   map[string]bool   // "name" or "name arg" that exits non-zero
	Contains  map[string]string // a part of the command line -> stdout, for ssh commands
	Ran       []string
}

func (r *Runner) Has(name string) bool { return r.Installed[name] }

func (r *Runner) Output(_ context.Context, name string, args ...string) ([]byte, error) {
	line := strings.TrimSpace(name + " " + strings.Join(args, " "))
	r.Ran = append(r.Ran, line)
	if !r.Installed[name] {
		return nil, errors.New("not installed: " + name)
	}
	if r.Failing[name] || r.Failing[line] {
		return []byte(r.Answers[name]), errors.New("exit status 1")
	}
	for part, a := range r.Contains {
		if strings.Contains(line, part) {
			if r.Failing[part] {
				return nil, errors.New("exit status 1")
			}
			return []byte(a), nil
		}
	}
	// An answer by the program and its first word is enough for the tests.
	if a, ok := r.Answers[line]; ok {
		return []byte(a), nil
	}
	if a, ok := r.Answers[name]; ok {
		return []byte(a), nil
	}
	return nil, nil
}

func (r *Runner) Stream(ctx context.Context, w io.Writer, name string, args ...string) error {
	b, err := r.Output(ctx, name, args...)
	_, _ = w.Write(b)
	return err
}

func (r *Runner) Passthrough(ctx context.Context, name string, args ...string) int {
	line := strings.TrimSpace(name + " " + strings.Join(args, " "))
	r.Ran = append(r.Ran, line)
	if !r.Installed[name] {
		return 127
	}
	if r.Failing[name] || r.Failing[line] {
		return 255
	}
	return 0
}
