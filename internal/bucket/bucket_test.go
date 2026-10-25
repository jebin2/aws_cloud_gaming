package bucket

import (
	"os/exec"
	"strings"
	"testing"
)

// The name must be what the Bash cg derives: sha256 of "account-host-region",
// the first 12 hex digits. A different formula would watch a bucket that does
// not exist and never see the real one.
func TestNameMatchesTheBashFormula(t *testing.T) {
	out, err := exec.Command("bash", "-c", `printf '%s' "123456789012-gamevps-ap-south-2" | sha256sum | cut -c1-12`).Output()
	if err != nil {
		t.Skip("no bash")
	}
	if got, want := Name("123456789012", "gamevps", "ap-south-2"), "cg-library-"+strings.TrimSpace(string(out)); got != want {
		t.Errorf("got %s want %s", got, want)
	}
	if Name("1", "h", "ap-south-1") == Name("1", "h", "ap-south-2") {
		t.Error("the region must be in the hash")
	}
}
