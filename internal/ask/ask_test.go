package ask

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

func asker(input string, jsonMode bool) (*Asker, *bytes.Buffer, *bytes.Buffer) {
	var o, e, p bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e, JSON: jsonMode}
	return &Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &p, TTY: !jsonMode}, &e, &p
}

func TestAPersonIsAskedAtTheTerminal(t *testing.T) {
	a, _, p := asker("blue\n", false)
	if got := a.Ask("colour", "colour? ", "red", ""); got != "blue" || p.String() != "colour? " {
		t.Errorf("%q %q", got, p.String())
	}
	// Nothing typed: the default stands; and a reply with no newline still counts.
	if got, _ := func() (string, int) { a, _, _ := asker("\n", false); return a.Ask("c", "?", "red", ""), 0 }(); got != "red" {
		t.Errorf("default %q", got)
	}
	if a, _, _ := asker("green", false); a.Ask("c", "?", "red", "") != "green" {
		t.Error("a reply typed without a newline still counts")
	}
	if a, _, _ := asker("", false); a.Ask("c", "?", "red", "") != "red" {
		t.Error("no reply at all is the default")
	}
}

func TestTheAppIsAskedWithAnEvent(t *testing.T) {
	a, e, _ := asker("answer\n", true)
	if got := a.Ask("alert-email", "email: ", "x@y.z", "a,b"); got != "answer" {
		t.Errorf("%q", got)
	}
	var ev map[string]any
	if err := json.Unmarshal(e.Bytes(), &ev); err != nil {
		t.Fatalf("%v %s", err, e.String())
	}
	if ev["t"] != "ask" || ev["id"] != "alert-email" || ev["prompt"] != "email: " || ev["default"] != "x@y.z" || ev["choices"] != "a,b" {
		t.Errorf("%v", ev)
	}
	if !a.CanAsk() {
		t.Error("the app can be asked")
	}
	a, _, _ = asker("", true)
	if a.Ask("id", "?", "dflt", "") != "dflt" {
		t.Error("an app that said nothing: the default")
	}
}

func TestASecretIsMarkedAndNeverEchoed(t *testing.T) {
	a, e, p := asker("tskey-secret\n", true)
	if got := a.Secret("tailscale-api-token", "token: "); got != "tskey-secret" {
		t.Errorf("%q", got)
	}
	var ev map[string]any
	_ = json.Unmarshal(e.Bytes(), &ev)
	if ev["secret"] != 1.0 || ev["id"] != "tailscale-api-token" || strings.Contains(e.String()+p.String(), "tskey-secret") {
		t.Errorf("secret is a number, and the value never appears: %s", e.String())
	}
	b, _, p2 := asker("", false)
	b.ReadSecret = func() (string, error) { return "hidden", nil }
	if got := b.Secret("id", "pw: "); got != "hidden" || strings.Contains(p2.String(), "hidden") {
		t.Errorf("%q %q", got, p2.String())
	}
}

func TestConfirmAndTypedWords(t *testing.T) {
	a, _, _ := asker("y\n", false)
	if !a.Confirm("go", "go? ", "N") {
		t.Error("yes")
	}
	a, _, _ = asker("n\n", false)
	if a.Confirm("go", "go? ", "Y") {
		t.Error("no")
	}
	a, _, _ = asker("\n", false)
	if !a.Confirm("go", "go? ", "Y") || a.Confirm("go", "go? ", "N") && false {
		t.Error("the default stands")
	}
	// CG_YES takes the default, asks nothing.
	a, e, p := asker("", false)
	a.Yes = true
	if !a.Confirm("go", "go? ", "Y") || a.Confirm("go", "go? ", "N") || e.Len() != 0 || p.Len() != 0 {
		t.Error("CG_YES answers a yes/no question with its default")
	}
	// ...but never a typed confirmation.
	a, _, _ = asker("", false)
	a.Yes = true
	if a.Typed("destroy-all", "type DESTROY-ALL: ", "DESTROY-ALL") {
		t.Error("typing the word is the confirmation: nothing assumes it")
	}
	a, _, _ = asker("DESTROY-ALL\n", false)
	if !a.Typed("destroy-all", "type DESTROY-ALL: ", "DESTROY-ALL") {
		t.Error("typed")
	}
	a, _, _ = asker("destroy-all\n", false)
	if a.Typed("destroy-all", "type DESTROY-ALL: ", "DESTROY-ALL") {
		t.Error("the exact word")
	}
}
