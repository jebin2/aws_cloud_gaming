// Package notify is `cg notify`: a test message, to check the phone end before
// relying on it. The topic is never printed: on ntfy.sh, anyone who knows it can
// read and post to it.
package notify

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Send posts the test message. client may be nil.
func Send(ctx context.Context, client *http.Client, env *config.Env, out *output.Out) int {
	raw := env.Get("GAME_NTFY_URL")
	if raw == "" {
		out.Die("set GAME_NTFY_URL in .env - a long random topic name, or a full ntfy URL")
		return 1
	}
	target := config.NtfyURL(raw)
	if target == "" {
		out.Die("GAME_NTFY_URL is not a topic (letters, digits, - and _, up to 64) or an http(s)://host/topic URL")
		return 1
	}
	u, _ := url.Parse(target)
	host := u.Host
	out.Say("sending a test notification")
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, strings.NewReader("Notifications from cloud_gaming reach this device."))
	if err == nil {
		req.Header.Set("Title", env.Host()+": test")
		req.Header.Set("Tags", "bell")
		var resp *http.Response
		if resp, err = client.Do(req); err == nil {
			resp.Body.Close()
			if resp.StatusCode/100 != 2 {
				err = fmt.Errorf("HTTP %d", resp.StatusCode)
			}
		}
	}
	if err != nil {
		// The error is not shown: it carries the URL, and the URL is the secret.
		out.Die("could not send to " + host + " - check the URL, and that this machine can reach it")
		return 1
	}
	out.Log("sent to " + host + " - check the ntfy app")
	return 0
}
