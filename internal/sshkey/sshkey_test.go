package sshkey

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/smithy-go"
)

type fake struct {
	fp       string
	err      error
	boxes    int
	describe int
}

func (f *fake) DescribeKeyPairs(context.Context, *ec2.DescribeKeyPairsInput, ...func(*ec2.Options)) (*ec2.DescribeKeyPairsOutput, error) {
	if f.err != nil {
		return nil, f.err
	}
	return &ec2.DescribeKeyPairsOutput{KeyPairs: []types.KeyPairInfo{{KeyFingerprint: aws.String(f.fp)}}}, nil
}

func (f *fake) DescribeInstances(context.Context, *ec2.DescribeInstancesInput, ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	o := &ec2.DescribeInstancesOutput{}
	if f.boxes > 0 {
		o.Reservations = []types.Reservation{{Instances: []types.Instance{{}}}}
	}
	return o, nil
}

func writeKey(t *testing.T, pkcs8 bool) (path string, k *rsa.PrivateKey) {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	blk := &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(k)}
	if pkcs8 {
		der, _ := x509.MarshalPKCS8PrivateKey(k)
		blk = &pem.Block{Type: "PRIVATE KEY", Bytes: der}
	}
	path = filepath.Join(t.TempDir(), "box.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(blk), 0o600); err != nil {
		t.Fatal(err)
	}
	return path, k
}

func TestFingerprintMatchesOpenSSL(t *testing.T) {
	if _, err := exec.LookPath("openssl"); err != nil {
		t.Skip("no openssl")
	}
	path, _ := writeKey(t, false)
	b, _ := os.ReadFile(path)
	got, err := Fingerprint(b)
	if err != nil || len(got) != 59 {
		t.Fatalf("%q %v", got, err)
	}
	// What the Bash compared with: pkcs8 DER, sha1, colon hex.
	out, err := exec.Command("sh", "-c", "openssl pkcs8 -in "+path+" -inform PEM -outform DER -topk8 -nocrypt | openssl sha1 -c").Output()
	if err != nil {
		t.Skip("openssl could not read it")
	}
	f := strings.Fields(string(out))
	if !strings.EqualFold(f[len(f)-1], got) {
		t.Errorf("openssl %s, go %s", f[len(f)-1], got)
	}
}

func TestStates(t *testing.T) {
	ctx := context.Background()
	path, _ := writeKey(t, true)
	b, _ := os.ReadFile(path)
	fp, _ := Fingerprint(b)
	other, _ := writeKey(t, false)

	if got := Check(ctx, &fake{fp: strings.ToUpper(fp)}, "n", path); got != Match {
		t.Errorf("match: %s", got)
	}
	if got := Check(ctx, &fake{fp: fp}, "n", other); got != Mismatch {
		t.Errorf("mismatch: %s", got)
	}
	if got := Check(ctx, &fake{fp: fp}, "n", filepath.Join(t.TempDir(), "none.pem")); got != Missing {
		t.Errorf("missing: %s", got)
	}
	// An imported pair's fingerprint is an MD5 of the public key: not compared.
	if got := Check(ctx, &fake{fp: "ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89"}, "n", path); got != Unknown {
		t.Errorf("imported: %s", got)
	}
	if got := Check(ctx, &fake{err: &smithy.GenericAPIError{Code: "InvalidKeyPair.NotFound"}}, "n", path); got != None {
		t.Errorf("none: %s", got)
	}
	if got := Check(ctx, &fake{err: errors.New("dial tcp: i/o timeout")}, "n", path); got != Unknown {
		t.Errorf("no answer: %s", got)
	}
	notPEM := filepath.Join(t.TempDir(), "x.pem")
	_ = os.WriteFile(notPEM, []byte("junk"), 0o600)
	if got := Check(ctx, &fake{fp: fp}, "n", notPEM); got != Mismatch {
		t.Errorf("junk pem: %s", got)
	}
}

func TestBoxExists(t *testing.T) {
	if !BoxExists(context.Background(), &fake{boxes: 1}, "n") || BoxExists(context.Background(), &fake{}, "n") {
		t.Error("a box is a reservation with an instance")
	}
	if Words(Missing) != "not on this laptop" || Words(Mismatch) != "not the key pair's private key" || Words(Match) != "" {
		t.Error("words")
	}
}
