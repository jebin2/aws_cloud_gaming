// Package quota is `cg quota`: the G-instance quota, what you have, what a build
// needs, and how to ask.
//
// A new AWS account gets 0 vCPU of GPU instances. The request is free and the
// API takes it, but the first answer is an automatic refusal - "service quotas
// are put in place to help you gradually ramp up activity" - and what gets it
// approved is the APPEAL on that same case, with a specific use case in it.
// That is a human conversation, and the Support API needs a Business plan, so
// cg cannot have it for you. What it can do is ask, track the answer, and write
// the appeal out of facts this rig already knows.
//
// Two quotas, not one. They are separate limits and a build needs whichever
// purchase model it is using.
package quota

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/servicequotas"
	sqtypes "github.com/aws/aws-sdk-go-v2/service/servicequotas/types"
)

// The quota codes.
const (
	CodeOnDemand = "L-DB2E81BA" // Running On-Demand G and VT instances
	CodeSpot     = "L-3819A6DF" // All G and VT Spot Instance Requests
)

// SQAPI is the part of Service Quotas this uses.
type SQAPI interface {
	GetServiceQuota(context.Context, *servicequotas.GetServiceQuotaInput, ...func(*servicequotas.Options)) (*servicequotas.GetServiceQuotaOutput, error)
	ListRequestedServiceQuotaChangeHistoryByQuota(context.Context, *servicequotas.ListRequestedServiceQuotaChangeHistoryByQuotaInput, ...func(*servicequotas.Options)) (*servicequotas.ListRequestedServiceQuotaChangeHistoryByQuotaOutput, error)
	RequestServiceQuotaIncrease(context.Context, *servicequotas.RequestServiceQuotaIncreaseInput, ...func(*servicequotas.Options)) (*servicequotas.RequestServiceQuotaIncreaseOutput, error)
}

// EC2API says how many vCPUs the machine has.
type EC2API interface {
	DescribeInstanceTypes(context.Context, *ec2.DescribeInstanceTypesInput, ...func(*ec2.Options)) (*ec2.DescribeInstanceTypesOutput, error)
}

// Quota reads one region.
type Quota struct {
	SQ     SQAPI
	EC2    EC2API
	Region string
	Type   string // the configured machine type
}

// Code is the quota code for a purchase model.
func Code(kind string) string {
	if kind == "spot" {
		return CodeSpot
	}
	return CodeOnDemand
}

// Label is a quota's name for a person.
func Label(kind string) string {
	if kind == "spot" {
		return "G and VT spot"
	}
	return "G and VT on demand"
}

// Need is how many vCPUs one box of the configured type needs. The ask is
// exactly that and never more - the appeal that worked said so in as many words.
func (q Quota) Need(ctx context.Context) int {
	o, err := q.EC2.DescribeInstanceTypes(ctx, &ec2.DescribeInstanceTypesInput{InstanceTypes: []ec2types.InstanceType{ec2types.InstanceType(q.Type)}})
	if err == nil && len(o.InstanceTypes) > 0 && o.InstanceTypes[0].VCpuInfo != nil && o.InstanceTypes[0].VCpuInfo.DefaultVCpus != nil {
		return int(*o.InstanceTypes[0].VCpuInfo.DefaultVCpus)
	}
	return 4
}

// Request is the most recent request for a quota.
type Request struct {
	Status      string   `json:"status"`
	Desired     *float64 `json:"desired"`
	Created     *string  `json:"created"`
	CaseID      *string  `json:"case_id"`
	LastUpdated *string  `json:"last_updated"` // when AWS last touched the REQUEST: a reply on the case is not a change to it
}

// Kind is one purchase model's quota.
type Kind struct {
	Code    string   `json:"code"`
	Value   *float64 `json:"value"`
	Enough  bool     `json:"enough"` // a quota that already covers one box is not a problem to solve, and asking again is refused as a duplicate
	Request *Request `json:"request"`
}

// Status is `cg quota --json`.
type Status struct {
	Region       string `json:"region"`
	InstanceType string `json:"instance_type"`
	VCPUsNeeded  int    `json:"vcpus_needed"`
	OnDemand     *Kind  `json:"ondemand"`
	Spot         *Kind  `json:"spot"`
}

func (q Quota) value(ctx context.Context, code string) *float64 {
	o, err := q.SQ.GetServiceQuota(ctx, &servicequotas.GetServiceQuotaInput{ServiceCode: aws.String("ec2"), QuotaCode: aws.String(code)})
	if err != nil || o.Quota == nil || o.Quota.Value == nil {
		return nil
	}
	return o.Quota.Value
}

// stamp renders a time as the AWS CLI printed it: ISO with the local offset,
// microseconds when there are any.
func stamp(t *time.Time) *string {
	if t == nil {
		return nil
	}
	layout := "2006-01-02T15:04:05-07:00"
	if t.Nanosecond() != 0 {
		layout = "2006-01-02T15:04:05.000000-07:00"
	}
	s := t.Local().Format(layout)
	return &s
}

// last is the most recent request, nil when there has never been one.
func (q Quota) last(ctx context.Context, code string) *Request {
	var all []sqtypes.RequestedServiceQuotaChange
	var token *string
	for {
		o, err := q.SQ.ListRequestedServiceQuotaChangeHistoryByQuota(ctx, &servicequotas.ListRequestedServiceQuotaChangeHistoryByQuotaInput{
			ServiceCode: aws.String("ec2"), QuotaCode: aws.String(code), NextToken: token})
		if err != nil {
			return nil
		}
		all = append(all, o.RequestedQuotas...)
		if o.NextToken == nil || *o.NextToken == "" {
			break
		}
		token = o.NextToken
	}
	if len(all) == 0 {
		return nil
	}
	sort.SliceStable(all, func(i, j int) bool {
		a, b := all[i].Created, all[j].Created
		if a == nil || b == nil {
			return a == nil && b != nil
		}
		return a.Before(*b)
	})
	r := all[len(all)-1]
	out := &Request{Status: string(r.Status), Desired: r.DesiredValue, Created: stamp(r.Created), LastUpdated: stamp(r.LastUpdated)}
	if c := aws.ToString(r.CaseId); c != "" {
		out.CaseID = &c
	}
	return out
}

// Read is the whole status.
func (q Quota) Read(ctx context.Context) Status {
	need := q.Need(ctx)
	kind := func(k string) *Kind {
		code := Code(k)
		v := q.value(ctx, code)
		have := 0.0
		if v != nil {
			have = *v
		}
		return &Kind{Code: code, Value: v, Enough: have >= float64(need), Request: q.last(ctx, code)}
	}
	return Status{Region: q.Region, InstanceType: q.Type, VCPUsNeeded: need, OnDemand: kind("ondemand"), Spot: kind("spot")}
}

// Row is a line of the human view: the kind of mark and its text.
type Row struct{ Kind, Text string }

// Rows is the human view, and the lines after it that are not log lines.
func Rows(s Status) (rows []Row, after []string) {
	for _, k := range []struct {
		q     *Kind
		label string
	}{{s.OnDemand, "on demand"}, {s.Spot, "spot     "}} {
		have, mark := "unknown", "fail"
		if k.q != nil && k.q.Value != nil {
			have = fmt.Sprintf("%g vCPU", *k.q.Value)
		}
		if k.q != nil && k.q.Enough {
			mark = "ok"
		}
		rows = append(rows, Row{mark, fmt.Sprintf("%-12s %s", k.label, have)})
		if k.q != nil && k.q.Request != nil {
			r := k.q.Request
			when := ""
			if r.Created != nil {
				when = (*r.Created)[:min(10, len(*r.Created))]
			}
			desired := 0.0
			if r.Desired != nil {
				desired = *r.Desired
			}
			st := strings.ToLower(strings.ReplaceAll(r.Status, "_", " "))
			c := ""
			if r.CaseID != nil {
				c = ", case " + *r.CaseID
			}
			rows = append(rows, Row{"info", fmt.Sprintf("%-12s %s", "  last asked", fmt.Sprintf("%s for %g vCPU, %s%s", when, desired, st, c))})
		}
	}
	var short []string
	if s.OnDemand == nil || !s.OnDemand.Enough {
		short = append(short, "ondemand")
	}
	if s.Spot == nil || !s.Spot.Enough {
		short = append(short, "spot")
	}
	if len(short) > 0 {
		after = append(after,
			fmt.Sprintf("  ask for %s:  cg quota request %s", strings.Join(short, " and "), short[0]),
			fmt.Sprintf("  the first answer is usually no; the appeal is what works: cg quota appeal %s", short[0]))
	}
	return
}

// Ask is `cg quota request`: ask AWS for exactly what one box needs.
type Asker struct {
	Quota
	Say    func(string)
	LogAs  func(kind, text string)
	Log    func(string)
	Appeal string // "cg quota appeal <kind>" hint
}

// Request asks for the quota, unless it is already enough or a request is open.
func (a Asker) Request(ctx context.Context, kind string) int {
	code := Code(kind)
	need := a.Need(ctx)
	if v := a.value(ctx, code); v != nil && int(*v) >= need {
		a.LogAs("ok", fmt.Sprintf("%s in %s is already %s vCPU - nothing to ask for", Label(kind), a.Region, strconv.FormatFloat(*v, 'f', -1, 64)))
		return 0
	}
	if r := a.last(ctx, code); r != nil && (r.Status == "PENDING" || r.Status == "CASE_OPENED") {
		a.LogAs("warn", "a request for this quota is already open - AWS refuses duplicates")
		when, desired := "", 0.0
		if r.Created != nil {
			when = (*r.Created)[:min(10, len(*r.Created))]
		}
		if r.Desired != nil {
			desired = *r.Desired
		}
		a.Log(fmt.Sprintf("  asked %s for %s vCPU, %s", when, strconv.FormatFloat(desired, 'f', -1, 64), strings.ToLower(r.Status)))
		if r.CaseID != nil {
			a.Log("  its case: https://console.aws.amazon.com/support/home#/case/?displayId=" + *r.CaseID)
		}
		return 0
	}
	a.Say(fmt.Sprintf("asking for %d vCPU of %s in %s", need, Label(kind), a.Region))
	o, err := a.SQ.RequestServiceQuotaIncrease(ctx, &servicequotas.RequestServiceQuotaIncreaseInput{
		ServiceCode: aws.String("ec2"), QuotaCode: aws.String(code), DesiredValue: aws.Float64(float64(need))})
	if err != nil {
		msg := strings.Join(strings.Fields(err.Error()), " ")
		if len(msg) > 300 {
			msg = msg[:300]
		}
		a.LogAs("fail", "AWS refused the request: "+msg)
		return 1
	}
	id, caseID := "", ""
	if o.RequestedQuota != nil {
		id, caseID = aws.ToString(o.RequestedQuota.Id), aws.ToString(o.RequestedQuota.CaseId)
	}
	a.LogAs("ok", fmt.Sprintf("asked AWS for %d vCPU. request %s", need, id))
	if caseID != "" {
		a.Log(fmt.Sprintf("  case %s - https://console.aws.amazon.com/support/home#/case/?displayId=%s", caseID, caseID))
	}
	a.Log("  The first answer is usually an automatic refusal - that is normal, and")
	a.Log("  the appeal on the same case is what gets approved.")
	a.Log("  Write it with:  cg quota appeal " + kind)
	return 0
}

// AppealFacts are the numbers in the appeal; every one is measured here rather
// than invented: the appeal that worked was specific and checkable, and the
// agent escalated it for that reason.
type AppealFacts struct {
	Type            string
	Need            int
	Region          string
	City            string // from the last sweep; the line is left out rather than guessed at
	RTT             string
	BudgetINR       int
	IdleMin         int
	StuckMin        int
	CloudWatchEvery int
}

// AppealText is the case text.
func AppealText(f AppealFacts) string {
	region := f.Region
	if f.City != "" {
		region += " (" + f.City + ")"
	}
	if f.RTT != "" {
		region += " is " + f.RTT + "ms from me"
	}
	return fmt.Sprintf(`Requesting an appeal with detailed use case.

WORKLOAD
Low-latency remote desktop and game streaming for personal use, using
Sunshine (host) and Moonlight (client) over a private Tailscale network.
The GPU is required for NVENC hardware video encoding - encoding a 1080p60
stream in real time. Software encoding is not viable: it adds 30-40ms of
latency and saturates all vCPUs, which defeats the purpose.

INSTANCE AND SIZE
A single %s (%d vCPU). I am requesting exactly %d vCPUs - the
minimum for one instance. I will never run more than one at a time.

USAGE PATTERN
The instance is started on demand for a session and stopped immediately
afterwards. It is not a persistent workload.

COST CONTROLS ALREADY IN PLACE
- An AWS Budget at %d INR/month, created before the first launch
- A cloud watchdog (Lambda, every %d minutes) that stops the instance after
  %d minutes with no stream traffic
- An on-instance watchdog that shuts the box down from inside
- A forced shutdown after %d minutes, whatever the traffic says

REGION
%s. Latency is the whole
constraint for interactive streaming: anything above about 40ms is unusable,
which rules out most regions from my location.

This is not for cryptocurrency mining, ML training, or resale of compute.
`, f.Type, f.Need, f.Need, f.BudgetINR, f.CloudWatchEvery, f.IdleMin, f.StuckMin, region)
}
