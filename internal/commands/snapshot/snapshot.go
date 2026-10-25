// Package snapshot is `cg snapshot`. Only the listing is ported so far.
//
// Images bill every month, forever, and nothing else here lists them - a
// create-only snapshot command is a slow leak.
package snapshot

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"

	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// Image is a saved image of the box, newest first.
type Image struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Created string `json:"created"`
	State   string `json:"state"`
	GB      *int32 `json:"gb"`
}

// EC2API is what the listing reads.
type EC2API interface {
	DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
}

// List reads the images this account owns, newest first.
func List(ctx context.Context, c EC2API) ([]Image, error) {
	o, err := c.DescribeImages(ctx, &ec2.DescribeImagesInput{Owners: []string{"self"}})
	if err != nil {
		return nil, err
	}
	out := []Image{}
	for _, im := range o.Images {
		i := Image{ID: aws.ToString(im.ImageId), Name: aws.ToString(im.Name), Created: aws.ToString(im.CreationDate), State: string(im.State)}
		if len(im.BlockDeviceMappings) > 0 && im.BlockDeviceMappings[0].Ebs != nil {
			i.GB = im.BlockDeviceMappings[0].Ebs.VolumeSize
		}
		out = append(out, i)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Created > out[j].Created })
	return out, nil
}

// Show is the table. The size is the volume the image was taken from - the most
// its snapshot can bill.
func Show(imgs []Image, rate, inr *float64) string {
	if len(imgs) == 0 {
		return "no saved images - nothing billing\n"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%-24s%-22s%4s  %8s  NAME\n", "IMAGE", "CREATED", "GB", "~USD/mo")
	tot := 0.0
	for _, i := range imgs {
		gb := int32(0)
		if i.GB != nil {
			gb = *i.GB
		}
		mo := "?"
		if rate != nil {
			m := float64(gb) * *rate
			tot += m
			mo = fmt.Sprintf("%.2f", m)
		}
		created := i.Created
		if len(created) > 19 {
			created = created[:19]
		}
		fmt.Fprintf(&b, "%-24s%-22s%4d  %8s  %s\n", i.ID, created, gb, mo, i.Name)
	}
	if rate == nil {
		fmt.Fprintf(&b, "\n%d image(s) - the snapshot price could not be read from AWS\n", len(imgs))
	} else {
		more := ""
		if inr != nil {
			more = fmt.Sprintf(" (~INR %.0f)", tot**inr)
		}
		fmt.Fprintf(&b, "\nat most %.2f USD/month%s for %d image(s)\n", tot, more, len(imgs))
	}
	b.WriteString("delete one with:  cg snapshot --delete <image-id>\n")
	return b.String()
}

// Run is `cg snapshot`.
func Run(ctx context.Context, env *config.Env, args []string, jsonFlag bool, out *output.Out) int {
	sub := "create"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "--list", "list":
	case "--delete", "delete", "create", "":
		out.Die("snapshot " + sub + " is not ported to Go yet")
		return 1
	default:
		out.Die("usage: cg snapshot [create|--list|--delete <id>]")
		return 1
	}
	cfg, err := awscfg.New(ctx, env.Region())
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	imgs, err := List(ctx, ec2.NewFromConfig(cfg))
	if err != nil {
		out.Die("could not list the saved images: " + err.Error())
		return 1
	}
	if jsonFlag {
		b, _ := json.Marshal(imgs)
		fmt.Fprintf(out.Stdout, "%s\n", b)
		return 0
	}
	us, _ := awscfg.New(ctx, "us-east-1")
	rates := pricing.Load(ctx, pricing.Options{Getenv: env.Get,
		Source: pricing.AWSSource{API: pricing.SDKProducts{Client: awspricing.NewFromConfig(us)}}}, env.Region())
	out.Report("Saved images", Show(imgs, rates.SnapshotGBMonth, rates.INRPerUSD))
	return 0
}
