package stream

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

func none(string) string { return "" }

func TestFlagsAreOnlyWhatIsSet(t *testing.T) {
	if len(Flags(none)) != 0 {
		t.Error("an unset variable passes no flag, so Moonlight's own setting stays")
	}
	env := map[string]string{"GAME_RES": "1920x1080", "GAME_FPS": "60", "GAME_BITRATE_KBPS": "20000", "GAME_VIDEO_CODEC": "HEVC", "GAME_PERF_OVERLAY": "1"}
	got := strings.Join(Flags(func(k string) string { return env[k] }), " ")
	if got != "--resolution 1920x1080 --fps 60 --bitrate 20000 --video-codec HEVC --performance-overlay" {
		t.Error(got)
	}
	env["GAME_PERF_OVERLAY"] = "0"
	if strings.Contains(strings.Join(Flags(func(k string) string { return env[k] }), " "), "overlay") {
		t.Error("only 1 turns it on")
	}
}

// laptop builds a fake root with an NVIDIA driver, an Intel render node and the Mesa pieces.
func laptop(t *testing.T, intel bool, files ...string) string {
	root := t.TempDir()
	for _, f := range files {
		p := filepath.Join(root, f)
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		_ = os.WriteFile(p, nil, 0o644)
	}
	drv := "i915"
	if !intel {
		drv = "nvidia"
	}
	target := filepath.Join(root, "sys/bus/pci/drivers", drv)
	_ = os.MkdirAll(target, 0o755)
	dev := filepath.Join(root, "sys/class/drm/renderD128/device")
	_ = os.MkdirAll(dev, 0o755)
	_ = os.Symlink(target, filepath.Join(dev, "driver"))
	return root
}

func TestAHybridLaptopStreamsOnTheIntelGPU(t *testing.T) {
	root := laptop(t, true, "dev/nvidiactl", "usr/share/glvnd/egl_vendor.d/50_mesa.json", "usr/share/vulkan/icd.d/intel_icd.x86_64.json", "usr/lib/dri/iHD_drv_video.so")
	env, label := GPU(root, none, "x86_64")
	got := strings.Join(env, "\n")
	for _, want := range []string{"__GLX_VENDOR_LIBRARY_NAME=mesa", "__EGL_VENDOR_LIBRARY_FILENAMES=" + root + "/usr/share/glvnd/egl_vendor.d/50_mesa.json",
		"VK_DRIVER_FILES=" + root + "/usr/share/vulkan/icd.d/intel_icd.x86_64.json", "VK_ICD_FILENAMES=", "LIBVA_DRIVER_NAME=iHD"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	if label != "the Intel GPU (NVIDIA left alone)" {
		t.Error(label)
	}
}

func TestNothingIsChosenWhereItWouldNotHelpOrIsAlreadyChosen(t *testing.T) {
	for name, c := range map[string]struct {
		root string
		get  func(string) string
	}{
		"no NVIDIA driver":   {laptop(t, true), none},
		"only an NVIDIA GPU": {laptop(t, false, "dev/nvidiactl"), none},
	} {
		if env, label := GPU(c.root, c.get, "x86_64"); env != nil || label != "" {
			t.Errorf("%s: %v %q", name, env, label)
		}
	}
	root := laptop(t, true, "dev/nvidiactl")
	// A choice made already - by you, or by the app - is left alone, and said when it is this one.
	chosen := func(k string) string {
		if k == "__GLX_VENDOR_LIBRARY_NAME" {
			return "mesa"
		}
		return ""
	}
	if env, label := GPU(root, chosen, "x86_64"); env != nil || label != "the Intel GPU (NVIDIA left alone)" {
		t.Errorf("%v %q", env, label)
	}
	other := func(k string) string {
		if k == "LIBVA_DRIVER_NAME" {
			return "radeonsi"
		}
		return ""
	}
	if env, label := GPU(root, other, "x86_64"); env != nil || label != "" {
		t.Errorf("%v %q", env, label)
	}
	// Without a Vulkan or VA file for Intel, only what is installed is set.
	env, _ := GPU(root, none, "x86_64")
	if strings.Join(env, " ") != "__GLX_VENDOR_LIBRARY_NAME=mesa" {
		t.Errorf("%v", env)
	}
}

func TestPlayTimesTheSessionAndExplainsAShortOne(t *testing.T) {
	clock := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
	r := &fx.Runner{Installed: map[string]bool{"moonlight": true}, Answers: map[string]string{"moonlight stream --bitrate 20000 100.64.0.9 Desktop": "" +
		"Qt Warning: QML noise\nSDL Error: no display\ntrying VDPAU decoder\nConnection failed to host\nQt Critical: bad thing\nprobe libplacebo\n"}}
	var echo, logs, warns []string
	p := Player{R: r, Get: func(k string) string {
		if k == "GAME_BITRATE_KBPS" {
			return "20000"
		}
		return ""
	}, CacheDir: t.TempDir(), Root: t.TempDir(), Now: func() time.Time { clock = clock.Add(7 * time.Second); return clock },
		Echo: func(s string) { echo = append(echo, s) }, Log: func(s string) { logs = append(logs, s) }, Warn: func(s string) { warns = append(warns, s) }}
	took := p.Play(context.Background(), "100.64.0.9", "")
	if took != 7*time.Second || echo[0] != "    stream: --bitrate 20000" || echo[len(echo)-1] != "session ended after 7s" {
		t.Errorf("%v %v", took, echo)
	}
	if warns[0] != "the stream ended after 7s - Moonlight said:" {
		t.Error(warns)
	}
	// Its warnings, not the decoder probing: three lines kept, QML noise dropped.
	if strings.Join(logs[:3], "|") != "    SDL Error: no display|    Connection failed to host|    Qt Critical: bad thing" || !strings.HasPrefix(logs[3], "  all of it: ") {
		t.Errorf("%q", logs)
	}
	if b, _ := os.ReadFile(filepath.Join(p.CacheDir, LogName)); !strings.Contains(string(b), "libplacebo") {
		t.Error("the whole log is kept in its file")
	}
	// A long one is just timed.
	n := 0
	p.Now = func() time.Time {
		n++
		return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC).Add(time.Duration(n-1) * 125 * time.Minute)
	}
	echo, warns = nil, nil
	p.Play(context.Background(), "100.64.0.9", "Steam")
	if echo[len(echo)-1] != "session ended after 125m" || len(warns) != 0 {
		t.Errorf("%v %v", echo, warns)
	}
}
