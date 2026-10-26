package testfixture

import (
	"context"
	"errors"
	"io"
	"strconv"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// Runner is a fake local.Runner: programs that are "installed", what each
// prints, and a record of what was run.
type Runner struct {
	Installed map[string]bool
	Answers   map[string]string // "name arg arg" -> stdout
	Failing   map[string]bool   // "name" or "name arg" that exits non-zero
	Contains  map[string]string // a part of the command line -> stdout, for ssh commands
	Ran       []string
	// What was fed to programs on standard input, and the environment each was
	// given, by command line - for tests of what must never reach a command line.
	Stdin map[string]string
	Envs  map[string][]string
	// Exit is the exit status of a failing command by "name" or "name arg".
	Exit map[string]int
	// Hook sees a command line first. handled false falls through to the maps.
	Hook func(line string) (handled bool, out string, err error)
	Hang map[string]bool
	// Stderr is what a failing command said, by command line.
	Stderr  map[string]string
	Started []*fakeProc
}

func (r *Runner) Has(name string) bool { return r.Installed[name] }

func (r *Runner) Output(_ context.Context, name string, args ...string) ([]byte, error) {
	line := strings.TrimSpace(name + " " + strings.Join(args, " "))
	r.Ran = append(r.Ran, line)
	if !r.Installed[name] {
		return nil, errors.New("not installed: " + name)
	}
	if r.Hook != nil {
		if ok, out, err := r.Hook(line); ok {
			return []byte(out), err
		}
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

func (r *Runner) Run(ctx context.Context, c local.Cmd) ([]byte, error) {
	line := strings.TrimSpace(c.Name + " " + strings.Join(c.Args, " "))
	if c.Stdin != nil {
		b, _ := io.ReadAll(c.Stdin)
		if r.Stdin == nil {
			r.Stdin = map[string]string{}
		}
		r.Stdin[line] += string(b)
	}
	if r.Envs == nil {
		r.Envs = map[string][]string{}
	}
	r.Envs[line] = c.Env
	b, err := r.Output(ctx, c.Name, c.Args...)
	if c.Combined != nil {
		_, _ = c.Combined.Write(b)
		b = nil
	}
	if err != nil {
		for _, k := range []string{line, c.Name} {
			if n, ok := r.Exit[k]; ok {
				return b, &exitErr{n, r.Stderr[line]}
			}
		}
	}
	return b, err
}

type exitErr struct {
	code   int
	stderr string
}

func (e *exitErr) StderrText() string { return e.stderr }

func (e *exitErr) Error() string { return "exit status " + strconv.Itoa(e.code) }
func (e *exitErr) ExitCode() int { return e.code }

// Procs are the programs started in the background, and Hang keeps one running
// until it is killed (by "name arg"); otherwise it has already exited.
func (r *Runner) Start(_ context.Context, c local.Cmd) (local.Proc, error) {
	line := strings.TrimSpace(c.Name + " " + strings.Join(c.Args, " "))
	r.Ran = append(r.Ran, line)
	if r.Envs == nil {
		r.Envs = map[string][]string{}
	}
	r.Envs[line] = c.Env
	if !r.Installed[c.Name] {
		return nil, errors.New("not installed: " + c.Name)
	}
	p := &fakeProc{done: make(chan struct{})}
	if r.Hang[line] || r.Hang[c.Name] {
		r.Started = append(r.Started, p)
	} else {
		close(p.done)
	}
	return p, nil
}

type fakeProc struct {
	done   chan struct{}
	Killed bool
}

func (p *fakeProc) Done() <-chan struct{} { return p.done }
func (p *fakeProc) Kill() {
	p.Killed = true
	select {
	case <-p.done:
	default:
		close(p.done)
	}
}

// Killed is whether a background program was killed.
func (p *fakeProc) WasKilled() bool { return p.Killed }

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
