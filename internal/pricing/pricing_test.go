package pricing

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func product(usage string, tiers ...[2]string) string {
	dims := ""
	for i, t := range tiers {
		if i > 0 {
			dims += ","
		}
		dims += fmt.Sprintf(`"d%d":{"beginRange":%q,"pricePerUnit":{"USD":%q}}`, i, t[0], t[1])
	}
	return fmt.Sprintf(`{"product":{"attributes":{"usagetype":%q}},"terms":{"OnDemand":{"t":{"priceDimensions":{%s}}}}}`, usage, dims)
}

// fakeProducts is the Price List for a region billed as APS2-.
type fakeProducts struct {
	prefix string
	calls  atomic.Int32
	fail   bool
	omit   string // a usage type left out
}

func (f *fakeProducts) Products(_ context.Context, service string, flt [][2]string) ([]string, error) {
	f.calls.Add(1)
	if f.fail {
		return nil, errors.New("down")
	}
	var usage string
	for _, x := range flt {
		if x[0] == "usagetype" {
			usage = x[1]
		}
	}
	if service == "AmazonEC2" && usage == "" {
		// The disk: a free tier first, then the paid one, which is the price.
		return []string{product(f.prefix+"EBS:VolumeUsage.gp3", [2]string{"0", "0.0000000000"}, [2]string{"0", "0.0912"})}, nil
	}
	if usage == f.omit {
		return nil, nil
	}
	price := map[string]string{
		f.prefix + "EBS:SnapshotUsage":              "0.05",
		f.prefix + "TimedStorage-ByteHrs":           "0.025",
		f.prefix + "PublicIPv4:InUseAddress":        "0.005",
		f.prefix + "AWS-Out-Bytes":                  "0.086",
		"USE1-APIRequest":                           "0.01",
		f.prefix + "DataTransfer-Out-Bytes":         "0.1093",
		"USE1-" + f.prefix + "TimedStorage-ByteHrs": "0.023",
	}[usage]
	if price == "" {
		return nil, nil
	}
	// Data out: 100 GB free (not listed), then the first paid tier, then cheaper.
	if strings.HasSuffix(usage, "DataTransfer-Out-Bytes") {
		return []string{product(usage, [2]string{"10240", "0.085"}, [2]string{"100", "0.1093"})}, nil
	}
	return []string{product(usage, [2]string{"0", price})}, nil
}

func fakeSource(p *fakeProducts, fx float64, fxErr error) Source {
	return stub{AWSSource{API: p}, fx, fxErr}
}

type stub struct {
	AWSSource
	fx    float64
	fxErr error
}

func (s stub) FX(context.Context) (float64, error) { return s.fx, s.fxErr }

func opts(t *testing.T, src Source, env map[string]string) Options {
	return Options{
		Getenv:   func(k string) string { return env[k] },
		CacheDir: t.TempDir(),
		Source:   src,
	}
}

func eq(t *testing.T, name string, got *float64, want float64) {
	t.Helper()
	if got == nil || *got != want {
		t.Errorf("%s: got %v want %v", name, got, want)
	}
}

func TestPricesComeFromTheirFirstPaidTier(t *testing.T) {
	m, err := AWSSource{API: &fakeProducts{prefix: "APS2-"}}.Prices(context.Background(), "ap-south-2")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]float64{
		"CG_EBS_USD_GB_MONTH": 0.0912, "CG_SNAPSHOT_USD_GB_MONTH": 0.05, "CG_S3_USD_GB_MONTH": 0.025,
		"CG_IPV4_USD_HOUR": 0.005, "CG_EGRESS_USD_GB": 0.1093, "CG_XREGION_USD_GB": 0.086, "CG_CE_CALL_USD": 0.01,
	}
	for k, v := range want {
		if m[k] != v {
			t.Errorf("%s: got %v want %v", k, m[k], v)
		}
	}
}

func TestAHalfReadTableIsAFailure(t *testing.T) {
	_, err := AWSSource{API: &fakeProducts{prefix: "APS2-", omit: "APS2-PublicIPv4:InUseAddress"}}.Prices(context.Background(), "ap-south-2")
	if err == nil {
		t.Fatal("a table missing a price was accepted")
	}
	if _, err := (AWSSource{API: &fakeProducts{fail: true}}).Prices(context.Background(), "ap-south-2"); err == nil {
		t.Fatal("AWS being down was not an error")
	}
}

func TestUSEast1MixesPrefixes(t *testing.T) {
	// us-east-1 bills its disks with no prefix and the rest as USE1-.
	p := &fakeProducts{prefix: ""}
	m, err := AWSSource{API: p}.Prices(context.Background(), "us-east-1")
	if err != nil {
		t.Fatal(err)
	}
	if m["CG_CE_CALL_USD"] != 0.01 {
		t.Errorf("CE price %v", m["CG_CE_CALL_USD"])
	}
}

func TestFromAWSKeptADay(t *testing.T) {
	p := &fakeProducts{prefix: "APS2-"}
	o := opts(t, fakeSource(p, 100, nil), map[string]string{"CG_TAX_PCT": "0"})
	r := Load(context.Background(), o, "ap-south-2")
	eq(t, "snapshot", r.SnapshotGBMonth, 0.05)
	eq(t, "s3", r.S3GBMonth, 0.025)
	eq(t, "rupees", r.INRPerUSD, 100)
	if b, _ := os.ReadFile(filepath.Join(o.CacheDir, "prices-ap-south-2")); strings.Count(string(b), "\n") != 7 {
		t.Errorf("cache has %q", b)
	}
	n := p.calls.Load()
	Load(context.Background(), o, "ap-south-2")
	if p.calls.Load() != n {
		t.Error("the same day, AWS was asked again")
	}
	// A day old and AWS down: the last answer stands.
	old := time.Now().Add(-48 * time.Hour)
	_ = os.Chtimes(filepath.Join(o.CacheDir, "prices-ap-south-2"), old, old)
	o.Source = fakeSource(&fakeProducts{fail: true}, 100, nil)
	r = Load(context.Background(), o, "ap-south-2")
	eq(t, "stale price", r.S3GBMonth, 0.025)
}

func TestNeverReadAndAWSDownIsUnknown(t *testing.T) {
	o := opts(t, fakeSource(&fakeProducts{fail: true}, 100, errors.New("x")), map[string]string{"CG_TAX_PCT": "0"})
	r := Load(context.Background(), o, "ap-south-2")
	if r.S3GBMonth != nil || r.SnapshotGBMonth != nil || r.INRPerUSD != nil {
		t.Errorf("a price was invented: %+v", r)
	}
}

func TestAPriceSetByHandWins(t *testing.T) {
	o := opts(t, fakeSource(&fakeProducts{prefix: "APS2-"}, 100, nil), map[string]string{"CG_TAX_PCT": "0", "CG_S3_USD_GB_MONTH": "0.5"})
	r := Load(context.Background(), o, "ap-south-2")
	eq(t, "snapshot", r.SnapshotGBMonth, 0.05)
	eq(t, "s3 by hand", r.S3GBMonth, 0.5)
}

func TestAPricesFileAnswersOffline(t *testing.T) {
	f := filepath.Join(t.TempDir(), "p.env")
	_ = os.WriteFile(f, []byte("CG_S3_USD_GB_MONTH=0.025\nCG_TAX_PCT=0\nCG_EGRESS_FREE_GB=100\n"), 0o644)
	o := opts(t, nil, map[string]string{"CG_PRICES_FILE": f, "CG_INR_PER_USD": "88"})
	r := Load(context.Background(), o, "ap-south-2")
	eq(t, "s3", r.S3GBMonth, 0.025)
	eq(t, "tax from the file", &r.TaxPct, 0)
	eq(t, "rupees", r.INRPerUSD, 88)
	if r.SnapshotGBMonth != nil {
		t.Error("a price not in the file was invented")
	}
	eq(t, "another region, same file", For(context.Background(), o, "ap-south-1", "CG_S3_USD_GB_MONTH"), 0.025)
}

func TestGST(t *testing.T) {
	for _, c := range []struct {
		inr, tax string
		fx, want float64
	}{{"100", "18", 100, 118}, {"94.95", "0", 94.95, 94.95}} {
		o := opts(t, nil, map[string]string{"CG_INR_PER_USD": c.inr, "CG_TAX_PCT": c.tax, "CG_PRICES_FILE": "/nonexistent"})
		r := Load(context.Background(), o, "x")
		eq(t, "exchange rate", r.FXINRPerUSD, c.fx)
		if r.INRPerUSD == nil || fmt.Sprintf("%.2f", *r.INRPerUSD) != fmt.Sprintf("%.2f", c.want) {
			t.Errorf("tax %s: got %v want %v", c.tax, r.INRPerUSD, c.want)
		}
	}
}

func fxServer(t *testing.T, body string, code int) AWSSource {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(code)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(s.Close)
	return AWSSource{FXURL: s.URL}
}

func fxLoad(t *testing.T, src Source, dir string, now time.Time) *float64 {
	o := Options{Getenv: func(k string) string {
		return map[string]string{"CG_TAX_PCT": "0", "CG_PRICES_FILE": "/nonexistent"}[k]
	},
		CacheDir: dir, Source: src, Now: func() time.Time { return now }}
	return Load(context.Background(), o, "x").INRPerUSD
}

func TestExchangeRate(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	eq(t, "today's rate", fxLoad(t, fxServer(t, `{"value":94.951}`, 200), dir, now), 94.95)
	if b, _ := os.ReadFile(filepath.Join(dir, "inr-per-usd")); string(b) != "94.95" {
		t.Errorf("cache has %q", b)
	}
	eq(t, "the same day it is not asked again", fxLoad(t, fxServer(t, `{"value":80}`, 200), dir, now), 94.95)
	later := now.Add(25 * time.Hour)
	eq(t, "a day later it is", fxLoad(t, fxServer(t, `{"value":80}`, 200), dir, later), 80)
	much := later.Add(25 * time.Hour)
	eq(t, "5000 rupees to the dollar: the last good rate", fxLoad(t, fxServer(t, `{"value":5000}`, 200), dir, much), 80)
	eq(t, "not json: the last good rate", fxLoad(t, fxServer(t, `nope`, 200), dir, much), 80)
	eq(t, "unreachable: the last good rate", fxLoad(t, fxServer(t, ``, 500), dir, much), 80)
	if got := fxLoad(t, fxServer(t, ``, 500), t.TempDir(), now); got != nil {
		t.Errorf("never fetched and unreachable should be unknown, got %v", *got)
	}
}
