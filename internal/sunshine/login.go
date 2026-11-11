package sunshine

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
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
	// OnMachine runs a command on the machine (over ssh) with stdin; nil when it
	// cannot.
	OnMachine func(ctx context.Context, command string, stdin io.Reader) error
	Sleep     func(time.Duration)
	Tries     int // how many 3-second checks after the reset; 20 by default
}

func newPass() string {
	b := make([]byte, 18)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// newSalt is a Sunshine state-file salt: 16 letters and digits.
func newSalt() string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

// sunshineHash is the password Sunshine stores in its state file:
// SHA-256(password + salt), the digest's bytes reversed and hex in upper case -
// save_user_creds in Sunshine's src/httpcommon.cpp, Hex in src/utility.h.
func sunshineHash(pass, salt string) string {
	sum := sha256.Sum256([]byte(pass + salt))
	for i, j := 0, len(sum)-1; i < j; i, j = i+1, j-1 {
		sum[i], sum[j] = sum[j], sum[i]
	}
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

// stateScript writes a Sunshine login into its state file in Sunshine's own
// format. The username, salt and hash arrive on stdin, one per line, so the
// password is never an argument to anything - `sunshine --creds` put it in the
// process's command line, where any other local account could read it from
// /proc/<pid>/cmdline. A state file that is there but unreadable is left alone
// rather than replaced: it holds the paired devices. The service is restarted so
// the running Sunshine reads the new login.
const stateScript = `IFS= read -r u && IFS= read -r s && IFS= read -r h || { echo "no Sunshine login on stdin" >&2; exit 1; }
d="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine"
st="$d/sunshine_state.json"
mkdir -p "$d"
if [ -s "$st" ] && ! jq . "$st" >/dev/null 2>&1; then
  echo "the Sunshine state file is not valid JSON - leaving it alone" >&2
  exit 1
fi
if [ -s "$st" ]; then
  (umask 077; jq --arg u "$u" --arg s "$s" --arg p "$h" '.username = $u | .salt = $s | .password = $p' "$st" > "$st.new") || { rm -f "$st.new"; exit 1; }
else
  (umask 077; jq -nc --arg u "$u" --arg s "$s" --arg p "$h" '{username: $u, salt: $s, password: $p}' > "$st.new") || { rm -f "$st.new"; exit 1; }
fi
mv "$st.new" "$st"
unit=$(XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-unit-files '*unshine*' --no-legend 2>/dev/null | awk 'NR==1{print $1}')
if [ -n "$unit" ]; then
  XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user restart "$unit"
fi
`

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
	// The state file is written on the machine and Sunshine restarted, so the
	// running one reads it. The unit is found rather than named: the package names
	// it differently from one distribution to the next.
	if e.OnMachine != nil {
		salt := newSalt()
		in := strings.NewReader(e.Login.User + "\n" + salt + "\n" + sunshineHash(e.Login.Pass, salt) + "\n")
		if e.OnMachine(ctx, stateScript, in) == nil {
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
