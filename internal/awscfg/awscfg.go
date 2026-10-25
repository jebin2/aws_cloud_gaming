// Package awscfg builds the AWS SDK configuration every command uses: the
// region, the credentials, a User-Agent that names cg, and an endpoint
// override so tests can point the SDK at a fake.
package awscfg

import (
	"context"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
)

// New returns the SDK config for a region. CG_AWS_ENDPOINT, if set, sends
// every call to that URL; it exists for the tests and is not documented to
// users.
func New(ctx context.Context, region string) (aws.Config, error) {
	opts := []func(*config.LoadOptions) error{config.WithAppID("cg")}
	if region != "" {
		opts = append(opts, config.WithRegion(region))
	}
	if u := os.Getenv("CG_AWS_ENDPOINT"); u != "" {
		opts = append(opts, config.WithBaseEndpoint(u))
	}
	return config.LoadDefaultConfig(ctx, opts...)
}
