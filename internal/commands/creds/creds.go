// Package creds is `cg creds`: the two keys only a person can give cg - the AWS
// access key and the Tailscale API token - and whether each works.
package creds

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/laptop"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// STSAPI is the one free call that can say whether a key works.
type STSAPI interface {
	GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error)
}

// Prober finds where the AWS key comes from. The SDK's credential chain does,
// and says which link answered.
type Prober interface {
	Retrieve(ctx context.Context) (aws.Credentials, error)
}

// AWS is the access key and whether AWS takes it.
type AWS struct {
	CLI     bool    `json:"cli"` // always true: the AWS CLI is no longer needed to read anything
	Source  *string `json:"source"`
	KeyID   *string `json:"key_id"`
	Account *string `json:"account"`
	ARN     *string `json:"arn"`
	// Valid is a third state short of true/false: nothing was asked if there
	// was no key, so nothing was rejected either - which is not "valid".
	Valid *bool `json:"valid"`
	// Reason is WHY it is not valid, because the answers are not interchangeable
	// and only cg can tell them apart: no-key | unreachable | rejected, null when
	// the key works. A laptop with no network was once told "AWS rejected this
	// access key", a lie about a call that never arrived.
	Reason *string `json:"reason"`
	Error  *string `json:"error"`
}

func nz(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Mask shows the last four of a key and nothing else.
func Mask(key string) string {
	if key == "" {
		return ""
	}
	if len(key) < 4 {
		return "****" + key
	}
	return "****" + key[len(key)-4:]
}

var unreachable = []string{"no such host", "connection refused", "i/o timeout", "dial tcp", "network is unreachable",
	"temporary failure in name resolution", "connection reset", "context deadline exceeded", "tls:", "ssl", "timeout", "eof"}

// Classify says why an error means what it means. Anything unrecognised is a
// rejection: that is what the overwhelming majority of these are, and treating
// a refusal as a network blip would have someone waiting for it to clear.
func Classify(err error) string {
	low := strings.ToLower(err.Error())
	switch {
	case strings.Contains(low, "failed to refresh cached credentials") || strings.Contains(low, "nocredentialproviders") ||
		strings.Contains(low, "unable to locate credentials") || strings.Contains(low, "no ec2 imds role") ||
		strings.Contains(low, "you must specify a region"):
		return "no-key" // nothing was rejected: there is nothing here to reject
	}
	for _, s := range unreachable {
		if strings.Contains(low, s) {
			return "unreachable"
		}
	}
	return "rejected"
}

// SourceText is where the key comes from, in words: the SDK names the link of
// its chain that answered.
func SourceText(source, home, profile string) string {
	if profile == "" {
		profile = "default"
	}
	tilde := func(p string) string {
		if home != "" && strings.HasPrefix(p, home) {
			return "~" + strings.TrimPrefix(p, home)
		}
		return p
	}
	switch {
	case strings.HasPrefix(source, "EnvConfigCredentials"):
		// cg loads .env into the environment, so a key there would silently win.
		return "AWS_ACCESS_KEY_ID in the environment - it wins over ~/.aws/credentials"
	case strings.HasPrefix(source, "SharedConfigCredentials"):
		file := strings.TrimSpace(strings.TrimPrefix(source, "SharedConfigCredentials:"))
		if file == "" {
			file = "~/.aws/credentials"
		}
		if strings.HasSuffix(file, "/config") {
			return tilde(file) + ", profile " + profile
		}
		return tilde(file) + ", profile " + profile
	case source == "":
		return ""
	}
	return source + ", profile " + profile
}

// ReadAWS asks which key is in force and whether AWS takes it.
func ReadAWS(ctx context.Context, p Prober, s STSAPI, home, profile string) AWS {
	a := AWS{CLI: true}
	c, err := p.Retrieve(ctx)
	if err != nil {
		reason := Classify(err)
		msg := "Unable to locate credentials - set a working key: cg creds set"
		if reason != "no-key" {
			msg = oneLine(err.Error())
		}
		a.Reason, a.Error = &reason, &msg
		f := false
		a.Valid = &f
		if reason == "no-key" {
			a.Valid = nil
		}
		return a
	}
	a.Source = nz(SourceText(c.Source, home, profile))
	a.KeyID = nz(Mask(c.AccessKeyID))
	id, err := s.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		reason := Classify(err)
		msg := oneLine(err.Error())
		if msg == "" {
			msg = "AWS rejected the credentials"
		}
		f := false
		a.Valid, a.Reason, a.Error = &f, &reason, &msg
		return a
	}
	t := true
	a.Valid, a.Account, a.ARN = &t, nz(aws.ToString(id.Account)), nz(aws.ToString(id.Arn))
	return a
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// ShowAWS is `cg creds` for the access key; it returns false when something is wrong.
func ShowAWS(a AWS, out *output.Out) bool {
	out.Say("aws credentials")
	kind := "warn"
	key := "none configured"
	if a.KeyID != nil {
		kind, key = "ok", *a.KeyID
	}
	out.LogAs(kind, "access key       "+key)
	src := "not known"
	if a.Source != nil {
		src = *a.Source
	}
	out.LogAs("info", "from             "+src)
	if a.Error != nil {
		out.LogAs("fail", "accepted         no  <- "+*a.Error)
		out.Log("  set a working key: cg creds set   (or the Set access key button in Settings)")
		return false
	}
	out.LogAs("ok", "accepted         yes")
	out.LogAs("info", "account          "+orUnknown(a.Account))
	out.LogAs("info", "identity         "+orUnknown(a.ARN))
	return true
}

func orUnknown(p *string) string {
	if p == nil {
		return "unknown"
	}
	return *p
}

// TS is the Tailscale API token, which prunes old nodes and checks the box's
// auth key; it is not the auth key itself.
type TS struct {
	Present bool    `json:"present"`
	Valid   *bool   `json:"valid"` // present and valid are separate: set and refused is not the same as none, and both differ from "the API could not be reached"
	State   string  `json:"state"` // ok | rejected | unreachable | absent
	Detail  *string `json:"detail"`
	// SignedIn is null when Tailscale is not here.
	SignedIn *bool   `json:"signed_in"`
	Node     *string `json:"node"`
	// AuthKeyStored: the box needs a key of its own to join the tailnet. Either
	// one is stored in .env, or a working token mints one per build, or the
	// build has to ask. The key itself is never reported.
	AuthKeyStored bool `json:"auth_key_stored"`
	CanMint       bool `json:"can_mint"`
}

// TSAPI is where the token is checked.
var TSAPI = "https://api.tailscale.com/api/v2"

// CheckToken asks Tailscale whether the token works: ok, rejected, or
// unreachable - which says nothing about the token.
func CheckToken(ctx context.Context, client *http.Client, token string) (state, detail string) {
	if token == "" {
		return "absent", ""
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, TSAPI+"/tailnet/-/devices", nil)
	if err != nil {
		return "unreachable", "000"
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		return "unreachable", "000"
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode/100 == 2:
		return "ok", ""
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		return "rejected", fmt.Sprint(resp.StatusCode)
	}
	return "unreachable", fmt.Sprint(resp.StatusCode)
}

// ReadTS gathers the token's state and this computer's side of Tailscale.
func ReadTS(ctx context.Context, l laptop.Laptop, client *http.Client, token string, authKeyStored bool) TS {
	state, detail := CheckToken(ctx, client, token)
	t := TS{Present: state != "absent", State: state, Detail: nz(detail), AuthKeyStored: authKeyStored, CanMint: state == "ok"}
	switch state {
	case "ok":
		v := true
		t.Valid = &v
	case "rejected":
		v := false
		t.Valid = &v
	}
	if l.Runner.Has("tailscale") {
		signed := !l.TailscaleDown(ctx)
		t.SignedIn = &signed
		if out, err := l.Runner.Output(ctx, "tailscale", "status", "--json"); err == nil {
			var st struct{ Self struct{ DNSName string } }
			if json.Unmarshal(out, &st) == nil {
				t.Node = nz(strings.SplitN(st.Self.DNSName, ".", 2)[0])
			}
		}
	}
	return t
}

// ShowTS is `cg creds tailscale`; it returns false when the token is rejected.
func ShowTS(t TS, out *output.Out) bool {
	out.Say("tailscale")
	switch {
	case t.SignedIn == nil:
		out.LogAs("fail", "tailscale        not installed")
	case *t.SignedIn:
		node := "yes"
		if t.Node != nil {
			node = *t.Node
		}
		out.LogAs("ok", "signed in        "+node)
	default:
		out.LogAs("fail", "signed in        no  <- sudo tailscale up")
	}
	detail := ""
	if t.Detail != nil {
		detail = *t.Detail
	}
	good := true
	switch t.State {
	case "ok":
		out.LogAs("ok", "api token        works")
	case "absent":
		out.LogAs("warn", "api token        not set  (an AWS build needs it, to check the box's auth key)")
	case "rejected":
		out.LogAs("fail", fmt.Sprintf("api token        rejected (%s) <- https://login.tailscale.com/admin/settings/keys", detail))
		good = false
	default:
		out.LogAs("warn", fmt.Sprintf("api token        set, but api.tailscale.com did not answer (%s)", detail))
	}
	switch {
	case t.AuthKeyStored:
		out.LogAs("ok", "box auth key     stored in .env")
	case t.State == "ok":
		out.LogAs("ok", "box auth key     minted from the token at each build")
	default:
		out.LogAs("warn", "box auth key     none - the next build will ask for one")
	}
	return good
}
