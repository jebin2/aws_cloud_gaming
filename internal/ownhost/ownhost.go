// Package ownhost is a machine of yours, reached over ssh: cg's own key on it,
// what it is, and how it is named and told apart from the others.
//
// The prerequisite is a machine with its OS installed and an ssh server. The
// first connection may use its password, once: cg puts a key of its own on it
// and uses that from then on - the password is never saved. cg adds only what
// streaming needs and touches nothing else: not the desktop, not autologin, not
// the display, not the games. It is your machine, not a throwaway one.
package ownhost

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	cg "github.com/jebin2/aws_cloud_gaming"
	"github.com/jebin2/aws_cloud_gaming/internal/hosts"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
)

// factsScript asks the machine what it is: KEY=value lines, one read-only ssh.
// The Ubuntu release function the build itself uses goes ahead of it, so the two
// agree.
const factsScript = `
os=$(uname -s 2>/dev/null)
echo "os=${os:-unknown}"
[ -r /etc/os-release ] && . /etc/os-release
echo "id=${ID:-}"; echo "id_like=${ID_LIKE:-}"; echo "version_id=${VERSION_ID:-}"
echo "codename=${VERSION_CODENAME:-}"; echo "pretty=${PRETTY_NAME:-}"
# The Ubuntu release underneath, for a derivative too - the function the build
# itself uses (lib/bootstrap.d/01-release.sh), included below, so the two agree.
echo "ubuntu_version=$(ubuntu_release)"
echo "debian_codename=${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
echo "arch=$(uname -m)"; echo "user=$(id -un)"; echo "hostname=$(hostname 2>/dev/null)"
# The machine itself, whatever address or name reaches it: kept on this laptop
# only as a hash, so the same machine is never added twice.
echo "machine_id=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null)"
# By device class, not anywhere on the line: "3d" also matched the PCI address
# 3d:00.0 of an NVMe drive.
echo "gpu=$(lspci 2>/dev/null | grep -E " (VGA compatible|3D|Display) controller: " | sed -E "s/^[0-9a-f:.]+ [^:]+: //" | paste -sd";" -)"
echo "nvidia=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
echo "render=$(ls /dev/dri/renderD* 2>/dev/null | head -1)"
sudo -n true 2>/dev/null && echo "sudo=nopass" || echo "sudo=password"
echo "tailscale=$(command -v tailscale || true)"
echo "ts_ip=$(tailscale ip -4 2>/dev/null | head -1)"
echo "sunshine=$(command -v sunshine || true)"
steam=$(command -v steam || true)
[ -z "$steam" ] && flatpak list --app 2>/dev/null | grep -q com.valvesoftware.Steam && steam=flatpak
echo "steam=$steam"
s=""
for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" "\$3==u{print \$1}"); do
  t=$(loginctl show-session "$id" -p Type --value 2>/dev/null)
  case $t in x11|wayland) s=$t ;; esac
done
echo "session=$s"
# What the AWS build adds that a machine may already have: a desktop to start,
# somewhere for sound to go, a driver for an NVIDIA card.
dm=""; for d in lightdm gdm gdm3 sddm lxdm xdm; do command -v "$d" >/dev/null 2>&1 && dm=$d && break; done
echo "dm=$dm"
echo "sinks=$(XDG_RUNTIME_DIR=/run/user/$(id -u) pactl list short sinks 2>/dev/null | wc -l)"
echo "nvidia_card=$(lspci 2>/dev/null | grep -E " (VGA compatible|3D) controller: " | grep -ci nvidia)"
echo "flatpak=$(command -v flatpak || true)"
# The Sunshine login every device shares, base64 so it is one line whatever it
# holds. Read with the rest, and never printed: facts are read a field at a time.
echo "sunlogin=$(base64 -w0 ~/.config/cg/sunshine-login 2>/dev/null)"
`

// KeyPath is cg's own key for machines of yours: one per laptop, made the first
// time a machine is added, put on each machine by InstallKey. Its own, so that
// removing a machine takes off exactly the line cg added and nothing of yours.
func KeyPath(get func(string) (string, bool)) string {
	base, ok := get("XDG_CONFIG_HOME")
	if !ok || base == "" {
		home, _ := get("HOME")
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "cg", "ssh", "id_ed25519")
}

// Conn reaches machines with cg's key.
type Conn struct {
	R   local.Runner
	Key string
	// Hostname names the key's comment; "laptop" when it is not known.
	Hostname func() string
}

var pubShape = regexp.MustCompile(`^ssh-ed25519 [A-Za-z0-9+/=]`)

// keyOK: a key only counts when its public half reads as one.
func (c Conn) keyOK() bool {
	b, err := os.ReadFile(c.Key + ".pub")
	if err != nil {
		return false
	}
	if st, err := os.Stat(c.Key); err != nil || st.Size() == 0 {
		return false
	}
	return pubShape.Match(b)
}

// EnsureKey makes cg's key if it is not there. A .pub that is missing or empty
// is made again from the private key, and a pair that cannot be read is replaced
// - an empty line is not a key, and sending one lets nothing in.
func (c Conn) EnsureKey(ctx context.Context) error {
	if c.keyOK() {
		return nil
	}
	if st, err := os.Stat(c.Key); err == nil && st.Size() > 0 {
		if out, err := c.R.Run(ctx, local.Cmd{Name: "ssh-keygen", Args: []string{"-y", "-f", c.Key}}); err == nil && len(out) > 0 {
			if os.WriteFile(c.Key+".pub", out, 0o644) == nil && c.keyOK() {
				return nil
			}
		}
	}
	os.Remove(c.Key)
	os.Remove(c.Key + ".pub")
	if err := os.MkdirAll(filepath.Dir(c.Key), 0o700); err != nil {
		return err
	}
	_ = os.Chmod(filepath.Dir(c.Key), 0o700)
	host := "laptop"
	if c.Hostname != nil {
		host = c.Hostname()
	}
	if _, err := c.R.Run(ctx, local.Cmd{Name: "ssh-keygen", Args: []string{"-q", "-t", "ed25519", "-N", "", "-C", "cg@" + host, "-f", c.Key}}); err != nil || !c.keyOK() {
		return errors.New("could not make cg's ssh key (" + c.Key + ")")
	}
	return nil
}

func (c Conn) opts(connect string) []string {
	o := []string{"-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=" + connect, "-o", "BatchMode=yes"}
	if _, err := os.Stat(c.Key); err == nil {
		o = append([]string{"-i", c.Key}, o...)
	}
	return o
}

// Raw runs a command as you would: your keys, your ~/.ssh/config, plus cg's own
// key. A key, never a password: BatchMode turns a password prompt into a clear
// failure. Standard input only when given, for data piped on purpose: otherwise
// ssh reads cg's own, where the app's answers arrive, and would swallow the next.
func (c Conn) Raw(ctx context.Context, target, command string, stdin io.Reader) ([]byte, error) {
	args := append(c.opts("10"), target, command)
	return c.R.Run(ctx, local.Cmd{Name: "ssh", Args: args, Stdin: stdin})
}

// SSH runs a command under sh whatever the login shell is - cg's one way of
// reaching any machine - with your own ssh setup.
func (c Conn) SSH(ctx context.Context, target, command string, stdin io.Reader) ([]byte, error) {
	q := "'\\''"
	args := append(c.opts("8"), target, "sh -c '"+strings.ReplaceAll(command, "'", q)+"'")
	return c.R.Run(ctx, local.Cmd{Name: "ssh", Args: args, Stdin: stdin})
}

// InstallKey puts cg's key on the machine, logging in once with its password.
// The password reaches ssh through SSH_ASKPASS from this process's environment -
// never a file of its own, never a command line - and is gone when this returns.
// On the machine the key is appended to ~/.ssh/authorized_keys unless it is
// there already, and read back. It returns ssh's exit status: 3 is "the line is
// not there after all".
func (c Conn) InstallKey(ctx context.Context, target, password string) int {
	if !c.keyOK() {
		return 1
	}
	b, err := os.ReadFile(c.Key + ".pub")
	if err != nil {
		return 1
	}
	pub := strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0])
	f, err := os.CreateTemp("", "cg-askpass-")
	if err != nil {
		return 1
	}
	defer os.Remove(f.Name())
	f.WriteString("#!/bin/sh\nprintf \"%s\\n\" \"$CG_SSH_PASSWORD\"\n")
	f.Close()
	os.Chmod(f.Name(), 0o700)
	display := os.Getenv("DISPLAY")
	if display == "" {
		display = ":0"
	}
	remote := `sh -c 'umask 077; mkdir -p "$HOME/.ssh"; f="$HOME/.ssh/authorized_keys"; touch "$f"; [ -n "$1" ] || exit 3; grep -qxF "$1" "$f" || printf "%s\n" "$1" >> "$f"; grep -qxF "$1" "$f" || exit 3' _ '` + pub + `'`
	_, err = c.R.Run(ctx, local.Cmd{Name: "ssh", Args: []string{"-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new", "-o", "PubkeyAuthentication=no",
		"-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "NumberOfPasswordPrompts=1", target, remote},
		Env: []string{"CG_SSH_PASSWORD=" + password, "SSH_ASKPASS=" + f.Name(), "SSH_ASKPASS_REQUIRE=force", "DISPLAY=" + display}})
	return local.ExitCode(err)
}

// RemoveKey takes cg's line off the machine, and nothing else.
func (c Conn) RemoveKey(ctx context.Context, target string) error {
	b, err := os.ReadFile(c.Key + ".pub")
	if err != nil {
		return nil
	}
	pub := strings.TrimSpace(string(b))
	_, err = c.Raw(ctx, target, `sh -c 'f="$HOME/.ssh/authorized_keys"; [ -f "$f" ] || exit 0; grep -vxF "$1" "$f" > "$f.cg"; cat "$f.cg" > "$f"; rm -f "$f.cg"' _ '`+pub+`'`, nil)
	return err
}

// Facts is what the machine said about itself.
type Facts map[string]string

// Get is one fact, "" when the machine did not say.
func (f Facts) Get(k string) string { return f[k] }

// ReadFacts asks the machine what it is: nil when it cannot be asked. Windows
// answers uname with an error, so it is told apart by `ver`.
func (c Conn) ReadFacts(ctx context.Context, target string) Facts {
	rel, _ := cg.Files.ReadFile("lib/bootstrap.d/01-release.sh")
	var script strings.Builder
	for _, l := range strings.Split(string(rel), "\n") {
		if t := strings.TrimSpace(l); t != "" && !strings.HasPrefix(t, "#") {
			script.WriteString(l + "\n")
		}
	}
	script.WriteString(factsScript)
	out, err := c.Raw(ctx, target, "sh -s", strings.NewReader(script.String()))
	if err != nil {
		out = nil
	}
	if !strings.Contains(string(out), "os=Linux") {
		if v, err := c.Raw(ctx, target, "ver", nil); err == nil && strings.Contains(strings.ToLower(string(v)), "windows") {
			return Facts{"os": "Windows"}
		}
		if len(out) > 0 {
			return parseFacts(string(out))
		}
		return nil
	}
	return parseFacts(string(out))
}

func parseFacts(s string) Facts {
	f := Facts{}
	for _, l := range strings.Split(s, "\n") {
		if k, v, ok := strings.Cut(l, "="); ok && regexp.MustCompile(`^[a-z_]+$`).MatchString(k) {
			if _, seen := f[k]; !seen {
				f[k] = v
			}
		}
	}
	if len(f) == 0 {
		return nil
	}
	return f
}

// Family is the distribution family, which decides how Sunshine is installed -
// from os-release (ID, then ID_LIKE), so CachyOS or Manjaro count as Arch.
func Family(f Facts) string {
	for _, w := range strings.Fields(f["id"] + " " + f["id_like"]) {
		switch w {
		case "ubuntu", "debian", "arch", "fedora":
			return w
		}
	}
	return "unsupported"
}

var nameShape = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`)

// NameOK: a name the cloud's own pruning can never take for one of its boxes, and
// one Tailscale accepts as a hostname. "" when it will do, else why not.
func NameOK(name, awsHost string) string {
	if !nameShape.MatchString(name) {
		return "use lowercase letters, digits and dashes"
	}
	if regexp.MustCompile(`^` + regexp.QuoteMeta(awsHost) + `(-[0-9]+)?$`).MatchString(name) {
		return fmt.Sprintf("'%s' is the name cg gives its AWS boxes, and their clean-up would delete it - pick another", name)
	}
	return ""
}

// MachineKey is who the machine is, as a short hash of its own machine id: an IP,
// a tailnet name and a hostname can all reach one machine, and the raw id is not
// this laptop's to keep. "" when it has none.
func MachineKey(f Facts) string {
	m := f["machine_id"]
	if m == "" {
		return ""
	}
	h := sha256.Sum256([]byte(m))
	return hex.EncodeToString(h[:])[:16]
}

// AddedAs is the name a machine is already added under: the same machine by its
// key, or the same ssh address. "" when it is new.
func AddedAs(s hosts.Store, key, target string) string {
	for _, n := range s.Names() {
		r := s.Get(n)
		if (key != "" && r.Field("machine") == key) || r.Field("ssh") == target {
			return n
		}
	}
	return ""
}

var nonName = regexp.MustCompile(`[^a-z0-9-]+`)

// NameFrom is a name from the machine's own hostname: what Tailscale would call it.
func NameFrom(hostname string) string {
	n := strings.ToLower(hostname)
	n, _, _ = strings.Cut(n, ".")
	n = strings.Trim(nonName.ReplaceAllString(n, "-"), "-")
	if len(n) > 40 {
		n = n[:40]
	}
	return n
}

// Login is the Sunshine login a machine keeps for every device: "user", "pass".
// Each device used to keep its own copy, so a setup from one - which sets a new
// login - left every other device holding a password Sunshine no longer took.
func Login(f Facts) (user, pass string) {
	b, err := base64.StdEncoding.DecodeString(f["sunlogin"])
	if err != nil || len(b) == 0 {
		return "", ""
	}
	l := strings.Split(string(b), "\n")
	if len(l) < 2 {
		return "", ""
	}
	return l[0], l[1]
}

// ShareLogin keeps the login on the machine, in cg's folder there, readable by
// its user alone. Over stdin, so the password is in no command line there.
func (c Conn) ShareLogin(ctx context.Context, target, user, pass string) bool {
	if user == "" || pass == "" {
		return false
	}
	_, err := c.Raw(ctx, target, "umask 077; mkdir -p ~/.config/cg && cat > ~/.config/cg/sunshine-login.new && mv -f ~/.config/cg/sunshine-login.new ~/.config/cg/sunshine-login",
		strings.NewReader(user+"\n"+pass+"\n"))
	return err == nil
}
