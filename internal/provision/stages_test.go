package provision

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/render"
)

func repoFS() fs.FS { return os.DirFS("../..") }

// The values a real launch gives the box, as awsVars names them.
func realEnv() map[string]string {
	return awsVars(Params{Host: "gamevps", Bucket: "cg-lib", AuthKey: "tskey-auth-x", DataGB: 190, ExtraApps: "7,9"},
		"https://b.s3.ap-south-1.amazonaws.com/boot/host.tgz?a=b&c=d", "all", "use", "20")
}

func TestThePlanIsSound(t *testing.T) {
	if err := ValidatePlan(repoFS(), Plan(), EnvNames(realEnv())); err != nil {
		t.Fatal(err)
	}
}

func TestEveryStageThatInstallsPackagesTakesTheLock(t *testing.T) {
	// The check itself is in ValidatePlan; here it is shown to bite.
	bad := []Stage{{Name: "x", File: "30-desktop.sh"}}
	if err := ValidatePlan(repoFS(), bad, EnvNames(realEnv())); err == nil || !strings.Contains(err.Error(), "does not take the") {
		t.Errorf("a stage that installs packages without the lock must be refused: %v", err)
	}
}

func TestAPlanThatLoopsOrNeedsWhatIsNotThereIsRefused(t *testing.T) {
	env := EnvNames(realEnv())
	loop := []Stage{{Name: "a", File: "12-scratch.sh", Needs: []string{"b"}}, {Name: "b", File: "15-watchdog.sh", Needs: []string{"a"}}}
	if err := ValidatePlan(repoFS(), loop, env); err == nil || !strings.Contains(err.Error(), "wait on each other") {
		t.Errorf("%v", err)
	}
	if err := ValidatePlan(repoFS(), []Stage{{Name: "a", File: "12-scratch.sh", Needs: []string{"nope"}}}, env); err == nil || !strings.Contains(err.Error(), "not a stage") {
		t.Errorf("%v", err)
	}
	if err := ValidatePlan(repoFS(), []Stage{{Name: "a", File: "12-scratch.sh"}, {Name: "a", File: "15-watchdog.sh"}}, env); err == nil {
		t.Error("two stages with one name")
	}
	if err := ValidatePlan(repoFS(), []Stage{{Name: "a", File: "12-scratch.sh"}}, []string{"CG_USER"}); err == nil || !strings.Contains(err.Error(), "is not given") {
		t.Errorf("a stage asking for a value the box is not given: %v", err)
	}
}

func TestEveryModuleIsInTheUserDataOrAStage(t *testing.T) {
	// A module added to lib/bootstrap.d and left out of the plan would run on a
	// machine of yours and never on the AWS box. The ones the user-data holds are
	// said here.
	inUserData := map[string]bool{"00-header.sh": true, "01-release.sh": true, "20-tailscale.sh": true}
	staged := map[string]bool{}
	for _, s := range Plan() {
		staged[s.File] = true
	}
	mods, _ := fs.Glob(repoFS(), "lib/bootstrap.d/*.sh")
	for _, m := range mods {
		n := m[strings.LastIndex(m, "/")+1:]
		if !inUserData[n] && !staged[n] {
			t.Errorf("%s is neither in the user-data nor a stage", n)
		}
	}
}

func TestTheOrderThatMatters(t *testing.T) {
	byName := map[string]Stage{}
	for _, s := range Plan() {
		byName[s.Name] = s
	}
	has := func(stage, need string) bool {
		for _, n := range byName[stage].Needs {
			if n == need {
				return true
			}
		}
		return false
	}
	for _, c := range [][2]string{
		{"steam", "nvidia"},      // 70 installs the driver's 32-bit NVIDIA library
		{"autologin", "desktop"}, // 60 reads what 30 set
		{"autologin", "xorg"},
		{"xorg", "nvidia"},
		{"steam-update", "steam-setup"},
		{"library", "scratch"},
	} {
		if !has(c[0], c[1]) {
			t.Errorf("%s must wait for %s", c[0], c[1])
		}
	}
	last := byName["finish"]
	if !last.RebootAfter {
		t.Error("the last stage reboots")
	}
	for _, s := range Plan() {
		if s.Name != "finish" && s.RebootAfter {
			t.Errorf("%s reboots, and others still have to run", s.Name)
		}
		if s.Name != "finish" && !has("finish", s.Name) {
			// Reached through another stage is fine; directly or not, finish must
			// come after it. Walk the needs.
			if !reaches(byName, "finish", s.Name) {
				t.Errorf("the last stage does not wait for %s", s.Name)
			}
		}
	}
}

func reaches(by map[string]Stage, from, to string) bool {
	for _, n := range by[from].Needs {
		if n == to || reaches(by, n, to) {
			return true
		}
	}
	return false
}

func TestTheUserDataIsSmallAndHandsOver(t *testing.T) {
	u, err := AssembleSupervised(repoFS(), realEnv())
	if err != nil {
		t.Fatal(err)
	}
	s := string(u.Raw)
	for _, want := range []string{"tailscale up", "cg-build.service", "/etc/cg-build/env", "TS_AUTHKEY=tskey-auth-x", "CG_EXTRA_APPS=7,9", "S3_BUCKET=cg-lib"} {
		if !strings.Contains(s, want) {
			t.Errorf("the user-data lacks %q", want)
		}
	}
	for _, not := range []string{"nvidia-driver", "xfce4", "sunshine", "steam_latest"} {
		if strings.Contains(s, not) {
			t.Errorf("%q is a stage's work, not the user-data's", not)
		}
	}
	if strings.Contains(s, "__") && strings.Contains(s, "__CG_") {
		t.Error("a placeholder is left")
	}
	t.Logf("user-data: %d bytes, %d gzipped of %d", len(u.Raw), len(u.Gzipped), UserDataLimit)
	if len(u.Gzipped) > UserDataLimit/2 {
		t.Errorf("the user-data was meant to leave room: %d of %d", len(u.Gzipped), UserDataLimit)
	}
}

func TestTheBundleCarriesThePlanThePreludeAndEveryStage(t *testing.T) {
	b, err := SupervisedBundle(repoFS(), "")
	if err != nil {
		t.Fatal(err)
	}
	gz, _ := gzip.NewReader(bytes.NewReader(b))
	tr := tar.NewReader(gz)
	files := map[string]string{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(tr)
		files[h.Name] = string(body)
	}
	for _, want := range []string{"plan.json", "prelude.sh", "cg-build", "cg-build.service", "cg-library", "install-library.sh"} {
		if _, ok := files[want]; !ok {
			t.Errorf("the bundle lacks %s", want)
		}
	}
	for _, s := range Plan() {
		body, ok := files["stages/"+s.File]
		if !ok {
			t.Errorf("the bundle lacks the stage %s", s.File)
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(body), "#") && !strings.HasPrefix(body, "#!") {
			t.Errorf("%s still has its comments", s.File)
		}
	}
	// The values are the box's own, never in the bundle: it sits in S3.
	for name, body := range files {
		if strings.Contains(body, "tskey-auth") {
			t.Errorf("%s holds a tailnet key", name)
		}
	}
	if !strings.Contains(files["prelude.sh"], "progress()") || !strings.Contains(files["prelude.sh"], "ubuntu_release") ||
		!strings.Contains(files["prelude.sh"], "cg_save_vars") {
		t.Error("the prelude lacks the header's functions, the release helper or the hand-over of shared values")
	}
	if strings.Contains(files["prelude.sh"], "tee /var/log") || strings.Contains(files["prelude.sh"], "apt-get update") {
		t.Error("the prelude holds what must happen once, not in every stage")
	}
	if !strings.Contains(files["plan.json"], `"reboot_after": true`) {
		t.Error("the plan does not say where to reboot")
	}
}

// A value one module sets and a later one reads (DESKTOP_ADDED: 30 sets, 60 reads)
// used to live in the one script's memory; each stage is its own process now.
func TestAValueOneStageSetsIsThereForTheNext(t *testing.T) {
	pre, err := render.Prelude(repoFS())
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range realEnv() {
		pre = strings.ReplaceAll(pre, "__"+k+"__", v)
	}
	dir := t.TempDir()
	run := func(body string) string {
		cmd := exec.Command("bash", "-c", pre+"\n"+body)
		cmd.Env = append(os.Environ(), "CG_BUILD_STATE="+dir)
		_ = os.MkdirAll(dir+"/vars", 0o755)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%v\n%s", err, out)
		}
		return string(out)
	}
	run(`DESKTOP_ADDED=1; NVIDIA_ADDED=`)
	got := run(`set +x; echo "desktop=${DESKTOP_ADDED:-none} nvidia=${NVIDIA_ADDED:-none}"`)
	if !strings.Contains(got, "desktop=1 nvidia=none") {
		t.Errorf("the next stage sees what the last set, and an empty value is not carried: %q", got)
	}
}

// The real plan, the real prelude and the real supervisor, with each stage's work
// swapped for a few lines that only say when it ran: whatever the stages do, the
// order and the overlap the plan gives is what it gives, and the build ends done.
func TestTheRealPlanRunsToTheEndUnderTheRealSupervisor(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("no python3")
	}
	b, err := SupervisedBundle(repoFS(), "")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	host := root + "/opt/cloud-gaming-host"
	gz, _ := gzip.NewReader(bytes.NewReader(b))
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(tr)
		if err := os.MkdirAll(filepath.Dir(host+"/"+h.Name), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(host+"/"+h.Name, body, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	order := root + "/order"
	for _, s := range Plan() {
		stub := fmt.Sprintf("progress 'stub %s'\nnow() { date +%%s%%N; }\necho \"start %s $(now)\" >> %s\nsleep 0.15\necho \"end %s $(now)\" >> %s\n", s.Name, s.Name, order, s.Name, order)
		if err := os.WriteFile(host+"/stages/"+s.File, []byte(stub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(root+"/etc/cg-build", 0o755); err != nil {
		t.Fatal(err)
	}
	// The user the prelude looks up: "ubuntu" is on the box, not necessarily here.
	env := realEnv()
	if u, err := user.Current(); err == nil {
		env["CG_USER"] = u.Username
	}
	lines, _ := EnvLines(env)
	if err := os.WriteFile(root+"/etc/cg-build/env", []byte(lines+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// The one the bundle carries (comments stripped), not the file in the repo.
	cmd := exec.Command("python3", host+"/cg-build", "run")
	cmd.Env = append(os.Environ(), "CG_BUILD_ROOT="+root, "CG_BUILD_BACKOFF=0", "CG_BUILD_TICK=0.02", "CG_BUILD_HOME="+root, "CG_BUILD_NO_WAIT=1",
		"CG_BUILD_NO_SYSTEMD=1", "CG_BUILD_BOOT_ID=b1", "CG_BUILD_REBOOT=echo reboot >> "+root+"/reboot")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	rc, _ := os.ReadFile(root + "/var/lib/cloud-gaming-bootstrap.rc")
	if strings.TrimSpace(string(rc)) != "0" {
		ev, _ := os.ReadFile(root + "/var/lib/cg-build/events.jsonl")
		lg, _ := os.ReadFile(root + "/var/log/cg-build/base.log")
		t.Fatalf("the build did not end done: rc %q\n%s\n--- base.log\n%s", rc, ev, lg)
	}
	if r, _ := os.ReadFile(root + "/reboot"); strings.Count(string(r), "reboot") != 1 {
		t.Errorf("one reboot: %q", r)
	}
	type span struct{ start, end int64 }
	spans := map[string]span{}
	ord, _ := os.ReadFile(order)
	for _, l := range strings.Split(strings.TrimSpace(string(ord)), "\n") {
		var kind, name string
		var ts int64
		if _, err := fmt.Sscanf(l, "%s %s %d", &kind, &name, &ts); err != nil {
			t.Fatalf("%q", l)
		}
		sp := spans[name]
		if kind == "start" {
			sp.start = ts
		} else {
			sp.end = ts
		}
		spans[name] = sp
	}
	if len(spans) != len(Plan()) {
		t.Fatalf("%d stages ran of %d", len(spans), len(Plan()))
	}
	for _, s := range Plan() {
		for _, n := range s.Needs {
			if spans[s.Name].start < spans[n].end {
				t.Errorf("%s started before %s was done", s.Name, n)
			}
		}
	}
	// The package installs never overlap.
	var aptStages []Stage
	for _, s := range Plan() {
		if s.Lock == apt {
			aptStages = append(aptStages, s)
		}
	}
	for i, a := range aptStages {
		for _, b := range aptStages[i+1:] {
			if spans[a.Name].start < spans[b.Name].end && spans[b.Name].start < spans[a.Name].end {
				t.Errorf("%s and %s installed packages at the same time", a.Name, b.Name)
			}
		}
	}
	// And what the plan is for: Steam's update runs while packages go in.
	su := spans["steam-update"]
	overlap := 0
	for _, s := range aptStages {
		if spans[s.Name].start < su.end && su.start < spans[s.Name].end {
			overlap++
		}
	}
	if overlap == 0 {
		t.Error("Steam's update does not overlap any install")
	}
	if spans["finish"].start < su.end {
		t.Error("the reboot does not wait for it")
	}
}
