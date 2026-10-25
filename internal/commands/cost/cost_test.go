package cost

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

const host = "gamevps"

var now = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

// box is tests/cost-estimate.sh's account: one g6.xlarge (spot, or on demand),
// its 100 GB disk made on the 1st, a 50 GB cg leftover made today, and another
// project's 500 GB disk.
func box(onDemand bool) *fx.Scenario {
	s := &fx.Scenario{
		Account: "123456789012", KeyPair: true, SecGroup: true, SpotPrice: "0.2000", CPUHours: 10,
		Credits: 122.29, Budget: "50", Bucket: "cg-library-test",
		Instances: []fx.Instance{{ID: "i-box", State: "running", Type: "g6.xlarge", Lifecycle: "spot", AZ: "ap-south-2a", Name: host}},
		Volumes: []fx.Volume{
			{ID: "vol-root", State: "in-use", GB: 100, Instance: "i-box", Created: time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)},
			{ID: "vol-left", State: "available", GB: 50, Created: now.Truncate(24 * time.Hour), Tags: map[string]string{"cg:host": host}},
			{ID: "vol-theirs", State: "available", GB: 500, Created: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)},
		},
	}
	if onDemand {
		s.Instances[0].Lifecycle = ""
	}
	return s
}

func gather(t *testing.T, s *fx.Scenario) costfacts.Facts {
	t.Helper()
	g := &costfacts.Gatherer{
		EC2: fx.EC2{S: s}, CloudWatch: fx.CloudWatch{S: s}, CE: fx.CE{S: s}, Budgets: fx.Budgets{S: s},
		FreeTier: fx.FreeTier{S: s}, S3: fx.S3{S: s}, STS: fx.STS{S: s},
		Host: host, Bucket: s.Bucket, Now: func() time.Time { return now },
	}
	f, err := g.Gather(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func fl(v float64) *float64 { return &v }

var prices = pricing.Rates{S3GBMonth: fl(0.025), EBSGBMonth: fl(0.0912), SnapshotGBMonth: fl(0.05),
	EgressGB: fl(0.1093), CECallUSD: fl(0.01), IPv4Hour: fl(0.005), EgressFreeGB: 100,
	INRPerUSD: fl(88), FXINRPerUSD: fl(88)}

func inputs(f costfacts.Facts, rate *float64) Inputs {
	return Inputs{Facts: f, Rates: prices, Host: host, Region: "ap-south-2", ConfiguredType: "g6.xlarge",
		OnDemandRate: rate, Now: now}
}

func has(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
}

func lacks(t *testing.T, out string, bad ...string) {
	t.Helper()
	for _, w := range bad {
		if strings.Contains(out, w) {
			t.Errorf("output has %q:\n%s", w, out)
		}
	}
}

func TestTheMachineAsItIs(t *testing.T) {
	out := inputs(gather(t, box(false)), fl(0.9664)).Human(false, "")
	has(t, out, "THIS instance only, spot, price now", "10.0 hrs  $  2.05")
	out = inputs(gather(t, box(true)), fl(0.9664)).Human(false, "")
	has(t, out, "THIS instance only, on demand", "10.0 hrs  $  9.71")
	out = inputs(gather(t, box(true)), nil).Human(false, "")
	has(t, out, "10.0 hrs        ?")
	lacks(t, out, "9.71")
}

func TestOnlyCgsDisksAreCounted(t *testing.T) {
	out := inputs(gather(t, box(false)), fl(0.9664)).Human(false, "")
	has(t, out, "volumes         150 GB")
	lacks(t, out, "650 GB")
}

func TestStorageAccruesEachDiskFromWhenItWasMade(t *testing.T) {
	in := inputs(gather(t, box(false)), fl(0.9664))
	start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	month := 31 * 86400.0
	want := (100*now.Sub(start).Seconds()/month + 50*float64(12*3600)/month) * 0.0912
	has(t, in.Human(false, ""), fmt.Sprintf("$ %5.2f", want))
}

func TestResourcesBlock(t *testing.T) {
	out := inputs(gather(t, box(false)), fl(0.9664)).Human(false, "")
	has(t, out, "resources in ap-south-2:", "instance        i-box  (running)", "key pair        gamevps",
		"security group  gamevps-sg", "budget          $50/month", "credits remaining: $122.29",
		"game library    s3://cg-library-test  EMPTY") // the bucket exists and holds nothing
}

func TestNoMachineSaysWhatItCoversAndOrphansAreFlagged(t *testing.T) {
	s := box(false)
	s.Instances = nil
	s.Volumes = []fx.Volume{{ID: "vol-left", State: "available", GB: 50, Created: now, Tags: map[string]string{"cg:host": host}}}
	out := inputs(gather(t, s), fl(0.9664)).Human(false, "")
	has(t, out, "instance        none", "<- ORPHANED, still billing", "no instance exists")
	s.Volumes = nil
	out = inputs(gather(t, s), fl(0.9664)).Human(false, "")
	has(t, out, "no machine, disks, snapshots or images in ap-south-2.")
	lacks(t, out, "ORPHANED")
}

func TestAnUnreadableFactIsNeverZeroOrNone(t *testing.T) {
	s := box(false)
	s.Fail = map[string]bool{"DescribeVolumes": true, "DescribeImages": true, "DescribeKeyPairs": true, "GetCostAndUsage": true}
	out := inputs(gather(t, s), fl(0.9664)).Human(false, "")
	has(t, out, "volumes         ? GB", "images          ?", "key pair        ?", "(Cost Explorer unavailable)")
	lacks(t, out, "ORPHANED", "no machine, disks", "key pair        none")
	b, _ := inputs(gather(t, s), fl(0.9664)).JSON()
	var j map[string]any
	if err := json.Unmarshal(b, &j); err != nil {
		t.Fatal(err)
	}
	res := j["resources"].(map[string]any)
	for _, k := range []string{"volumes_gb", "images", "key_pair", "snapshots_gb"} {
		if res[k] != nil {
			t.Errorf("%s should be null when AWS could not be asked, got %v", k, res[k])
		}
	}
	if j["standby"].(map[string]any)["usd_month"] != nil {
		t.Error("standby must be unknown when a part of it is")
	}
}

func TestTheArchiveIsTheGamesOnly(t *testing.T) {
	s := box(false)
	s.Objects = []fx.Object{{Key: "steam/account/login.tar", Size: 22645}}
	out := inputs(gather(t, s), nil).Human(false, "")
	has(t, out, "game library    s3://cg-library-test  EMPTY - no games archived")
	s.Objects = append(s.Objects, fx.Object{Key: "steam/steamapps/common/g/a.bin", Size: 171986001052})
	out = inputs(gather(t, s), nil).Human(false, "")
	has(t, out, "1 objects, 161GB  ($4.00/mo)")
}

func TestABucketThatCannotBeReadIsNotEmpty(t *testing.T) {
	s := box(false)
	s.BucketGone = true
	has(t, inputs(gather(t, s), nil).Human(false, ""), "none - s3://cg-library-test does not exist")
	s = box(false)
	s.Denied = true
	out := inputs(gather(t, s), nil).Human(false, "")
	has(t, out, "COULD NOT BE READ")
	lacks(t, out, "EMPTY")
	s = box(false)
	s.Fail = map[string]bool{"ListObjectsV2": true}
	out = inputs(gather(t, s), nil).Human(false, "")
	has(t, out, "COULD NOT BE LISTED")
	lacks(t, out, "EMPTY")
}

func TestAWSRefusingEndsItWithItsOwnWords(t *testing.T) {
	s := box(false)
	s.Fail = map[string]bool{"GetCallerIdentity": true}
	g := &costfacts.Gatherer{STS: fx.STS{S: s}, Host: host}
	_, err := g.Gather(context.Background())
	var refused *costfacts.AWSRefused
	if err == nil || !strings.Contains(err.Error(), "AWS did not answer") {
		t.Fatalf("got %v", err)
	}
	_ = refused
}

// tests/cost-daily.sh "4e. storage as the bill sees it": a region move left the
// games in a bucket cg no longer looks at.
func TestStorageAsTheBillSeesIt(t *testing.T) {
	d := func(back int) string { return now.AddDate(0, 0, -back).Format("2006-01-02") }
	s := &fx.Scenario{Account: "1", Bucket: "", Month: []fx.Day{
		{Date: d(3), Usage: map[string][2]string{"APS2-TimedStorage-ByteHrs": {"0.12", "5"}}},
		{Date: d(2), Usage: map[string][2]string{"APS2-TimedStorage-ByteHrs": {"0.13", "5"}}},
		{Date: d(1), Usage: map[string][2]string{"APS2-TimedStorage-ByteHrs": {"0.05", "2"}}},
		{Date: d(0), Usage: map[string][2]string{"APS2-TimedStorage-ByteHrs": {"0.01", "1"}}},
	}}
	j := func(s *fx.Scenario) map[string]any {
		b, err := inputs(gather(t, s), nil).JSON()
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		return m["storage"].(map[string]any)
	}
	st := j(s)
	if st["billed_usd_month"] != 3.9 || st["known_usd_month"] != 0.0 || st["unknown_usd_month"] != 3.9 {
		t.Errorf("the bill's storage, a month of the busiest recent whole day: %v", st)
	}
	// A bucket that explains it leaves nothing over.
	s.Bucket = "b"
	s.Objects = []fx.Object{{Key: "steam/steamapps/x", Size: 171986001052}}
	if st := j(s); st["unknown_usd_month"] != 0.0 {
		t.Errorf("a bucket that explains it leaves nothing over: %v", st)
	}
	// An S3 price AWS did not answer: nothing known, so nothing claimed elsewhere.
	in := inputs(gather(t, s), nil)
	in.Rates.S3GBMonth = nil
	b, _ := in.JSON()
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	st = m["storage"].(map[string]any)
	if st["known_usd_month"] != nil || st["unknown_usd_month"] != nil {
		t.Errorf("an unknown S3 price explains nothing known: %v", st)
	}
}

func TestBudgetWarning(t *testing.T) {
	s := box(false)
	s.Budget = ""
	has(t, inputs(gather(t, s), nil).Human(false, ""), "budget          none", "WARNING: no budget exists")
}

func TestOneCostExplorerCall(t *testing.T) {
	s := box(false)
	in := inputs(gather(t, s), nil)
	in.Human(true, "")
	if s.Calls["GetCostAndUsage"] != 1 {
		t.Errorf("Cost Explorer bills $0.01 a call; made %d", s.Calls["GetCostAndUsage"])
	}
}
