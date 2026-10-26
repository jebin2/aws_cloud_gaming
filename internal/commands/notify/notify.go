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

// Push sends one notification, if notifications are on. It never fails the
// command: the build carries on, and says once that it was not sent. The URL is
// never printed - on ntfy.sh, the topic is all it takes to read and post.
func Push(ctx context.Context, client *http.Client, env *config.Env, out *output.Out, title, message, priority, tags string) {
	target := config.NtfyURL(env.Get("GAME_NTFY_URL"))
	if target == "" {
		return
	}
	if client == nil {
		client = http.DefaultClient
	}
	if priority == "" {
		priority = "default"
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, strings.NewReader(message))
	if err == nil {
		req.Header.Set("Title", env.Host()+": "+title)
		req.Header.Set("Priority", priority)
		req.Header.Set("Tags", tags)
		var resp *http.Response
		if resp, err = client.Do(req); err == nil {
			resp.Body.Close()
			if resp.StatusCode/100 != 2 {
				err = fmt.Errorf("HTTP %d", resp.StatusCode)
			}
		}
	}
	if err != nil {
		out.Log("notification not sent (ignored)")
	}
}
