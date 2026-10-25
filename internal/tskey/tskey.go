// Package tskey is the Tailscale side of the box's keys: the API token (which
// prunes old nodes and checks keys) and the pre-auth key the box joins with. The
// box cannot use the API token to join - `tailscale up` takes a node
// registration key and nothing else - and it should not have it either: that key
// travels in EC2 user-data, which anyone holding ec2:DescribeInstanceAttribute can
// read. An auth key there can register one machine; the API token there could
// delete every node on the tailnet. So the token stays on the laptop and mints
// what the box needs.
package tskey

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// API is Tailscale's.
const API = "https://api.tailscale.com/api/v2"

// Client talks to it. Base and HTTP are replaced in tests.
type Client struct {
	Base  string
	HTTP  *http.Client
	Token string
	Now   func() time.Time
}

func (c Client) base() string {
	if c.Base != "" {
		return c.Base
	}
	return API
}

func (c Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

func (c Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c Client) do(ctx context.Context, method, path string, body io.Reader) (int, []byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, c.base()+path, body)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.client().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, b, nil
}

// CheckToken asks Tailscale whether the API token works: ok, rejected, or
// unreachable - which says nothing about the token.
func (c Client) CheckToken(ctx context.Context) (state, detail string) {
	if c.Token == "" {
		return "absent", ""
	}
	code, _, err := c.do(ctx, http.MethodGet, "/tailnet/-/devices", nil)
	switch {
	case err != nil:
		return "unreachable", "000"
	case code/100 == 2:
		return "ok", ""
	case code == 401 || code == 403:
		return "rejected", fmt.Sprint(code)
	}
	return "unreachable", fmt.Sprint(code)
}

// Minted is the outcome of asking for a key.
type Minted struct {
	Key  string
	Code int    // the HTTP status; 0 when there was no answer
	Err  string // Tailscale's reason, usually that the tailnet's ACLs want a tag
}

// Mint makes a pre-auth key for the box.
//
//	reusable:false   - the key is single use; cg checks the one it keeps
//	ephemeral:false  - an ephemeral node is purged when it goes offline, and this
//	                   box goes offline every time the watchdog stops it
//	preauthorized    - nobody is at the box to approve it
func (c Client) Mint(ctx context.Context, host string) Minted {
	if c.Token == "" {
		return Minted{Err: "no API token"}
	}
	body := fmt.Sprintf(`{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":[]}}},"expirySeconds":3600,"description":"cg %s"}`, host)
	code, b, err := c.do(ctx, http.MethodPost, "/tailnet/-/keys", strings.NewReader(body))
	if err != nil {
		return Minted{}
	}
	m := Minted{Code: code}
	if code/100 != 2 {
		m.Err = clip(strings.Join(strings.Fields(string(b)), " "), 300)
		return m
	}
	var d struct{ Key string }
	if json.Unmarshal(b, &d) != nil || d.Key == "" {
		m.Err = "the API answered without a key"
		return m
	}
	m.Key = d.Key
	return m
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

var kinds = regexp.MustCompile(`^(auth|api|client)-`)

// AuthID is a key's id, which is what the API knows it by. A key reads
// tskey-auth-<id>-<secret>; the API's "id" is that middle part.
func AuthID(key string) string {
	k := strings.TrimPrefix(key, "tskey-")
	if key == "" {
		return ""
	}
	k = kinds.ReplaceAllString(k, "")
	return strings.SplitN(k, "-", 2)[0]
}

// Probe is the state of a stored auth key: ok, expired, gone, or unknown with a
// reason (no-token, no-key, refused, unreachable <code>, unreadable). Unknown is
// NOT a reason to throw a key away: a flat network would otherwise delete a
// perfectly good key and then fail to mint its replacement.
func (c Client) Probe(ctx context.Context, key string) string {
	if c.Token == "" {
		return "unknown no-token"
	}
	id := AuthID(key)
	if key == "" || id == "" {
		return "unknown no-key"
	}
	code, b, err := c.do(ctx, http.MethodGet, "/tailnet/-/keys/"+id, nil)
	switch {
	case err != nil:
		return "unknown unreachable 000"
	case code == 404:
		return "gone"
	case code == 401 || code == 403:
		return "unknown refused" // the TOKEN is the problem, not the key
	case code/100 != 2:
		return fmt.Sprintf("unknown unreachable %d", code)
	}
	var d struct {
		Invalid bool
		Revoked any // a timestamp in the API, a bool in older answers
		Expires string
	}
	if json.Unmarshal(b, &d) != nil {
		return "unknown unreadable"
	}
	if d.Invalid || (d.Revoked != nil && d.Revoked != false) {
		return "expired"
	}
	if d.Expires == "" {
		return "ok"
	}
	when, err := time.Parse(time.RFC3339, d.Expires)
	if err != nil {
		return "unknown"
	}
	// An hour of margin: a key that dies during the build is a box that never
	// joins, which costs a rebuild rather than a retry.
	if !when.After(c.now().Add(time.Hour)) {
		return "expired"
	}
	return "ok"
}

// State is just the first word of Probe.
func (c Client) State(ctx context.Context, key string) string {
	return strings.SplitN(c.Probe(ctx, key), " ", 2)[0]
}

// Delete tidies up a dead key.
func (c Client) Delete(ctx context.Context, key string) bool {
	id := AuthID(key)
	if key == "" || c.Token == "" || id == "" {
		return false
	}
	_, _, err := c.do(ctx, http.MethodDelete, "/tailnet/-/keys/"+id, nil)
	return err == nil
}

// Shape is what a Tailscale key looks like.
var Shape = regexp.MustCompile(`^tskey-[A-Za-z0-9-]+$`)
