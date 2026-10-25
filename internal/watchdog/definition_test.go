package watchdog

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const pyZip = `
import sys, zipfile, hashlib, base64
src, out = sys.argv[1:3]
info = zipfile.ZipInfo("cloud_watchdog.py", (1980, 1, 1, 0, 0, 0))
info.external_attr = 0o644 << 16
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    z.writestr(info, open(src, "rb").read())
print(base64.b64encode(hashlib.sha256(open(out, "rb").read()).digest()).decode())
`

// The package must be byte-identical to the one the Bash cg builds with
// Python's zipfile: Lambda's CodeSha256 of a function it deployed is compared
// against this, and one differing byte reads as "code changed" forever.
func TestZipIsByteIdenticalToPythons(t *testing.T) {
	src, err := os.ReadFile("../../lambda/cloud_watchdog.py")
	if err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), "fn.zip")
	b, err := exec.Command("python3", "-I", "-c", pyZip, "../../lambda/cloud_watchdog.py", out).Output()
	if err != nil {
		t.Skip("no python3")
	}
	want, _ := os.ReadFile(out)
	got, sha := Zip(src)
	if !bytes.Equal(got, want) {
		t.Fatalf("zip differs: got %d bytes, python %d", len(got), len(want))
	}
	if sha != strings.TrimSpace(string(b)) {
		t.Errorf("sha %s want %s", sha, b)
	}
	// And it is a real zip.
	r, err := zip.NewReader(bytes.NewReader(got), int64(len(got)))
	if err != nil || len(r.File) != 1 || r.File[0].Name != "cloud_watchdog.py" {
		t.Fatalf("not a zip of one file: %v", err)
	}
	f, _ := r.File[0].Open()
	body, _ := io.ReadAll(f)
	if !bytes.Equal(body, src) {
		t.Error("the entry is not the source")
	}
}

func TestEnvAndFingerprint(t *testing.T) {
	s := Settings{Host: "gamevps", Account: "123456789012", Bucket: "cg-library-abc", IdleMinutes: 30, StuckMinutes: 60, ExpiryDays: 14,
		S3GBMonth: "0.025", INRPerUSD: "112.041", NtfyURL: "https://ntfy.sh/topic"}
	want := "Variables={CG_TS_HOST=gamevps,CG_IDLE_MINUTES=30,CG_BOOT_GRACE_MINUTES=20,CG_STUCK_MINUTES=60,CG_BUCKET=cg-library-abc,CG_ACCOUNT=123456789012,CG_ARCHIVE_EXPIRY_DAYS=14,CG_S3_USD_GB_MONTH=0.025,CG_INR_PER_USD=112.041,CG_NTFY_URL=https://ntfy.sh/topic}"
	if got := s.Env(); got != want {
		t.Errorf("env %s", got)
	}
	s.S3GBMonth, s.INRPerUSD, s.NtfyURL = "", "", ""
	if got := s.Env(); !strings.HasSuffix(got, "CG_ARCHIVE_EXPIRY_DAYS=14}") {
		t.Errorf("unset values are absent: %s", got)
	}
	a := s.Fingerprint("arn:aws:iam::123456789012:role/gamevps-cloud-watchdog")
	if len(a) != 12 {
		t.Errorf("fingerprint %q", a)
	}
	s.IdleMinutes = 31
	if s.Fingerprint("arn:aws:iam::123456789012:role/gamevps-cloud-watchdog") == a {
		t.Error("a changed setting must change the fingerprint")
	}
	// The same text the shell hashed: runtime|handler|role|timeout|memory|env, newline.
	out, err := exec.Command("bash", "-c", `printf '%s|%s|%s|300|128|%s\n' python3.13 cloud_watchdog.handler "$1" "$2" | sha256sum | cut -c1-12`,
		"_", "arn:aws:iam::1:role/r", s.Env()).Output()
	if err == nil && strings.TrimSpace(string(out)) != s.Fingerprint("arn:aws:iam::1:role/r") {
		t.Errorf("fingerprint differs from the shell's: %s", out)
	}
}

func TestPolicyOnlyGrowsWithExpiry(t *testing.T) {
	s := Settings{Host: "gamevps", Account: "1", ExpiryDays: 0}
	n := func(p map[string]any) int { return len(p["Statement"].([]any)) }
	off := n(s.Policy("ap-south-2"))
	s.ExpiryDays = 14
	if on := n(s.Policy("ap-south-2")); on <= off {
		t.Errorf("expiry on should add statements: %d vs %d", on, off)
	}
	// With expiry 0 the role cannot delete a single game.
	b, _ := jsonOf(s.withExpiry(0).Policy("ap-south-2"))
	if strings.Contains(b, "s3:DeleteObject") || strings.Contains(b, "s3:DeleteBucket") {
		t.Error("expiry 0 must not grant any delete")
	}
	if !strings.Contains(jsonMust(s.Policy("ap-south-2")), "cg-stopped-warned") {
		t.Error("the stopped-box tags must be allowed")
	}
}

func TestPolicyComparedAsData(t *testing.T) {
	s := Settings{Host: "gamevps", Account: "1", ExpiryDays: 14}
	p := s.Policy("ap-south-2")
	reformatted := []byte("{\n  \"Statement\": " + jsonMust(p["Statement"]) + ",\n \"Version\": \"2012-10-17\"}")
	if !PolicyMatches(reformatted, p) {
		t.Error("a reformatted but equal policy must match")
	}
	if PolicyMatches([]byte(`{"Version":"2012-10-17","Statement":[]}`), p) || PolicyMatches([]byte("nope"), p) {
		t.Error("a different or broken policy must not match")
	}
}

func (s Settings) withExpiry(days int) Settings { s.ExpiryDays = days; return s }

func jsonOf(v any) (string, error) { b, err := json.Marshal(v); return string(b), err }

func jsonMust(v any) string { s, _ := jsonOf(v); return s }
