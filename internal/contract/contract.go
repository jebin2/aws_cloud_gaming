// Package contract is the command registry and the event contract the app
// drives cg by. Help, --contract and dispatch are all generated from it, so
// none of them can say something the others do not.
package contract

import "encoding/json"

// EventsVersion is the version of the NDJSON event stream on stderr.
const EventsVersion = 1

// Command is one entry in the registry: a path such as ["library", "push"]
// and what the app needs to know about running it.
type Command struct {
	Path      []string
	Aliases   [][]string
	Summary   string
	JSON      bool // supports --json
	Watch     bool // supports --watch
	RunsAlone bool // may not run beside any other command
}

// Registry is every command cg-go implements. A command that is not in it is
// not reachable. The pilot has only cost; the rest is added as it is ported.
var Registry = []Command{
	{Path: []string{"cost"}, Summary: "spend this month: billed so far, and an estimate for what is not billed yet", JSON: true},
}

// RunsAlone lists commands that cannot run beside anything else. These are
// named by path prefix, as `cg --contract` has always published them, and
// include commands not yet ported: the app schedules from this list.
var RunsAlone = [][]string{
	{"init"}, {"destroy"}, {"open"},
	{"library", "push"}, {"library", "pull"}, {"library", "forget"},
	{"library", "clean"}, {"library", "account"}, {"library", "move"},
	{"library", "reset"}, {"library", "keep-for"},
	{"creds", "set"},
	{"creds", "tailscale", "signin"},
	{"creds", "tailscale", "authkey"},
	{"deps", "install"},
	{"aws", "disconnect"},
}

// Asks is every question cg can put to the app, by id.
var Asks = []string{
	"aws-access-key-id", "aws-secret-access-key",
	"tailscale-api-token", "tailscale-auth-key",
	"alert-email", "session-end", "fix-go-ahead", "steam-login",
	"clean-orphans", "delete-volume", "destroy-all", "forget-game", "forget-login",
	"move-game", "host-sudo", "host-ssh-password", "aws-disconnect",
}

type document struct {
	Events    int        `json:"events"`
	RunsAlone [][]string `json:"runs_alone"`
	Asks      []string   `json:"asks"`
}

// JSON is what `cg --contract` prints.
func JSON() ([]byte, error) {
	return json.MarshalIndent(document{EventsVersion, RunsAlone, Asks}, "", "  ")
}
