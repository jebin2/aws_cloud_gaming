package tskey

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
)

// Expiry is the outcome of turning a node's key expiry off.
type Expiry struct {
	// Off is true when key expiry is off for the node (now, or already).
	Off bool
	// NoToken: there is no API token, so nothing was tried.
	NoToken bool
	// Lines say what happened, for the log.
	Lines []string
}

type device struct {
	ID                string `json:"id"`
	NodeID            string `json:"nodeId"`
	Hostname          string `json:"hostname"`
	Name              string `json:"name"`
	Created           string `json:"created"`
	Connected         bool   `json:"connectedToControl"`
	KeyExpiryDisabled bool   `json:"keyExpiryDisabled"`
}

func (c Client) devices(ctx context.Context) ([]device, int) {
	code, b, err := c.do(ctx, http.MethodGet, "/tailnet/-/devices", nil)
	if err != nil {
		return nil, 0
	}
	var d struct{ Devices []device }
	if code/100 == 2 {
		_ = json.Unmarshal(b, &d)
	}
	return d.Devices, code
}

// pick is the connected node named exactly this, newest first. "name" is the
// MagicDNS name, which carries any -1 suffix; "hostname" is the OS hostname, which
// a live box and a stale one share. Only the CONNECTED node with this name is
// touched: a stale, offline node from an earlier box is never the one being built.
func pick(devs []device, node string) *device {
	var live []device
	for _, d := range devs {
		if strings.SplitN(d.Name, ".", 2)[0] == node && d.Connected {
			live = append(live, d)
		}
	}
	if len(live) == 0 {
		return nil
	}
	sort.SliceStable(live, func(i, j int) bool { return live[i].Created > live[j].Created })
	return &live[0]
}

// DisableExpiry turns Tailscale key expiry off for the node that just joined. A
// node's key expires after ~180 days by default, and then the box drops off the
// tailnet and `cg open` hangs waiting for it. The API token that already prunes
// stale nodes can stop that instead of a manual step in the admin console.
func (c Client) DisableExpiry(ctx context.Context, node string) Expiry {
	if c.Token == "" {
		return Expiry{NoToken: true, Lines: []string{"no TAILSCALE_API_KEY in .env - key expiry left on"}}
	}
	devs, code := c.devices(ctx)
	switch {
	case code == 401 || code == 403:
		return Expiry{Lines: []string{fmt.Sprintf("tailnet token rejected (%d) - key expiry left on", code), "a new one: https://login.tailscale.com/admin/settings/keys"}}
	case code/100 != 2:
		return Expiry{Lines: []string{fmt.Sprintf("could not reach api.tailscale.com (%03d) - key expiry left on", code)}}
	}
	d := pick(devs, node)
	if d == nil {
		return Expiry{Lines: []string{fmt.Sprintf("no connected tailnet node named '%s' - key expiry left on", node)}}
	}
	if d.KeyExpiryDisabled {
		return Expiry{Off: true, Lines: []string{fmt.Sprintf("key expiry already off for '%s'", node)}}
	}
	code, _, err := c.do(ctx, http.MethodPost, "/device/"+d.ID+"/key", strings.NewReader(`{"keyExpiryDisabled": true}`))
	if err != nil || code/100 != 2 {
		return Expiry{Lines: []string{fmt.Sprintf("could not turn off key expiry (%03d) - the token may lack write scope on devices", code)}}
	}
	// Checked, not assumed: a 200 is the API accepting the request, not proof of
	// the setting.
	if devs, code := c.devices(ctx); code/100 == 2 {
		if d := pick(devs, node); d != nil && d.KeyExpiryDisabled {
			return Expiry{Off: true, Lines: []string{fmt.Sprintf("key expiry off for '%s' - it will not drop off the tailnet", node)}}
		}
	}
	return Expiry{Lines: []string{fmt.Sprintf("the API accepted it, but '%s' still shows key expiry on", node)}}
}

// PruneStale deletes OFFLINE tailnet nodes named after this host, before a build.
//
// Pruning used to happen only in `cg destroy`. That was fine when destroy was how
// a session ended - but the box now terminates itself when it goes idle, and
// nothing on the box can delete its own tailnet entry (that needs an API token,
// which deliberately never leaves the laptop). So every auto-terminated box leaked
// a node, the next build found its name taken, and the tailnet crept to gamevps-1,
// gamevps-2, ... That is not cosmetic: a suffixed name means `.env` and Moonlight
// disagree about what the box is called, and a stale entry answers DNS for a
// machine that no longer exists.
//
// Only OFFLINE nodes are touched. An online one is a box that exists, which this
// must never disturb - including the one being rebuilt beside it.
func (c Client) PruneStale(ctx context.Context, host string) []string {
	if c.Token == "" {
		return nil
	}
	code, b, err := c.do(ctx, http.MethodGet, "/tailnet/-/devices", nil)
	switch {
	case err != nil:
		return []string{"    could not reach api.tailscale.com (000) - skipping the prune"}
	case code == 401 || code == 403:
		// Said out loud: an expired token and a clean tailnet look identical
		// otherwise, and the cleanup just silently stops happening.
		return []string{fmt.Sprintf("    tailnet token rejected (%d) - stale nodes will not be pruned", code), "    a new one: https://login.tailscale.com/admin/settings/keys"}
	case code/100 != 2:
		return []string{fmt.Sprintf("    could not reach api.tailscale.com (%d) - skipping the prune", code)}
	}
	var d struct {
		Devices []struct {
			ID                 string `json:"id"`
			Hostname           string `json:"hostname"`
			LastSeen           string `json:"lastSeen"`
			ConnectedToControl *bool  `json:"connectedToControl"`
		}
	}
	if json.Unmarshal(b, &d) != nil {
		return nil
	}
	pat := regexp.MustCompile(`^` + regexp.QuoteMeta(host) + `(-\d+)?$`)
	var out []string
	for _, dev := range d.Devices {
		// connectedToControl, not "online": the v2 devices API has no "online"
		// field at all (checked live 2026-09-14). A node whose field is absent is
		// left alone: deleting the tailnet identity of a box that is still up makes
		// it unreachable.
		if !pat.MatchString(dev.Hostname) || dev.ConnectedToControl == nil || *dev.ConnectedToControl {
			continue
		}
		seen := dev.LastSeen
		if len(seen) > 19 {
			seen = seen[:19]
		}
		if code, _, err := c.do(ctx, http.MethodDelete, "/device/"+dev.ID, nil); err == nil && code/100 == 2 {
			out = append(out, fmt.Sprintf("    pruned stale tailnet node '%s' (last seen %s)", dev.Hostname, seen))
		} else {
			out = append(out, fmt.Sprintf("    could not prune '%s' - the token may lack write scope", dev.Hostname))
		}
	}
	return out
}

// DeleteNodes removes every tailnet node named after this host - the host and its
// numeric suffixes, online ones included - and nothing else on the tailnet, which
// may include machines that matter. A node's identity lives on the disk a destroy
// just deleted, so the entry left behind can never be reused; it only pushes the
// next build onto a suffixed name. Deleting devices needs an API access token (NOT
// the auth key). It returns what to say.
func (c Client) DeleteNodes(ctx context.Context, host string) []string {
	if c.Token == "" {
		return []string{
			"  Tailnet nodes were left alone - a node's identity lives on the disk",
			"  just deleted, so it cannot be reused. A rebuild joins under the next",
			fmt.Sprintf("  free name (%s-1, -2, ...) and everything adapts to that.", host),
			"",
			"  To have this cleaned up automatically, put a Tailscale API access",
			"  token in .env as TAILSCALE_API_KEY (this is NOT the auth key):",
			"  https://login.tailscale.com/admin/settings/keys",
			"  Or prune them by hand: https://login.tailscale.com/admin/machines"}
	}
	// The status is kept apart from the body. Without this an expired token just
	// yields empty output and the run reports "no matching tailnet nodes found" - an
	// expired key and a clean tailnet look identical, so the cleanup silently stops
	// happening and nothing ever says why.
	devs, code := c.devices(ctx)
	switch {
	case code == 401 || code == 403:
		return []string{fmt.Sprintf("TAILSCALE_API_KEY rejected (HTTP %d) - it has expired or lacks scope", code),
			"  Tailscale access tokens expire after 90 days at most.",
			"  Generate a new one and replace TAILSCALE_API_KEY in .env:",
			"    https://login.tailscale.com/admin/settings/keys",
			"  (needs write scope on devices; this is NOT the auth key)",
			"  Until then, prune by hand: https://login.tailscale.com/admin/machines"}
	case code == 0:
		return []string{"could not reach api.tailscale.com - tailnet nodes left in place", "  (the instance is already deleted; only the tailnet entries remain)"}
	case code/100 != 2:
		return []string{fmt.Sprintf("tailscale API returned HTTP %d - tailnet nodes left in place", code)}
	}
	pat := regexp.MustCompile(`^` + regexp.QuoteMeta(host) + `(-\d+)?$`)
	var out []string
	found := false
	for _, d := range devs {
		name := strings.SplitN(d.Hostname, ".", 2)[0]
		if !pat.MatchString(name) {
			continue
		}
		found = true
		id := d.NodeID
		if id == "" {
			id = d.ID
		}
		if code, _, err := c.do(ctx, http.MethodDelete, "/device/"+id, nil); err == nil && code/100 == 2 {
			out = append(out, fmt.Sprintf("deleted tailnet node '%s'", name))
		} else {
			out = append(out, fmt.Sprintf("could not delete '%s' - check the token has write scope", name))
		}
	}
	if !found {
		out = append(out, fmt.Sprintf("no %s nodes on the tailnet - nothing to remove", host))
	}
	return out
}
