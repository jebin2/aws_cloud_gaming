// Package provision creates what a box needs before and while it launches: the
// bucket the game library lives in, the role the box assumes to reach it, the
// security group, the key pair, the user-data, the instance itself. Every step is
// idempotent, so running it again is also the repair path.
package provision

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"

	"github.com/jebin2/aws_cloud_gaming/internal/bucket"
)

// S3Admin is what making the bucket uses.
type S3Admin interface {
	HeadBucket(context.Context, *s3.HeadBucketInput, ...func(*s3.Options)) (*s3.HeadBucketOutput, error)
	CreateBucket(context.Context, *s3.CreateBucketInput, ...func(*s3.Options)) (*s3.CreateBucketOutput, error)
	PutPublicAccessBlock(context.Context, *s3.PutPublicAccessBlockInput, ...func(*s3.Options)) (*s3.PutPublicAccessBlockOutput, error)
	PutBucketEncryption(context.Context, *s3.PutBucketEncryptionInput, ...func(*s3.Options)) (*s3.PutBucketEncryptionOutput, error)
	PutBucketLifecycleConfiguration(context.Context, *s3.PutBucketLifecycleConfigurationInput, ...func(*s3.Options)) (*s3.PutBucketLifecycleConfigurationOutput, error)
	PutBucketTagging(context.Context, *s3.PutBucketTaggingInput, ...func(*s3.Options)) (*s3.PutBucketTaggingOutput, error)
}

// IAMAdmin is what making the role and the instance profile uses.
type IAMAdmin interface {
	GetRole(context.Context, *iam.GetRoleInput, ...func(*iam.Options)) (*iam.GetRoleOutput, error)
	CreateRole(context.Context, *iam.CreateRoleInput, ...func(*iam.Options)) (*iam.CreateRoleOutput, error)
	PutRolePolicy(context.Context, *iam.PutRolePolicyInput, ...func(*iam.Options)) (*iam.PutRolePolicyOutput, error)
	TagRole(context.Context, *iam.TagRoleInput, ...func(*iam.Options)) (*iam.TagRoleOutput, error)
	GetInstanceProfile(context.Context, *iam.GetInstanceProfileInput, ...func(*iam.Options)) (*iam.GetInstanceProfileOutput, error)
	CreateInstanceProfile(context.Context, *iam.CreateInstanceProfileInput, ...func(*iam.Options)) (*iam.CreateInstanceProfileOutput, error)
	TagInstanceProfile(context.Context, *iam.TagInstanceProfileInput, ...func(*iam.Options)) (*iam.TagInstanceProfileOutput, error)
	AddRoleToInstanceProfile(context.Context, *iam.AddRoleToInstanceProfileInput, ...func(*iam.Options)) (*iam.AddRoleToInstanceProfileOutput, error)
}

// Library ensures the durable half of the game library: an S3 bucket to hold it,
// and an EC2 instance profile that lets the box read and write that one bucket.
//
// Why S3 and not the EBS volume this replaces: a 160 GB gp3 volume bills
// INR 1,284/month whether or not the box exists, and it pins every launch to one
// AZ because EBS cannot cross one. The same library in S3 Standard is INR
// ~310/month and unpins the AZ.
//
// Credentials: an instance ROLE, not an access key. The box is the one machine
// here that can borrow an identity from EC2, so it should - there is no secret to
// leak, rotate or accidentally commit.
type Library struct {
	S3      S3Admin
	IAM     IAMAdmin
	Account string
	Host    string
	Region  string
	// Named is GAME_S3_BUCKET when .env names one; the derived name otherwise.
	Named  string
	TagKey string
	Note   func(string)
	Sleep  func(time.Duration)
}

func (l Library) sleep(d time.Duration) {
	if l.Sleep != nil {
		l.Sleep(d)
		return
	}
	time.Sleep(d)
}

// Role is the role (and the instance profile) the box assumes.
func (l Library) Role() string { return l.Host + "-box" }

// Bucket is the bucket in use. Bucket names are globally unique, so it cannot just
// be "cg-library": it is derived from the account, host AND REGION so it is the
// SAME name every time this runs in the same place - and hashed rather than
// embedding the account number, which does not belong in a name that is
// effectively public. The region is in there because a bucket IS regional and the
// name was not: moving GAME_REGION derived the old region's bucket's name, found
// it, and used it - so the box pulled its library across regions, and its
// presigned host bundle was signed for the wrong region and came back 400.
func (l Library) Bucket() string {
	if l.Named != "" {
		return l.Named
	}
	return bucket.Name(l.Account, l.Host, l.Region)
}

func code(err error) string {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		return ae.ErrorCode()
	}
	return ""
}

// Ensure makes the bucket, the role, its policy and the profile, and returns the
// bucket's name.
func (l Library) Ensure(ctx context.Context) (string, error) {
	b := l.Bucket()
	if _, err := l.S3.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(b)}); err == nil {
		l.Note(fmt.Sprintf("bucket %s exists", b))
	} else {
		l.Note(fmt.Sprintf("creating bucket %s in %s", b, l.Region))
		in := &s3.CreateBucketInput{Bucket: aws.String(b)}
		// us-east-1 is the one region that rejects a LocationConstraint.
		if l.Region != "us-east-1" {
			in.CreateBucketConfiguration = &s3types.CreateBucketConfiguration{LocationConstraint: s3types.BucketLocationConstraint(l.Region)}
		}
		// The name is derived from the account, so `cg destroy --all` followed by
		// `cg init` recreates the SAME name - and S3 refuses that for a short while
		// after a delete with OperationAborted. It is a propagation delay, not a
		// failure, so it is waited out here rather than surfaced as an init that
		// works on the second try and looks flaky on the first.
		for attempt := 1; ; attempt++ {
			_, err := l.S3.CreateBucket(ctx, in)
			if err == nil {
				break
			}
			if attempt == 8 {
				return "", fmt.Errorf("could not create bucket %s after %d attempts.\nIf you just ran 'cg destroy --all', S3 can hold the name for a few\nminutes. Wait and run cg init again; nothing else is wrong. (%s)", b, attempt, firstLine(err))
			}
			l.Note(fmt.Sprintf("S3 has not released the name yet (attempt %d) - waiting 15s", attempt))
			l.sleep(15 * time.Second)
		}
	}

	// Applied every run, not only on the run that created the bucket. Both are
	// idempotent PUTs and both are things you want to be true of the bucket
	// whatever its history: a bucket that already existed - made by hand, made by
	// an older version, or restored - would otherwise get NEITHER.
	if _, err := l.S3.PutPublicAccessBlock(ctx, &s3.PutPublicAccessBlockInput{Bucket: aws.String(b), PublicAccessBlockConfiguration: &s3types.PublicAccessBlockConfiguration{
		BlockPublicAcls: aws.Bool(true), IgnorePublicAcls: aws.Bool(true), BlockPublicPolicy: aws.Bool(true), RestrictPublicBuckets: aws.Bool(true)}}); err != nil {
		l.Note("could not set the public access block (not fatal)")
	}
	if _, err := l.S3.PutBucketEncryption(ctx, &s3.PutBucketEncryptionInput{Bucket: aws.String(b), ServerSideEncryptionConfiguration: &s3types.ServerSideEncryptionConfiguration{
		Rules: []s3types.ServerSideEncryptionRule{{ApplyServerSideEncryptionByDefault: &s3types.ServerSideEncryptionByDefault{SSEAlgorithm: s3types.ServerSideEncryptionAes256}}}}}); err != nil {
		l.Note("could not set default encryption (not fatal)")
	}
	// Abandoned multipart uploads bill as storage forever and appear in no listing
	// - the classic S3 leak. A 140 GB push that dies halfway would otherwise cost
	// real money invisibly.
	if _, err := l.S3.PutBucketLifecycleConfiguration(ctx, &s3.PutBucketLifecycleConfigurationInput{Bucket: aws.String(b), LifecycleConfiguration: &s3types.BucketLifecycleConfiguration{
		Rules: []s3types.LifecycleRule{{ID: aws.String("abort-incomplete-multipart"), Status: s3types.ExpirationStatusEnabled, Filter: &s3types.LifecycleRuleFilter{},
			AbortIncompleteMultipartUpload: &s3types.AbortIncompleteMultipartUpload{DaysAfterInitiation: aws.Int32(3)}}}}}); err != nil {
		l.Note("could not set the lifecycle rule (not fatal)")
	}

	role := l.Role()
	if _, err := l.IAM.GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String(role)}); err != nil {
		l.Note("creating role " + role)
		if _, err := l.IAM.CreateRole(ctx, &iam.CreateRoleInput{RoleName: aws.String(role), Description: aws.String("cloud_gaming box: read/write its own game library bucket"),
			AssumeRolePolicyDocument: aws.String(`{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}`)}); err != nil {
			return "", fmt.Errorf("could not create the role %s: %s", role, firstLine(err))
		}
	}
	// put-role-policy overwrites, so this also repairs a policy edited by hand.
	// Deliberately narrow: this one bucket, nothing else in the account. The worst
	// a compromised box can do to AWS is damage its own game library.
	if _, err := l.IAM.PutRolePolicy(ctx, &iam.PutRolePolicyInput{RoleName: aws.String(role), PolicyName: aws.String("library-rw"),
		PolicyDocument: aws.String(fmt.Sprintf(`{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::%s"},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],"Resource":"arn:aws:s3:::%s/*"}]}`, b, b))}); err != nil {
		return "", fmt.Errorf("could not set the role's policy: %s", firstLine(err))
	}

	// cg's tag, on the role and the bucket - every run, so ones made before the tag
	// existed get it too. Tagged apart from creating them, and never fatal: a key
	// without the tagging permissions still builds.
	tag := l.TagKey
	if tag == "" {
		tag = "cg:host"
	}
	_, _ = l.IAM.TagRole(ctx, &iam.TagRoleInput{RoleName: aws.String(role), Tags: []iamtypes.Tag{{Key: aws.String(tag), Value: aws.String(l.Host)}}})
	_, _ = l.S3.PutBucketTagging(ctx, &s3.PutBucketTaggingInput{Bucket: aws.String(b), Tagging: &s3types.Tagging{TagSet: []s3types.Tag{{Key: aws.String(tag), Value: aws.String(l.Host)}}}})

	// An instance profile is a separate object that wraps the role; run-instances
	// takes the profile, not the role, and the two are easy to confuse.
	if _, err := l.IAM.GetInstanceProfile(ctx, &iam.GetInstanceProfileInput{InstanceProfileName: aws.String(role)}); err != nil {
		l.Note("creating instance profile " + role)
		if _, err := l.IAM.CreateInstanceProfile(ctx, &iam.CreateInstanceProfileInput{InstanceProfileName: aws.String(role)}); err != nil {
			return "", fmt.Errorf("could not create the instance profile %s: %s", role, firstLine(err))
		}
	}
	_, _ = l.IAM.TagInstanceProfile(ctx, &iam.TagInstanceProfileInput{InstanceProfileName: aws.String(role), Tags: []iamtypes.Tag{{Key: aws.String(tag), Value: aws.String(l.Host)}}})
	has := false
	if p, err := l.IAM.GetInstanceProfile(ctx, &iam.GetInstanceProfileInput{InstanceProfileName: aws.String(role)}); err == nil && len(p.InstanceProfile.Roles) > 0 {
		has = aws.ToString(p.InstanceProfile.Roles[0].RoleName) == role
	}
	if !has {
		_, _ = l.IAM.AddRoleToInstanceProfile(ctx, &iam.AddRoleToInstanceProfileInput{InstanceProfileName: aws.String(role), RoleName: aws.String(role)})
	}
	return b, nil
}

func firstLine(err error) string {
	return strings.SplitN(strings.TrimSpace(err.Error()), "\n", 2)[0]
}
