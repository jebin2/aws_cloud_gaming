package watchdog

import (
	"context"
	"os"
	"testing"

	"github.com/jebin2/ayis/internal/config"
)

// TestLiveDeploymentIsCurrent reads the REAL account, so it only runs when asked:
//
//	AYIS_LIVE=1 AYIS_REPO=/path/to/checkout go test ./internal/commands/watchdog -run Live -v
//
// It proves the Go fingerprint, policy and package are the ones the Bash ayis
// deployed: a function it made must read as current here. Read-only and free.
func TestLiveDeploymentIsCurrent(t *testing.T) {
	if os.Getenv("AYIS_LIVE") != "1" {
		t.Skip("set AYIS_LIVE=1 to read the real account")
	}
	env := config.Load(config.OSLookup, os.Getenv("AYIS_REPO"))
	r, err := NewReader(context.Background(), env)
	if err != nil {
		t.Fatal(err)
	}
	r.Source = mustRead(t, os.Getenv("AYIS_REPO")+"/lambda/cloud_watchdog.py")
	st := r.Current(context.Background())
	t.Logf("installed=%v rule=%q drift=%v", st.Installed, st.Rule, st.Drift)
	if len(st.Drift) != 0 {
		t.Errorf("a function deployed by the Bash ayis reads as drifted: %v", st.Drift)
	}
}

func mustRead(t *testing.T, p string) []byte {
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
