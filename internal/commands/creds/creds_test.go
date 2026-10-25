package creds

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

type prober struct {
	c   aws.Credentials
	err error
}

func (p prober) Retrieve(context.Context) (aws.Credentials, error) { return p.c, p.err }

type stsFake struct{ err error }

func (s stsFake) GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error) {
	if s.err != nil {
		return nil, s.err
	}
	return &sts.GetCallerIdentityOutput{Account: aws.String("123456789012"), Arn: aws.String("arn:aws:iam::123456789012:user/CLI")}, nil
}

func outs() (*output.Out, *bytes.Buffer) {
	var o, e bytes.Buffer
	return &output.Out{Stdout: &o, Stderr: &e}, &o
}

// A made-up access key, assembled so that no scanner mistakes this file for one.
var fakeKey = "AK" + "IA" + "ABCDEFGH" + "1234"

func TestMask(t *testing.T) {
	if Mask(fakeKey) != "****1234" || Mask("") != "" || Mask("ab") != "****ab" {
		t.Error("the last four and nothing else")
	}
}

func TestClassifyTellsTheAnswersApart(t *testing.T) {
	for msg, want := range map[string]string{
		"failed to refresh cached credentials, no EC2 IMDS role found": "no-key",
		"Unable to locate credentials":                                 "no-key",
		"dial tcp: lookup sts.amazonaws.com: no such host":             "unreachable",
		"Post \"https://sts\": i/o timeout":                            "unreachable",
		"operation error STS: GetCallerIdentity, InvalidClientTokenId": "rejected",
		"SignatureDoesNotMatch":                                        "rejected",
	} {
		if got := Classify(errors.New(msg)); got != want {
			t.Errorf("%q: got %s want %s", msg, got, want)
		}
	}
}

func TestAKeyThatWorks(t *testing.T) {
	a := ReadAWS(context.Background(), prober{c: aws.Credentials{AccessKeyID: fakeKey, Source: "SharedConfigCredentials: /home/u/.aws/credentials"}},
		stsFake{}, "/home/u", "")
	if a.Valid == nil || !*a.Valid || a.Reason != nil || a.Error != nil || *a.KeyID != "****1234" || *a.Account != "123456789012" {
		t.Errorf("%+v", a)
	}
	if *a.Source != "~/.aws/credentials, profile default" {
		t.Errorf("source %q", *a.Source)
	}
	out, o := outs()
	if !ShowAWS(a, out) {
		t.Error("ok")
	}
	for _, want := range []string{"==> aws credentials", "access key       ****1234", "from             ~/.aws/credentials, profile default",
		"accepted         yes", "account          123456789012", "identity         arn:aws:iam::123456789012:user/CLI"} {
		if !strings.Contains(o.String(), want) {
			t.Errorf("lacks %q:\n%s", want, o.String())
		}
	}
}

func TestNoKeyIsNotARejection(t *testing.T) {
	a := ReadAWS(context.Background(), prober{err: errors.New("failed to refresh cached credentials, no EC2 IMDS role found")}, stsFake{}, "", "")
	if a.Valid != nil || *a.Reason != "no-key" || !a.CLI {
		t.Errorf("valid must be null - nothing was asked, so nothing was rejected: %+v", a)
	}
}

func TestRejectedAndUnreachable(t *testing.T) {
	good := prober{c: aws.Credentials{AccessKeyID: fakeKey, Source: "EnvConfigCredentials"}}
	a := ReadAWS(context.Background(), good, stsFake{err: errors.New("InvalidClientTokenId: the token is invalid")}, "", "")
	if *a.Valid || *a.Reason != "rejected" || !strings.Contains(*a.Error, "InvalidClientTokenId") {
		t.Errorf("%+v", a)
	}
	if !strings.Contains(*a.Source, "AWS_ACCESS_KEY_ID in the environment - it wins") {
		t.Errorf("source %q", *a.Source)
	}
	a = ReadAWS(context.Background(), good, stsFake{err: errors.New("dial tcp: no such host")}, "", "")
	if *a.Valid || *a.Reason != "unreachable" {
		t.Errorf("a laptop with no network was told its key was rejected: %+v", a)
	}
	out, o := outs()
	if ShowAWS(a, out) {
		t.Error("not ok")
	}
	if !strings.Contains(o.String(), "accepted         no  <- ") || !strings.Contains(o.String(), "set a working key: cg creds set") {
		t.Errorf("%s", o.String())
	}
}

func tsServer(t *testing.T, code int) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tskey-api-abc123" && code == 200 {
			w.WriteHeader(401)
			return
		}
		w.WriteHeader(code)
	}))
	t.Cleanup(s.Close)
	old := TSAPI
	TSAPI = s.URL
	t.Cleanup(func() { TSAPI = old })
}

func lap(has ...string) laptop.Laptop {
	r := &fx.Runner{Installed: map[string]bool{}, Answers: map[string]string{}, Failing: map[string]bool{}}
	for _, h := range has {
		r.Installed[h] = true
	}
	r.Answers["tailscale status --json"] = `{"Self":{"DNSName":"mylaptop.tailnet-name.ts.net."}}`
	return laptop.Laptop{Runner: r, Getenv: func(string) string { return "" }, TTY: func() bool { return true }}
}

func TestTokenStates(t *testing.T) {
	ctx := context.Background()
	tsServer(t, 200)
	if s, _ := CheckToken(ctx, http.DefaultClient, "tskey-api-abc123"); s != "ok" {
		t.Errorf("ok: %s", s)
	}
	if s, d := CheckToken(ctx, http.DefaultClient, "tskey-api-wrong"); s != "rejected" || d != "401" {
		t.Errorf("rejected: %s %s", s, d)
	}
	if s, _ := CheckToken(ctx, http.DefaultClient, ""); s != "absent" {
		t.Errorf("absent: %s", s)
	}
	tsServer(t, 502)
	if s, d := CheckToken(ctx, http.DefaultClient, "tskey-api-abc123"); s != "unreachable" || d != "502" {
		t.Errorf("a server error says nothing about the token: %s %s", s, d)
	}
	TSAPI = "http://127.0.0.1:1"
	if s, d := CheckToken(ctx, http.DefaultClient, "tskey-api-abc123"); s != "unreachable" || d != "000" {
		t.Errorf("%s %s", s, d)
	}
}

func TestTailscaleFactsAndReport(t *testing.T) {
	tsServer(t, 200)
	ts := ReadTS(context.Background(), lap("tailscale"), http.DefaultClient, "tskey-api-abc123", false)
	if !ts.Present || ts.Valid == nil || !*ts.Valid || ts.State != "ok" || !ts.CanMint || ts.SignedIn == nil || !*ts.SignedIn || *ts.Node != "mylaptop" {
		t.Errorf("%+v", ts)
	}
	out, o := outs()
	if !ShowTS(ts, out) {
		t.Error("ok")
	}
	for _, want := range []string{"==> tailscale", "signed in        mylaptop", "api token        works", "box auth key     minted from the token at each build"} {
		if !strings.Contains(o.String(), want) {
			t.Errorf("lacks %q:\n%s", want, o.String())
		}
	}
	none := ReadTS(context.Background(), lap(), http.DefaultClient, "", true)
	if none.Present || none.Valid != nil || none.SignedIn != nil || !none.AuthKeyStored {
		t.Errorf("%+v", none)
	}
	out, o = outs()
	ShowTS(none, out)
	for _, want := range []string{"tailscale        not installed", "api token        not set", "box auth key     stored in .env"} {
		if !strings.Contains(o.String(), want) {
			t.Errorf("lacks %q:\n%s", want, o.String())
		}
	}
	rej := ReadTS(context.Background(), lap("tailscale"), http.DefaultClient, "tskey-api-wrong", false)
	out, o = outs()
	if ShowTS(rej, out) || !strings.Contains(o.String(), "api token        rejected (401)") || rej.Valid == nil || *rej.Valid {
		t.Errorf("%s", o.String())
	}
}
