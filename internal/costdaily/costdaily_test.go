package costdaily

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The oracle is what lib/cost-daily.py printed (testdata/capture/cost-daily.sh).
// Tables are compared on their text; JSON on its values, keys and nulls - the
// formatting of a number (110 or 110.0) is not part of the contract.

func rates(known bool) Rates {
	free := 100.0
	r := Rates{FreeGB: &free}
	if known {
		v := 88.0
		r.INRPerUSD = &v
	}
	return r
}

func TestAgainstOracle(t *testing.T) {
	ins, _ := filepath.Glob("../../testdata/cost/in/*.json")
	if len(ins) == 0 {
		t.Fatal("no inputs")
	}
	for _, in := range ins {
		name := strings.TrimSuffix(filepath.Base(in), ".json")
		b, err := os.ReadFile(in)
		if err != nil {
			t.Fatal(err)
		}
		for _, known := range []bool{true, false} {
			rate := map[bool]string{true: "known", false: "unknown"}[known]
			for mode, ext := range map[Mode]string{ModeTable: "table", ModeJSON: "json", ModeAggregate: "aggregate"} {
				t.Run(name+"/"+rate+"/"+ext, func(t *testing.T) {
					want, err := os.ReadFile("../../testdata/cost/oracle/" + name + "." + rate + "." + ext + ".txt")
					if err != nil {
						t.Fatal(err)
					}
					got := Render(mode, b, rates(known))
					if mode == ModeTable {
						if got != string(want) {
							t.Fatalf("table differs\n--- got\n%s--- want\n%s", got, want)
						}
						return
					}
					var g, w any
					if err := json.Unmarshal([]byte(got), &g); err != nil {
						t.Fatalf("got is not JSON: %v\n%s", err, got)
					}
					if err := json.Unmarshal(want, &w); err != nil {
						t.Fatalf("oracle is not JSON: %v", err)
					}
					if !reflect.DeepEqual(g, w) {
						t.Fatalf("JSON differs\n--- got\n%s--- want\n%s", got, want)
					}
				})
			}
		}
	}
}

func TestBrokenAnswerIsSaid(t *testing.T) {
	r := rates(true)
	for mode, want := range map[Mode]string{
		ModeTable: "  (Cost Explorer unavailable)\n", ModeJSON: "{}\n", ModeAggregate: "[]\n"} {
		if got := Render(mode, []byte("not json"), r); got != want {
			t.Errorf("mode %d: got %q want %q", mode, got, want)
		}
	}
}

func TestOnlyARegionPrefixIsStripped(t *testing.T) {
	for in, want := range map[string]string{
		"APS5-BoxUsage:g6.xlarge":   "BoxUsage:g6.xlarge",
		"USE1-APIRequest":           "APIRequest",
		"EU-DataTransfer-Out-Bytes": "DataTransfer-Out-Bytes",
		"DataTransfer-Out-Bytes":    "DataTransfer-Out-Bytes",
		"TimedStorage-ByteHrs":      "TimedStorage-ByteHrs",
		"Requests-Tier1":            "Requests-Tier1",
	} {
		if got := StripRegion(in); got != want {
			t.Errorf("%s: got %s want %s", in, got, want)
		}
	}
	if Bucket("DataTransfer-Out-Bytes") != "egress" || Bucket("TimedStorage-ByteHrs") != "s3" {
		t.Error("unprefixed usage types fell into the wrong column")
	}
}
