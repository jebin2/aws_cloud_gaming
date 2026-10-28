package check

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

var (
	keyShape  = regexp.MustCompile(`^tskey-[A-Za-z0-9-]+$`)
	ntfyShape = regexp.MustCompile(`^[A-Za-z0-9:/._-]+$`)
)

// secret asks for a pasted secret. Stray whitespace is removed and up to three
// tries are given. It returns false with no usable answer; an optional one
// returns an empty value when Enter is pressed on its own.
func (c *Checker) secret(id, prompt string, re *regexp.Regexp, what string, optional bool) (string, bool) {
	for try := 0; try < 3; try++ {
		v := strings.Join(strings.Fields(c.Ask.Secret(id, prompt)), "")
		if v == "" {
			if optional {
				return "", true
			}
			fmt.Fprintln(c.Ask.Prompts, "    nothing arrived - paste with Ctrl+Shift+V (or right-click, Paste), then press Enter")
			continue
		}
		if re.MatchString(v) {
			return v, true
		}
		fmt.Fprintf(c.Ask.Prompts, "    that is not a %s - check you copied all of it, and paste again\n", what)
	}
	return "", false
}

// number asks for a whole number, with its default shown. Enter keeps the
// default, and either way the value is saved, so it is not asked again.
func (c *Checker) number(key, def string, min int, prompt string) bool {
	for try := 0; try < 3; try++ {
		p := prompt
		if !c.Out.JSON {
			p = fmt.Sprintf("%s [%s]: ", prompt, def)
		}
		v := strings.Join(strings.Fields(c.Ask.Ask(strings.ToLower(key), p, def, "")), "")
		if n, err := strconv.Atoi(v); err == nil && n >= min {
			return c.Env.Set(key, strconv.Itoa(n)) == nil
		}
		fmt.Fprintf(c.Ask.Prompts, "    a whole number, at least %d - try again\n", min)
	}
	return false
}

func (c *Checker) first(keys ...string) string {
	for _, k := range keys {
		if v := c.Env.Get(k); v != "" {
			return v
		}
	}
	return ""
}

// settings asks for what .env lacks and saves it. It returns the box's auth key.
//
//	required  TAILSCALE_AUTH_KEY, EMAIL_ALERTS - asked whenever missing
//	optional  TAILSCALE_API_KEY, GAME_DISK_GB, GAME_ARCHIVE_EXPIRY_DAYS, GAME_NTFY_URL -
//	          asked by --fix, with the default shown, and only when .env does not
//	          mention them: whatever is answered is saved, so it is not asked again
//
// Values are saved to .env and never printed.
func (c *Checker) settings(ctx context.Context) (string, bool) {
	out := c.Out
	host := c.Env.Host()
	// The names these are commonly already exported under.
	authKey := c.first("GAME_TS_AUTHKEY", "TAILSCALE_AUTH_KEY")
	email := c.first("GAME_ALERT_EMAIL", "EMAIL_ALERTS")
	staleKey := false

	// An expired key in .env used to be found out at BOOT: the instance is
	// launched, billing, and never joins the tailnet. With a token it is
	// answerable here, before anything starts. And with a token there is nothing
	// to type: keep the stored key while it is valid, replace it when it expires
	// or is revoked, mint one when there is none.
	if k, ok := c.ensureAuthKey(ctx, authKey, host); ok {
		authKey = k
	} else if authKey != "" {
		// A key that is known to be dead and could not be replaced is not a key:
		// keeping it only ended the build with "could not be replaced". Ask for a
		// new one, here, where the person is already looking.
		switch c.TS(c.Env.Get("TAILSCALE_API_KEY")).State(ctx, authKey) {
		case "expired", "gone":
			c.Out.LogAs("warn", "the stored Tailscale auth key is dead and could not be replaced automatically - a new one is needed")
			authKey, staleKey = "", true
		}
	}

	// In the app, a missing setting is NOT a question to ask here. A build is
	// fifteen minutes of watching a log, and stopping it halfway with a dialog is
	// the wrong place to answer: these belong on the screens that show them,
	// before the build starts.
	if authKey == "" {
		if out.JSON && !staleKey {
			out.Die("no Tailscale auth key for the box.\n       Settings > Tailscale has it, and with an API token set cg makes one itself.")
			return "", false
		}
		out.Gap()
		out.Echo("A Tailscale pre-auth key is needed to join the box to your tailnet.")
		out.Echo("Generate one at: https://login.tailscale.com/admin/settings/keys")
		out.Echo("  Reusable: on  - a retry needs a key that has not been spent.")
		out.Echo("  Ephemeral: OFF - ephemeral nodes are purged when they go offline, and")
		out.Echo("             this box goes offline every time the watchdog stops it.")
		k, ok := c.secret("tailscale-auth-key", "  paste auth key: ", keyShape, "Tailscale auth key", false)
		if !ok {
			out.Die("no auth key given - copy it from the Tailscale page and paste it with Ctrl+Shift+V")
			return "", false
		}
		authKey = k
		_ = c.Env.Set("TAILSCALE_AUTH_KEY", authKey)
	}
	if email == "" {
		if out.JSON {
			out.Die("no address for billing alerts.\n       Settings > billing alerts to.")
			return "", false
		}
		email = strings.TrimSpace(c.Ask.Ask("alert-email", "  email for billing alerts (comma-separated for several): ", "", ""))
		if email == "" {
			out.Die("no email given")
			return "", false
		}
		_ = c.Env.Set("EMAIL_ALERTS", email)
	}
	out.LogAs("ok", "Tailscale auth key and alert email set")

	interactive := c.Fix && c.Ask.TTY
	if !c.Env.Has("TAILSCALE_API_KEY") && interactive {
		out.Gap()
		out.Echo("Optional: a Tailscale API access token - not the auth key. With it, cg init removes old")
		out.Echo("box entries, so the box keeps its name, and turns off the box's key expiry.")
		out.Echo("Generate one at: https://login.tailscale.com/admin/settings/keys")
		if v, ok := c.secret("tailscale-api-token", "  paste API token (Enter to skip): ", keyShape, "Tailscale API token", true); ok {
			_ = c.Env.Set("TAILSCALE_API_KEY", v)
		} else {
			out.LogAs("fail", "no valid API token - not saved, so cg check --fix asks again")
		}
	}
	if c.Env.Get("TAILSCALE_API_KEY") != "" {
		out.LogAs("ok", "Tailscale API key set - old nodes are pruned and key expiry is turned off")
	} else {
		out.LogAs("warn", "no TAILSCALE_API_KEY - old nodes and key expiry stay manual")
	}

	var rates pricing.Rates // looked up only when a question needs a price in it
	if interactive && (!c.Env.Has("GAME_DISK_GB") || !c.Env.Has("GAME_ARCHIVE_EXPIRY_DAYS")) {
		rates = c.Rates(ctx)
	}
	if !c.Env.Has("GAME_DISK_GB") && interactive {
		out.Gap()
		out.Echo("Root disk, in GB: the OS, the driver and Steam - games live on the box's own NVMe.")
		// AWS's disk price, not one written down here.
		if rates.EBSGBMonth != nil && rates.INRPerUSD != nil {
			out.Echo(fmt.Sprintf("About INR %.1f per GB a month while the box exists, and it cannot be shrunk later.", *rates.EBSGBMonth**rates.INRPerUSD))
		} else {
			out.Echo("Billed by the GB, every month the box exists, and it cannot be shrunk later.")
		}
		if !c.number("GAME_DISK_GB", "50", 30, "  root disk GB") {
			out.LogAs("fail", "no disk size saved - the default, 50 GB, is used, and cg check --fix asks again")
		}
	}
	disk, def := c.Env.Get("GAME_DISK_GB"), ""
	if disk == "" {
		disk, def = "50", " (the default)"
	}
	out.LogAs("info", fmt.Sprintf("root disk %s GB%s", disk, def))

	if !c.Env.Has("GAME_ARCHIVE_EXPIRY_DAYS") && interactive {
		out.Gap()
		cost := ""
		if rates.S3GBMonth != nil && rates.INRPerUSD != nil {
			cost = fmt.Sprintf(" (about INR %.0f a month for 100 GB)", 100**rates.S3GBMonth**rates.INRPerUSD)
		}
		out.Echo("Days with no box before the cloud watchdog deletes your game archive in S3" + cost + ".")
		out.Echo("0 keeps it forever. The next cg init applies a change.")
		if !c.number("GAME_ARCHIVE_EXPIRY_DAYS", "14", 0, "  delete the archive after how many days") {
			out.LogAs("fail", "no expiry saved - the default, 14 days, is used, and cg check --fix asks again")
		}
	}
	days := c.Env.Get("GAME_ARCHIVE_EXPIRY_DAYS")
	if days == "" {
		days = "14"
	}
	if days == "0" {
		out.LogAs("info", "game archive: kept forever (GAME_ARCHIVE_EXPIRY_DAYS=0)")
	} else {
		out.LogAs("info", fmt.Sprintf("game archive: deleted after %s days with no box", days))
	}

	if c.AdoptNtfy != nil {
		c.AdoptNtfy(ctx)
	}
	if !c.Env.Has("GAME_NTFY_URL") && interactive {
		out.Gap()
		out.Echo("Optional: notifications on your phone. Install the ntfy app, subscribe to a long random")
		out.Echo("topic name, and paste that name (or a full ntfy URL) here. Enter skips.")
		v, ok := c.secret("ntfy-topic-or-url", "  ntfy topic or URL (Enter to skip): ", ntfyShape, "ntfy topic or URL", true)
		if !ok || (v != "" && config.NtfyURL(v) == "") {
			out.LogAs("fail", "that is not a valid ntfy topic or URL - not saved, so cg check --fix asks again")
		} else {
			_ = c.Env.Set("GAME_NTFY_URL", v)
		}
	}
	if c.Env.Get("GAME_NTFY_URL") != "" {
		out.LogAs("ok", "notifications on (GAME_NTFY_URL set)")
	} else {
		out.LogAs("info", "notifications off - GAME_NTFY_URL not set")
	}
	return authKey, true
}
