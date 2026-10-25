package cost

import (
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

func fp(v float64) *float64 { return &v }

func known[T any](v T) costfacts.Known[T] { return costfacts.Known[T]{V: v, OK: true} }

var rates = pricing.Rates{EBSGBMonth: fp(0.0912), SnapshotGBMonth: fp(0.05), IPv4Hour: fp(0.005), INRPerUSD: fp(88)}

func est(kind string, rate *float64) Estimate {
	return Estimate{Hours: known(10), Kind: kind, HourlyRate: rate,
		DiskGB: known(50.0), DiskGBMon: known(2.0), SnapGB: known(0.0), Day: 15, MonthDays: 30}
}

// The numbers of tests/cost-estimate.sh.
func TestSpotAndOnDemandPricedAtTheirOwnRatePlusIPv4(t *testing.T) {
	spot := est("spot, price now", fp(0.20)).Render(rates)
	for _, want := range []string{"THIS instance only, spot, price now, with its IPv4", "10.0 hrs  $  2.05"} {
		if !strings.Contains(spot, want) {
			t.Errorf("spot lacks %q:\n%s", want, spot)
		}
	}
	od := est("on demand", fp(0.9664)).Render(rates)
	if !strings.Contains(od, "10.0 hrs  $  9.71") {
		t.Errorf("on demand:\n%s", od)
	}
}

func TestAnUnknownPriceIsAQuestionMarkNeverFree(t *testing.T) {
	out := est("on demand", nil).Render(rates)
	if !strings.Contains(out, "10.0 hrs        ?") {
		t.Errorf("an unknown machine price:\n%s", out)
	}
	if strings.Contains(out, "9.66") || strings.Contains(out, "$  0.05") {
		t.Errorf("a price was invented:\n%s", out)
	}
	r := rates
	r.IPv4Hour = nil
	if out := est("on demand", fp(0.9664)).Render(r); !strings.Contains(out, "10.0 hrs        ?") {
		t.Errorf("an unknown IPv4 price must make the line unknown too:\n%s", out)
	}
	if out := est("on demand", fp(0.9664)).Render(rates); !strings.Contains(out, "estimate ") {
		t.Errorf("no estimate line:\n%s", out)
	}
}

func TestAnUnreadableFactIsUnknownNotZero(t *testing.T) {
	e := est("on demand", fp(0.9664))
	e.Hours = costfacts.Known[int]{}
	e.DiskGB = costfacts.Known[float64]{}
	e.DiskGBMon = costfacts.Known[float64]{}
	out := e.Render(rates)
	if !strings.Contains(out, "compute         ? hrs") || !strings.Contains(out, "storage        ? GB") {
		t.Errorf("unreadable facts printed as numbers:\n%s", out)
	}
	if strings.Contains(out, "$  0.00") {
		t.Errorf("an unreadable fact was priced at zero:\n%s", out)
	}
}

func TestEachDiskAccruesFromWhenItWasMade(t *testing.T) {
	now := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	vols := []costfacts.Volume{
		{ID: "old", GB: 50, Created: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}, // since the 1st
		{ID: "new", GB: 100, Created: now.Add(-24 * time.Hour)},                   // yesterday
	}
	got := GBMonths(vols, now)
	month := start.AddDate(0, 1, 0).Sub(start).Seconds()
	want := 50*now.Sub(start).Seconds()/month + 100*86400/month
	if d := got - want; d > 1e-9 || d < -1e-9 {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestNoInstanceSaysEarlierRuntimeIsNotCounted(t *testing.T) {
	e := est("on demand", fp(0.9664))
	e.NoInstance = true
	if out := e.Render(rates); !strings.Contains(out, "no instance exists") {
		t.Errorf("missing note:\n%s", out)
	}
}

func TestSnapshotsShowOnlyWhenThereAreSome(t *testing.T) {
	e := est("on demand", fp(0.9664))
	if strings.Contains(e.Render(rates), "snapshots") {
		t.Error("a zero snapshot line was printed")
	}
	e.SnapGB = known(40.0)
	if out := e.Render(rates); !strings.Contains(out, "at most - AWS bills only the changed blocks") {
		t.Errorf("no snapshot line:\n%s", out)
	}
}
