package local

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// installed is where a desktop installer puts a program it does not put on PATH:
// Moonlight and Tailscale come as applications on macOS and Windows, and their
// installers leave the command line out. cg runs them by name, so it looks here
// when PATH has nothing.
func installed(goos, name string, getenv func(string) string) []string {
	switch goos + ":" + name {
	// ssh sessions and the app start with a bare PATH, which has no Homebrew.
	case "darwin:brew":
		return []string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"}
	case "darwin:moonlight":
		return []string{"/Applications/Moonlight.app/Contents/MacOS/Moonlight"}
	case "darwin:tailscale":
		return []string{"/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"}
	case "windows:moonlight":
		return programFiles(getenv, `Moonlight Game Streaming\Moonlight.exe`)
	case "windows:tailscale":
		return programFiles(getenv, `Tailscale\tailscale.exe`)
	}
	return nil
}

func programFiles(getenv func(string) string, rel string) []string {
	var out []string
	for _, v := range []string{"ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"} {
		if base := getenv(v); base != "" {
			out = append(out, filepath.Join(base, rel))
		}
	}
	return out
}

// Find is the program to run for a name: the one on PATH, else the one the
// installer put in its usual place, else the name itself (so the error says what
// was asked for).
func Find(name string) string {
	return find(runtime.GOOS, name, os.Getenv, exec.LookPath, func(p string) bool { st, err := os.Stat(p); return err == nil && !st.IsDir() })
}

func find(goos, name string, getenv func(string) string, look func(string) (string, error), exists func(string) bool) string {
	if p, err := look(name); err == nil {
		return p
	}
	for _, p := range installed(goos, name, getenv) {
		if exists(p) {
			return p
		}
	}
	return name
}
