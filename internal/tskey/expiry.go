package tskey

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
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
