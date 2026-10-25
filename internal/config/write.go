package config

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// Has reports whether a setting is mentioned at all - in the environment or in
// the file - even if it is empty. An empty GAME_NTFY_URL= is a choice to go
// without, which is not the same as never having been asked.
func (e *Env) Has(key string) bool {
	if _, ok := e.getenv(key); ok {
		return true
	}
	_, ok := e.vars[key]
	return ok
}

// Set writes one line in the settings file, replacing any earlier one and
// keeping every other line. The file is made readable by you alone before
// anything is written to it, and the write is atomic: a crash leaves the old
// file, not half of a new one. The in-memory view follows.
func (e *Env) Set(key, value string) error {
	if err := rewrite(e.File, key, &value); err != nil {
		return err
	}
	e.vars[key] = value
	return nil
}

// Unset takes one key out, keeping every other line.
func (e *Env) Unset(key string) error {
	if err := rewrite(e.File, key, nil); err != nil {
		return err
	}
	delete(e.vars, key)
	return nil
}

func rewrite(path, key string, value *string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var keep []string
	if f, err := os.Open(path); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
		for sc.Scan() {
			if !strings.HasPrefix(sc.Text(), key+"=") {
				keep = append(keep, sc.Text())
			}
		}
		f.Close()
	}
	if value != nil {
		keep = append(keep, key+"="+*value)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".env-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if len(keep) > 0 {
		if _, err := tmp.WriteString(strings.Join(keep, "\n") + "\n"); err != nil {
			tmp.Close()
			return err
		}
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
