package output

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func out(json bool) (Out, *bytes.Buffer) {
	var e bytes.Buffer
	at := time.Date(2026, 10, 25, 18, 30, 2, 0, time.FixedZone("", 19800))
	return Out{Stdout: &bytes.Buffer{}, Stderr: &e, JSON: json, Now: func() time.Time { return at }}, &e
}

func TestDiePlain(t *testing.T) {
	o, e := out(false)
	o.Die("unknown flag '--nope' (see: cg help)")
	if got, want := e.String(), "2026-10-25T18:30:02+05:30  error: unknown flag '--nope' (see: cg help)\n"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestEventsAreOneJSONObjectPerLine(t *testing.T) {
	o, e := out(true)
	o.Die("it broke \x1b[31mred\x1b[0m")
	o.Event("step_end", "rc", "3", "secs", "", "title", `say "hi"`)
	lines := strings.Split(strings.TrimSpace(e.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("lines: %q", lines)
	}
	var a, b map[string]any
	if json.Unmarshal([]byte(lines[0]), &a) != nil || json.Unmarshal([]byte(lines[1]), &b) != nil {
		t.Fatalf("not JSON: %q", lines)
	}
	if a["t"] != "error" || a["text"] != "it broke red" || a["at"] != "2026-10-25T18:30:02+05:30" {
		t.Errorf("error event %v", a)
	}
	if b["rc"] != 3.0 || b["secs"] != 0.0 || b["title"] != `say "hi"` {
		t.Errorf("numbers must be numbers, strings strings: %v", b)
	}
}
