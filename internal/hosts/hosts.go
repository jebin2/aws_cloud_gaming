// Package hosts is your own machines: a PC or a server you already have,
// reached over ssh and streamed from over Tailscale - not only an AWS box. They
// are kept in one JSON file, readable by you alone, because it holds each
// machine's Sunshine login.
package hosts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// Store is the file.
type Store struct{ Path string }

// PathFor is where it lives: $XDG_CONFIG_HOME/cg/hosts.json, else ~/.config.
func PathFor(get func(string) (string, bool)) string {
	base, ok := get("XDG_CONFIG_HOME")
	if !ok || base == "" {
		home, _ := get("HOME")
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "cg", "hosts.json")
}

// Record is one machine, as a free map: setup adds fields as it learns them.
type Record map[string]any

func (s Store) all() map[string]Record {
	b, err := os.ReadFile(s.Path)
	if err != nil {
		return map[string]Record{}
	}
	d := map[string]Record{}
	if json.Unmarshal(b, &d) != nil {
		return map[string]Record{}
	}
	return d
}

// Names are the machines, sorted.
func (s Store) Names() []string {
	var out []string
	for n := range s.all() {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Get is a machine, nil when there is none.
func (s Store) Get(name string) Record { return s.all()[name] }

// Field is one field of a machine as text, "" when it has none.
func (r Record) Field(k string) string {
	if v, ok := r[k].(string); ok {
		return v
	}
	return ""
}

// Public is the record without the secret: the Sunshine password never leaves
// the file in a list.
func (r Record) Public(name string) Record {
	out := Record{}
	for k, v := range r {
		if k != "sunshine_pass" {
			out[k] = v
		}
	}
	out["name"] = name
	return out
}
