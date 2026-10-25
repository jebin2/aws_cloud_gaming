package costreport

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/costdaily"
)

func f(v float64) *float64 { return &v }

var variants = map[string]Settings{
	"all":             {INRPerUSD: f(88), EgressUSD: f(0.1093), FreeGB: f(100)},
	"no-inr":          {EgressUSD: f(0.1093), FreeGB: f(100)},
	"no-egress-price": {INRPerUSD: f(88), FreeGB: f(100)},
	"no-free":         {INRPerUSD: f(88), EgressUSD: f(0.1093)},
}

func TestAgainstOracle(t *testing.T) {
	ins, _ := filepath.Glob("../../testdata/cost/in/*.json")
	for _, in := range ins {
		name := strings.TrimSuffix(filepath.Base(in), ".json")
		b, _ := os.ReadFile(in)
		days, err := costdaily.Parse(b)
		var usage []costdaily.Usage
		if err == nil {
			usage = costdaily.Aggregate(days)
		}
		for v, s := range variants {
			t.Run(name+"/"+v, func(t *testing.T) {
				want, err := os.ReadFile("../../testdata/cost/report-oracle/" + name + "." + v + ".txt")
				if err != nil {
					t.Fatal(err)
				}
				if got := Render(usage, s, nil); got != string(want) {
					t.Fatalf("differs\n--- got\n%s--- want\n%s", got, want)
				}
			})
		}
	}
}

func TestSubCentChargesStillShowTheirTotal(t *testing.T) {
	usage := []costdaily.Usage{
		{U: "Requests-Tier1", C: 0.004, Q: 800},
		{U: "Requests-Tier2", C: 0.004, Q: 9000},
		{U: "APS5-CW:Requests", C: 0.004, Q: 400},
	}
	got := Render(usage, variants["all"], nil)
	if strings.Contains(got, "nothing billed yet") {
		t.Fatalf("a bill of 1.2 cents was reported as nothing:\n%s", got)
	}
	if !strings.Contains(got, "TOTAL") || !strings.Contains(got, "0.01") {
		t.Fatalf("the total is missing:\n%s", got)
	}
	if !strings.Contains(got, "under half a cent") {
		t.Fatalf("the hidden rows are not explained:\n%s", got)
	}
}

func TestNothingBilledIsStillNothing(t *testing.T) {
	if got := Render(nil, variants["all"], nil); got != "  nothing billed yet this month\n" {
		t.Fatalf("got %q", got)
	}
}

func TestEgressIsToldToTheCache(t *testing.T) {
	days, _ := costdaily.Parse([]byte(`[{"d":"2026-09-20","g":[{"u":"DataTransfer-Out-Bytes","c":"0","q":"9.4"}]}]`))
	var gotGB float64
	var gotFree *float64
	Render(costdaily.Aggregate(days), variants["all"], func(gb float64, free *float64) { gotGB, gotFree = gb, free })
	if gotGB != 9.4 || gotFree == nil || *gotFree != 100 {
		t.Fatalf("cache got %v %v", gotGB, gotFree)
	}
}
