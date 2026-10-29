// Package config is where cg's settings live and the one loader that reads
// them. It replaces the old Bash env-file loader and, with it, the
// settings registry.
package config

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// TagKey is the tag every AWS resource cg creates carries, valued with the
// box's name: cg:host=<host>. What cg deletes is chosen by it, never by a Name
// alone - a Name is a label anyone can give anything. AWS reserves only "aws:".
const TagKey = "cg:host"

// Env is the process environment plus the settings file, with the rule that
// anything already exported wins.
type Env struct {
	vars   map[string]string
	getenv Lookup
	File   string // the settings file that was read, or would be written
}

// Defaults are the registry's defaults for the settings the ported commands
// read. The full registry arrives with `cg config`.
var Defaults = map[string]string{
	"GAME_REGION":        "ap-south-2",
	"GAME_INSTANCE_TYPE": "g6.xlarge",
	"GAME_TS_HOST":       "gamevps",
}

// Lookup is a way to read the process environment, for tests.
type Lookup func(string) (string, bool)

// Resolve finds the settings file, first hit wins:
//
//	$CG_ENV_FILE              said outright - tests use this
//	$CG_HOME/.env             a chosen state directory
//	<repo>/.env               an existing checkout that already has one
//	<repo>/.env               a checkout cg can write to - the normal case
//	$XDG_CONFIG_HOME/cg/.env  otherwise: an installed, read-only copy
//
// The checkout comes before XDG deliberately: a fresh `git clone` plus
// `cg check --fix` keeps putting settings beside .env.example. XDG is for the
// case the repo cannot serve.
func Resolve(get Lookup, repo string) string {
	if v, ok := get("CG_ENV_FILE"); ok && v != "" {
		return v
	}
	if v, ok := get("CG_HOME"); ok && v != "" {
		return filepath.Join(v, ".env")
	}
	if repo != "" {
		if st, err := os.Stat(filepath.Join(repo, ".env")); err == nil && st.Mode().IsRegular() {
			return filepath.Join(repo, ".env")
		}
		if writable(repo) {
			return filepath.Join(repo, ".env")
		}
	}
	base, ok := get("XDG_CONFIG_HOME")
	if !ok || base == "" {
		home, _ := get("HOME")
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "cg", ".env")
}

func writable(dir string) bool {
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		return false
	}
	f, err := os.CreateTemp(dir, ".cg-w-*")
	if err != nil {
		return false
	}
	name := f.Name()
	f.Close()
	os.Remove(name)
	return true
}

var assignment = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)

// Load reads the settings file into the environment view. KEY=VALUE lines are
// read, never executed: `source` runs any stray line as a command, so one
// malformed entry turns a config file into a script. A comment, a malformed
// line and a key already set are skipped; a last line with no newline counts.
func Load(get Lookup, repo string) *Env {
	e := &Env{vars: map[string]string{}, getenv: get, File: Resolve(get, repo)}
	f, err := os.Open(e.File)
	if err != nil {
		return e
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if t := strings.TrimLeft(line, " \t"); strings.HasPrefix(t, "#") || !assignment.MatchString(line) {
			continue
		}
		k, v, _ := strings.Cut(line, "=")
		if cur, ok := get(k); ok && cur != "" {
			continue
		}
		e.vars[k] = v
	}
	return e
}

// Get is a setting: the environment, which wins, then the file. Empty if neither.
func (e *Env) Get(key string) string {
	if v, ok := e.getenv(key); ok && v != "" {
		return v
	}
	return e.vars[key]
}

// Setting is Get with the registry's default behind it.
func (e *Env) Setting(key string) string {
	if v := e.Get(key); v != "" {
		return v
	}
	return Defaults[key]
}

// Region is the AWS region everything lives in.
func (e *Env) Region() string { return e.Setting("GAME_REGION") }

// Host is the box's name; it is also the value of cg's ownership tag.
func (e *Env) Host() string { return e.Setting("GAME_TS_HOST") }

// OSLookup reads the real environment.
func OSLookup(k string) (string, bool) { return os.LookupEnv(k) }

// InRegion is these settings seen from another region, for acting there: the same
// file, the same everything, with GAME_REGION answering differently. Writes still go
// to the file, so it is for reading.
func (e *Env) InRegion(region string) *Env {
	c := &Env{vars: map[string]string{}, File: e.File}
	for k, v := range e.vars {
		c.vars[k] = v
	}
	c.vars["GAME_REGION"] = region
	c.getenv = func(k string) (string, bool) {
		if k == "GAME_REGION" {
			return region, true
		}
		return e.getenv(k)
	}
	return c
}
