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
	{Path: []string{"games"}, Summary: "what Steam has on the box: installed, downloading, running, archived"},
	{Path: []string{"aws", "inventory"}, Summary: "everything of cg's in this AWS account, and what it bills", JSON: true},
	{Path: []string{"snapshot"}, Summary: "saved images (--list for now)", JSON: true},
	{Path: []string{"host"}, Summary: "your own machines (list for now; add, setup, status, open, remove to come)", JSON: true},
	{Path: []string{"library"}, Aliases: [][]string{{"lib"}}, Summary: "the game archive: list, elsewhere, account (more as they are ported)", JSON: true},
	{Path: []string{"regions"}, Summary: "the regions you have enabled; optin lists the rest, enable turns one on", JSON: true},
	{Path: []string{"quota"}, Summary: "the GPU quota: what you have, how to ask for more, and the appeal text", JSON: true},
	{Path: []string{"sweep"}, Aliases: [][]string{{"regions-sweep"}}, Summary: "every region scored for latency, capacity and quota", JSON: true},
	{Path: []string{"machines"}, Aliases: [][]string{{"types"}}, Summary: "what GPU shapes a region rents, and what each costs", JSON: true},
	{Path: []string{"deps"}, Aliases: [][]string{{"dependencies"}}, Summary: "the tools this computer needs, and what is missing", JSON: true},
	{Path: []string{"creds"}, Aliases: [][]string{{"credentials"}}, Summary: "the AWS access key and the Tailscale token, and whether each works", JSON: true},
	{Path: []string{"config"}, Summary: "what .env decides; set validates and writes, get reveals one", JSON: true},
	{Path: []string{"ping"}, Summary: "latency to the box, and whether the path is direct", JSON: true, Watch: true},
	{Path: []string{"log"}, Aliases: [][]string{{"logs"}}, Summary: "the box's build, steam, watchdog, disk or sunshine log", Watch: true},
	{Path: []string{"ssh"}, Summary: "a shell on the box, or one command"},
	{Path: []string{"watcher"}, Aliases: [][]string{{"guards"}}, Summary: "every guard, and whether each is armed", JSON: true, Watch: true},
	{Path: []string{"watchdog"}, Summary: "layer 3: the cloud watchdog (Lambda) - status and logs", Watch: true},
	{Path: []string{"status"}, Summary: "what exists, and whether every safeguard is on", JSON: true},
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
