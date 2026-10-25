package output

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func out(json bool) (*Out, *bytes.Buffer) {
	var e bytes.Buffer
	at := time.Date(2026, 10, 25, 18, 30, 2, 0, time.FixedZone("", 19800))
	return &Out{Stdout: &bytes.Buffer{}, Stderr: &e, JSON: json, Now: func() time.Time { return at }}, &e
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

func plain(o *Out) string { return o.Stdout.(*bytes.Buffer).String() }

func TestPlainFormats(t *testing.T) {
	o, _ := out(false)
	o.Say("guards")
	o.Log("instance          running")
	o.LogAs("ok", "budget            $53")
	o.Gap()
	o.Echo("  loose line")
	o.Relay(strings.NewReader("a\n\nb\n"), "      ")
	o.Report("anything", "X\nY\n")
	want := "\n2026-10-25T18:30:02+05:30  ==> guards\n" +
		"2026-10-25T18:30:02+05:30      instance          running\n" +
		"2026-10-25T18:30:02+05:30      budget            $53\n" +
		"\n  loose line\n      a\n      \n      b\nX\nY\n"
	if got := plain(o); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func events(t *testing.T, e *bytes.Buffer) []map[string]any {
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(e.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("not JSON: %q", l)
		}
		out = append(out, m)
	}
	return out
}

func TestStepsEndWhenTheNextBeginsAndOnExit(t *testing.T) {
	o, e := out(true)
	o.Say("one")
	o.Log("keeping the box")
	o.LogAs("warn", "fine")
	o.Say("two")
	o.End(3)
	o.End(0) // nothing open: nothing said
	ev := events(t, e)
	var kinds []string
	for _, m := range ev {
		kinds = append(kinds, m["t"].(string))
	}
	if got := strings.Join(kinds, ","); got != "step,line,line,step_end,step,step_end" {
		t.Fatalf("events %s", got)
	}
	if ev[1]["kind"] != "kept" || ev[2]["kind"] != "warn" {
		t.Errorf("kinds %v %v", ev[1], ev[2])
	}
	if ev[5]["rc"] != 3.0 {
		t.Errorf("a step ends in the status it ended with: %v", ev[5])
	}
	if o.Stdout.(*bytes.Buffer).Len() != 0 {
		t.Error("events mode must print nothing on stdout")
	}
}

func TestReportAndRelayInEvents(t *testing.T) {
	o, e := out(true)
	o.Report("", "line 1\nline 2\n")
	o.Relay(strings.NewReader("hello\n\n!! it broke\n"), "      ")
	ev := events(t, e)
	if ev[0]["t"] != "report" || ev[0]["title"] != "report" || ev[0]["text"] != "line 1\nline 2" {
		t.Errorf("report %v", ev[0])
	}
	if len(ev) != 3 || ev[1]["kind"] != "cont" || ev[1]["source"] != "box" || ev[2]["kind"] != "fail" || ev[2]["text"] != "it broke" {
		t.Errorf("relay %v", ev)
	}
}

func TestEventsAreNotHTMLEscaped(t *testing.T) {
	o, e := out(true)
	o.Log("a <b> & c")
	if !strings.Contains(e.String(), `"text":"a <b> & c"`) {
		t.Errorf("escaped: %s", e.String())
	}
}

func TestKind(t *testing.T) {
	for text, want := range map[string]string{
		"  indented":                         "cont",
		"the push failed":                    "fail",
		"could not reach it":                 "fail",
		"nothing to push":                    "skip",
		"NOT registered":                     "warn",
		"stale cache":                        "warn",
		"waiting for the node":               "wait",
		"keeping the budget":                 "kept",
		"box stopped":                        "ok",
		"it guards the account, not the box": "info",
		"broken":                             "info",
		"token":                              "info",
		"instance          running":          "ok",
	} {
		if got := Kind(text); got != want {
			t.Errorf("%q: got %s want %s", text, got, want)
		}
	}
}
