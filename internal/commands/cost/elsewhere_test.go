package cost

import (
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

func i64(v int64) *int64  { return &v }
func sp(s string) *string { return &s }

func TestNothingOfCgsElsewhere(t *testing.T) {
	places := []library.Place{}
	got := OtherRegions(library.Elsewhere{Places: &places}, storage.Everywhere{Found: []storage.Found{{Region: "ap-south-1"}, {Region: "us-east-1"}}}, "ap-south-1", rates)
	if got != "other regions:\n  nothing of cg's\n" {
		t.Errorf("%q", got)
	}
}

func TestWhatARegionMoveLeftBehind(t *testing.T) {
	places := []library.Place{{Bucket: "b", Region: sp("ap-south-2"), Bytes: i64(160 << 30), USDMonth: fp(4)}}
	st := storage.Everywhere{Found: []storage.Found{
		{Region: "ap-south-1", Volumes: []costfacts.Volume{{ID: "vol-here", GB: 50}}}, // here: this report covered it
		{Region: "ap-south-2",
			Volumes:   []costfacts.Volume{{ID: "vol-old", GB: 100}},
			Images:    []costfacts.Image{{ID: "ami-1", Snapshots: []costfacts.Snapshot{{ID: "snap-a", GB: 30}, {ID: "snap-b", GB: 20}}}},
			Snapshots: []costfacts.Snapshot{{ID: "snap-loose", GB: 10}}},
	}}
	got := OtherRegions(library.Elsewhere{Places: &places}, st, "ap-south-1", rates)
	for _, want := range []string{"other regions:\n", "  saved games     160.0 GB in ap-south-2  ($4.00/mo)\n",
		"  disk            vol-old, 100 GB in ap-south-2  ($9.12/mo)\n", "  image           ami-1, 50 GB in ap-south-2  ($2.50/mo)\n",
		"  snapshot        snap-loose, 10 GB in ap-south-2  ($0.50/mo)\n", "  removed by: cg aws disconnect\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "vol-here") {
		t.Error("this region is the report's, not 'elsewhere'")
	}
	// An unknown price leaves the cost off, never a zero.
	got = OtherRegions(library.Elsewhere{Places: &[]library.Place{}}, st, "ap-south-1", pricing.Rates{})
	if !strings.Contains(got, "disk            vol-old, 100 GB in ap-south-2\n") || strings.Contains(got, "$0.00") {
		t.Errorf("%s", got)
	}
}

// The Bash printed "nothing of cg's" when the library scan had failed, and read
// a failed region list as none.
func TestAFailedReadIsNeverNothing(t *testing.T) {
	msg := "could not list your buckets - AWS did not answer"
	got := OtherRegions(library.Elsewhere{Error: &msg}, storage.Everywhere{}, "ap-south-1", rates)
	if strings.Contains(got, "nothing of cg's") || !strings.Contains(got, "could not be read - could not list your buckets") {
		t.Errorf("%s", got)
	}
	places := []library.Place{}
	got = OtherRegions(library.Elsewhere{Places: &places}, storage.Everywhere{Failed: []string{"eu-west-1", "us-east-1"}}, "ap-south-1", rates)
	if strings.Contains(got, "nothing of cg's") || !strings.Contains(got, "could not be read - eu-west-1, us-east-1") {
		t.Errorf("%s", got)
	}
	// Something found, and a region unreadable: both are said.
	got = OtherRegions(library.Elsewhere{Places: &[]library.Place{{Bucket: "b", Bytes: i64(1 << 30), Region: sp("x")}}}, storage.Everywhere{Failed: []string{"eu-west-1"}}, "ap-south-1", rates)
	if !strings.Contains(got, "saved games") || !strings.Contains(got, "could not be read: eu-west-1") {
		t.Errorf("%s", got)
	}
}
