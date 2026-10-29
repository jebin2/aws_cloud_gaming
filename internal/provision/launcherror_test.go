package provision

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"
)

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
