package watchdog

import (
	"context"
	"os"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
)

// TestLiveDeploymentIsCurrent reads the REAL account, so it only runs when asked:
//
//	CG_LIVE=1 CG_REPO=/path/to/checkout go test ./internal/commands/watchdog -run Live -v
//
// It proves the Go fingerprint, policy and package are the ones the Bash cg
// deployed: a function it made must read as current here. Read-only and free.
func TestLiveDeploymentIsCurrent(t *testing.T) {
	if os.Getenv("CG_LIVE") != "1" {
		t.Skip("set CG_LIVE=1 to read the real account")
	}
	env := config.Load(config.OSLookup, os.Getenv("CG_REPO"))
	r, err := NewReader(context.Background(), env)
	if err != nil {
		t.Fatal(err)
	}
	r.Source = mustRead(t, os.Getenv("CG_REPO")+"/lambda/cloud_watchdog.py")
	st := r.Current(context.Background())
	t.Logf("installed=%v rule=%q drift=%v", st.Installed, st.Rule, st.Drift)
	if len(st.Drift) != 0 {
		t.Errorf("a function deployed by the Bash cg reads as drifted: %v", st.Drift)
	}
}

func mustRead(t *testing.T, p string) []byte {
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
