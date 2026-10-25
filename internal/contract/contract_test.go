package contract

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// testdata/contract/contract.json is what the Bash `cg --contract` printed.
func TestContractMatchesTheBashOne(t *testing.T) {
	want, err := os.ReadFile("../../testdata/contract/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	got, err := JSON()
	if err != nil {
		t.Fatal(err)
	}
	var g, w any
	if err := json.Unmarshal(got, &g); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(want, &w); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(g, w) {
		t.Fatalf("contract differs\n--- got\n%s\n--- want\n%s", got, want)
	}
}

func TestEveryRegisteredCommandHasASummary(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range Registry {
		key := ""
		for _, p := range c.Path {
			key += p + " "
		}
		if c.Summary == "" {
			t.Errorf("%s has no summary", key)
		}
		if seen[key] {
			t.Errorf("%s is registered twice", key)
		}
		seen[key] = true
	}
}
