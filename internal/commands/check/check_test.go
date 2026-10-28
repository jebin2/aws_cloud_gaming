package check

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/freetier"
	fttypes "github.com/aws/aws-sdk-go-v2/service/freetier/types"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"
	sqtypes "github.com/aws/aws-sdk-go-v2/service/servicequotas/types"
	"github.com/aws/smithy-go"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/creds"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// ec2Fake answers the preflight's questions and, having no create method,
// cannot launch anything: a check that tried would not compile.
type ec2Fake struct {
	noRegion, noType bool
	vcpus            int32
	keyFP            string
	keyGone          bool
	box              bool
	calls            []string
}

func (f *ec2Fake) DescribeRegions(context.Context, *ec2.DescribeRegionsInput, ...func(*ec2.Options)) (*ec2.DescribeRegionsOutput, error) {
	f.calls = append(f.calls, "DescribeRegions")
	if f.noRegion {
		return nil, errors.New("InvalidParameterValue")
	}
	return &ec2.DescribeRegionsOutput{}, nil
}
func (f *ec2Fake) DescribeInstanceTypes(context.Context, *ec2.DescribeInstanceTypesInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error) {
	f.calls = append(f.calls, "DescribeInstanceTypes")
	if f.noType {
		return nil, errors.New("InvalidInstanceType")
	}
	return &ec2.DescribeInstanceTypesOutput{InstanceTypes: []ec2types.InstanceTypeInfo{{VCpuInfo: &ec2types.VCpuInfo{DefaultVCpus: aws.Int32(f.vcpus)}}}}, nil
}
func (f *ec2Fake) DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error) {
	f.calls = append(f.calls, "DescribeKeyPairs")
	if f.keyGone {
		return nil, &smithy.GenericAPIError{Code: "InvalidKeyPair.NotFound"}
	}
	return &ec2.DescribeKeyPairsOutput{KeyPairs: []ec2types.KeyPairInfo{{KeyFingerprint: aws.String(f.keyFP)}}}, nil
}
func (f *ec2Fake) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	f.calls = append(f.calls, "DescribeInstances")
	o := &ec2.DescribeInstancesOutput{}
	if f.box {
		o.Reservations = []ec2types.Reservation{{Instances: []ec2types.Instance{{}}}}
	}
	return o, nil
}

type quotaFake map[string]float64

func (q quotaFake) GetServiceQuota(_ context.Context, in *servicequotas.GetServiceQuotaInput, _ ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error) {
	v, ok := q[aws.ToString(in.QuotaCode)]
	if !ok {
		return nil, errors.New("NoSuchResource")
	}
	return &servicequotas.GetServiceQuotaOutput{Quota: &sqtypes.ServiceQuota{Value: aws.Float64(v)}}, nil
}

type planFake string

func (p planFake) GetAccountPlanState(context.Context, *freetier.GetAccountPlanStateInput, ...func(*freetier.Options)) (*freetier.GetAccountPlanStateOutput, error) {
	return &freetier.GetAccountPlanStateOutput{AccountPlanType: fttypes.AccountPlanType(p)}, nil
}

type rig struct {
	c      *Checker
	e      *ec2Fake
	env    *config.Env
	home   string
	o, e2  *bytes.Buffer
	minted *int
}

// tailscale knows one live auth key, one dead one, and mints a new one.
func tailscale(t *testing.T) (*httptest.Server, *int) {
	minted := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A token that can read keys but not make them: the usual reason a
		// replacement fails.
		readonly := r.Header.Get("Authorization") == "Bearer tskey-api-readonly"
		if r.Header.Get("Authorization") != "Bearer tskey-api-abc123" && !readonly {
			w.WriteHeader(401)
			return
		}
		if readonly && r.Method == "POST" {
			w.WriteHeader(403)
			_, _ = w.Write([]byte(`{"message":"requires scope auth_keys"}`))
			return
		}
		switch {
		case r.Method == "POST" && r.URL.Path == "/tailnet/-/keys":
			minted++
			_, _ = w.Write([]byte(`{"key":"tskey-auth-fresh-secret"}`))
		case r.URL.Path == "/tailnet/-/keys/live", r.URL.Path == "/tailnet/-/keys/fresh":
			_, _ = w.Write([]byte(`{}`))
		case r.URL.Path == "/tailnet/-/keys/dead":
			_, _ = w.Write([]byte(`{"invalid":true}`))
		case r.Method == "DELETE":
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(s.Close)
	return s, &minted
}

// newRig is a laptop with everything installed, working AWS credentials, and a
// .env holding whatever the test says.
func newRig(t *testing.T, dotenv string, input string, jsonMode bool) *rig {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(dotenv), 0o600); err != nil {
		t.Fatal(err)
	}
	env := config.Load(func(k string) (string, bool) { return "", false }, dir)
	var o, e bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e, JSON: jsonMode}
	a := &ask.Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &bytes.Buffer{}, TTY: !jsonMode}
	a.ReadSecret = func() (string, error) { s, err := a.In.ReadString('\n'); return strings.TrimRight(s, "\n"), err }
	run := &fx.Runner{Installed: map[string]bool{"ssh": true, "scp": true, "tailscale": true, "moonlight": true}}
	l := laptop.Laptop{Runner: run, Getenv: func(string) string { return "" }, TTY: func() bool { return true }}
	ts, minted := tailscale(t)
	ef := &ec2Fake{vcpus: 4, keyGone: true}
	valid, src := true, "~/.aws/credentials, profile default"
	cl := Clients{EC2: ef, Quotas: quotaFake{QuotaSpot: 4, QuotaOnDemand: 4}, FreeTier: planFake("PAID")}
	c := &Checker{Out: out, Ask: a, Env: env, Laptop: l, Installer: &laptop.Installer{L: l, Say: func(string, string) {}},
		Setter:   creds.Setter{Out: out, Ask: a, Env: env, Getenv: func(string) string { return "" }},
		Identify: func(context.Context) creds.AWS { return creds.AWS{Valid: &valid, Source: &src} },
		Clients:  func(context.Context) (Clients, error) { return cl, nil },
		TS:       func(token string) tskey.Client { return tskey.Client{Token: token, Base: ts.URL} },
		Rates:    func(context.Context) pricing.Rates { return pricing.Rates{} },
		Home:     dir}
	return &rig{c: c, e: ef, env: env, home: dir, o: &o, e2: &e, minted: minted}
}

const good = "TAILSCALE_API_KEY=tskey-api-abc123\nTAILSCALE_AUTH_KEY=tskey-auth-live-secret\nEMAIL_ALERTS=a@b.c\n"

func TestAGoodSetupPassesAndChangesNothing(t *testing.T) {
	r := newRig(t, good, "", false)
	res, rc := r.c.Run(context.Background())
	if rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e2)
	}
	if !res.Spot || res.VCPUs != 4 || res.Type != "g6.xlarge" || res.AuthKey != "tskey-auth-live-secret" {
		t.Errorf("%+v", res)
	}
	got := r.o.String()
	for _, want := range []string{"AWS credentials work (~/.aws/credentials, profile default)", "account plan: PAID", "spot quota 4 vCPU covers g6.xlarge (4)",
		"no key pair yet - cg init creates one", "the stored Tailscale auth key is still valid", "the Tailscale auth key works", "notifications off", "root disk 50 GB (the default)"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(r.home, ".env")); string(b) != good {
		t.Errorf(".env changed:\n%s", b)
	}
	if *r.minted != 0 {
		t.Error("minted a key it did not need")
	}
}

func TestSpotFallsBackToOnDemandWhenItsQuotaCannotCoverTheBox(t *testing.T) {
	r := newRig(t, good, "", false)
	r.c.Clients = func(context.Context) (Clients, error) {
		return Clients{EC2: r.e, Quotas: quotaFake{QuotaSpot: 0, QuotaOnDemand: 8}, FreeTier: planFake("PAID")}, nil
	}
	res, rc := r.c.Run(context.Background())
	if rc != 0 || res.Spot {
		t.Fatalf("rc %d %+v", rc, res)
	}
	if !strings.Contains(r.o.String(), "spot quota 0 vCPU cannot cover g6.xlarge (4) - using on-demand") || !strings.Contains(r.o.String(), "on-demand quota 8 vCPU covers") {
		t.Error(r.o.String())
	}
	// An explicit choice is honoured as written, whatever the quota says.
	r = newRig(t, good+"GAME_SPOT=1\n", "", false)
	r.c.Clients = func(context.Context) (Clients, error) {
		return Clients{EC2: r.e, Quotas: quotaFake{QuotaSpot: 0, QuotaOnDemand: 8}, FreeTier: planFake("PAID")}, nil
	}
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String()+r.o.String(), "spot GPU quota in ap-south-2 is 0 vCPU; g6.xlarge needs 4.") {
		t.Errorf("rc %d\n%s%s", rc, r.o, r.e2)
	}
}

func TestTheFreePlanStopsEverythingBeforeTheQuotaIsAsked(t *testing.T) {
	r := newRig(t, good, "", false)
	r.c.Clients = func(context.Context) (Clients, error) {
		return Clients{EC2: r.e, Quotas: quotaFake{}, FreeTier: planFake("FREE")}, nil
	}
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "this AWS account is on the Free Plan") || len(r.e.calls) != 0 {
		t.Errorf("rc %d calls %v\n%s", rc, r.e.calls, r.e2)
	}
}

func TestBadRegionAndMissingTypeSayWhatToChange(t *testing.T) {
	r := newRig(t, good, "", false)
	r.e.noRegion = true
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "is not a region you can use. Set GAME_REGION to a valid one.") {
		t.Errorf("%s", r.e2)
	}
	r = newRig(t, good, "", false)
	r.e.noType = true
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "g6.xlarge is not offered in ap-south-2.") {
		t.Errorf("%s", r.e2)
	}
}

func TestWorkingCredentialsAreRequired(t *testing.T) {
	r := newRig(t, good, "", false)
	r.c.Identify = func(context.Context) creds.AWS { return creds.AWS{} }
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "AWS credentials are not working.") || !strings.Contains(r.e2.String(), "cg creds set") {
		t.Errorf("%s", r.e2)
	}
}

func TestACheckWithATokenMintsAndSavesTheBoxKey(t *testing.T) {
	r := newRig(t, "TAILSCALE_API_KEY=tskey-api-abc123\nEMAIL_ALERTS=a@b.c\n", "", false)
	res, rc := r.c.Run(context.Background())
	if rc != 0 || res.AuthKey != "tskey-auth-fresh-secret" || *r.minted != 1 {
		t.Fatalf("rc %d %+v minted %d\n%s%s", rc, res, *r.minted, r.o, r.e2)
	}
	b, _ := os.ReadFile(filepath.Join(r.home, ".env"))
	if !strings.Contains(string(b), "TAILSCALE_AUTH_KEY=tskey-auth-fresh-secret") {
		t.Errorf("check writes settings:\n%s", b)
	}
	if !strings.Contains(r.o.String(), "minted a Tailscale auth key from your API token, and saved it") {
		t.Error(r.o.String())
	}
	for _, c := range r.e.calls {
		if strings.Contains(c, "Create") || strings.Contains(c, "Run") {
			t.Errorf("created something: %s", c)
		}
	}
}

func TestADeadStoredKeyIsReplacedAndTheOldOneDeleted(t *testing.T) {
	r := newRig(t, "TAILSCALE_API_KEY=tskey-api-abc123\nTAILSCALE_AUTH_KEY=tskey-auth-dead-secret\nEMAIL_ALERTS=a@b.c\n", "", false)
	res, rc := r.c.Run(context.Background())
	if rc != 0 || res.AuthKey != "tskey-auth-fresh-secret" || !strings.Contains(r.o.String(), "the stored Tailscale auth key has expired - replacing it") || !strings.Contains(r.o.String(), "the old key was deleted") {
		t.Errorf("rc %d %+v\n%s", rc, res, r.o)
	}
}

func TestADeadKeyThatCannotBeReplacedIsAskedForNotKept(t *testing.T) {
	r := newRig(t, "TAILSCALE_API_KEY=tskey-api-readonly\nTAILSCALE_AUTH_KEY=tskey-auth-dead-secret\nEMAIL_ALERTS=a@b.c\n", "tskey-auth-live-secret\n", true)
	res, rc := r.c.Run(context.Background())
	if rc != 0 || res.AuthKey != "tskey-auth-live-secret" || !strings.Contains(r.e2.String(), "tailscale-auth-key") {
		t.Fatalf("rc %d %+v\n%s%s", rc, res, r.o, r.e2)
	}
}

func TestWithoutATokenACheckStopsBeforeAnythingIsAsked(t *testing.T) {
	r := newRig(t, "TAILSCALE_AUTH_KEY=tskey-auth-live-secret\nEMAIL_ALERTS=a@b.c\n", "", false)
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "no Tailscale API token is saved.") || !strings.Contains(r.e2.String(), "Nothing was launched.") {
		t.Errorf("%s", r.e2)
	}
}

func TestTheAppIsToldWhatIsMissingNotAsked(t *testing.T) {
	r := newRig(t, "TAILSCALE_API_KEY=tskey-api-abc123\nTAILSCALE_AUTH_KEY=tskey-auth-live-secret\n", "", true)
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "no address for billing alerts.") {
		t.Errorf("%s", r.e2)
	}
}

func TestAKeyThatIsNotTheBoxsStopsABuildWhenABoxExists(t *testing.T) {
	r := newRig(t, good, "", false)
	r.e.keyGone, r.e.keyFP, r.e.box = false, strings.Repeat("ab:", 19)+"ab", true
	// A pem that exists but is not this pair's.
	_ = os.MkdirAll(filepath.Join(r.home, ".ssh"), 0o700)
	_ = os.WriteFile(filepath.Join(r.home, ".ssh", "gamevps.pem"), []byte("not a key"), 0o600)
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "a box exists, but ~/.ssh/gamevps.pem is not the key pair's private key") {
		t.Errorf("%s", r.e2)
	}
	// With no box, it is only a warning: cg init replaces the pair.
	r = newRig(t, good, "", false)
	r.e.keyGone, r.e.keyFP = false, strings.Repeat("ab:", 19)+"ab"
	_ = os.MkdirAll(filepath.Join(r.home, ".ssh"), 0o700)
	_ = os.WriteFile(filepath.Join(r.home, ".ssh", "gamevps.pem"), []byte("not a key"), 0o600)
	if _, rc := r.c.Run(context.Background()); rc != 0 || !strings.Contains(r.o.String(), "cg init replaces the key pair (free)") {
		t.Errorf("rc %d\n%s", rc, r.o)
	}
}

func TestFixAsksTheOptionalSettingsOnceAndSavesThem(t *testing.T) {
	// token, disk (Enter keeps 50), expiry 7, ntfy skipped.
	r := newRig(t, "TAILSCALE_AUTH_KEY=tskey-auth-live-secret\nEMAIL_ALERTS=a@b.c\n", "tskey-api-abc123\n\n7\n\n", false)
	r.c.Fix = true
	r.c.Setter.Ask = r.c.Ask
	// Nothing missing and nothing signed out: the laptop step has no work.
	if _, rc := r.c.Run(context.Background()); rc != 0 {
		t.Fatalf("rc %d\n%s%s", rc, r.o, r.e2)
	}
	b, _ := os.ReadFile(filepath.Join(r.home, ".env"))
	for _, want := range []string{"TAILSCALE_API_KEY=tskey-api-abc123", "GAME_DISK_GB=50", "GAME_ARCHIVE_EXPIRY_DAYS=7", "GAME_NTFY_URL="} {
		if !strings.Contains(string(b), want) {
			t.Errorf("lacks %q:\n%s", want, b)
		}
	}
	// Answered once: a second run asks nothing, and the same answers stand.
	r2 := newRig(t, string(b), "", false)
	r2.c.Fix = true
	if _, rc := r2.c.Run(context.Background()); rc != 0 {
		t.Fatalf("second run: %s%s", r2.o, r2.e2)
	}
	if !strings.Contains(r2.o.String(), "game archive: deleted after 7 days") {
		t.Error(r2.o.String())
	}
}

func TestPreflightRefusesAKeyTailscaleDoesNotKnow(t *testing.T) {
	r := newRig(t, "TAILSCALE_API_KEY=tskey-api-abc123\nTAILSCALE_AUTH_KEY=tskey-auth-live-secret\nEMAIL_ALERTS=a@b.c\n", "", false)
	r.c.TS = func(token string) tskey.Client {
		c := tskey.Client{Token: token, Base: "http://127.0.0.1:1"}
		return c
	}
	if _, rc := r.c.Run(context.Background()); rc != 1 || !strings.Contains(r.e2.String(), "api.tailscale.com did not answer (000)") {
		t.Errorf("%s", r.e2)
	}
}
