// Package library is the game archive in S3: what is in it, what it costs, and
// where else cg has left games. Everything here is read-only and answers
// without the box - the archive outlives every box, so "what is saved, and as
// whom would a new box sign in" has to be answerable when there is none.
package library

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Object is one key in a listing.
type Object struct {
	Key      string
	Size     int64
	Modified time.Time
}

// Head is an object's metadata.
type Head struct {
	Size     int64
	Modified time.Time
	ETag     string
}

// ErrNotFound is a key or bucket that is not there. It is not a failure: a
// bucket we can read that holds no index really is an empty archive.
var ErrNotFound = errors.New("not found")

// Store is S3, as far as the archive uses it. Region is the bucket's own: a
// client for another region is not the same client.
type Store interface {
	Get(ctx context.Context, bucket, region, key string) ([]byte, error)
	Head(ctx context.Context, bucket, region, key string) (Head, error)
	List(ctx context.Context, bucket, region, prefix string) ([]Object, error)
	// Location is the region a bucket is in.
	Location(ctx context.Context, bucket string) (string, error)
	// Buckets is the name of every bucket in the account.
	Buckets(ctx context.Context) ([]string, error)
}

// Reason turns an S3 failure into a sentence, or "missing" when the thing is
// simply not there. The reasons are not interchangeable: an index that could
// not be read must never read as an empty archive. That is the most alarming lie
// this tool can tell, and it told it for free when failures ended in
// `|| echo '{"apps":[]}'`: expired credentials, a denied bucket or a dead
// network all came out as "the archive is empty" about 160 GB of games sitting
// safely in S3.
func Reason(err error, bucket string) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, ErrNotFound) {
		return "missing"
	}
	e := err.Error()
	has := func(s ...string) bool {
		for _, x := range s {
			if strings.Contains(e, x) {
				return true
			}
		}
		return false
	}
	switch {
	case has("InvalidAccessKeyId", "InvalidClientTokenId", "SignatureDoesNotMatch", "ExpiredToken", "security token"):
		return "the AWS credentials are not valid - check: aws sts get-caller-identity"
	case has("NoSuchBucket"):
		return fmt.Sprintf("the bucket s3://%s does not exist", bucket)
	case has("AccessDenied", "Access Denied"):
		return fmt.Sprintf("these AWS credentials may not read s3://%s", bucket)
	// HeadObject answers 403 both for a key that is denied and for credentials
	// that no longer exist, so the message must cover both rather than guess.
	case has("403", "Forbidden"):
		return fmt.Sprintf("S3 refused the read (403) - the credentials are invalid, or may not read s3://%s. Check: aws sts get-caller-identity", bucket)
	case has("EndpointConnectionError", "Could not connect", "Connect timeout", "Unable to locate credentials",
		"no such host", "connection refused", "i/o timeout", "failed to refresh cached credentials"):
		return "cannot reach S3 - no network, or no credentials configured"
	case has("404", "Not Found", "does not exist", "NoSuchKey"):
		return "missing"
	case strings.TrimSpace(e) == "":
		return "the S3 read failed and said nothing"
	}
	return strings.SplitN(strings.TrimSpace(e), "\n", 2)[0]
}
