package library

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// copyLimit is the largest object one CopyObject can move; a bigger one is
// copied in parts, as `aws s3 sync` does.
const copyLimit = 5 << 30

// partSize is the size of one part of a large copy.
const partSize = 1 << 30

// Put writes an object.
func (a *AWSStore) Put(ctx context.Context, bucket, region, key string, body []byte) error {
	c, err := a.client(ctx, region)
	if err != nil {
		return err
	}
	_, err = c.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String(key), Body: strings.NewReader(string(body))})
	return err
}

// Delete removes one object. A key that is not there is not an error.
func (a *AWSStore) Delete(ctx context.Context, bucket, region, key string) error {
	c, err := a.client(ctx, region)
	if err != nil {
		return err
	}
	_, err = c.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	return err
}

// DeletePrefix removes everything under a prefix, a thousand keys at a time. A
// prefix with nothing under it deletes nothing and succeeds, so a failure here
// is AWS refusing - and what it kept still bills.
func (a *AWSStore) DeletePrefix(ctx context.Context, bucket, region, prefix string) error {
	c, err := a.client(ctx, region)
	if err != nil {
		return err
	}
	objs, err := a.List(ctx, bucket, region, prefix)
	if err != nil {
		return err
	}
	failed := 0
	for i := 0; i < len(objs); i += 1000 {
		end := min(i+1000, len(objs))
		var ids []s3types.ObjectIdentifier
		for _, o := range objs[i:end] {
			ids = append(ids, s3types.ObjectIdentifier{Key: aws.String(o.Key)})
		}
		out, err := c.DeleteObjects(ctx, &s3.DeleteObjectsInput{Bucket: aws.String(bucket), Delete: &s3types.Delete{Objects: ids, Quiet: aws.Bool(true)}})
		if err != nil {
			return err
		}
		failed += len(out.Errors)
	}
	if failed > 0 {
		return fmt.Errorf("%d objects could not be deleted", failed)
	}
	return nil
}

// Copy copies one object between buckets, between regions too: the request goes
// to the destination's region, which is where AWS bills the transfer from.
func (a *AWSStore) Copy(ctx context.Context, srcBucket, srcRegion, dstBucket, dstRegion, key string, size int64) error {
	c, err := a.client(ctx, dstRegion)
	if err != nil {
		return err
	}
	src := (&url.URL{Path: srcBucket + "/" + key}).EscapedPath()
	if size <= copyLimit {
		_, err = c.CopyObject(ctx, &s3.CopyObjectInput{Bucket: aws.String(dstBucket), Key: aws.String(key), CopySource: aws.String(src)})
		return err
	}
	mp, err := c.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{Bucket: aws.String(dstBucket), Key: aws.String(key)})
	if err != nil {
		return err
	}
	abort := func() {
		_, _ = c.AbortMultipartUpload(context.WithoutCancel(ctx), &s3.AbortMultipartUploadInput{Bucket: aws.String(dstBucket), Key: aws.String(key), UploadId: mp.UploadId})
	}
	var parts []s3types.CompletedPart
	for off, n := int64(0), int32(1); off < size; off, n = off+partSize, n+1 {
		end := min(off+partSize, size) - 1
		p, err := c.UploadPartCopy(ctx, &s3.UploadPartCopyInput{Bucket: aws.String(dstBucket), Key: aws.String(key), UploadId: mp.UploadId,
			PartNumber: aws.Int32(n), CopySource: aws.String(src), CopySourceRange: aws.String(fmt.Sprintf("bytes=%d-%d", off, end))})
		if err != nil {
			abort()
			return err
		}
		parts = append(parts, s3types.CompletedPart{ETag: p.CopyPartResult.ETag, PartNumber: aws.Int32(n)})
	}
	_, err = c.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{Bucket: aws.String(dstBucket), Key: aws.String(key), UploadId: mp.UploadId,
		MultipartUpload: &s3types.CompletedMultipartUpload{Parts: parts}})
	if err != nil {
		abort()
	}
	return err
}

// DeleteBucket removes an empty bucket, emptying it first.
func (a *AWSStore) DeleteBucket(ctx context.Context, bucket, region string) error {
	if err := a.DeletePrefix(ctx, bucket, region, ""); err != nil {
		return err
	}
	c, err := a.client(ctx, region)
	if err != nil {
		return err
	}
	_, err = c.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: aws.String(bucket)})
	return err
}
