package boxcmd

import (
	"context"
	"strings"
	"testing"
)

func stdins(r *rig) string {
	var b []string
	for _, v := range r.r.Stdin {
		b = append(b, v)
	}
	return strings.Join(b, "|")
}

func TestClipSendPutsThisClipboardOnTheGamePC(t *testing.T) {
	r := newRig(t, "")
	r.d.GOOS = "linux"
	r.r.Answers = map[string]string{}
	r.r.Installed["wl-paste"] = true
	r.r.Answers["wl-paste --no-newline"] = "a password\nwith two lines"
	if rc := r.d.ClipSend(context.Background()); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	if !strings.Contains(stdins(r), "a password\nwith two lines") {
		t.Errorf("the text is sent as it is, on standard input, never in the command: %v", r.r.Stdin)
	}
	ssh := sshLines(r.r)
	for _, want := range []string{"xclip -selection clipboard -i", "DISPLAY=:0", "apt-get install -y -qq xclip"} {
		if !strings.Contains(ssh, want) {
			t.Errorf("lacks %q in\n%s", want, ssh)
		}
	}
	if strings.Contains(ssh, "a password") {
		t.Error("what is copied must not appear in a command line")
	}
	if !strings.Contains(r.o.String()+r.w.String(), "Paste there with Ctrl+V") {
		t.Errorf("%s%s", r.o, r.w)
	}
}

func TestClipSendSaysWhatToInstallWhenThereIsNoClipboardProgram(t *testing.T) {
	r := newRig(t, "")
	r.d.GOOS = "linux"
	r.r.Answers = map[string]string{}
	if rc := r.d.ClipSend(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "Install wl-clipboard") {
		t.Errorf("rc %d %s", rc, r.w)
	}
}

func TestClipSendRefusesNothingAndTooMuch(t *testing.T) {
	r := newRig(t, "")
	r.d.GOOS = "linux"
	r.r.Answers = map[string]string{}
	r.r.Installed["wl-paste"] = true
	r.r.Answers["wl-paste --no-newline"] = "  \n"
	if rc := r.d.ClipSend(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "empty") {
		t.Errorf("%s", r.w)
	}
	r = newRig(t, "")
	r.d.GOOS = "linux"
	r.r.Answers = map[string]string{}
	r.r.Installed["wl-paste"] = true
	r.r.Answers["wl-paste --no-newline"] = strings.Repeat("x", clipMax+1)
	if rc := r.d.ClipSend(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "more than 1 MB") {
		t.Errorf("%s", r.w)
	}
	if sshLines(r.r) != "" && strings.Contains(sshLines(r.r), "xclip -selection clipboard -i") {
		t.Error("nothing is sent")
	}
}

func TestClipGetBringsTheGamePCsClipboardHere(t *testing.T) {
	r := newRig(t, "")
	r.d.GOOS = "linux"
	r.r.Answers = map[string]string{}
	r.r.Installed["sh"] = true
	r.r.Installed["wl-copy"] = true
	inner := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "xclip -selection clipboard -o") {
			return true, "copied in the game", nil
		}
		return inner(line)
	}
	if rc := r.d.ClipGet(context.Background()); rc != 0 {
		t.Fatalf("%s%s", r.o, r.w)
	}
	if !strings.Contains(stdins(r), "copied in the game") {
		t.Errorf("handed to the clipboard program: %v", r.r.Stdin)
	}
	ran := strings.Join(r.r.Ran, "\n")
	if !strings.Contains(ran, "sh -c wl-copy >/dev/null 2>&1") {
		t.Errorf("its output is sent away so waiting for it ends:\n%s", ran)
	}
}

func TestClipGetEmptyIsSaidNotPasted(t *testing.T) {
	r := newRig(t, "")
	r.d.GOOS = "linux"
	r.r.Answers = map[string]string{}
	r.r.Installed["wl-copy"] = true
	if rc := r.d.ClipGet(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "empty") {
		t.Errorf("%s", r.w)
	}
	if len(r.r.Stdin) != 0 {
		t.Errorf("an empty clipboard must not overwrite yours: %v", r.r.Stdin)
	}
}

func TestClipToolsPerSystem(t *testing.T) {
	if got := clipReaders("darwin")[0].name; got != "pbpaste" {
		t.Error(got)
	}
	if got := clipWriters("windows")[0].name; got != "powershell" {
		t.Error(got)
	}
	if n := len(clipWriters("linux")); n != 3 {
		t.Errorf("Wayland and both X programs: %d", n)
	}
}
