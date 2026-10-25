package snapshot

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

type fake struct{ imgs []ec2types.Image }

func (f fake) DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error) {
	return &ec2.DescribeImagesOutput{Images: f.imgs}, nil
}

func img(id, name, created string, gb int32) ec2types.Image {
	return ec2types.Image{ImageId: aws.String(id), Name: aws.String(name), CreationDate: aws.String(created), State: "available",
		BlockDeviceMappings: []ec2types.BlockDeviceMapping{{Ebs: &ec2types.EbsBlockDevice{VolumeSize: aws.Int32(gb)}}}}
}

func fl(v float64) *float64 { return &v }

func TestNewestFirstAndPriced(t *testing.T) {
	imgs, err := List(context.Background(), fake{[]ec2types.Image{
		img("ami-old", "gamevps-image-1", "2026-09-01T10:00:00.000Z", 50), img("ami-new", "gamevps-image-2", "2026-10-01T10:00:00.000Z", 100)}})
	if err != nil || imgs[0].ID != "ami-new" {
		t.Fatalf("%v %v", imgs, err)
	}
	text := Show(imgs, fl(0.05), fl(100))
	for _, want := range []string{"IMAGE", "ami-new                 2026-10-01T10:00:00    100      5.00  gamevps-image-2", "at most 7.50 USD/month (~INR 750) for 2 image(s)", "delete one with:  cg snapshot --delete <image-id>"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
}

func TestNothingAndAnUnknownPrice(t *testing.T) {
	if got := Show(nil, fl(0.05), nil); got != "no saved images - nothing billing\n" {
		t.Errorf("%q", got)
	}
	text := Show([]Image{{ID: "ami-1", Name: "n", Created: "2026-10-01T10:00:00Z", GB: func() *int32 { v := int32(40); return &v }()}}, nil, nil)
	if !strings.Contains(text, "?  n") || !strings.Contains(text, "1 image(s) - the snapshot price could not be read from AWS") || strings.Contains(text, "USD/month") {
		t.Errorf("an unknown price is a question mark, never zero:\n%s", text)
	}
}
