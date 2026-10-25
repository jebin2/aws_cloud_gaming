package config

import (
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// Setting is one row of the registry: what a setting is, what it may be, and
// where it belongs on screen. One registry, read by `cg config` and by the app,
// so the rules - a disk that cannot be shrunk, an expiry of 0 meaning "keep
// forever", a token that must look like a token - live here and not in a
// renderer.
type Setting struct {
	Key     string
	Kind    string // number | text | choice | secret | ntfy | email | region
	Default string
	Rule    string // number: the minimum; choice: the allowed values, comma separated
	Note    string
	Label   string // what a person calls it
	Group   string // which card it belongs on; empty means it has a card of its own
}

// Registry is every setting cg reads from .env.
var Registry = []Setting{
	{"GAME_DISK_GB", "number", "50", "30", "Root disk in GB. Cannot be shrunk later; applies to the next build.", "root disk (GB)", "The box"},
	{"GAME_DISK_RESERVE_GB", "number", "20", "0", "Space kept free on the game disk for Steam's downloads, updates and shader caches.", "game disk kept free (GB)", "The box"},
	{"GAME_ARCHIVE_EXPIRY_DAYS", "number", "14", "0", "Days with no box before the cloud watchdog deletes the archive, and days an on-demand box may stay stopped before it is deleted (its games kept). 0 keeps both forever.", "archive expiry (days)", "The guards"},
	{"GAME_INSTANCE_TYPE", "text", "g6.xlarge", "", "The EC2 instance type. Its GPU quota must cover it.", "instance type", "The box"},
	{"GAME_REGION", "region", "ap-south-2", "", "The AWS region everything lives in. Changing it starts over: the archive does not follow.", "region", "The box"},
	{"GAME_SPOT", "choice", "auto", "auto,1,0", "Purchase model: spot, on demand, or spot whenever the quota allows.", "purchase model", "The box"},
	{"GAME_STEAM_LOGIN", "choice", "use", "use,fresh", "Whether a new box restores the archived Steam login, or asks you to sign in.", "Steam sign-in", "The box"},
	{"GAME_BUDGET_INR", "number", "5000", "100", "Monthly budget. It emails you; it stops nothing.", "monthly budget (INR)", "The guards"},
	{"GAME_WATCHDOG_IDLE_MIN", "number", "30", "10", "Minutes of quiet before the cloud watchdog ends the box.", "cloud watchdog idle (min)", "The guards"},
	{"GAME_WATCHDOG_STUCK_MIN", "number", "60", "40", "Minutes before a stuck shutdown is forced. Never inside the push's 30.", "stuck shutdown forced after (min)", "The guards"},
	{"GAME_NTFY_URL", "ntfy", "", "", "Phone notifications: an ntfy topic or full URL. Empty turns them off.", "phone notifications", "Notifications"},
	{"TAILSCALE_API_KEY", "secret", "", "", "Tailscale API token. Prunes old nodes and turns off key expiry. Empty goes without.", "Tailscale API token", ""},
	{"EMAIL_ALERTS", "email", "", "", "Where budget alerts are sent. Comma separated for several.", "billing alerts to", "Notifications"},
	{"GAME_RES", "text", "", "", "Moonlight resolution, e.g. 1920x1080. Empty leaves Moonlight's own setting.", "stream resolution", "The stream"},
	{"GAME_FPS", "number", "60", "24", "Moonlight frame rate.", "stream fps", "The stream"},
	{"GAME_BITRATE_KBPS", "number", "20000", "500", "Moonlight bitrate. Lower it to cut streaming egress proportionally.", "stream bitrate (kbps)", "The stream"},
}

// Find returns the registry row for a key.
func Find(key string) (Setting, bool) {
	for _, s := range Registry {
		if s.Key == key {
			return s, true
		}
	}
	return Setting{}, false
}

func init() {
	for _, s := range Registry {
		if s.Default != "" {
			Defaults[s.Key] = s.Default
		}
	}
}

var (
	wholeNumber = regexp.MustCompile(`^[0-9]+$`)
	tskey       = regexp.MustCompile(`^tskey-[A-Za-z0-9-]+$`)
	regionShape = regexp.MustCompile(`^[a-z]{2}(-[a-z]+)+-[0-9]$`)
	ntfyShape   = regexp.MustCompile(`^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_-]{1,64}$`)
)

// NtfyURL is the URL to post to, or "": unset and malformed are both "off". A
// bare topic is a topic on ntfy.sh.
func NtfyURL(v string) string {
	if v == "" {
		return ""
	}
	if !strings.HasPrefix(v, "http://") && !strings.HasPrefix(v, "https://") {
		v = "https://ntfy.sh/" + v
	}
	if !ntfyShape.MatchString(v) {
		return ""
	}
	if _, err := url.Parse(v); err != nil {
		return ""
	}
	return v
}

// Validate says why a value is refused, or "" if it is fine. It is a pure
// function: whether a region exists or rents a GPU is AWS's answer, and comes
// from `cg sweep`.
func Validate(key, value string) string {
	s, ok := Find(key)
	if !ok {
		return fmt.Sprintf("unknown setting '%s'", key)
	}
	if strings.Contains(value, "\n") {
		return "a setting cannot contain a newline"
	}
	switch s.Kind {
	case "number":
		if !wholeNumber.MatchString(value) {
			return "must be a whole number"
		}
		min, _ := strconv.Atoi(s.Rule)
		if n, err := strconv.Atoi(value); err != nil || n < min {
			return fmt.Sprintf("must be at least %d", min)
		}
	case "choice":
		if !strings.Contains(","+s.Rule+",", ","+value+",") {
			return "must be one of: " + strings.ReplaceAll(s.Rule, ",", ", ")
		}
	case "secret":
		if value != "" && !tskey.MatchString(value) {
			return "does not look like a Tailscale token"
		}
	case "ntfy":
		if value != "" && NtfyURL(value) == "" {
			return "not a valid ntfy topic or URL"
		}
	case "email":
		i := strings.Index(value, "@")
		if i < 0 || !strings.Contains(value[i:], ".") {
			return "does not look like an email address"
		}
	case "region":
		if !regionShape.MatchString(value) {
			return "does not look like an AWS region, e.g. ap-south-1"
		}
	case "text":
		if value == "" {
			return "cannot be empty"
		}
	}
	return ""
}

// Int reads a setting as a whole number: the file's value, else the registry's
// default, and never under the registry's minimum - the floors cw_install has
// always applied. A value that is not a number falls back to the default.
func (e *Env) Int(key string) int {
	s, _ := Find(key)
	def, _ := strconv.Atoi(s.Default)
	min, _ := strconv.Atoi(s.Rule)
	v := def
	if raw := e.Get(key); wholeNumber.MatchString(raw) {
		v, _ = strconv.Atoi(raw)
	}
	if s.Kind == "number" && s.Rule != "" && v < min {
		v = min
	}
	return v
}
