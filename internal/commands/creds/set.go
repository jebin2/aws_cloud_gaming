package creds

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
	"github.com/jebin2/aws_cloud_gaming/internal/tskey"
)

// Setter takes the keys only a person can give cg, checks them, and only then
// keeps them.
type Setter struct {
	Out *output.Out
	Ask *ask.Asker
	Env *config.Env
	// Verify asks AWS whose key this is. The candidate is used for this one call
	// and nothing else: an AWS_PROFILE or a session token in the environment
	// would otherwise win over it, and the answer would be about another key.
	Verify func(ctx context.Context, keyID, secret, region string) (account string, err error)
	// TS is the Tailscale API, with whatever token it is given.
	TS func(token string) tskey.Client
	// Home, Getenv place the AWS files.
	Home   string
	Getenv func(string) string
}

// VerifyKey is the real Verify.
func VerifyKey(ctx context.Context, keyID, secret, region string) (string, error) {
	if region == "" {
		region = "us-east-1"
	}
	opts := sts.Options{Region: region, Credentials: credentials.NewStaticCredentialsProvider(keyID, secret, ""), AppID: "cg"}
	if u := os.Getenv("CG_AWS_ENDPOINT"); u != "" {
		opts.BaseEndpoint = aws.String(u)
	}
	r, err := sts.New(opts).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		return "", err
	}
	return aws.ToString(r.Account), nil
}

func (s Setter) say(kind, text string) {
	if kind == "log" {
		s.Out.Log(text)
		return
	}
	s.Out.LogAs(kind, text)
}

func (s Setter) needAsk(what string) bool {
	if s.Ask.CanAsk() {
		return true
	}
	s.Out.Die("cg creds set " + what + " has to ask - run it in a terminal, or use the app")
	return false
}

// SetAWS asks for an access key and keeps it if AWS takes it.
//
// It asks for the two things only a person has: a default region and an output
// format are cg's to set, and it passes both on every call. The secret is read
// without echo. The key is checked BEFORE it is written: the other order meant
// one mistyped character replaced a key that worked, and every screen then
// reported rejected credentials - about the key you had just destroyed.
func (s Setter) SetAWS(ctx context.Context, region string) int {
	if !s.needAsk("aws") {
		return 1
	}
	s.Out.Log("AWS credentials: paste an access key (IAM > Users > Security credentials > Create access key)")
	id := strings.TrimSpace(s.Ask.Ask("aws-access-key-id", "    access key id: ", "", ""))
	secret := strings.TrimSpace(s.Ask.Secret("aws-secret-access-key", "    secret access key: "))
	if id == "" || secret == "" {
		s.Out.Log("no key given - nothing saved")
		return 1
	}
	who, err := s.Verify(ctx, id, secret, region)
	if err != nil {
		s.Out.LogAs("fail", "AWS rejected that key: "+oneLine(err.Error()))
		s.Out.Log("  nothing was saved - the key you had before is untouched")
		s.Out.Log("  check the key is Active: IAM > Users > Security credentials")
		return 1
	}
	profile := s.Getenv("AWS_PROFILE")
	if profile == "" {
		profile = "default"
	}
	if err := WriteAWSKey(s.awsFiles(), profile, id, secret, region); err != nil {
		s.Out.LogAs("fail", "could not save the key: "+err.Error())
		return 1
	}
	s.Out.Log(fmt.Sprintf("saved to ~/.aws/credentials, profile %s - not to .env (.env.example says why)", profile))
	s.Out.LogAs("ok", fmt.Sprintf("credentials work (account %s)", who))
	return 0
}

func (s Setter) awsFiles() AWSFiles {
	f := AWSFiles{Credentials: s.Getenv("AWS_SHARED_CREDENTIALS_FILE"), Config: s.Getenv("AWS_CONFIG_FILE")}
	if f.Credentials == "" {
		f.Credentials = filepath.Join(s.Home, ".aws", "credentials")
	}
	if f.Config == "" {
		f.Config = filepath.Join(s.Home, ".aws", "config")
	}
	return f
}

// AWSFiles is where the AWS SDK and CLI keep their settings.
type AWSFiles struct{ Credentials, Config string }

// WriteAWSKey puts the key in the credentials file and the region in the config
// file, under the profile, as `aws configure set` does: every other line stays,
// the files are made readable by you alone, and each write is atomic so a crash
// leaves the old file.
func WriteAWSKey(f AWSFiles, profile, keyID, secret, region string) error {
	if err := setINI(f.Credentials, profile, [][2]string{{"aws_access_key_id", keyID}, {"aws_secret_access_key", secret}}); err != nil {
		return err
	}
	if region == "" {
		return nil
	}
	section := profile
	if profile != "default" {
		section = "profile " + profile
	}
	return setINI(f.Config, section, [][2]string{{"region", region}})
}

var iniKey = regexp.MustCompile(`^\s*([A-Za-z0-9_.-]+)\s*=`)

// setINI sets keys in one section, creating the section or the file as needed.
func setINI(path, section string, kvs [][2]string) error {
	var lines []string
	if f, err := os.Open(path); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
		for sc.Scan() {
			lines = append(lines, sc.Text())
		}
		f.Close()
	}
	header := "[" + section + "]"
	start, end := -1, len(lines)
	for i, l := range lines {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "[") {
			if start >= 0 {
				end = i
				break
			}
			if t == header {
				start = i
			}
		}
	}
	if start < 0 {
		if len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) != "" {
			lines = append(lines, "")
		}
		lines = append(lines, header)
		for _, kv := range kvs {
			lines = append(lines, kv[0]+" = "+kv[1])
		}
	} else {
		done := map[string]bool{}
		body := append([]string{}, lines[start+1:end]...)
		for i, l := range body {
			if m := iniKey.FindStringSubmatch(l); m != nil {
				for _, kv := range kvs {
					if m[1] == kv[0] {
						body[i] = kv[0] + " = " + kv[1]
						done[kv[0]] = true
					}
				}
			}
		}
		// New keys go after the last line with something in it, not after the
		// blank line that separates this section from the next.
		at := len(body)
		for at > 0 && strings.TrimSpace(body[at-1]) == "" {
			at--
		}
		var add []string
		for _, kv := range kvs {
			if !done[kv[0]] {
				add = append(add, kv[0]+" = "+kv[1])
			}
		}
		body = append(body[:at], append(add, body[at:]...)...)
		lines = append(append(append([]string{}, lines[:start+1]...), body...), lines[end:]...)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".cg-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.WriteString(strings.Join(lines, "\n") + "\n"); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// SetToken asks for the Tailscale API token, checks it, and only then writes it.
func (s Setter) SetToken(ctx context.Context) int {
	if !s.needAsk("tailscale") {
		return 1
	}
	s.Out.Log("Tailscale API token (NOT an auth key): https://login.tailscale.com/admin/settings/keys")
	tok := strings.TrimSpace(s.Ask.Secret("tailscale-api-token", "    api token: "))
	if tok == "" {
		s.Out.Log("no token given - nothing saved")
		return 1
	}
	if !tskey.Shape.MatchString(tok) {
		s.Out.LogAs("fail", "that does not look like a Tailscale token - they start with tskey-")
		return 1
	}
	switch state, detail := s.TS(tok).CheckToken(ctx); state {
	case "ok":
	case "rejected":
		s.Out.LogAs("fail", fmt.Sprintf("Tailscale rejected that token (%s) - nothing was saved", detail))
		s.Out.Log("  make one at https://login.tailscale.com/admin/settings/keys (API access token)")
		return 1
	default:
		s.Out.LogAs("fail", fmt.Sprintf("could not reach api.tailscale.com (%s) - nothing was saved", detail))
		s.Out.Log("  nothing is wrong with the token as far as this knows; try again when the network is back")
		return 1
	}
	if err := s.Env.Set("TAILSCALE_API_KEY", tok); err != nil {
		s.Out.LogAs("fail", "could not write .env")
		return 1
	}
	s.Out.LogAs("ok", "the token works")
	s.Out.Log("  saved to .env as TAILSCALE_API_KEY")
	return 0
}

// SetAuthKey keeps a pre-auth key for the box, for a tailnet whose ACLs will not
// issue one to the API token (tags). It is checked the way a stored one is
// before it is kept.
func (s Setter) SetAuthKey(ctx context.Context) int {
	if !s.needAsk("tailscale authkey") {
		return 1
	}
	s.Out.Log("A pre-auth key for the box: https://login.tailscale.com/admin/settings/keys")
	s.Out.Log("  Reusable: on  - a rebuild needs a key that has not been spent.")
	s.Out.Log("  Ephemeral: OFF - an ephemeral node is purged when it goes offline, and")
	s.Out.Log("             this box goes offline every time the watchdog stops it.")
	key := strings.TrimSpace(s.Ask.Secret("tailscale-auth-key", "    paste auth key: "))
	if key == "" {
		s.Out.Log("no key given - nothing saved")
		return 1
	}
	if !tskey.Shape.MatchString(key) {
		s.Out.LogAs("fail", "that does not look like a Tailscale key - they start with tskey-")
		return 1
	}
	// With a token in hand this is answerable now rather than at boot. Without
	// one, "unknown" is the honest answer and the key is taken at its word.
	state := s.TS(s.Env.Get("TAILSCALE_API_KEY")).State(ctx, key)
	switch state {
	case "expired":
		s.Out.LogAs("fail", "that key has expired or been revoked - nothing was saved")
		return 1
	case "gone":
		s.Out.LogAs("fail", "Tailscale has no such key - nothing was saved")
		return 1
	}
	if err := s.Env.Set("TAILSCALE_AUTH_KEY", key); err != nil {
		s.Out.LogAs("fail", "could not write .env")
		return 1
	}
	if state == "ok" {
		s.Out.LogAs("ok", "the key works, and is saved")
	} else {
		s.Out.LogAs("ok", "saved (there is no API token to check it with)")
	}
	return 0
}
