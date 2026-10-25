// Package configcmd is `cg config`: the settings in .env, with the rules in one
// place. The app never writes .env itself - it asks cg, so a disk that cannot
// be shrunk, an expiry of 0 meaning "keep forever" and a token that must look
// like a token are enforced once, here, rather than in a renderer.
package configcmd

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Row is one setting as the app reads it. A secret's value is never printed:
// an app shows "set", and may replace it, never read it.
type Row struct {
	Key       string  `json:"key"`
	Kind      string  `json:"kind"`
	Note      string  `json:"note"`
	Label     string  `json:"label"`
	Group     *string `json:"group"`
	Default   *string `json:"default"`
	Rule      *string `json:"rule"`
	Secret    bool    `json:"secret"`
	IsSet     bool    `json:"is_set"`
	Mentioned bool    `json:"mentioned"`
	Value     *string `json:"value"`
	Effective *string `json:"effective"`
}

func nz(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Rows is every setting, its value and whether it is set.
func Rows(env *config.Env) []Row {
	rows := make([]Row, 0, len(config.Registry))
	for _, s := range config.Registry {
		raw := env.Get(s.Key)
		r := Row{Key: s.Key, Kind: s.Kind, Note: s.Note, Label: s.Label, Group: nz(s.Group), Default: nz(s.Default),
			Rule: nz(s.Rule), Secret: s.Kind == "secret", IsSet: raw != "", Mentioned: env.Has(s.Key)}
		if r.Label == "" {
			r.Label = s.Key
		}
		// The ntfy topic is shown: it is yours, in your own window, and an Edit
		// that opened on an empty box asked you to type a topic you could not see.
		if !r.Secret {
			r.Value = nz(raw)
			if raw != "" {
				r.Effective = nz(raw)
			} else {
				r.Effective = nz(s.Default)
			}
		}
		rows = append(rows, r)
	}
	return rows
}

// JSON is `cg config --json`.
func JSON(env *config.Env) ([]byte, error) { return json.MarshalIndent(Rows(env), "", "  ") }

// Show is the human view.
func Show(env *config.Env) string {
	var b strings.Builder
	fmt.Fprintf(&b, "  %-28s %-12s %s\n", "SETTING", "VALUE", "NOTE")
	for _, s := range config.Registry {
		v := env.Get(s.Key)
		switch {
		case s.Kind == "secret":
			v = "not set"
			if env.Get(s.Key) != "" {
				v = "set"
			}
		case v == "":
			v = "–"
			if s.Default != "" {
				v = s.Default + " (default)"
			}
		}
		fmt.Fprintf(&b, "  %-28s %-12s %s\n", s.Key, v, s.Note)
	}
	return b.String()
}

// Get is the one deliberate way to see a secret: it prints the value, alone, so
// it can be piped.
func Get(env *config.Env, key string) (string, error) {
	if _, ok := config.Find(key); !ok {
		return "", fmt.Errorf("unknown setting '%s'", key)
	}
	return env.Get(key), nil
}

// Set validates, writes, and says what it did - and when it applies. A secret
// is never echoed.
func Set(env *config.Env, key, value string, out *output.Out) error {
	if why := config.Validate(key, value); why != "" {
		return fmt.Errorf("%s: %s", key, why)
	}
	if err := env.Set(key, value); err != nil {
		return fmt.Errorf("could not write .env")
	}
	s, _ := config.Find(key)
	shown := value
	if s.Kind == "secret" && value != "" {
		shown = "set"
	}
	if value == "" {
		shown = "cleared"
	}
	out.LogAs("ok", fmt.Sprintf("%s = %s", key, shown))
	switch key {
	case "GAME_DISK_GB", "GAME_DISK_RESERVE_GB", "GAME_INSTANCE_TYPE", "GAME_REGION", "GAME_SPOT":
		out.LogAs("info", "applies to the next cg init")
	case "GAME_ARCHIVE_EXPIRY_DAYS", "GAME_WATCHDOG_IDLE_MIN", "GAME_WATCHDOG_STUCK_MIN", "GAME_NTFY_URL":
		out.LogAs("info", "applies when the cloud watchdog is next deployed: cg watchdog install")
	case "GAME_BUDGET_INR", "EMAIL_ALERTS":
		out.LogAs("info", "applies at the next cg init, which rewrites the budget")
	}
	return nil
}

// Run is `cg config`.
func Run(env *config.Env, args []string, jsonFlag bool, out *output.Out) int {
	sub := "show"
	if len(args) > 0 {
		sub, args = args[0], args[1:]
	}
	switch sub {
	case "show", "":
		if jsonFlag {
			return printJSON(env, out)
		}
		out.Report("Settings", Show(env))
		return 0
	case "--json":
		return printJSON(env, out)
	case "set":
		if len(args) < 1 {
			out.Die("usage: cg config set <key> [value]")
			return 1
		}
		value := ""
		if len(args) > 1 {
			value = args[1]
		}
		if err := Set(env, args[0], value, out); err != nil {
			out.Die(err.Error())
			return 1
		}
		return 0
	case "get":
		if len(args) < 1 {
			out.Die("usage: cg config get <key>")
			return 1
		}
		v, err := Get(env, args[0])
		if err != nil {
			out.Die(err.Error())
			return 1
		}
		fmt.Fprintf(out.Stdout, "%s\n", v)
		return 0
	}
	out.Die("usage: cg config [show|--json|get <key>|set <key> [value]]")
	return 1
}

func printJSON(env *config.Env, out *output.Out) int {
	b, err := JSON(env)
	if err != nil {
		out.Die(err.Error())
		return 1
	}
	fmt.Fprintf(out.Stdout, "%s\n", b)
	return 0
}
