package provision

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/render"
)

// Stage is one step of the AWS box's build, run by cg-build on the box. File is its
// module in lib/bootstrap.d. Needs are the stages that must be done first. Lock
// names a resource only one stage at a time may use (the package installer).
// Timeout is seconds; Retries are the extra attempts after a failure.
type Stage struct {
	Name        string   `json:"name"`
	File        string   `json:"file"`
	Needs       []string `json:"needs"`
	Lock        string   `json:"lock,omitempty"`
	Timeout     int      `json:"timeout"`
	Retries     int      `json:"retries"`
	RebootAfter bool     `json:"reboot_after,omitempty"`
}

// apt is the lock every stage that installs packages takes: the package installer
// allows one at a time, so they are ordered here rather than failing on it.
const apt = "apt"

// Plan is the AWS build, in priority order: when several stages can start, the
// earlier one does. The reasons for the order are in the module each stage runs.
//
//   - The package installs go one at a time: the driver first, then Steam (whose
//     32-bit NVIDIA library needs the driver), then the desktop and the rest.
//   - Steam's client comes from the archive on GitHub at the very start, in its own
//     stage, and the update then has little left to do. With no archive, the update
//     downloads the client from Valve, starting the moment Steam is installed and
//     running beside the installs: it needs only the network.
//   - The disks, the idle watchdog and the game restore need no package at all and
//     start at once; the restore then runs for as long as it takes.
//   - Nothing graphical is configured before the driver and the desktop it needs.
//   - The last stage waits for everything and reboots the machine into the desktop.
func Plan() []Stage {
	return []Stage{
		{Name: "base", File: "10-base.sh", Lock: apt, Timeout: 900, Retries: 2},
		{Name: "scratch", File: "12-scratch.sh", Timeout: 300, Retries: 1},
		{Name: "watchdog", File: "15-watchdog.sh", Timeout: 300, Retries: 1},
		{Name: "library", File: "22-library.sh", Needs: []string{"scratch"}, Timeout: 900, Retries: 2},
		{Name: "nvidia", File: "40-nvidia.sh", Needs: []string{"base"}, Lock: apt, Timeout: 2400, Retries: 2},
		{Name: "steam", File: "70-steam-pkg.sh", Needs: []string{"nvidia"}, Lock: apt, Timeout: 1200, Retries: 2},
		{Name: "steam-client", File: "71-steam-client.sh", Needs: []string{"base"}, Timeout: 1200},
		{Name: "steam-setup", File: "72-steam-prewarm.sh", Needs: []string{"steam"}, Timeout: 300, Retries: 1},
		{Name: "steam-update", File: "73-steam-update.sh", Needs: []string{"steam-setup", "steam-client"}, Timeout: 1500},
		{Name: "desktop", File: "30-desktop.sh", Needs: []string{"base"}, Lock: apt, Timeout: 1500, Retries: 2},
		{Name: "xorg", File: "50-xorg.sh", Needs: []string{"nvidia"}, Timeout: 300, Retries: 1},
		{Name: "autologin", File: "60-autologin.sh", Needs: []string{"desktop", "xorg"}, Timeout: 300, Retries: 1},
		{Name: "firefox", File: "80-firefox.sh", Needs: []string{"base"}, Lock: apt, Timeout: 600, Retries: 2},
		{Name: "audio", File: "92-audio.sh", Needs: []string{"base"}, Lock: apt, Timeout: 600, Retries: 2},
		{Name: "sunshine", File: "95-sunshine.sh", Needs: []string{"base"}, Lock: apt, Timeout: 900, Retries: 2},
		{Name: "finish", File: "99-finish.sh", Needs: []string{
			"scratch", "watchdog", "library", "steam-update", "autologin", "firefox", "audio", "sunshine"},
			Timeout: 600, Retries: 1, RebootAfter: true},
	}
}

// PlanJSON is the plan as the box reads it.
func PlanJSON() ([]byte, error) {
	plan := Plan()
	for i := range plan {
		if plan[i].Needs == nil {
			plan[i].Needs = []string{} // [] and not null: the box reads a list
		}
	}
	return json.MarshalIndent(map[string]any{"version": 1, "max_parallel": 4, "stages": plan}, "", " ")
}

// ValidatePlan checks the plan against the files it names, before a box is paid for.
func ValidatePlan(fsys fs.FS, plan []Stage, env []string) error {
	byName := map[string]Stage{}
	for _, s := range plan {
		if _, dup := byName[s.Name]; dup {
			return fmt.Errorf("two stages are called %s", s.Name)
		}
		byName[s.Name] = s
	}
	have := map[string]bool{}
	for _, k := range env {
		have[k] = true
	}
	for _, s := range plan {
		for _, n := range s.Needs {
			if _, ok := byName[n]; !ok {
				return fmt.Errorf("%s needs %s, which is not a stage", s.Name, n)
			}
		}
		b, err := fs.ReadFile(fsys, render.Dir+"/"+s.File)
		if err != nil {
			return fmt.Errorf("%s: %v", s.Name, err)
		}
		// Every value a stage asks for must be one the box is given: otherwise it
		// is a stage that fails late, on a machine that is being paid for.
		for _, p := range render.Placeholders(string(b)) {
			if !have[p] {
				return fmt.Errorf("%s asks for __%s__, which the box is not given", s.Name, p)
			}
		}
		// A stage that installs packages must hold the lock, or two of them meet on
		// the package installer's own and one fails.
		if installs(string(b)) && s.Lock != apt {
			return fmt.Errorf("%s installs packages but does not take the %q lock", s.Name, apt)
		}
	}
	pre, err := render.Prelude(fsys)
	if err != nil {
		return err
	}
	for _, p := range render.Placeholders(pre) {
		if !have[p] {
			return fmt.Errorf("the prelude asks for __%s__, which the box is not given", p)
		}
	}
	// Loops: a stage that can never start stalls the build with nothing said.
	done := map[string]bool{}
	for len(done) < len(plan) {
		moved := false
		for _, s := range plan {
			if done[s.Name] {
				continue
			}
			ok := true
			for _, n := range s.Needs {
				ok = ok && done[n]
			}
			if ok {
				done[s.Name], moved = true, true
			}
		}
		if !moved {
			var left []string
			for _, s := range plan {
				if !done[s.Name] {
					left = append(left, s.Name)
				}
			}
			return fmt.Errorf("the stages %s wait on each other", strings.Join(left, ", "))
		}
	}
	return nil
}

// installs is whether a module's text runs the package installer.
func installs(text string) bool {
	for _, m := range []string{"apt-get install", "apt-get update", "add-apt-repository", "\npkg ", "dpkg --add-architecture", "dpkg -i"} {
		if strings.Contains("\n"+text, m) {
			return true
		}
	}
	return false
}

// EnvNames are the names of the values the box is given, sorted.
func EnvNames(vars map[string]string) []string {
	var out []string
	for k := range vars {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// EnvLines is those values as the box's environment file holds them: NAME=value, a
// line each. A value with a line break in it would be two lines.
func EnvLines(vars map[string]string) (string, error) {
	var b strings.Builder
	for _, k := range EnvNames(vars) {
		if strings.ContainsAny(vars[k], "\r\n") {
			return "", fmt.Errorf("the value of %s has a line break in it", k)
		}
		b.WriteString(k + "=" + vars[k] + "\n")
	}
	return strings.TrimRight(b.String(), "\n"), nil
}

// headerRefresh is the header's own refresh of apt's lists, as it stands once the
// comments are stripped.
const headerRefresh = "  ubuntu|debian) apt-get update ;;\n"

// AssembleSupervised is the user-data of a supervised build: the header, the
// tailnet and the hand-over, and nothing else - the rest is in the bundle.
func AssembleSupervised(fsys fs.FS, vars map[string]string) (UserData, error) {
	lines, err := EnvLines(vars)
	if err != nil {
		return UserData{}, err
	}
	v := map[string]string{"CG_ENV_LINES": lines}
	for k, val := range vars {
		v[k] = val
	}
	s, err := render.Select(fsys, []string{
		render.Dir + "/00-header.sh", render.Dir + "/01-release.sh", render.Dir + "/20-tailscale.sh", "lib/supervised/start.sh"}, v)
	if err != nil {
		return UserData{}, err
	}
	// The header refreshes apt's lists, sixteen seconds before the box can join the
	// tailnet - and Tailscale's own installer refreshes them again as it adds its
	// repository. Here the second is enough: the base stage checks the lists are
	// fresh before it installs from them (10-base.sh).
	if !strings.Contains(s, headerRefresh) {
		return UserData{}, fmt.Errorf("the header no longer refreshes apt's lists as expected (%q): update AssembleSupervised", headerRefresh)
	}
	s = strings.Replace(s, headerRefresh, "  ubuntu|debian) : ;;\n", 1)
	var buf bytes.Buffer
	gz, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if _, err := gz.Write([]byte(s)); err != nil {
		return UserData{}, err
	}
	if err := gz.Close(); err != nil {
		return UserData{}, err
	}
	u := UserData{Raw: []byte(s), Gzipped: buf.Bytes(), Modules: 4}
	if len(u.Gzipped) >= UserDataLimit {
		return u, fmt.Errorf("user-data still too large even gzipped")
	}
	return u, nil
}

// SupervisedBundle is HostBundle plus what the supervisor runs: the plan, the
// prelude and each stage's module (comments stripped, placeholders left for the box
// to fill from its own environment file).
func SupervisedBundle(fsys fs.FS, ntfyURL string) ([]byte, error) {
	extra := map[string][]byte{}
	plan, err := PlanJSON()
	if err != nil {
		return nil, err
	}
	extra["plan.json"] = plan
	pre, err := render.Prelude(fsys)
	if err != nil {
		return nil, err
	}
	extra["prelude.sh"] = []byte(pre)
	for _, s := range Plan() {
		b, err := fs.ReadFile(fsys, render.Dir+"/"+s.File)
		if err != nil {
			return nil, err
		}
		extra["stages/"+s.File] = []byte(render.Strip(string(b)))
	}
	return hostBundle(fsys, ntfyURL, extra)
}

// tarEntries adds the extra files, in a fixed order so the bundle is the same each
// time it is made from the same files.
func tarEntries(tw *tar.Writer, extra map[string][]byte) error {
	var names []string
	for n := range extra {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		if err := tw.WriteHeader(&tar.Header{Name: n, Mode: 0o644, Size: int64(len(extra[n])), ModTime: time.Unix(0, 0)}); err != nil {
			return err
		}
		if _, err := tw.Write(extra[n]); err != nil {
			return err
		}
	}
	return nil
}
