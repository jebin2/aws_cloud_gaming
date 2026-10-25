package ownhost

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/hosts"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
)

func TestNames(t *testing.T) {
	for in, want := range map[string]string{"Desktop-PC.local": "desktop-pc", "My Box!": "my-box", "-x-": "x", strings.Repeat("a", 50): strings.Repeat("a", 40)} {
		if got := NameFrom(in); got != want {
			t.Errorf("%q: %q want %q", in, got, want)
		}
	}
	for name, bad := range map[string]bool{"pc": false, "my-pc-2": false, "PC": true, "-pc": true, "pc-": true, "gamevps": true, "gamevps-3": true, "gamevpsx": false, "": true} {
		if got := NameOK(name, "gamevps"); (got != "") != bad {
			t.Errorf("%q: %q", name, got)
		}
	}
	if !strings.Contains(NameOK("gamevps-2", "gamevps"), "clean-up would delete it") {
		t.Error("it says why")
	}
}

func TestFamilyFollowsOsReleaseAndItsParents(t *testing.T) {
	for facts, want := range map[string]string{"ubuntu": "ubuntu", "cachyos|arch": "arch", "pop|ubuntu debian": "ubuntu", "nobara|fedora": "fedora", "gentoo": "unsupported", "": "unsupported"} {
		id, like, _ := strings.Cut(facts, "|")
		if got := Family(Facts{"id": id, "id_like": like}); got != want {
			t.Errorf("%q: %s want %s", facts, got, want)
		}
	}
}

func TestAMachineIsKnownByItsIdNotItsAddress(t *testing.T) {
	s := hosts.Store{Path: filepath.Join(t.TempDir(), "hosts.json")}
	key := MachineKey(Facts{"machine_id": "abc123"})
	if len(key) != 16 || key == "abc123" || MachineKey(Facts{}) != "" {
		t.Errorf("a short hash, never the raw id: %q", key)
	}
	_ = s.Set("pc", "ssh", "me@pc.lan", "machine", key)
	if AddedAs(s, "", "me@pc.lan") != "pc" {
		t.Error("same address")
	}
	if AddedAs(s, key, "me@100.64.0.9") != "pc" {
		t.Error("same machine by another address")
	}
	if AddedAs(s, "", "me@other") != "" || AddedAs(s, MachineKey(Facts{"machine_id": "zzz"}), "me@other") != "" {
		t.Error("a new machine")
	}
}

func TestFactsAreParsedFirstValueWins(t *testing.T) {
	f := parseFacts("os=Linux\nid=ubuntu\nid=other\nuser=me\nnot a fact\npretty=Ubuntu 24.04 LTS\nsudo=nopass\n")
	if f["os"] != "Linux" || f["id"] != "ubuntu" || f["pretty"] != "Ubuntu 24.04 LTS" || f["sudo"] != "nopass" {
		t.Errorf("%v", f)
	}
	if parseFacts("garbage") != nil {
		t.Error("nothing parsed is nothing")
	}
	user, pass := Login(Facts{"sunlogin": base64.StdEncoding.EncodeToString([]byte("admin\nsecretpw\n"))})
	if user != "admin" || pass != "secretpw" {
		t.Errorf("%q %q", user, pass)
	}
	if u, p := Login(Facts{}); u != "" || p != "" {
		t.Error("no login")
	}
}

func conn(t *testing.T) (Conn, *fx.Runner) {
	r := &fx.Runner{Installed: map[string]bool{"ssh": true, "ssh-keygen": true}, Contains: map[string]string{}}
	return Conn{R: r, Key: filepath.Join(t.TempDir(), "cg", "ssh", "id_ed25519")}, r
}

func TestFactsAreReadWithOneReadOnlySSH(t *testing.T) {
	c, r := conn(t)
	r.Contains["sh -s"] = "os=Linux\nid=arch\nuser=me\nmachine_id=m1\n"
	f := c.ReadFacts(context.Background(), "me@pc")
	if f["id"] != "arch" || len(r.Ran) != 1 || !strings.HasPrefix(r.Ran[0], "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes me@pc sh -s") {
		t.Errorf("%v\n%v", f, r.Ran)
	}
	// What is sent is the build's own release function followed by the questions.
	script := r.Stdin[r.Ran[0]]
	if !strings.Contains(script, "ubuntu_release") || !strings.Contains(script, `echo "machine_id=`) || strings.Contains(script, "#!/usr/bin/env") {
		t.Errorf("script:\n%.300s", script)
	}
	// Windows answers uname with an error, and `ver` says what it is.
	c, r = conn(t)
	r.Contains["ver"] = "Microsoft Windows [Version 10.0.19045]"
	if f := c.ReadFacts(context.Background(), "me@win"); f["os"] != "Windows" {
		t.Errorf("%v", f)
	}
	// Nothing answered.
	c, r = conn(t)
	r.Failing = map[string]bool{"ssh": true}
	if c.ReadFacts(context.Background(), "me@down") != nil {
		t.Error("cannot be asked")
	}
}

func TestThePasswordIsInTheEnvironmentAndNowhereElse(t *testing.T) {
	c, r := conn(t)
	if err := os.MkdirAll(filepath.Dir(c.Key), 0o700); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(c.Key, []byte("private"), 0o600)
	_ = os.WriteFile(c.Key+".pub", []byte("ssh-ed25519 AAAAC3Nza cg@laptop\n"), 0o644)
	if rc := c.InstallKey(context.Background(), "me@pc", "hunter2-pw"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	line := r.Ran[0]
	if strings.Contains(line, "hunter2-pw") {
		t.Errorf("the password is on a command line: %s", line)
	}
	env := strings.Join(r.Envs[line], " ")
	if !strings.Contains(env, "CG_SSH_PASSWORD=hunter2-pw") || !strings.Contains(env, "SSH_ASKPASS_REQUIRE=force") {
		t.Errorf("env %s", env)
	}
	for _, want := range []string{"PubkeyAuthentication=no", "NumberOfPasswordPrompts=1", "ssh-ed25519 AAAAC3Nza cg@laptop", "grep -qxF"} {
		if !strings.Contains(line, want) {
			t.Errorf("lacks %q: %s", want, line)
		}
	}
	// The askpass helper is gone as soon as it returns.
	for _, e := range r.Envs[line] {
		if p, ok := strings.CutPrefix(e, "SSH_ASKPASS="); ok {
			if _, err := os.Stat(p); err == nil {
				t.Error("the helper was left behind")
			}
		}
	}
	// Exit 3 is "the line is not there after all".
	r.Exit = map[string]int{"ssh": 3}
	r.Failing = map[string]bool{"ssh": true}
	if rc := c.InstallKey(context.Background(), "me@pc", "x"); rc != 3 {
		t.Errorf("rc %d", rc)
	}
}

func TestEnsureKeyMakesOneAndRepairsTheHalf(t *testing.T) {
	if _, err := os.Stat("/usr/bin/ssh-keygen"); err != nil {
		t.Skip("no ssh-keygen")
	}
	c := Conn{R: local.Exec{}, Key: filepath.Join(t.TempDir(), "cg", "ssh", "id_ed25519"), Hostname: func() string { return "testbox" }}
	ctx := context.Background()
	if err := c.EnsureKey(ctx); err != nil || !c.keyOK() {
		t.Fatalf("%v", err)
	}
	pub, _ := os.ReadFile(c.Key + ".pub")
	if !strings.Contains(string(pub), "cg@testbox") {
		t.Errorf("%s", pub)
	}
	st, _ := os.Stat(c.Key)
	if st.Mode().Perm() != 0o600 {
		t.Errorf("private key mode %v", st.Mode())
	}
	// An empty .pub is made again from the private key: the same key.
	_ = os.WriteFile(c.Key+".pub", nil, 0o644)
	if err := c.EnsureKey(ctx); err != nil {
		t.Fatal(err)
	}
	again, _ := os.ReadFile(c.Key + ".pub")
	if !strings.HasPrefix(string(again), strings.Fields(string(pub))[0]+" "+strings.Fields(string(pub))[1]) {
		t.Errorf("a repaired pair is the same key:\n%s\n%s", pub, again)
	}
	// A pair that cannot be read is replaced.
	_ = os.WriteFile(c.Key, []byte("junk"), 0o600)
	_ = os.WriteFile(c.Key+".pub", nil, 0o644)
	if err := c.EnsureKey(ctx); err != nil || !c.keyOK() {
		t.Errorf("%v", err)
	}
}

func TestSSHQuotesTheCommandForSh(t *testing.T) {
	c, r := conn(t)
	_, _ = c.SSH(context.Background(), "me@pc", "echo 'hi'", nil)
	if !strings.Contains(r.Ran[0], `me@pc sh -c 'echo '\''hi'\'''`) {
		t.Errorf("%s", r.Ran[0])
	}
}
