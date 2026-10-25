package testfixture

import (
	"github.com/aws/aws-sdk-go-v2/aws"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func s3object(o Object) s3types.Object {
	return s3types.Object{Key: aws.String(o.Key), Size: aws.Int64(o.Size)}
}
