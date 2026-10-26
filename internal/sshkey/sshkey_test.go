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
	"time"

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

type admin struct {
	*fake
	deleted, created []string
	material         string
}

func (a *admin) DeleteKeyPair(_ context.Context, in *ec2.DeleteKeyPairInput, _ ...func(*ec2.Options)) (*ec2.DeleteKeyPairOutput, error) {
	a.deleted = append(a.deleted, aws.ToString(in.KeyName))
	return &ec2.DeleteKeyPairOutput{}, nil
}
func (a *admin) CreateKeyPair(_ context.Context, in *ec2.CreateKeyPairInput, _ ...func(*ec2.Options)) (*ec2.CreateKeyPairOutput, error) {
	a.created = append(a.created, aws.ToString(in.KeyName))
	return &ec2.CreateKeyPairOutput{KeyMaterial: aws.String(a.material)}, nil
}

func TestEnsureKeepsAMatchingPairAndReplacesAnUnusableOne(t *testing.T) {
	ctx := context.Background()
	now := func() time.Time { return time.Date(2026, 10, 25, 9, 8, 7, 0, time.UTC) }
	var said []string
	say := func(s string) { said = append(said, s) }
	path, _ := writeKey(t, true)
	b, _ := os.ReadFile(path)
	fp, _ := Fingerprint(b)
	// This laptop holds the private key: nothing changes.
	a := &admin{fake: &fake{fp: fp}}
	if err := Ensure(ctx, a, "gamevps", path, "cg:host", say, now); err != nil || len(a.deleted) != 0 || len(a.created) != 0 {
		t.Fatalf("%v %v %v", err, a.deleted, a.created)
	}
	// Some other key: the pair is replaced, and the old file is kept under a dated name.
	other, _ := writeKey(t, false)
	a = &admin{fake: &fake{fp: fp}, material: "NEW-PRIVATE-KEY"}
	if err := Ensure(ctx, a, "gamevps", other, "cg:host", say, now); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(other)
	st, _ := os.Stat(other)
	kept := strings.TrimSuffix(other, ".pem") + "-replaced-20261025090807.pem"
	old, err := os.ReadFile(kept)
	if string(got) != "NEW-PRIVATE-KEY" || st.Mode().Perm() != 0o600 || err != nil || len(old) == 0 || len(a.deleted) != 1 {
		t.Errorf("%q %v %v %v", got, st.Mode(), err, a.deleted)
	}
	joined := strings.Join(said, "\n")
	if !strings.Contains(joined, "==> replacing key pair gamevps - "+other+" is not the key pair's private key") || !strings.Contains(joined, "the old file is kept as "+kept) {
		t.Errorf("%s", joined)
	}
	// No pair at all: one is made and its private key written, nothing deleted.
	a = &admin{fake: &fake{err: &smithy.GenericAPIError{Code: "InvalidKeyPair.NotFound"}}, material: "FRESH"}
	fresh := filepath.Join(t.TempDir(), "ssh", "gamevps.pem")
	if err := Ensure(ctx, a, "gamevps", fresh, "cg:host", say, now); err != nil || len(a.deleted) != 0 || len(a.created) != 1 {
		t.Fatalf("%v", err)
	}
	if b, _ := os.ReadFile(fresh); string(b) != "FRESH" {
		t.Errorf("%q", b)
	}
	// A pair that cannot be compared (imported, or AWS silent) is used as it is.
	a = &admin{fake: &fake{fp: "ab:cd"}}
	if err := Ensure(ctx, a, "gamevps", other, "cg:host", say, now); err != nil || len(a.created) != 0 {
		t.Errorf("%v", err)
	}
}
