package output

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// A progress line from the box must not read as a failure. The box said
// "disabling nvidia DRM KMS (NvFBC cannot capture with it on)", which has the
// word "cannot", so a healthy build showed its driver step as failed in red.
// Every progress line in the bootstrap modules is checked here.
func TestNoBootstrapProgressLineReadsAsAFailure(t *testing.T) {
	files, _ := filepath.Glob("../../lib/bootstrap.d/*.sh")
	re := regexp.MustCompile(`(?m)^\s*progress "([^"$]+)"`)
	n := 0
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range re.FindAllStringSubmatch(string(b), -1) {
			n++
			if Kind(m[1]) == "fail" {
				t.Errorf("reads as a failure: %s", m[1])
			}
		}
	}
	if n <= 10 {
		t.Fatalf("found only %d progress lines - did the pattern stop matching?", n)
	}
}
