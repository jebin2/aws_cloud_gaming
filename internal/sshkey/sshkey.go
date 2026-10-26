// Package sshkey is whether this laptop holds the private key of the box's EC2
// key pair.
//
// AWS hands a key pair's private key out once, when the pair is created. A second
// laptop, or a lost .pem, therefore had no way in to a box launched with that
// pair: `cg init` reused the pair, and every ssh step of the build failed. The
// pair is now reused only when the .pem here is its private key.
package sshkey

import (
	"context"
	"crypto/sha1"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"
)

// EC2 is the two calls the comparison needs.
type EC2 interface {
	DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error)
	DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
}

// State is how the pair and the .pem here relate.
type State string

const (
	None     State = "none"     // AWS has no key pair of that name
	Match    State = "match"    // the .pem here is its private key
	Missing  State = "missing"  // AWS has the pair, and there is no .pem here
	Mismatch State = "mismatch" // AWS has the pair, and the .pem here is some other key
	Unknown  State = "unknown"  // they cannot be compared: AWS did not answer, or the pair was imported
)

// Fingerprint is the SHA-1 of a private key as PKCS#8 DER, as colon-separated
// hex: what AWS reports for a pair it created (59 characters). Checked against a
// real pair on 2026-09-15. An imported pair's is an MD5 of the public key
// instead, and is not compared.
func Fingerprint(pemBytes []byte) (string, error) {
	blk, _ := pem.Decode(pemBytes)
	if blk == nil {
		return "", errors.New("not a PEM file")
	}
	var der []byte
	switch blk.Type {
	case "RSA PRIVATE KEY":
		k, err := x509.ParsePKCS1PrivateKey(blk.Bytes)
		if err != nil {
			return "", err
		}
		if der, err = x509.MarshalPKCS8PrivateKey(k); err != nil {
			return "", err
		}
	case "PRIVATE KEY":
		der = blk.Bytes
	default:
		return "", errors.New("unsupported key type " + blk.Type)
	}
	sum := sha1.Sum(der)
	parts := make([]string, len(sum))
	for i, b := range sum {
		parts[i] = fmt.Sprintf("%02x", b)
	}
	return strings.Join(parts, ":"), nil
}

// Check compares the pair AWS holds with the .pem here.
func Check(ctx context.Context, c EC2, name, pemPath string) State {
	o, err := c.DescribeKeyPairs(ctx, &ec2.DescribeKeyPairsInput{KeyNames: []string{name}})
	if err != nil {
		var ae smithy.APIError
		if errors.As(err, &ae) && ae.ErrorCode() == "InvalidKeyPair.NotFound" {
			return None
		}
		return Unknown
	}
	if len(o.KeyPairs) == 0 {
		return None
	}
	b, err := os.ReadFile(pemPath)
	if err != nil {
		return Missing
	}
	fp := strings.Join(strings.Fields(aws.ToString(o.KeyPairs[0].KeyFingerprint)), "")
	if len(fp) != 59 {
		return Unknown
	}
	mine, err := Fingerprint(b)
	if err != nil {
		return Mismatch
	}
	if strings.EqualFold(mine, fp) {
		return Match
	}
	return Mismatch
}

// Words says what is wrong with the .pem.
func Words(s State) string {
	switch s {
	case Missing:
		return "not on this laptop"
	case Mismatch:
		return "not the key pair's private key"
	}
	return ""
}

// BoxExists is whether a box of that name is up or stopped: replacing the pair
// would not let this laptop log in to it.
func BoxExists(ctx context.Context, c EC2, name string) bool {
	o, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{Filters: []types.Filter{
		{Name: aws.String("tag:Name"), Values: []string{name}},
		{Name: aws.String("instance-state-name"), Values: []string{"pending", "running", "stopping", "stopped"}},
	}})
	if err != nil {
		return false
	}
	for _, r := range o.Reservations {
		if len(r.Instances) > 0 {
			return true
		}
	}
	return false
}

// KeyAdmin is what making a key pair uses.
type KeyAdmin interface {
	EC2
	DeleteKeyPair(context.Context, *ec2.DeleteKeyPairInput, ...func(*ec2.Options)) (*ec2.DeleteKeyPairOutput, error)
	CreateKeyPair(context.Context, *ec2.CreateKeyPairInput, ...func(*ec2.Options)) (*ec2.CreateKeyPairOutput, error)
}

// Ensure leaves a key pair this laptop can log in with. Only where no box uses the
// pair: the check stops a build that would reuse one. A pair this laptop holds the
// private key of (or cannot compare) is kept; otherwise it is replaced, the old
// .pem is kept beside it under a new name, and the new private key is written for
// its owner alone. AWS hands a private key out once, which is why the pair is
// reused only when the .pem is here.
func Ensure(ctx context.Context, c KeyAdmin, name, pem, tagKey string, say func(string), now func() time.Time) error {
	state := Check(ctx, c, name, pem)
	switch state {
	case Match, Unknown:
		return nil
	case Missing, Mismatch:
		say(fmt.Sprintf("==> replacing key pair %s - %s is %s", name, pem, Words(state)))
		if _, err := c.DeleteKeyPair(ctx, &ec2.DeleteKeyPairInput{KeyName: aws.String(name)}); err != nil {
			return err
		}
	}
	if _, err := os.Stat(pem); err == nil {
		keep := strings.TrimSuffix(pem, ".pem") + "-replaced-" + now().Format("20060102150405") + ".pem"
		if os.Rename(pem, keep) == nil {
			say("    the old file is kept as " + keep)
		}
	}
	say("==> creating key pair -> " + pem)
	if tagKey == "" {
		tagKey = "cg:host"
	}
	o, err := c.CreateKeyPair(ctx, &ec2.CreateKeyPairInput{KeyName: aws.String(name), TagSpecifications: []types.TagSpecification{
		{ResourceType: types.ResourceTypeKeyPair, Tags: []types.Tag{{Key: aws.String(tagKey), Value: aws.String(name)}}}}})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(pem), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(pem, []byte(aws.ToString(o.KeyMaterial)), 0o600); err != nil {
		os.Remove(pem)
		return err
	}
	return os.Chmod(pem, 0o600)
}
