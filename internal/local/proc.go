package local

import (
	"os"
	"path/filepath"
)

// Home is the user's home directory: $HOME where it is set, else what the system
// says (the profile folder, on Windows, which has no $HOME).
func Home(get func(string) (string, bool)) string {
	if h, ok := get("HOME"); ok && h != "" {
		return h
	}
	if h, err := os.UserHomeDir(); err == nil {
		return h
	}
	if h, ok := get("USERPROFILE"); ok {
		return h
	}
	return ""
}

// ConfigBase is where ayis keeps its own files: $XDG_CONFIG_HOME, else ~/.config.
func ConfigBase(get func(string) (string, bool)) string {
	if b, ok := get("XDG_CONFIG_HOME"); ok && b != "" {
		return b
	}
	return filepath.Join(Home(get), ".config")
}
