package storage

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/service/ec2"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
)

// failing is a region whose client could not even be built: every read of it
// fails, so the region is reported as unreadable rather than empty.
type failing struct{ costfacts.EC2API }

func (failing) DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	return nil, fmt.Errorf("no client for the region")
}

// ForHost is a gatherer per region on the real EC2.
func ForHost(ctx context.Context, host string) func(region string) *costfacts.Gatherer {
	return func(region string) *costfacts.Gatherer {
		c, err := awscfg.New(ctx, region)
		if err != nil {
			return &costfacts.Gatherer{EC2: failing{}, Host: host, TagKey: config.TagKey}
		}
		return &costfacts.Gatherer{EC2: ec2.NewFromConfig(c), Host: host, TagKey: config.TagKey}
	}
}
