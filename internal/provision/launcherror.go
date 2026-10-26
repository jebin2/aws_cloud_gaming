package provision

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"
)

// Holder is a spot machine that holds the spot allowance now.
type Holder struct{ ID, State, Type, Launched string }

// LaunchFailure is what run-instances said, and what it was asked for.
type LaunchFailure struct {
	Code, Message string
	Type, Region  string
	Spot          bool
	KeyName       string
	KeyFile       string
	Profile       string
	// Holders are the spot machines in the region that hold the allowance, read
	// when the failure was MaxSpotInstanceCountExceeded; HoldersKnown is false when
	// AWS could not be asked.
	Holders      []Holder
	HoldersKnown bool
}

// ErrorParts splits an AWS error into its code and its own sentence.
func ErrorParts(err error) (code, msg string) {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		code, msg = ae.ErrorCode(), ae.ErrorMessage()
	} else {
		msg = err.Error()
	}
	lines := []string{}
	for _, l := range strings.Split(msg, "\n") {
		if strings.TrimSpace(l) != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) > 2 {
		lines = lines[len(lines)-2:]
	}
	return code, strings.Join(lines, "\n")
}

// SpotHolders: the spot machines in a region that hold the spot allowance now -
// any that exists counts, a stopped one and one still shutting down included.
// Read-only and free. ok is false when AWS could not be asked.
func SpotHolders(ctx context.Context, c interface {
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
}) (hs []Holder, ok bool) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	o, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{Filters: []ec2types.Filter{
		{Name: aws.String("instance-lifecycle"), Values: []string{"spot"}},
		{Name: aws.String("instance-state-name"), Values: []string{"pending", "running", "stopping", "stopped", "shutting-down"}}}})
	if err != nil {
		return nil, false
	}
	for _, r := range o.Reservations {
		for _, i := range r.Instances {
			h := Holder{ID: aws.ToString(i.InstanceId), Type: string(i.InstanceType)}
			if i.State != nil {
				h.State = string(i.State.Name)
			}
			if i.LaunchTime != nil {
				h.Launched = i.LaunchTime.UTC().Format("2006-01-02T15:04:05+00:00")
			}
			hs = append(hs, h)
		}
	}
	return hs, true
}

// Report says what to say when run-instances refuses. The first line carries the
// "!! " marker that turns into a `fail` line, which is what lets the desktop app
// show the cause in its own panel instead of as line 183 of a scrolling log.
//
// One cause, not a list. The list that used to print here ran to 25 lines and
// pushed AWS's own message off the top of the screen, which is how a launch
// failure came to look like it had no error at all.
func (f LaunchFailure) Report() []string {
	typ, region := f.Type, f.Region
	if typ == "" {
		typ = "instance"
	}
	here := region
	if here == "" {
		here = "this region"
	}
	var live []Holder
	for _, h := range f.Holders {
		if h.State != "shutting-down" {
			live = append(live, h)
		}
	}
	var headline string
	switch f.Code {
	case "InsufficientInstanceCapacity", "SpotMaxPriceTooLow":
		if f.Spot {
			headline = fmt.Sprintf("AWS has no spare %s at the spot price in %s", typ, here)
		} else {
			headline = fmt.Sprintf("AWS has no spare %s in %s right now", typ, here)
		}
	case "MaxSpotInstanceCountExceeded":
		switch {
		case len(live) > 0:
			headline = fmt.Sprintf("a spot machine in %s is still there and holds your spot allowance: %s (%s)", here, live[0].ID, live[0].State)
		case len(f.Holders) > 0:
			headline = "your previous spot machine is still shutting down - try again in a minute or two"
		default:
			headline = "your previous spot allocation has not been released yet"
		}
	case "VcpuLimitExceeded", "InstanceLimitExceeded":
		t := f.Type
		if t == "" {
			t = "this machine"
		}
		headline = fmt.Sprintf("your AWS quota is too small for %s in %s", t, here)
	case "InvalidKeyPair.NotFound":
		headline = fmt.Sprintf("the SSH key pair %s is missing from %s", f.KeyName, here)
	case "AccessDenied", "AccessDeniedException", "UnauthorizedOperation":
		headline = "AWS refused the request: this key is not allowed to launch with a role"
	case "OptInRequired", "SubscriptionRequiredException", "AuthFailure", "UnauthorizedAccount", "Blocked":
		headline = "AWS refused the account itself"
	default:
		headline = "the instance could not be launched"
	}
	out := []string{"!! " + headline}
	// Nothing this build launched exists to clean up or pay for: run-instances
	// refusing is the one failure where that is certain, and it is the first thing
	// worth knowing - unless another machine is what refused it.
	if len(live) > 0 {
		out = append(out, "    nothing was launched by this build - but the machine above is still billing")
	} else {
		out = append(out, "    nothing was launched, and nothing is billing")
	}
	if f.Message != "" {
		for _, l := range strings.Split(f.Message, "\n") {
			out = append(out, "    AWS said: "+l)
		}
	}
	if f.Code != "" {
		out = append(out, "    error code: "+f.Code)
	}
	out = append(out, "")
	t := typ
	if f.Type == "" {
		t = "the instance"
	}
	r := f.Region
	switch f.Code {
	case "MaxSpotInstanceCountExceeded":
		if len(f.Holders) > 0 {
			out = append(out, fmt.Sprintf("  Spot machines in %s right now:", orStr(region, "the region")))
			for _, h := range f.Holders {
				out = append(out, fmt.Sprintf("    %s  %s  %s  launched %s", h.ID, h.State, h.Type, h.Launched))
			}
			out = append(out, "")
		}
		switch {
		case len(live) > 0:
			out = append(out, "  Each one counts against the spot allowance while it exists, stopped or not,",
				"  and a running one is billing. If it is the machine cg built, delete it -",
				"  Delete on the app's Machine page, or: cg destroy - then build again.",
				"  Anything else is in the EC2 console.",
				"  If the allowance is simply too small for two: GAME_SPOT=0 cg init (L-3819A6DF)")
		case len(f.Holders) > 0:
			out = append(out, "  It is on its way out; AWS frees its share of the allowance once it is gone.",
				"  Nothing is wrong - try again in a minute or two.")
		default:
			out = append(out, "  Your own spot allocation is still held. AWS releases the vCPU quota a",
				"  minute or two AFTER an instance terminates, so an immediate rebuild",
				"  hits it. Nothing is wrong - wait ~2 minutes and run it again.",
				fmt.Sprintf("  If it persists, the quota (L-3819A6DF) is smaller than %s needs:", t),
				"    GAME_SPOT=0 cg init",
				"  What holds it: aws ec2 describe-spot-instance-requests --region "+r)
		}
	case "InsufficientInstanceCapacity", "SpotMaxPriceTooLow":
		// Which purchase model was asked for decides what there is to say. Telling
		// someone already on demand to "try on demand" is worse than saying nothing:
		// it reads as a fix, and they have nowhere to go after trying it.
		if f.Spot {
			out = append(out, "  Spot rents the machines nobody else is paying full price for, and there",
				"  are none of those here at the moment. On demand is the same machine at",
				"  the full price, and it has first claim - so it usually works when this",
				"  does not.",
				"",
				"  Pay full price, and build now:",
				"      cg config set GAME_SPOT 0       (Settings > purchase model, in the app)",
				"  Try a different GPU - each shape is its own pool:",
				"      cg machines",
				"  Or see which region has capacity, free and about 90 seconds:",
				"      cg sweep                        (Scan all regions, in the app)",
				"",
				"  Or come back later. Spot capacity returns on its own, often within hours,",
				"  and nothing here needs fixing in the meantime.")
		} else {
			out = append(out, "  This was an ON DEMAND launch, so there is no fuller-priced option left to",
				"  fall back to - the region is simply out of this machine.",
				"",
				"  Try a different GPU - each shape is its own pool:",
				"      cg machines",
				"  Or see which region has capacity, free and about 90 seconds:",
				"      cg sweep                        (Scan all regions, in the app)",
				fmt.Sprintf("      note: your game archive lives in %s and does not", here),
				"      follow you - a box elsewhere re-downloads what it needs.",
				"",
				"  Or come back later. Capacity returns without warning, usually within hours.")
		}
	case "VcpuLimitExceeded", "InstanceLimitExceeded":
		out = append(out, fmt.Sprintf("  The on-demand vCPU quota in %s is smaller than", orStr(region, "the region")),
			fmt.Sprintf("  %s needs. What you have: cg status", orStr(f.Type, "this instance")))
	case "AccessDenied", "AccessDeniedException", "UnauthorizedOperation":
		out = append(out, "  Launching with an instance profile needs iam:PassRole for",
			fmt.Sprintf("  %s. Without it the box cannot reach", orStr(f.Profile, "the instance profile")),
			"  S3, and the game library will not survive a stop.")
	case "InvalidKeyPair.NotFound":
		out = append(out, fmt.Sprintf("  The key pair %s no longer exists in %s.", f.KeyName, orStr(region, "the region")),
			fmt.Sprintf("  cg check --fix recreates it and the matching %s.", orStr(f.KeyFile, ".pem")))
	case "OptInRequired", "SubscriptionRequiredException", "AuthFailure", "UnauthorizedAccount", "Blocked":
		out = append(out, "  AWS refused the ACCOUNT, not the request - a suspension, a verification",
			"  hold, or a payment problem. Read the console banner before changing",
			"  anything here; no amount of retrying fixes this one.")
	default:
		out = append(out, "  Not an error this script has been taught. The usual causes:",
			"    MaxSpotInstanceCountExceeded   your old allocation, wait ~2 minutes",
			fmt.Sprintf("    InsufficientInstanceCapacity   region short of %s, GAME_SPOT=0 cg init", orStr(f.Type, "the instance")),
			fmt.Sprintf("    VcpuLimitExceeded              quota smaller than %s needs", orStr(f.Type, "the instance")),
			fmt.Sprintf("    AccessDenied on iam:PassRole   cannot pass %s", orStr(f.Profile, "the profile")),
			"  Spot requests: aws ec2 describe-spot-instance-requests --region "+r)
	}
	return append(out, "")
}

func orStr(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
