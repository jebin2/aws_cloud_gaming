package sunshine

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Account creates the first-run login over the API: no browser, no password to
// invent. The PIN exchange cannot be done this way, which is why pairing is
// separate.
func (c Client) Account(ctx context.Context, ip, user, pass string) {
	body, _ := json.Marshal(map[string]string{"newUsername": user, "newPassword": pass, "confirmNewPassword": pass})
	c.do(ctx, http.MethodPost, ip, "/api/password", 15*time.Second, "", "", string(body))
}

// Wait polls /welcome until Sunshine has settled. Three outcomes, and each must
// END the loop as soon as it is certain:
//
//	200          first run, no account yet      -> create one
//	2xx/3xx/4xx  Sunshine is up and configured  -> nothing to do
//	000          not listening yet              -> keep waiting
//
// Poll /welcome itself, not /. Sunshine answers on / before /welcome is ready, so
// checking / raced ahead and a not-yet-200 /welcome was misread as "already
// configured" - which skipped account creation and pairing. A non-200 is
// confirmed a few times rather than trusted at once, because Sunshine serves /
// and redirects for a moment before /welcome settles. A configured machine used
// to run the loop to exhaustion - over five minutes for an answer it had on the
// first request.
func (c Client) Wait(ctx context.Context, ip string, tries int, sleep func(time.Duration)) (up, firstRun bool) {
	configured := 0
	for i := 0; i < tries; i++ {
		switch code := c.code(ctx, http.MethodGet, ip, "/welcome", 5*time.Second, "", ""); {
		case code == 200:
			return true, true
		case code == 0:
			configured = 0
		default:
			up = true
			configured++
			if configured >= 3 {
				return true, false
			}
		}
		sleep(3 * time.Second)
	}
	return up, false
}

// Keeper is where a Sunshine login is kept: .env for the AWS box, hosts.json for
// a machine of yours.
type Keeper func(key, value string)

// Login is the Sunshine login a machine and this laptop must agree on.
type Login struct{ User, Pass string }

// Ensure leaves a login that the machine accepts, and says what it did. A new
// password is saved BEFORE the machine is given it. It reports false only when it
// could not be done.
type Ensure struct {
	C     Client
	IP    string
	Login *Login
	Save  Keeper
	Say   func(string)
	// OnMachine runs a command on the machine (over ssh); nil when it cannot.
	OnMachine func(ctx context.Context, command string) error
	Sleep     func(time.Duration)
	Tries     int // how many 3-second checks after the reset; 20 by default
}

func newPass() string {
	b := make([]byte, 18)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func (e *Ensure) fresh() {
	if e.Login.User == "" {
		e.Login.User = "admin"
	}
	e.Login.Pass = newPass()
	e.Save("SUNSHINE_USER", e.Login.User)
	e.Save("SUNSHINE_PASS", e.Login.Pass)
}

// Run is the whole decision.
func (e *Ensure) Run(ctx context.Context, firstRun bool) bool {
	if firstRun {
		e.fresh()
		e.C.Account(ctx, e.IP, e.Login.User, e.Login.Pass)
	}
	if e.C.LoginOK(ctx, e.IP, e.Login.User, e.Login.Pass) {
		if firstRun {
			e.Say("created; credentials saved")
		} else {
			e.Say("already configured, and the saved login works")
		}
		return true
	}
	if e.Login.Pass == "" {
		e.Say("no Sunshine login saved here yet - setting one on the machine")
	} else {
		e.Say("the machine's Sunshine login is not the one saved here - setting it again on the machine")
	}
	e.fresh()
	// sunshine --creds writes the login and exits; a restart makes the running
	// Sunshine read it. The unit is found rather than named: the package names it
	// differently from one distribution to the next.
	if e.OnMachine != nil {
		cmd := fmt.Sprintf(`sunshine --creds '%s' '%s' >/dev/null 2>&1 && u=$(XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-unit-files '*unshine*' --no-legend 2>/dev/null | awk 'NR==1{print $1}') && XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user restart "$u"`, e.Login.User, e.Login.Pass)
		if e.OnMachine(ctx, cmd) == nil {
			n := e.Tries
			if n == 0 {
				n = 20
			}
			for i := 0; i < n; i++ {
				if e.C.LoginOK(ctx, e.IP, e.Login.User, e.Login.Pass) {
					break
				}
				e.Sleep(3 * time.Second)
			}
		}
	}
	if e.C.LoginOK(ctx, e.IP, e.Login.User, e.Login.Pass) {
		e.Say("reset; credentials saved")
		return true
	}
	e.Say(fmt.Sprintf("could not set the Sunshine login - do it in the browser at https://%s:%s", e.IP, Port))
	return false
}
