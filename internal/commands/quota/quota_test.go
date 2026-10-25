package quota

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"
	sqtypes "github.com/aws/aws-sdk-go-v2/service/servicequotas/types"
)

type sq struct {
	values   map[string]float64
	history  map[string][]sqtypes.RequestedServiceQuotaChange
	requests []float64
	failAsk  bool
}

func (s *sq) GetServiceQuota(_ context.Context, in *servicequotas.GetServiceQuotaInput, _ ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error) {
	v, ok := s.values[aws.ToString(in.QuotaCode)]
	if !ok {
		return nil, errors.New("denied")
	}
	return &servicequotas.GetServiceQuotaOutput{Quota: &sqtypes.ServiceQuota{Value: aws.Float64(v)}}, nil
}

func (s *sq) ListRequestedServiceQuotaChangeHistoryByQuota(_ context.Context, in *servicequotas.ListRequestedServiceQuotaChangeHistoryByQuotaInput, _ ...func(*servicequotas.Options)) (*servicequotas.ListRequestedServiceQuotaChangeHistoryByQuotaOutput, error) {
	return &servicequotas.ListRequestedServiceQuotaChangeHistoryByQuotaOutput{RequestedQuotas: s.history[aws.ToString(in.QuotaCode)]}, nil
}

func (s *sq) RequestServiceQuotaIncrease(_ context.Context, in *servicequotas.RequestServiceQuotaIncreaseInput, _ ...func(*servicequotas.Options)) (*servicequotas.RequestServiceQuotaIncreaseOutput, error) {
	if s.failAsk {
		return nil, errors.New("operation error: ResourceAlreadyExistsException: a request is already open\nsecond line")
	}
	s.requests = append(s.requests, aws.ToFloat64(in.DesiredValue))
	return &servicequotas.RequestServiceQuotaIncreaseOutput{RequestedQuota: &sqtypes.RequestedServiceQuotaChange{Id: aws.String("req-1"), CaseId: aws.String("1234567890")}}, nil
}

type e2 struct {
	vcpu int32
	fail bool
}

func (e e2) DescribeInstanceTypes(context.Context, *ec2.DescribeInstanceTypesInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error) {
	if e.fail {
		return nil, errors.New("denied")
	}
	return &ec2.DescribeInstanceTypesOutput{InstanceTypes: []ec2types.InstanceTypeInfo{{VCpuInfo: &ec2types.VCpuInfo{DefaultVCpus: aws.Int32(e.vcpu)}}}}, nil
}

func at(s string) *time.Time { t, _ := time.Parse(time.RFC3339, s); return &t }

func q(s *sq, e e2) Quota { return Quota{SQ: s, EC2: e, Region: "ap-south-1", Type: "g4dn.xlarge"} }

func TestStatusNeedsAndEnough(t *testing.T) {
	s := &sq{values: map[string]float64{CodeOnDemand: 4, CodeSpot: 0}}
	st := q(s, e2{vcpu: 4}).Read(context.Background())
	if st.VCPUsNeeded != 4 || !st.OnDemand.Enough || st.Spot.Enough || *st.OnDemand.Value != 4 || st.OnDemand.Request != nil {
		t.Errorf("%+v %+v", st.OnDemand, st.Spot)
	}
	// Unreadable: not enough, and the value is null - not zero.
	st = q(&sq{values: map[string]float64{}}, e2{fail: true}).Read(context.Background())
	if st.VCPUsNeeded != 4 || st.OnDemand.Value != nil || st.OnDemand.Enough {
		t.Errorf("%+v", st.OnDemand)
	}
	if st := q(s, e2{vcpu: 8}).Read(context.Background()); st.VCPUsNeeded != 8 || st.OnDemand.Enough {
		t.Errorf("a bigger box needs more: %+v", st.OnDemand)
	}
}

func TestTheLastRequestIsTheNewest(t *testing.T) {
	s := &sq{values: map[string]float64{CodeOnDemand: 0, CodeSpot: 0}, history: map[string][]sqtypes.RequestedServiceQuotaChange{
		CodeOnDemand: {
			{Status: "DENIED", DesiredValue: aws.Float64(4), Created: at("2026-09-01T10:00:00Z"), CaseId: aws.String("111")},
			{Status: "CASE_OPENED", DesiredValue: aws.Float64(4), Created: at("2026-10-14T10:00:00Z"), CaseId: aws.String("222"), LastUpdated: at("2026-10-15T10:00:00Z")},
			{Status: "PENDING", DesiredValue: aws.Float64(4), Created: at("2026-09-20T10:00:00Z")},
		}}}
	st := q(s, e2{vcpu: 4}).Read(context.Background())
	r := st.OnDemand.Request
	if r == nil || r.Status != "CASE_OPENED" || *r.CaseID != "222" || r.LastUpdated == nil || (*r.Created)[:10] != "2026-10-14" && (*r.Created)[:10] != "2026-10-13" {
		t.Fatalf("%+v", r)
	}
	if st.Spot.Request != nil {
		t.Error("never asked: null")
	}
	rows, after := Rows(st)
	text := ""
	for _, x := range rows {
		text += x.Kind + "|" + x.Text + "\n"
	}
	for _, want := range []string{"fail|on demand    0 vCPU", "info|  last asked 2026-10-14", " for 4 vCPU, case opened, case 222", "fail|spot         0 vCPU"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	if len(after) != 2 || after[0] != "  ask for ondemand and spot:  cg quota request ondemand" ||
		after[1] != "  the first answer is usually no; the appeal is what works: cg quota appeal ondemand" {
		t.Errorf("%q", after)
	}
	rows, after = Rows(Status{VCPUsNeeded: 4, OnDemand: &Kind{Enough: true, Value: aws.Float64(4)}, Spot: &Kind{Enough: true, Value: aws.Float64(4)}})
	if len(after) != 0 || rows[0].Kind != "ok" {
		t.Errorf("nothing to ask for: %v %v", rows, after)
	}
}

type said struct{ lines []string }

func (s *said) asker(sq *sq, e e2) Asker {
	return Asker{Quota: q(sq, e),
		Say:   func(x string) { s.lines = append(s.lines, "SAY "+x) },
		LogAs: func(k, x string) { s.lines = append(s.lines, k+" "+x) },
		Log:   func(x string) { s.lines = append(s.lines, "log "+x) }}
}

func (s *said) all() string { return strings.Join(s.lines, "\n") }

func TestAskForExactlyWhatOneBoxNeeds(t *testing.T) {
	var out said
	s := &sq{values: map[string]float64{CodeOnDemand: 0}}
	if rc := out.asker(s, e2{vcpu: 4}).Request(context.Background(), "ondemand"); rc != 0 || len(s.requests) != 1 || s.requests[0] != 4 {
		t.Fatalf("rc %d requests %v", rc, s.requests)
	}
	for _, want := range []string{"SAY asking for 4 vCPU of G and VT on demand in ap-south-1", "ok asked AWS for 4 vCPU. request req-1",
		"displayId=1234567890", "automatic refusal", "cg quota appeal ondemand"} {
		if !strings.Contains(out.all(), want) {
			t.Errorf("lacks %q:\n%s", want, out.all())
		}
	}
}

func TestNothingToAskForAndNoDuplicates(t *testing.T) {
	var out said
	s := &sq{values: map[string]float64{CodeSpot: 8}}
	if rc := out.asker(s, e2{vcpu: 4}).Request(context.Background(), "spot"); rc != 0 || len(s.requests) != 0 || !strings.Contains(out.all(), "ok G and VT spot in ap-south-1 is already 8 vCPU - nothing to ask for") {
		t.Errorf("%v\n%s", s.requests, out.all())
	}
	out = said{}
	s = &sq{values: map[string]float64{CodeOnDemand: 0}, history: map[string][]sqtypes.RequestedServiceQuotaChange{
		CodeOnDemand: {{Status: "PENDING", DesiredValue: aws.Float64(4), Created: at("2026-10-14T10:00:00Z"), CaseId: aws.String("999")}}}}
	if rc := out.asker(s, e2{vcpu: 4}).Request(context.Background(), "ondemand"); rc != 0 || len(s.requests) != 0 {
		t.Errorf("an open request is not asked again: %v", s.requests)
	}
	for _, want := range []string{"warn a request for this quota is already open - AWS refuses duplicates", "asked 2026-10-14 for 4 vCPU, pending", "displayId=999"} {
		if !strings.Contains(out.all(), want) {
			t.Errorf("lacks %q:\n%s", want, out.all())
		}
	}
}

func TestARefusalIsQuotedInOneLine(t *testing.T) {
	var out said
	s := &sq{values: map[string]float64{CodeOnDemand: 0}, failAsk: true}
	if rc := out.asker(s, e2{vcpu: 4}).Request(context.Background(), "ondemand"); rc != 1 {
		t.Errorf("rc %d", rc)
	}
	if !strings.Contains(out.all(), "fail AWS refused the request: operation error: ResourceAlreadyExistsException: a request is already open second line") {
		t.Errorf("%s", out.all())
	}
}

func TestTheAppealIsMadeOfThisRigsFacts(t *testing.T) {
	text := AppealText(AppealFacts{Type: "g4dn.xlarge", Need: 4, Region: "ap-south-1", City: "Mumbai", RTT: "19.3", BudgetINR: 5000, IdleMin: 30, StuckMin: 60, CloudWatchEvery: 5})
	for _, want := range []string{"A single g4dn.xlarge (4 vCPU). I am requesting exactly 4 vCPUs", "An AWS Budget at 5000 INR/month",
		"(Lambda, every 5 minutes) that stops the instance after\n  30 minutes", "A forced shutdown after 60 minutes",
		"ap-south-1 (Mumbai) is 19.3ms from me. Latency is the whole", "This is not for cryptocurrency mining"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	// With no sweep on file, the line is left out rather than guessed at.
	if text := AppealText(AppealFacts{Type: "g6.xlarge", Need: 4, Region: "ap-south-2"}); !strings.Contains(text, "ap-south-2. Latency is the whole") || strings.Contains(text, "ms from me") {
		t.Errorf("%s", text)
	}
	if Code("spot") != CodeSpot || Code("") != CodeOnDemand || Label("spot") != "G and VT spot" {
		t.Error("codes and labels")
	}
}
