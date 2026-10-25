package regions

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/account"
	accounttypes "github.com/aws/aws-sdk-go-v2/service/account/types"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

type e2 struct {
	regions []string
	fail    bool
}

func (e e2) DescribeRegions(context.Context, *ec2.DescribeRegionsInput, ...func(*ec2.Options)) (*ec2.DescribeRegionsOutput, error) {
	if e.fail {
		return nil, errors.New("denied")
	}
	o := &ec2.DescribeRegionsOutput{}
	for _, r := range e.regions {
		o.Regions = append(o.Regions, ec2types.Region{RegionName: aws.String(r), OptInStatus: aws.String("opt-in-not-required")})
	}
	return o, nil
}

func TestTheConfiguredRegionIsAlwaysInThePicker(t *testing.T) {
	l := Enabled(context.Background(), e2{regions: []string{"us-east-1", "ap-south-1"}}, "ap-south-2")
	var names []string
	for _, r := range l.Regions {
		names = append(names, r.Region)
	}
	if strings.Join(names, ",") != "ap-south-1,ap-south-2,us-east-1" {
		t.Errorf("sorted, with the configured one in: %v", names)
	}
	if l.Regions[1].OptIn != nil {
		t.Error("the configured one has no opt-in word when it was not listed")
	}
	// describe-regions unreadable: the picker still holds the current value.
	l = Enabled(context.Background(), e2{fail: true}, "ap-south-1")
	if len(l.Regions) != 1 || l.Regions[0].Region != "ap-south-1" {
		t.Errorf("%+v", l)
	}
	text := Show(l)
	if !strings.Contains(text, "  *ap-south-1\n") || !strings.Contains(text, "Only enabled regions are listed.") {
		t.Errorf("%s", text)
	}
	if got := Show(List{Regions: []Region{}}); !strings.Contains(got, "could not list regions") {
		t.Errorf("%s", got)
	}
}

type acct struct {
	status               map[string]string // region -> status; changes as polling goes on
	script               []string          // statuses returned for successive polls of the region
	listFail, enableFail bool
	enableErr            error
	enabled              []string
	polls                int
}

func (a *acct) ListRegions(context.Context, *account.ListRegionsInput, ...func(*account.Options)) (*account.ListRegionsOutput, error) {
	if a.listFail {
		return nil, errors.New("denied")
	}
	o := &account.ListRegionsOutput{}
	for r, s := range a.status {
		o.Regions = append(o.Regions, accounttypes.Region{RegionName: aws.String(r), RegionOptStatus: accounttypes.RegionOptStatus(s)})
	}
	return o, nil
}

func (a *acct) GetRegionOptStatus(_ context.Context, in *account.GetRegionOptStatusInput, _ ...func(*account.Options)) (*account.GetRegionOptStatusOutput, error) {
	r := aws.ToString(in.RegionName)
	if len(a.script) > 0 && a.polls > 0 {
		s := a.script[0]
		a.script = a.script[1:]
		return &account.GetRegionOptStatusOutput{RegionOptStatus: accounttypes.RegionOptStatus(s)}, nil
	}
	a.polls++
	s, ok := a.status[r]
	if !ok {
		return nil, errors.New("no such region")
	}
	return &account.GetRegionOptStatusOutput{RegionOptStatus: accounttypes.RegionOptStatus(s)}, nil
}

func (a *acct) EnableRegion(_ context.Context, in *account.EnableRegionInput, _ ...func(*account.Options)) (*account.EnableRegionOutput, error) {
	if a.enableFail {
		return nil, a.enableErr
	}
	a.enabled = append(a.enabled, aws.ToString(in.RegionName))
	return &account.EnableRegionOutput{}, nil
}

func TestOptIn(t *testing.T) {
	a := &acct{status: map[string]string{"ap-south-1": "ENABLED_BY_DEFAULT", "af-south-1": "DISABLED", "ap-south-2": "ENABLED", "me-south-1": "ENABLING"}}
	o := ReadOptIn(context.Background(), a)
	if len(o.Regions) != 4 || o.Regions[0].Region != "af-south-1" || strings.Join(o.Disabled, ",") != "af-south-1" || strings.Join(o.Enabling, ",") != "me-south-1" {
		t.Errorf("%+v", o)
	}
	text := ShowOptIn(o)
	for _, want := range []string{"  enabled: 2\n", "  af-south-1       disabled\n", "  me-south-1       enabling\n"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "ap-south-1 ") {
		t.Error("an enabled region is counted, not listed")
	}
	if o := ReadOptIn(context.Background(), &acct{listFail: true}); o.Error != "could not read the region list" || len(o.Regions) != 0 {
		t.Errorf("%+v", o)
	}
}

type log struct{ lines []string }

func (l *log) enabler(a *acct) Enabler {
	return Enabler{Account: a,
		Say:   func(s string) { l.lines = append(l.lines, "SAY "+s) },
		LogAs: func(k, s string) { l.lines = append(l.lines, k+" "+s) },
		Log:   func(s string) { l.lines = append(l.lines, "log "+s) },
		Sleep: func(time.Duration) {}}
}

func (l *log) all() string { return strings.Join(l.lines, "\n") }

func TestEnableAlreadyOnUnknownAndTheWholeWalk(t *testing.T) {
	var l log
	a := &acct{status: map[string]string{"ap-south-1": "ENABLED"}}
	if rc := l.enabler(a).Enable(context.Background(), "ap-south-1"); rc != 0 || len(a.enabled) != 0 || !strings.Contains(l.all(), "ok ap-south-1 is already enabled") {
		t.Errorf("%s", l.all())
	}
	l = log{}
	if rc := l.enabler(a).Enable(context.Background(), "mars-north-1"); rc != 1 || !strings.Contains(l.all(), "fail AWS does not list a region called mars-north-1") {
		t.Errorf("%s", l.all())
	}
	l = log{}
	a = &acct{status: map[string]string{"af-south-1": "DISABLED"}, script: []string{"ENABLING", "ENABLING", "ENABLED"}}
	if rc := l.enabler(a).Enable(context.Background(), "af-south-1"); rc != 0 || len(a.enabled) != 1 {
		t.Fatalf("rc %d\n%s", rc, l.all())
	}
	for _, want := range []string{"SAY enabling af-south-1", "an account-level change: everything on this account can use the region",
		"ok asked AWS to enable af-south-1", "log   still enabling (10s)", "log   still enabling (20s)", "ok af-south-1 is enabled"} {
		if !strings.Contains(l.all(), want) {
			t.Errorf("lacks %q:\n%s", want, l.all())
		}
	}
}

func TestEnableThatNeverFinishesIsNormal(t *testing.T) {
	var l log
	a := &acct{status: map[string]string{"af-south-1": "ENABLING"}, script: []string{"ENABLING", "ENABLING", "ENABLING", "ENABLING", "ENABLING", "ENABLING"}}
	if rc := l.enabler(a).Enable(context.Background(), "af-south-1"); rc != 0 || len(a.enabled) != 0 {
		t.Errorf("already enabling: not asked again: %v", a.enabled)
	}
	for _, want := range []string{"warn af-south-1 is already being enabled - that takes a few minutes", "warn af-south-1 is still enabling - this is normal", "check again with:  cg regions optin"} {
		if !strings.Contains(l.all(), want) {
			t.Errorf("lacks %q:\n%s", want, l.all())
		}
	}
}

func TestARefusalNamesTheTwoThatAreNotARetry(t *testing.T) {
	for msg, hint := range map[string]string{
		"AccessDeniedException: User is not authorized":           "this key needs account:EnableRegion",
		"ValidationException: this account is in an Organization": "only the management account can enable regions",
	} {
		var l log
		a := &acct{status: map[string]string{"af-south-1": "DISABLED"}, enableFail: true, enableErr: errors.New(msg)}
		if rc := l.enabler(a).Enable(context.Background(), "af-south-1"); rc != 1 {
			t.Errorf("rc %d", rc)
		}
		if !strings.Contains(l.all(), "fail AWS refused: "+msg) || !strings.Contains(l.all(), hint) {
			t.Errorf("%q:\n%s", msg, l.all())
		}
	}
}
