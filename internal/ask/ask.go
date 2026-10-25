// Package ask is how cg puts a question to whoever is there: a person at a
// terminal, or the app, where a question is an event on stderr and the answer
// comes back as a line on stdin.
//
// CG_YES=1 takes the default for every yes/no question, for a script that must
// not block. It does NOT answer a typed confirmation (DESTROY-ALL, FORGET):
// typing the word is the confirmation, so there is nothing to assume.
package ask

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Asker puts questions.
type Asker struct {
	Out *output.Out
	In  *bufio.Reader
	// Prompts is where a prompt is written for a person (stderr).
	Prompts io.Writer
	// TTY is whether standard input is a terminal.
	TTY bool
	// Yes is CG_YES=1.
	Yes bool
	// ReadSecret reads a line without echoing it; nil uses the terminal.
	ReadSecret func() (string, error)
}

// New is an Asker on the real standard input.
func New(out *output.Out, yes bool) *Asker {
	st, err := os.Stdin.Stat()
	return &Asker{Out: out, In: bufio.NewReader(os.Stdin), Prompts: os.Stderr, TTY: err == nil && st.Mode()&os.ModeCharDevice != 0, Yes: yes}
}

// CanAsk: is there anyone to ask? A terminal, or the app. This is NOT the same
// question as "is there a terminal", which is what sudo needs.
func (a *Asker) CanAsk() bool { return a.TTY || a.Out.JSON }

// line reads one line; ok is false when there was nothing to read.
func (a *Asker) line() (string, bool) {
	s, err := a.In.ReadString('\n')
	s = strings.TrimRight(s, "\r\n")
	if err != nil && s == "" {
		return "", false
	}
	return s, true
}

// Ask asks, and returns the answer, or the default when none came: a reply
// typed without a newline still counts; only no reply at all is none.
func (a *Asker) Ask(id, prompt, def, choices string) string {
	if a.Out.JSON {
		a.Out.Event("ask", "id", id, "prompt", prompt, "default", def, "choices", choices)
		if s, _ := a.line(); s != "" {
			return s
		}
		return def
	}
	fmt.Fprint(a.Prompts, prompt)
	if s, _ := a.line(); s != "" {
		return s
	}
	return def
}

// Secret asks for something that must not be echoed or logged.
func (a *Asker) Secret(id, prompt string) string {
	if a.Out.JSON {
		a.Out.Event("ask", "id", id, "prompt", prompt, "default", "", "secret", "1")
		s, _ := a.line()
		return s
	}
	fmt.Fprint(a.Prompts, prompt)
	var s string
	switch {
	case a.ReadSecret != nil:
		s, _ = a.ReadSecret()
	case a.TTY:
		b, _ := term.ReadPassword(int(os.Stdin.Fd()))
		s = string(b)
	default:
		s, _ = a.line()
	}
	fmt.Fprintln(a.Prompts)
	return s
}

// Confirm is a yes/no question; def is "Y" or "N".
func (a *Asker) Confirm(id, prompt, def string) bool {
	if a.Yes {
		return strings.HasPrefix(strings.ToLower(def), "y")
	}
	return strings.HasPrefix(strings.ToLower(a.Ask(id, prompt, def, "")), "y")
}

// Typed is true only when that exact word was typed. Nothing assumes it.
func (a *Asker) Typed(id, prompt, word string) bool { return a.Ask(id, prompt, "", "") == word }
