// Package costfacts collects what `cg cost` is built from: the box, the disks,
// images and snapshots cg owns, the month's Cost Explorer answer, and the
// prices. Every fact says whether it could be read. A failed read is unknown,
// never empty and never zero: "AWS could not be asked" is not "nothing exists".
package costfacts

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"
)

// Known is a value and whether it could be read.
type Known[T any] struct {
	V  T
	OK bool
}

func ok[T any](v T) Known[T] { return Known[T]{V: v, OK: true} }

// EC2API is the part of the EC2 client cost uses; the SDK client satisfies it.
type EC2API interface {
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
	DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error)
	DescribeImages(context.Context, *ec2.DescribeImagesInput, ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
	DescribeSnapshots(context.Context, *ec2.DescribeSnapshotsInput, ...func(*ec2.Options)) (*ec2.DescribeSnapshotsOutput, error)
	DescribeAddresses(context.Context, *ec2.DescribeAddressesInput, ...func(*ec2.Options)) (*ec2.DescribeAddressesOutput, error)
	DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error)
	DescribeSecurityGroups(context.Context, *ec2.DescribeSecurityGroupsInput, ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error)
	DescribeSpotPriceHistory(context.Context, *ec2.DescribeSpotPriceHistoryInput, ...func(*ec2.Options)) (*ec2.DescribeSpotPriceHistoryOutput, error)
}

func filter(name string, values ...string) types.Filter {
	return types.Filter{Name: aws.String(name), Values: values}
}

// Instance is the box, found by its Name tag rather than trusted from .env:
// after a destroy the variable is gone, and after a manual launch it may be
// stale. Either way `cost` must still report, because the point is finding
// what still bills.
type Instance struct {
	ID        string
	State     string
	Type      string
	Lifecycle string // "spot" or empty
	AZ        string
}

// Volume is a disk and when it was made, so it is charged from then and not
// from the first of the month.
type Volume struct {
	ID      string
	GB      float64
	AZ      string
	Created time.Time
}

// Image is a saved image of the box and the snapshots behind it.
type Image struct {
	ID        string
	Snapshots []Snapshot
}

// Snapshot is one block snapshot: the size it was taken FROM, which is the most
// it can bill (AWS bills only the changed blocks).
type Snapshot struct {
	ID string
	GB float64
}

func code(err error) string {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		return ae.ErrorCode()
	}
	return ""
}

func (g *Gatherer) instance(ctx context.Context) Known[*Instance] {
	var found *Instance
	var token *string
	for {
		out, err := g.EC2.DescribeInstances(ctx, &ec2.DescribeInstancesInput{
			Filters: []types.Filter{
				filter("tag:Name", g.Host),
				filter("instance-state-name", "pending", "running", "stopping", "stopped"),
			},
			NextToken: token,
		})
		if err != nil {
			return Known[*Instance]{}
		}
		for _, r := range out.Reservations {
			for _, i := range r.Instances {
				if found == nil {
					in := &Instance{ID: aws.ToString(i.InstanceId), Type: string(i.InstanceType),
						Lifecycle: string(i.InstanceLifecycle)}
					if i.State != nil {
						in.State = string(i.State.Name)
					}
					if i.Placement != nil {
						in.AZ = aws.ToString(i.Placement.AvailabilityZone)
					}
					found = in
				}
			}
		}
		if out.NextToken == nil || *out.NextToken == "" {
			return ok(found)
		}
		token = out.NextToken
	}
}

func (g *Gatherer) volumes(ctx context.Context, filters []types.Filter) ([]Volume, error) {
	var out []Volume
	var token *string
	for {
		r, err := g.EC2.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{Filters: filters, NextToken: token})
		if err != nil {
			return nil, err
		}
		for _, v := range r.Volumes {
			vol := Volume{ID: aws.ToString(v.VolumeId), GB: float64(aws.ToInt32(v.Size)), AZ: aws.ToString(v.AvailabilityZone)}
			if v.CreateTime != nil {
				vol.Created = *v.CreateTime
			}
			out = append(out, vol)
		}
		if r.NextToken == nil || *r.NextToken == "" {
			return out, nil
		}
		token = r.NextToken
	}
}

// ownedVolumes are cg's leftovers: unattached, tagged cg:host=<host> and, with
// games, the legacy games volume by the exact name cg gave it. Every volume in
// the region was counted once, another project's too, and called cg's.
func (g *Gatherer) ownedVolumes(ctx context.Context, games bool) ([]Volume, error) {
	vols, err := g.volumes(ctx, []types.Filter{filter("status", "available"), filter("tag:"+g.TagKey, g.Host)})
	if err != nil {
		return nil, err
	}
	if games {
		more, err := g.volumes(ctx, []types.Filter{filter("status", "available"), filter("tag:Name", g.Host+"-games")})
		if err != nil {
			return nil, err
		}
		vols = append(vols, more...)
	}
	return vols, nil
}

func (g *Gatherer) images(ctx context.Context) ([]Image, error) {
	var out []Image
	seen := map[string]bool{}
	for _, f := range [][]types.Filter{
		{filter("tag:"+g.TagKey, g.Host)},
		{filter("tag:Name", g.Host+"-image")}, // the exact name cg gave them before the tag
	} {
		var token *string
		for {
			r, err := g.EC2.DescribeImages(ctx, &ec2.DescribeImagesInput{Owners: []string{"self"}, Filters: f, NextToken: token})
			if err != nil {
				return nil, err
			}
			for _, im := range r.Images {
				id := aws.ToString(im.ImageId)
				if seen[id] {
					continue
				}
				seen[id] = true
				img := Image{ID: id}
				for _, b := range im.BlockDeviceMappings {
					if b.Ebs != nil && aws.ToString(b.Ebs.SnapshotId) != "" {
						img.Snapshots = append(img.Snapshots, Snapshot{aws.ToString(b.Ebs.SnapshotId), float64(aws.ToInt32(b.Ebs.VolumeSize))})
					}
				}
				out = append(out, img)
			}
			if r.NextToken == nil || *r.NextToken == "" {
				break
			}
			token = r.NextToken
		}
	}
	return out, nil
}

func (g *Gatherer) taggedSnapshots(ctx context.Context) ([]Snapshot, error) {
	var out []Snapshot
	var token *string
	for {
		r, err := g.EC2.DescribeSnapshots(ctx, &ec2.DescribeSnapshotsInput{
			OwnerIds: []string{"self"}, Filters: []types.Filter{filter("tag:"+g.TagKey, g.Host)}, NextToken: token})
		if err != nil {
			return nil, err
		}
		for _, s := range r.Snapshots {
			out = append(out, Snapshot{aws.ToString(s.SnapshotId), float64(aws.ToInt32(s.VolumeSize))})
		}
		if r.NextToken == nil || *r.NextToken == "" {
			return out, nil
		}
		token = r.NextToken
	}
}

// spotPrice is what a spot machine costs an hour now, in its own zone; nil when
// AWS would not say.
func (g *Gatherer) spotPrice(ctx context.Context, in Instance, now time.Time) *float64 {
	r, err := g.EC2.DescribeSpotPriceHistory(ctx, &ec2.DescribeSpotPriceHistoryInput{
		InstanceTypes:       []types.InstanceType{types.InstanceType(in.Type)},
		ProductDescriptions: []string{"Linux/UNIX"},
		AvailabilityZone:    aws.String(in.AZ),
		StartTime:           aws.Time(now),
	})
	if err != nil || len(r.SpotPriceHistory) == 0 {
		return nil
	}
	return parseFloat(aws.ToString(r.SpotPriceHistory[0].SpotPrice))
}

func (g *Gatherer) keyPair(ctx context.Context) Known[bool] {
	_, err := g.EC2.DescribeKeyPairs(ctx, &ec2.DescribeKeyPairsInput{KeyNames: []string{g.Host}})
	switch {
	case err == nil:
		return ok(true)
	case code(err) == "InvalidKeyPair.NotFound":
		return ok(false)
	}
	return Known[bool]{}
}

func (g *Gatherer) securityGroup(ctx context.Context) Known[bool] {
	r, err := g.EC2.DescribeSecurityGroups(ctx, &ec2.DescribeSecurityGroupsInput{
		Filters: []types.Filter{filter("group-name", g.Host+"-sg")}})
	if err != nil {
		return Known[bool]{}
	}
	return ok(len(r.SecurityGroups) > 0)
}

func (g *Gatherer) addresses(ctx context.Context) Known[int] {
	r, err := g.EC2.DescribeAddresses(ctx, &ec2.DescribeAddressesInput{})
	if err != nil {
		return Known[int]{}
	}
	return ok(len(r.Addresses))
}

// legacyGames is the old EBS games volume, in any state: the game library is in
// S3 now, and the only thing worth saying about the volume is that it still
// bills.
func (g *Gatherer) legacyGames(ctx context.Context) Known[*LegacyVolume] {
	vols, err := g.volumes(ctx, []types.Filter{filter("tag:Name", g.Host+"-games")})
	if err != nil {
		return Known[*LegacyVolume]{}
	}
	if len(vols) == 0 {
		return ok[*LegacyVolume](nil)
	}
	return ok(&LegacyVolume{ID: vols[0].ID, GB: vols[0].GB, AZ: vols[0].AZ})
}

// LegacyVolume is the old games disk.
type LegacyVolume struct {
	ID string
	GB float64
	AZ string
}

func parseFloat(s string) *float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil {
		return nil
	}
	return &v
}
