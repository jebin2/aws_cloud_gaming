// Package output is how cg talks: plain lines, and the NDJSON event stream the
// app reads on stderr when CG_JSON=1. Events are data, so escape codes are
// dropped rather than encoded - they are presentation.
//
// Stream rules, frozen: events on stderr, command data on stdout, answers on
// stdin. The fields rc, secs and secret are numbers; every other field is a
// string.
package output

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"
)

// Out is where a command writes.
type Out struct {
	Stdout, Stderr io.Writer
	JSON           bool             // CG_JSON=1: events instead of text
	Now            func() time.Time // the clock, for tests
}

func (o Out) ts() string {
	now := time.Now
	if o.Now != nil {
		now = o.Now
	}
	return now().Format("2006-01-02T15:04:05-07:00")
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

var numeric = map[string]bool{"rc": true, "secs": true, "secret": true}

// Event writes one event line to stderr: {"t":..., "at":..., k:v...}. kv is
// alternating keys and values; a number field with no value is 0.
func (o Out) Event(t string, kv ...string) {
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
			fmt.Fprintf(&b, `,%s:%s`, jstr(k), jstr(ansi.ReplaceAllString(v, "")))
		}
	}
	b.WriteString("}\n")
	io.WriteString(o.Stderr, b.String())
}

func jstr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// Die is an error the command cannot continue past. Plain, it is a timestamped
// line on stderr; in events mode it is an error event.
func (o Out) Die(text string) {
	if o.JSON {
		o.Event("error", "text", text)
		return
	}
	fmt.Fprintf(o.Stderr, "%s  error: %s\n", o.ts(), text)
}
