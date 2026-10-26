// Package output is how cg talks: plain lines, and the NDJSON event stream the
// app reads on stderr when CG_JSON=1. Events are data, so escape codes are
// dropped rather than encoded - they are presentation.
//
// Stream rules, frozen: events on stderr, command data on stdout, answers on
// stdin. The fields rc, secs and secret are numbers; every other field is a
// string. Plain text is the source of truth; a styled terminal view is a
// renderer on top of it, and is not here yet.
package output

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"
)

// Out is where a command writes. Use a pointer: it remembers the step in
// progress, so that a step ends when the next begins.
type Out struct {
	Stdout, Stderr io.Writer
	JSON           bool             // CG_JSON=1: events instead of text
	Now            func() time.Time // the clock, for tests

	open  bool      // a step is in progress
	began time.Time // when it started
}

func (o *Out) now() time.Time {
	if o.Now != nil {
		return o.Now()
	}
	return time.Now()
}

func (o *Out) ts() string { return o.now().Format("2006-01-02T15:04:05-07:00") }

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

var numeric = map[string]bool{"rc": true, "secs": true, "secret": true}

// Event writes one event line to stderr: {"t":..., "at":..., k:v...}. kv is
// alternating keys and values; a number field with no value is 0.
func (o *Out) Event(t string, kv ...string) {
	var b strings.Builder
	b.WriteString(`{"t":` + jstr(t) + `,"at":` + jstr(o.ts()))
	for i := 0; i+1 < len(kv); i += 2 {
		k, v := kv[i], kv[i+1]
		if numeric[k] {
			if v == "" {
				v = "0"
			}
			fmt.Fprintf(&b, `,%s:%s`, jstr(k), v)
		} else {
			fmt.Fprintf(&b, `,%s:%s`, jstr(k), jstr(v))
		}
	}
	b.WriteString("}\n")
	io.WriteString(o.Stderr, b.String())
}

// jstr is a JSON string with the escape codes and carriage returns dropped. It
// does not escape < > &: this stream is read by programs, not HTML.
func jstr(s string) string {
	s = strings.ReplaceAll(ansi.ReplaceAllString(s, ""), "\x1b", "")
	s = strings.ReplaceAll(s, "\r", "")
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	return strings.TrimRight(buf.String(), "\n")
}

// Die is an error the command cannot continue past. Plain, it is a timestamped
// line on stderr; in events mode it is an error event. The caller exits.
func (o *Out) Die(text string) {
	if o.JSON {
		o.Event("error", "text", text)
		return
	}
	fmt.Fprintf(o.Stderr, "%s  error: %s\n", o.ts(), text)
}

// Say starts a step. A step still open is closed first.
func (o *Out) Say(text string) {
	if o.JSON {
		o.End(0)
		o.Event("step", "text", text)
		o.open, o.began = true, o.now()
		return
	}
	fmt.Fprintf(o.Stdout, "\n%s  ==> %s\n", o.ts(), text)
}

// End closes the step in progress, if any, with the exit status it ended in.
// It is what makes every step end - on success, on failure and on interrupt.
func (o *Out) End(rc int) {
	if !o.open {
		return
	}
	o.open = false
	if o.JSON {
		o.Event("step_end", "rc", fmt.Sprint(rc), "secs", fmt.Sprint(int(o.now().Sub(o.began).Seconds())))
	}
}

// Log is a detail line whose meaning is read from its words (Kind).
func (o *Out) Log(text string) {
	if o.JSON {
		o.Event("line", "kind", Kind(text), "text", text)
		return
	}
	fmt.Fprintf(o.Stdout, "%s      %s\n", o.ts(), text)
}

// LogAs is a detail line whose meaning the caller states, instead of it being
// read from the words. For report-like rows where the words mislead: a row
// saying something is NOT enabled still contains "enabled", and read as a
// success. kind is ok|fail|warn|wait|kept|skip|info|cont.
func (o *Out) LogAs(kind, text string) {
	if o.JSON {
		o.Event("line", "kind", kind, "text", text)
		return
	}
	o.Log(text)
}

// Gap is a blank line.
func (o *Out) Gap() {
	if !o.JSON {
		fmt.Fprintln(o.Stdout)
	}
}

// Echo is a plain line off a terminal, and a classified detail line in events.
func (o *Out) Echo(text string) {
	if o.JSON {
		o.Event("line", "kind", Kind(text), "text", text)
		return
	}
	fmt.Fprintln(o.Stdout, text)
}

// Block is a boxed note: the lines as they are, or one block event so the app
// draws it as a card rather than a stream of lines.
func (o *Out) Block(title, text string) {
	if o.JSON {
		o.Event("block", "title", title, "text", strings.TrimRight(text, "\n"))
		return
	}
	io.WriteString(o.Stdout, text)
}

// Report is a finished report. Plain, it is the text as it is; in events it is
// one report event, so the app draws it as a block and not as a stream of
// lines.
func (o *Out) Report(title, text string) {
	if o.JSON {
		if title == "" {
			title = "report"
		}
		o.Event("report", "title", title, "text", strings.TrimRight(text, "\n"))
		return
	}
	io.WriteString(o.Stdout, text)
}

// Relay passes the box's output on. Plain, every line is indented. In events,
// blank lines are dropped and a line the relayed script marked "!! " is a
// failure: without that, every line it ever prints arrives as plain
// continuation, and an app cannot tell the one line that says why the run
// stopped from the hundred above it.
func (o *Out) Relay(r io.Reader, indent string) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if !o.JSON {
			fmt.Fprintf(o.Stdout, "%s%s\n", indent, line)
			continue
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "!! "); ok {
			o.Event("line", "kind", "fail", "source", "box", "text", rest)
		} else {
			o.Event("line", "kind", "cont", "source", "box", "text", line)
		}
	}
}
