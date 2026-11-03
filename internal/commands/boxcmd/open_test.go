package boxcmd

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestOpenWaitsForAMachineThatIsStillSavingBeforeItStartsIt(t *testing.T) {
	r := newRig(t, "")
	r.e.state, r.e.stoppingPolls = "stopping", 4
	if rc := r.d.Open(context.Background()); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.w)
	}
	if !strings.Contains(r.o.String(), "still shutting down and saving your games") {
		t.Errorf("it says why it waits:\n%s", r.o)
	}
	if strings.Join(r.e.calls, ",") != "start" {
		t.Errorf("started once, and only after it had stopped: %v", r.e.calls)
	}
}

func TestOpenGivesUpPlainlyOnAMachineThatNeverStops(t *testing.T) {
	r := newRig(t, "")
	r.e.state, r.e.stoppingPolls = "stopping", 1<<30
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "still shutting down") {
		t.Errorf("%s", r.w)
	}
	if len(r.e.calls) != 0 {
		t.Errorf("nothing is asked of AWS meanwhile: %v", r.e.calls)
	}
}

func TestAnAllowanceRefusalToStartIsSaidInPlainWords(t *testing.T) {
	r := newRig(t, "")
	r.e.state, r.e.startErr = "stopped", errors.New("api error VcpuLimitExceeded: You have requested more vCPU capacity than your current vCPU limit of 4")
	if rc := r.d.Open(context.Background()); rc != 1 || !strings.Contains(r.w.String(), "allowance for game PCs here is all in use") || strings.Contains(r.w.String(), "contact-us") {
		t.Errorf("%s", r.w)
	}
}
