package local

import (
	"errors"
	"testing"
)

func TestFindPrefersPathThenWhereTheInstallerPutsIt(t *testing.T) {
	none := func(string) (string, error) { return "", errors.New("not found") }
	env := func(k string) string { return map[string]string{"ProgramFiles": `C:\Program Files`}[k] }
	all := func(string) bool { return true }
	// On PATH: that one, whatever the system.
	if got := find("darwin", "moonlight", env, func(string) (string, error) { return "/usr/bin/moonlight", nil }, all); got != "/usr/bin/moonlight" {
		t.Errorf("%q", got)
	}
	// Not on PATH: the application the installer made.
	if got := find("darwin", "moonlight", env, none, all); got != "/Applications/Moonlight.app/Contents/MacOS/Moonlight" {
		t.Errorf("%q", got)
	}
	if got := find("windows", "moonlight", env, none, all); got != `C:\Program Files/Moonlight Game Streaming\Moonlight.exe` && got != `C:\Program Files\Moonlight Game Streaming\Moonlight.exe` {
		t.Errorf("%q", got)
	}
	// Not there either: the name, so the error names what was asked for.
	if got := find("darwin", "moonlight", env, none, func(string) bool { return false }); got != "moonlight" {
		t.Errorf("%q", got)
	}
	// Linux has no such places.
	if got := find("linux", "moonlight", env, none, all); got != "moonlight" {
		t.Errorf("%q", got)
	}
}

func TestHomebrewIsFoundOnAMacWithABarePath(t *testing.T) {
	none := func(string) (string, error) { return "", errors.New("not found") }
	got := find("darwin", "brew", func(string) string { return "" }, none, func(p string) bool { return p == "/usr/local/bin/brew" })
	if got != "/usr/local/bin/brew" {
		t.Errorf("%q", got)
	}
}
