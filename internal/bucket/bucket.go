// Package bucket names the game archive's S3 bucket. A bucket name is global,
// so it cannot just be "cg-library"; it is hashed from the account, the host
// and the region rather than spelling out the account number, which ends up in
// URLs and logs. The region is in the hash because a bucket IS regional.
package bucket

import (
	"crypto/sha256"
	"fmt"
)

// Name is the bucket cg derives for an account, host and region.
func Name(account, host, region string) string {
	sum := sha256.Sum256([]byte(account + "-" + host + "-" + region))
	return fmt.Sprintf("cg-library-%x", sum)[:len("cg-library-")+12]
}

// NameNoRegion is the name cg used before the region was in the hash. A bucket
// still carrying it is cg's, and is recognised, never created.
func NameNoRegion(account, host string) string {
	sum := sha256.Sum256([]byte(account + "-" + host))
	return fmt.Sprintf("cg-library-%x", sum)[:len("cg-library-")+12]
}
