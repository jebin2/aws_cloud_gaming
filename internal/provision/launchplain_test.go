package provision

import (
	"regexp"
	"strings"
	"testing"
)

// Every code Report has a paragraph for has a kind, and a kind has the words a
// person needs: what went wrong, what to do, and whether anything is charging.
func TestEveryLaunchCodeHasAPlainKind(t *testing.T) {
	cases := map[string]string{
		"InsufficientInstanceCapacity": NoCapacity, "SpotMaxPriceTooLow": NoCapacity,
		"MaxSpotInstanceCountExceeded": SpotSlotLeave,
		"VcpuLimitExceeded":            LimitTooSmall, "InstanceLimitExceeded": LimitTooSmall,
		"InvalidKeyPair.NotFound": KeyMissing,
		"AccessDenied":            NotAllowed, "AccessDeniedException": NotAllowed, "UnauthorizedOperation": NotAllowed,
		"OptInRequired": NotEnabled, "SubscriptionRequiredException": NotEnabled,
		"AuthFailure": SignInRefused,
		"Blocked":     AccountBlocked, "UnauthorizedAccount": AccountBlocked,
		"SomethingNew": Unknown, "": Unknown,
	}
	// What a phone or a window must never show: ids, setting names, quota codes,
	// AWS service names, commands.
	jargon := regexp.MustCompile(`\b(S3|EC2|IAM|vCPU|quota|instance|spot|GAME_[A-Z_]+|L-[0-9A-F]{8}|ayis [a-z]+|i-[0-9a-f]{4,}|SSH|key pair)\b`)
	for code, kind := range cases {
		for _, spot := range []bool{true, false} {
			p := LaunchFailure{Code: code, Spot: spot}.Plain()
			if p.Kind != kind {
				t.Errorf("%q: kind %q, want %q", code, p.Kind, kind)
			}
			if p.Title == "" || p.Text == "" || p.Charging != "no" {
				t.Errorf("%q: %+v", code, p)
			}
			if m := jargon.FindString(p.Title + " " + p.Text); m != "" {
				t.Errorf("%q: %q in %q / %q", code, m, p.Title, p.Text)
			}
		}
	}
}

func TestAMachineStillThereIsSaidToBeCharging(t *testing.T) {
	f := LaunchFailure{Code: "MaxSpotInstanceCountExceeded", Holders: []Holder{{ID: "i-1", State: "running"}}}
	if p := f.Plain(); p.Kind != SpotSlotHeld || p.Charging != "other" {
		t.Errorf("%+v", p)
	}
	f.Holders = []Holder{{ID: "i-1", State: "shutting-down"}}
	if p := f.Plain(); p.Kind != SpotSlotLeave || p.Charging != "no" {
		t.Errorf("one on its way out is not charging for long, and is not 'still there': %+v", p)
	}
}

func TestAnAllowanceRefusalSaysWhichMachineIsUsingIt(t *testing.T) {
	f := LaunchFailure{Code: "VcpuLimitExceeded", Holders: []Holder{{ID: "i-1", State: "running"}}}
	if p := f.Plain(); p.Kind != SpotSlotHeld || p.Charging != "other" || strings.Contains(p.Text, "Ask AWS") {
		t.Errorf("another game PC is using it, and asking AWS would not help: %+v", p)
	}
	f.Holders = []Holder{{ID: "i-1", State: "stopping"}}
	if p := f.Plain(); p.Kind != SpotSlotLeave || !strings.Contains(p.Text, "saving your games") {
		t.Errorf("%+v", p)
	}
	f.Holders = []Holder{{ID: "i-1", State: "shutting-down"}}
	if p := f.Plain(); p.Kind != SpotSlotLeave || p.Charging != "no" {
		t.Errorf("%+v", p)
	}
	f.Holders = nil
	if p := f.Plain(); p.Kind != LimitTooSmall {
		t.Errorf("nothing is using it: the permission is what is missing: %+v", p)
	}
}
