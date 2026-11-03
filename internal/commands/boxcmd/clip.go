package boxcmd

import (
	"bytes"
	"context"
	"fmt"
	"runtime"
	"unicode/utf8"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// clipMax is the most text carried across. A clipboard is a sentence or a
// password, not a file; a megabyte is far past that and still instant.
const clipMax = 1 << 20

// clipTool is one way to read or write this computer's clipboard.
type clipTool struct {
	name string
	args []string
}

// clipReaders and clipWriters are the programs that reach the clipboard, in the
// order they are tried. A Wayland session has wl-clipboard, an X session xclip
// or xsel; macOS and Windows ship their own.
func clipReaders(goos string) []clipTool {
	switch goos {
	case "darwin":
		return []clipTool{{"pbpaste", nil}}
	case "windows":
		return []clipTool{{"powershell", []string{"-NoProfile", "-Command", "Get-Clipboard -Raw"}}}
	}
	return []clipTool{{"wl-paste", []string{"--no-newline"}}, {"xclip", []string{"-selection", "clipboard", "-o"}}, {"xsel", []string{"--clipboard", "--output"}}}
}

func clipWriters(goos string) []clipTool {
	switch goos {
	case "darwin":
		return []clipTool{{"pbcopy", nil}}
	case "windows":
		return []clipTool{{"powershell", []string{"-NoProfile", "-Command", "$input | Set-Clipboard"}}}
	}
	return []clipTool{{"wl-copy", nil}, {"xclip", []string{"-selection", "clipboard", "-i"}}, {"xsel", []string{"--clipboard", "--input"}}}
}

// clipHint is what to install when this computer has no way to reach its
// clipboard. Plain: it is shown to someone looking at a window.
func clipHint(goos string) string {
	if goos == "linux" {
		return "this computer has no program for its clipboard. Install wl-clipboard (Wayland) or xclip (X), then try again"
	}
	return "this computer's clipboard could not be reached"
}

func (d Deps) goos() string {
	if d.GOOS != "" {
		return d.GOOS
	}
	return runtime.GOOS
}

// boxClipEnv points a program at the game PC's desktop, which is where its
// clipboard lives (an ssh login has no screen of its own).
const boxClipEnv = `export DISPLAY=:0 XAUTHORITY="$HOME/.Xauthority"; `

// boxClipReady installs the clipboard program on a game PC built before this
// existed, once. It is small, and from Ubuntu's own list.
const boxClipReady = `command -v xclip >/dev/null 2>&1 || { sudo apt-get install -y -qq xclip >/dev/null 2>&1; }; command -v xclip >/dev/null 2>&1 || { echo "the game PC could not install its clipboard program" >&2; exit 3; }; `

// ClipSend is `cg clip send`: this computer's clipboard, as text, onto the game
// PC's. Ctrl+V on the game PC then pastes it.
func (d Deps) ClipSend(ctx context.Context) int {
	if d.Box.ID == "" {
		return d.die("there is no game PC yet")
	}
	if !d.NeedNode(ctx) {
		return 1
	}
	d.Out.SayID("clip.read", "Reading your clipboard")
	text, ok := d.readLocalClip(ctx)
	if !ok {
		return d.die(clipHint(d.goos()))
	}
	if len(bytes.TrimSpace(text)) == 0 {
		return d.die("your clipboard is empty, or holds something that is not text")
	}
	if len(text) > clipMax {
		return d.die("your clipboard holds more than 1 MB of text, which is too much to carry across")
	}
	if !utf8.Valid(text) {
		return d.die("your clipboard holds something that is not text")
	}
	d.Out.SayID("clip.send", "Putting it on the game PC")
	script := boxClipReady + boxClipEnv + `xclip -selection clipboard -i >/dev/null 2>&1`
	if _, err := d.Box.SSH(ctx, remote("bash", "-c", script), bytes.NewReader(text)); err != nil {
		return d.die("the game PC did not take it: " + firstErrorLine(err.Error()))
	}
	d.Out.SayID("clip.done", fmt.Sprintf("Done: %d characters are on the game PC's clipboard. Paste there with Ctrl+V", utf8.RuneCount(text)))
	return 0
}

// ClipGet is `cg clip get`: the game PC's clipboard, as text, onto this
// computer's.
func (d Deps) ClipGet(ctx context.Context) int {
	if d.Box.ID == "" {
		return d.die("there is no game PC yet")
	}
	if !d.NeedNode(ctx) {
		return 1
	}
	d.Out.SayID("clip.read", "Reading the game PC's clipboard")
	script := boxClipReady + boxClipEnv + `xclip -selection clipboard -o 2>/dev/null || true`
	text, err := d.Box.SSH(ctx, remote("bash", "-c", script), nil)
	if err != nil {
		return d.die("the game PC did not answer: " + firstErrorLine(err.Error()))
	}
	if len(bytes.TrimSpace(text)) == 0 {
		return d.die("the game PC's clipboard is empty, or holds something that is not text")
	}
	if len(text) > clipMax {
		return d.die("the game PC's clipboard holds more than 1 MB of text, which is too much to carry across")
	}
	d.Out.SayID("clip.put", "Putting it on your clipboard")
	if !d.writeLocalClip(ctx, text) {
		return d.die(clipHint(d.goos()))
	}
	d.Out.SayID("clip.done", fmt.Sprintf("Done: %d characters are on your clipboard. Paste here with Ctrl+V", utf8.RuneCount(text)))
	return 0
}

func (d Deps) readLocalClip(ctx context.Context) ([]byte, bool) {
	for _, t := range clipReaders(d.goos()) {
		if !d.R.Has(t.name) {
			continue
		}
		if out, err := d.R.Run(ctx, local.Cmd{Name: t.name, Args: t.args}); err == nil {
			return out, true
		}
	}
	return nil, false
}

func (d Deps) writeLocalClip(ctx context.Context, text []byte) bool {
	for _, t := range clipWriters(d.goos()) {
		if !d.R.Has(t.name) {
			continue
		}
		name, args := t.name, t.args
		// wl-copy, xclip and xsel stay behind to serve the clipboard and keep
		// our output open while they do, so reading it to the end would wait
		// for ever. Their output is sent away; a shell does that where there is one.
		if d.goos() == "linux" {
			cmd := name
			for _, a := range args {
				cmd += " " + quote(a)
			}
			name, args = "sh", []string{"-c", cmd + " >/dev/null 2>&1"}
		}
		if _, err := d.R.Run(ctx, local.Cmd{Name: name, Args: args, Stdin: bytes.NewReader(text)}); err == nil {
			return true
		}
	}
	return false
}
