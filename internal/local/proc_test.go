package local

import (
	"os"
	"strings"
	"testing"
)

func TestOwnProcessIsAliveAndHasACommandLine(t *testing.T) {
	if !Alive(os.Getpid()) {
		t.Error("this process is alive")
	}
	if Alive(0x3ffffff0) {
		t.Error("no such process")
	}
	args, ok := Args(os.Getpid())
	if !ok || !strings.Contains(strings.ToLower(args), "test") {
		t.Errorf("%q %v", args, ok)
	}
	if home := Home(func(k string) (string, bool) { return map[string]string{"HOME": "/h"}[k], k == "HOME" }); home != "/h" {
		t.Errorf("%q", home)
	}
	if got := ConfigBase(func(k string) (string, bool) {
		return map[string]string{"XDG_CONFIG_HOME": "/c"}[k], k == "XDG_CONFIG_HOME"
	}); got != "/c" {
		t.Errorf("%q", got)
	}
}
