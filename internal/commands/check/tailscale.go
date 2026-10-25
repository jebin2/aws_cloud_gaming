package check

import (
	"context"
	"fmt"
	"strings"
)

// ensureAuthKey: use what is stored if it is still good; replace it when it is
// not; mint one when there is none. Everything it decides it says out loud,
// because "the build asked me for a key again" needs a reason attached. It
// returns false when it has nothing better than what it was given.
func (c *Checker) ensureAuthKey(ctx context.Context, stored, host string) (string, bool) {
	token := c.Env.Get("TAILSCALE_API_KEY")
	ts := c.TS(token)
	if stored != "" {
		switch ts.State(ctx, stored) {
		case "ok":
			c.Out.LogAs("ok", "the stored Tailscale auth key is still valid")
			return stored, true
		case "unknown":
			// No token, or the API could not be reached. The key may be fine and
			// there is no way to know; using it is the only option that can succeed.
			return stored, true
		case "expired":
			c.Out.LogAs("warn", "the stored Tailscale auth key has expired - replacing it")
		case "gone":
			c.Out.LogAs("warn", "the stored Tailscale auth key no longer exists - replacing it")
		}
	}
	if token == "" {
		return "", false
	}
	m := ts.Mint(ctx, host)
	if m.Key == "" {
		code := "no answer"
		if m.Code != 0 {
			code = fmt.Sprint(m.Code)
		}
		c.Out.LogAs("warn", fmt.Sprintf("could not mint an auth key (%s)", code))
		if m.Err != "" {
			c.Out.Log("  " + m.Err)
		}
		// Tags are the usual reason, and it is not something cg can guess at.
		c.Out.Log("  make one yourself: https://login.tailscale.com/admin/settings/keys")
		return "", false
	}
	// Only after a replacement exists: deleting first and failing to mint would
	// leave the laptop with nothing at all.
	if stored != "" && ts.Delete(ctx, stored) {
		c.Out.Log("  the old key was deleted")
	}
	if err := c.Env.Set("TAILSCALE_AUTH_KEY", m.Key); err != nil {
		c.Out.LogAs("fail", "could not write .env")
		return "", false
	}
	c.Out.LogAs("ok", "minted a Tailscale auth key from your API token, and saved it")
	return m.Key, true
}

// needToken stops, before anything is asked or launched, when there is no API
// token to check the box's key with. It returns true when it stopped.
func (c *Checker) needToken() bool {
	if c.Env.Get("TAILSCALE_API_KEY") != "" {
		return false
	}
	c.Out.Die("cannot check the Tailscale auth key: no Tailscale API token is saved.\n       Nothing was launched. Without the check, a key that no longer works is found\n       out only after the machine is billing. Add an access token in\n       Settings > Private network, or with cg creds tailscale - with one, cg also\n       makes and replaces the box's auth key itself.")
	return true
}

// authKeyPreflight stops a build whose key cannot be shown to work. A key that
// does not work is found out at boot: the box is launched, billing, and never
// joins - and the wait for it is half an hour. Only the API can say whether a
// key works, so a build that cannot ask it does not start.
func (c *Checker) authKeyPreflight(ctx context.Context, key string) bool {
	r := c.TS(c.Env.Get("TAILSCALE_API_KEY")).Probe(ctx, key)
	switch {
	case r == "ok":
		c.Out.LogAs("ok", "the Tailscale auth key works")
		return true
	case r == "expired" || r == "gone":
		c.Out.Die("the Tailscale auth key for the box has expired or been revoked, and could not be replaced.\n       Nothing was launched. Save a new one: Settings > Private network in the app,\n       or cg creds tailscale authkey.")
	case r == "unknown no-token":
		c.needToken()
	case r == "unknown refused":
		c.Out.Die("cannot check the Tailscale auth key: Tailscale refused the API token.\n       Nothing was launched. The token has probably been revoked or has expired -\n       make a new one at https://login.tailscale.com/admin/settings/keys and save\n       it in Settings > Private network (or cg creds tailscale).")
	case r == "unknown no-key":
		c.Out.Die("no Tailscale auth key for the box. Nothing was launched.")
	case r == "unknown unreadable":
		c.Out.Die("cannot check the Tailscale auth key: api.tailscale.com answered with something that is not Tailscale's.\n       Nothing was launched. A proxy or a sign-in page on this network may be in the way.")
	default:
		c.Out.Die(fmt.Sprintf("cannot check the Tailscale auth key: api.tailscale.com did not answer (%s).\n       Nothing was launched. Try again when it can be reached.", r[strings.LastIndex(r, " ")+1:]))
	}
	return false
}
