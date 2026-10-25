// Package stream is the stream itself, from whatever machine: Moonlight with the
// stream settings, timed. The lock, and anything to do with the machine before
// and after, stay with the caller.
package stream

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// GPU is the environment that keeps Moonlight off a hung NVIDIA driver, and the
// words that say so.
//
// On a laptop with an Intel and an NVIDIA GPU, Moonlight runs on the Intel one and
// never touches NVIDIA's. Before it streams, Moonlight tries every GPU it can find
// - a test window, a test decode - and a hung NVIDIA driver (Xid 109, seen on one
// such laptop) freezes any process that opens it: Moonlight sat at "connecting"
// and never asked the host for anything. Intel decodes a game stream perfectly
// well. Only what is installed is set, and a choice already made in the
// environment is left alone. Root is for tests.
func GPU(root string, get func(string) string, arch string) (env []string, label string) {
	for _, k := range []string{"__GLX_VENDOR_LIBRARY_NAME", "__EGL_VENDOR_LIBRARY_FILENAMES", "LIBVA_DRIVER_NAME", "VK_DRIVER_FILES", "VK_ICD_FILENAMES"} {
		if get(k) != "" {
			// Chosen already - by you, or by the app, which makes the same choice
			// for itself before it starts cg. Said when it is this one.
			if get("__GLX_VENDOR_LIBRARY_NAME") == "mesa" {
				label = "the Intel GPU (NVIDIA left alone)"
			}
			return nil, label
		}
	}
	exists := func(p string) bool { _, err := os.Stat(p); return err == nil }
	if !exists(filepath.Join(root, "dev/nvidiactl")) && !exists(filepath.Join(root, "proc/driver/nvidia/version")) {
		return nil, ""
	}
	intel := false
	devs, _ := filepath.Glob(filepath.Join(root, "sys/class/drm/renderD*/device/driver"))
	for _, d := range devs {
		if t, err := filepath.EvalSymlinks(d); err == nil {
			switch filepath.Base(t) {
			case "i915", "xe":
				intel = true
			}
		}
	}
	if !intel {
		return nil, ""
	}
	env = append(env, "__GLX_VENDOR_LIBRARY_NAME=mesa")
	if egl := filepath.Join(root, "usr/share/glvnd/egl_vendor.d/50_mesa.json"); exists(egl) {
		env = append(env, "__EGL_VENDOR_LIBRARY_FILENAMES="+egl)
	}
	for _, vk := range []string{filepath.Join(root, "usr/share/vulkan/icd.d/intel_icd."+arch+".json"), filepath.Join(root, "usr/share/vulkan/icd.d/intel_icd.json")} {
		if exists(vk) {
			env = append(env, "VK_DRIVER_FILES="+vk, "VK_ICD_FILENAMES="+vk)
			break
		}
	}
	va := ""
	for _, d := range []string{"usr/lib/dri", "usr/lib64/dri", "usr/lib/x86_64-linux-gnu/dri"} {
		if exists(filepath.Join(root, d, "iHD_drv_video.so")) {
			va = "iHD"
			break
		}
		if exists(filepath.Join(root, d, "i965_drv_video.so")) {
			va = "i965"
		}
	}
	if va != "" {
		env = append(env, "LIBVA_DRIVER_NAME="+va)
	}
	return env, "the Intel GPU (NVIDIA left alone)"
}

// Flags are the stream settings, from .env, as launch flags rather than by
// rewriting Moonlight's config: the flags win for this session and leave whatever
// you set in the GUI untouched. A variable left unset passes no flag at all, so
// Moonlight's own saved setting remains the default. No display mode: Moonlight
// keeps its own, full screen unless changed there.
func Flags(get func(string) string) []string {
	var f []string
	add := func(flag, key string) {
		if v := get(key); v != "" {
			f = append(f, flag, v)
		}
	}
	add("--resolution", "GAME_RES")
	add("--fps", "GAME_FPS")
	add("--bitrate", "GAME_BITRATE_KBPS")
	add("--video-codec", "GAME_VIDEO_CODEC")
	if get("GAME_PERF_OVERLAY") == "1" {
		f = append(f, "--performance-overlay")
	}
	return f
}

// Player starts Moonlight.
type Player struct {
	R        local.Runner
	Get      func(string) string
	CacheDir string
	Root     string // for GPU detection; "" is the real root
	Now      func() time.Time
	// Echo says a plain line, Log a detail line, Warn a warning.
	Echo, Log, Warn func(string)
}

var (
	said    = regexp.MustCompile(`Qt (Warning|Critical)|SDL (Error|Critical)|[Ff]ailed to start|[Cc]onnection|offline`)
	skipped = regexp.MustCompile(`QML|portal|libplacebo|VDPAU|AMF|v4l2m2m|cuvid|hwdevice|decoder for format`)
	LogName = "moonlight.log"
)

// Play streams, and returns how long it lasted. Moonlight's own output goes to a
// file of its own, not into cg's: it is a debug log - every decoder it tried,
// every packet format - thousands of lines that buried the one worth reading. A
// stream that ends within seconds did not end by choice, so then its last
// warnings are said, and where the rest is.
func (p Player) Play(ctx context.Context, ip, app string) time.Duration {
	if app == "" {
		app = "Desktop"
	}
	now := p.Now
	if now == nil {
		now = time.Now
	}
	logFile := filepath.Join(p.CacheDir, LogName)
	_ = os.MkdirAll(p.CacheDir, 0o755)
	flags := Flags(p.Get)
	if len(flags) > 0 {
		p.Echo("    stream: " + strings.Join(flags, " "))
	}
	var env []string
	var label string
	if runtime.GOOS == "linux" {
		env, label = GPU(p.Root, p.Get, runtime.GOARCH)
	}
	if label != "" {
		p.Echo("    decoding on " + label)
	}
	var out bytes.Buffer
	t0 := now()
	args := append([]string{"stream"}, flags...)
	_, _ = p.R.Run(ctx, local.Cmd{Name: "moonlight", Args: append(args, ip, app), Env: env, Combined: &out})
	took := now().Sub(t0)
	_ = os.WriteFile(logFile, out.Bytes(), 0o644)
	if took < 20*time.Second {
		p.Warn(fmt.Sprintf("the stream ended after %ds - Moonlight said:", int(took/time.Second)))
		// Its own warnings and errors, not the decoder probing that fills the rest.
		var keep []string
		for _, l := range strings.Split(out.String(), "\n") {
			if said.MatchString(l) && !skipped.MatchString(l) {
				keep = append(keep, l)
			}
		}
		if len(keep) > 4 {
			keep = keep[len(keep)-4:]
		}
		for _, l := range keep {
			p.Log("    " + l)
		}
		p.Log("  all of it: " + logFile)
	}
	if took < time.Minute {
		p.Echo(fmt.Sprintf("session ended after %ds", int(took/time.Second)))
	} else {
		p.Echo(fmt.Sprintf("session ended after %dm", int(took/time.Minute)))
	}
	return took
}
