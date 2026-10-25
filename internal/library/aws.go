package library

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/smithy-go"

	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
)

// AWSStore is the real Store: one client per region, because a bucket is
// regional and a request signed for the wrong region is refused.
type AWSStore struct {
	Home string // the region account-level calls (list buckets) are made from

	mu      sync.Mutex
	clients map[string]*s3.Client
}

func (a *AWSStore) client(ctx context.Context, region string) (*s3.Client, error) {
	if region == "" {
		region = a.Home
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if c, ok := a.clients[region]; ok {
		return c, nil
	}
	cfg, err := awscfg.New(ctx, region)
	if err != nil {
		return nil, err
	}
	if a.clients == nil {
		a.clients = map[string]*s3.Client{}
	}
	c := s3.NewFromConfig(cfg)
	a.clients[region] = c
	return c, nil
}

func notFound(err error) bool {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		switch ae.ErrorCode() {
		case "NoSuchKey", "NotFound", "404":
			return true
		}
	}
	var nf *s3types.NotFound
	var nk *s3types.NoSuchKey
	return errors.As(err, &nf) || errors.As(err, &nk)
}

func (a *AWSStore) Get(ctx context.Context, bucket, region, key string) ([]byte, error) {
	c, err := a.client(ctx, region)
	if err != nil {
		return nil, err
	}
	o, err := c.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		if notFound(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	defer o.Body.Close()
	var buf bytes.Buffer
	_, err = io.Copy(&buf, io.LimitReader(o.Body, 64<<20))
	return buf.Bytes(), err
}

func (a *AWSStore) Head(ctx context.Context, bucket, region, key string) (Head, error) {
	c, err := a.client(ctx, region)
	if err != nil {
		return Head{}, err
	}
	o, err := c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		if notFound(err) {
			return Head{}, ErrNotFound
		}
		return Head{}, err
	}
	h := Head{Size: aws.ToInt64(o.ContentLength), ETag: aws.ToString(o.ETag)}
	if o.LastModified != nil {
		h.Modified = *o.LastModified
	}
	return h, nil
}

func (a *AWSStore) List(ctx context.Context, bucket, region, prefix string) ([]Object, error) {
	c, err := a.client(ctx, region)
	if err != nil {
		return nil, err
	}
	var out []Object
	var token *string
	for {
		o, err := c.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: aws.String(bucket), Prefix: aws.String(prefix), ContinuationToken: token})
		if err != nil {
			return nil, err
		}
		for _, x := range o.Contents {
			obj := Object{Key: aws.ToString(x.Key), Size: aws.ToInt64(x.Size)}
			if x.LastModified != nil {
				obj.Modified = *x.LastModified
			}
			out = append(out, obj)
		}
		if !aws.ToBool(o.IsTruncated) {
			return out, nil
		}
		token = o.NextContinuationToken
	}
}

func (a *AWSStore) Location(ctx context.Context, bucket string) (string, error) {
	c, err := a.client(ctx, a.Home)
	if err != nil {
		return "", err
	}
	o, err := c.GetBucketLocation(ctx, &s3.GetBucketLocationInput{Bucket: aws.String(bucket)})
	if err != nil {
		return "", err
	}
	switch r := string(o.LocationConstraint); r {
	case "": // us-east-1 predates the location constraint and reports it as empty
		return "us-east-1", nil
	case "EU":
		return "eu-west-1", nil
	default:
		return r, nil
	}
}

func (a *AWSStore) Buckets(ctx context.Context) ([]string, error) {
	c, err := a.client(ctx, a.Home)
	if err != nil {
		return nil, err
	}
	var out []string
	var token *string
	for {
		o, err := c.ListBuckets(ctx, &s3.ListBucketsInput{ContinuationToken: token})
		if err != nil {
			return nil, err
		}
		for _, b := range o.Buckets {
			out = append(out, aws.ToString(b.Name))
		}
		if o.ContinuationToken == nil || *o.ContinuationToken == "" {
			return out, nil
		}
		token = o.ContinuationToken
	}
}

// SSMParams reads the marks.
type SSMParams struct{ Client *ssm.Client }

func (p SSMParams) Path(ctx context.Context, path string) (map[string]string, error) {
	out := map[string]string{}
	pg := ssm.NewGetParametersByPathPaginator(p.Client, &ssm.GetParametersByPathInput{Path: aws.String(path), Recursive: aws.Bool(true)})
	for pg.HasMorePages() {
		o, err := pg.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, x := range o.Parameters {
			out[aws.ToString(x.Name)] = aws.ToString(x.Value)
		}
	}
	return out, nil
}
