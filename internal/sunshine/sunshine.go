// Package sunshine is the stream server on a box or machine, as far as cg talks
// to it over HTTPS: whether it answers, and whether a login is the one it takes.
//
// The Sunshine login: this laptop and the machine must never hold different ones.
//  1. A new password is saved HERE before the machine is given it. Saved after, an
//     init that ended in between - the app closed mid-build - left the machine
//     with a password nothing here knew, and every pairing failed.
//  2. The saved login is checked against the machine, not assumed - which also
//     catches a reply lost after Sunshine took the password.
//  3. When they disagree, it is set again ON the machine (sunshine --creds over
//     ssh), which needs no old password.
package sunshine

import (
	"context"
	"crypto/tls"
	"net/http"
	"time"
)

// Port is the web UI and API.
const Port = "47990"

// Client reaches Sunshine. It has a self-signed certificate, which on a private
// tailnet is the expected state, so verification is off.
type Client struct {
	HTTP *http.Client
	// URL builds the address for a machine; nil is https://<ip>:47990<path>.
	URL func(ip, path string) string
}

func (c Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
}

func (c Client) url(ip, path string) string {
	if c.URL != nil {
		return c.URL(ip, path)
	}
	return "https://" + ip + ":" + Port + path
}

func (c Client) code(ctx context.Context, method, ip, path string, timeout time.Duration, user, pass string) int {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, c.url(ip, path), nil)
	if err != nil {
		return 0
	}
	if user != "" {
		req.SetBasicAuth(user, pass)
	}
	resp, err := c.client().Do(req)
	if err != nil {
		return 0
	}
	resp.Body.Close()
	return resp.StatusCode
}

// Answers is whether anything answers the welcome page: any HTTP status counts,
// only silence does not.
func (c Client) Answers(ctx context.Context, ip string) bool {
	return c.code(ctx, http.MethodGet, ip, "/welcome", 5*time.Second, "", "") != 0
}

// LoginOK: does Sunshine take this login - the same authenticated call pairing makes.
func (c Client) LoginOK(ctx context.Context, ip, user, pass string) bool {
	if user == "" || pass == "" {
		return false
	}
	return c.code(ctx, http.MethodGet, ip, "/api/clients/list", 10*time.Second, user, pass) == http.StatusOK
}
