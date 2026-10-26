package provision

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"
)

// The Bash report is the oracle: the same failure must be said the same way.
func TestReportMatchesTheBashWord(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	if _, err := os.Stat("../../lib/launch-error.sh"); err != nil {
		t.Skip("the Bash tree is gone")
	}
	msg := "We currently do not have sufficient g6.xlarge capacity in the Availability Zone you requested."
	cases := []struct {
		code string
		spot bool
	}{
		{"InsufficientInstanceCapacity", true}, {"InsufficientInstanceCapacity", false}, {"SpotMaxPriceTooLow", true}, {"VcpuLimitExceeded", false},
		{"InvalidKeyPair.NotFound", false}, {"UnauthorizedOperation", false}, {"AuthFailure", false}, {"SomethingNew", false}, {"", false},
	}
	for _, c := range cases {
		errf := t.TempDir() + "/err"
		text := "An error occurred (" + c.code + ") when calling the RunInstances operation: " + msg + "\n"
		if c.code == "" {
			text = msg + "\n"
		}
		_ = os.WriteFile(errf, []byte(text), 0o600)
		spot := "0"
		if c.spot {
			spot = "1"
		}
		cmd := exec.Command("bash", "-c", `source lib/launch-error.sh; launch_error_report "$1"`, "_", errf)
		cmd.Dir = "../.."
		cmd.Env = append(os.Environ(), "TYPE=g6.xlarge", "REGION=ap-south-1", "SPOT="+spot, "KEY_NAME=gamevps", "KEY_FILE=/home/x/.ssh/gamevps.pem", "INSTANCE_PROFILE=gamevps-box")
		want, err := cmd.Output()
		if err != nil {
			t.Fatalf("%s: %v", c.code, err)
		}
		f := LaunchFailure{Code: c.code, Message: msg, Type: "g6.xlarge", Region: "ap-south-1", Spot: c.spot, KeyName: "gamevps", KeyFile: "/home/x/.ssh/gamevps.pem", Profile: "gamevps-box"}
		got := strings.Join(f.Report(), "\n") + "\n"
		if got != string(want) {
			t.Errorf("code %q spot=%v differs:\n--- go\n%s\n--- bash\n%s", c.code, c.spot, got, want)
		}
	}
}

func TestSpotAllowanceNamesWhatHoldsIt(t *testing.T) {
	f := LaunchFailure{Code: "MaxSpotInstanceCountExceeded", Type: "g6.xlarge", Region: "ap-south-1", Holders: []Holder{{"i-1", "running", "g6.xlarge", "2026-10-25T01:00:00+00:00"}}, HoldersKnown: true}
	got := strings.Join(f.Report(), "\n")
	for _, want := range []string{"!! a spot machine in ap-south-1 is still there and holds your spot allowance: i-1 (running)", "nothing was launched by this build - but the machine above is still billing", "    i-1  running  g6.xlarge  launched 2026-10-25T01:00:00+00:00", "GAME_SPOT=0 cg init (L-3819A6DF)"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	f.Holders = []Holder{{"i-1", "shutting-down", "g6.xlarge", "x"}}
	got = strings.Join(f.Report(), "\n")
	if !strings.Contains(got, "!! your previous spot machine is still shutting down - try again in a minute or two") || !strings.Contains(got, "nothing was launched, and nothing is billing") {
		t.Errorf("%s", got)
	}
	f.Holders = nil
	if !strings.Contains(strings.Join(f.Report(), "\n"), "!! your previous spot allocation has not been released yet") {
		t.Error("no holders known")
	}
}

type descr struct {
	out *ec2.DescribeInstancesOutput
	err error
}

func (d descr) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	return d.out, d.err
}

func TestSpotHoldersAndErrorParts(t *testing.T) {
	hs, ok := SpotHolders(context.Background(), descr{out: &ec2.DescribeInstancesOutput{Reservations: []ec2types.Reservation{{Instances: []ec2types.Instance{
		{InstanceId: aws.String("i-9"), InstanceType: "g6.xlarge", State: &ec2types.InstanceState{Name: "stopped"}}}}}}})
	if !ok || len(hs) != 1 || hs[0].ID != "i-9" || hs[0].State != "stopped" {
		t.Errorf("%v %v", hs, ok)
	}
	if _, ok := SpotHolders(context.Background(), descr{err: errors.New("x")}); ok {
		t.Error("AWS did not answer")
	}
	code, msg := ErrorParts(&smithy.GenericAPIError{Code: "VcpuLimitExceeded", Message: "line one\n\nline two\nline three"})
	if code != "VcpuLimitExceeded" || msg != "line two\nline three" {
		t.Errorf("%q %q", code, msg)
	}
	if c, m := ErrorParts(errors.New("plain")); c != "" || m != "plain" {
		t.Errorf("%q %q", c, m)
	}
}
