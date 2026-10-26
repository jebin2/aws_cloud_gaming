package provision

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"testing/fstest"
)

func untar(t *testing.T, b []byte) map[string]string {
	gz, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gz)
	m := map[string]string{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return m
		}
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(tr)
		m[h.Name] = string(body)
		if h.Mode&0o111 != 0 {
			m[h.Name+":exec"] = "yes"
		}
	}
}

func TestHostBundleStripsCommentsKeepsShebangsAndAddsTheNotifyAddress(t *testing.T) {
	fsys := fstest.MapFS{
		"host/a.sh":         {Data: []byte("#!/bin/bash\n# why this\necho hi\n#\n  # indented\necho bye\n")},
		"host/cg-library":   {Data: []byte("#!/usr/bin/env python3\nx = 1\n")},
		"host/unit.service": {Data: []byte("[Unit]\n# note\nDescription=d\n")},
		"host/sub/ignored":  {Data: []byte("x")},
	}
	b, err := HostBundle(fsys, "https://ntfy.example/topic")
	if err != nil {
		t.Fatal(err)
	}
	m := untar(t, b)
	if m["a.sh"] != "#!/bin/bash\necho hi\necho bye\n" || m["unit.service"] != "[Unit]\nDescription=d\n" || m["notify.url"] != "https://ntfy.example/topic\n" {
		t.Errorf("%q", m)
	}
	if m["a.sh:exec"] != "yes" || m["cg-library:exec"] != "yes" || m["unit.service:exec"] == "yes" {
		t.Errorf("scripts run, units do not: %v", m)
	}
	if _, ok := m["sub/ignored"]; ok {
		t.Error("only the files in host/")
	}
	b, _ = HostBundle(fsys, "")
	if _, ok := untar(t, b)["notify.url"]; ok {
		t.Error("absent is off")
	}
}

// The Bash strip is the oracle for what the box is sent.
func TestHostBundleMatchesTheBashStripOnTheRealFiles(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	if _, err := os.Stat("../../host"); err != nil {
		t.Skip("no host/")
	}
	b, err := HostBundle(os.DirFS("../.."), "")
	if err != nil {
		t.Fatal(err)
	}
	m := untar(t, b)
	entries, _ := os.ReadDir("../../host")
	n := 0
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		want, err := exec.Command("bash", "-c", `grep -vE '^[[:space:]]*#([^!]|$)' "$1"`, "_", "../../host/"+e.Name()).Output()
		if err != nil && len(want) == 0 {
			want = nil
		}
		if m[e.Name()] != string(want) {
			t.Errorf("%s differs from the Bash strip (%d vs %d bytes)", e.Name(), len(m[e.Name()]), len(want))
		}
		n++
	}
	if n < 8 {
		t.Errorf("only %d files compared", n)
	}
}

func TestAssembleStaysUnderTheLimitForTheRealModules(t *testing.T) {
	vars := map[string]string{"TS_AUTHKEY": "tskey-auth-" + strings.Repeat("x", 40), "TS_HOST": "gamevps", "HOST_TGZ_URL": "https://b.s3.ap-south-1.amazonaws.com/boot/host.tgz?" + strings.Repeat("a=b&", 90),
		"S3_BUCKET": "cg-0123456789abcdef", "CG_APPS": "all", "CG_LOGIN": "use", "CG_RESERVE_GB": "20", "CG_TARGET": "aws", "CG_USER": "ubuntu", "CG_FAMILY": "ubuntu"}
	u, err := Assemble(os.DirFS("../.."), vars)
	if err != nil {
		t.Fatal(err)
	}
	if len(u.Gzipped) >= UserDataLimit || u.Modules < 15 {
		t.Errorf("%d bytes gzipped, %d modules", len(u.Gzipped), u.Modules)
	}
	gz, _ := gzip.NewReader(bytes.NewReader(u.Gzipped))
	back, _ := io.ReadAll(gz)
	if string(back) != string(u.Raw) || strings.Contains(string(u.Raw), "__TS_HOST__") {
		t.Error("cloud-init must get the same script back, with every placeholder filled")
	}
	// A script that cannot fit is refused rather than sent.
	big := fstest.MapFS{"lib/bootstrap.d/10.sh": {Data: []byte(randomText(40000))}}
	if _, err := Assemble(big, map[string]string{}); err == nil || !strings.Contains(err.Error(), "too large") {
		t.Errorf("%v", err)
	}
}

func randomText(n int) string {
	var b strings.Builder
	x := uint32(2463534242)
	for b.Len() < n {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		b.WriteString(string(rune('a' + x%26)))
		b.WriteString(string(rune('A' + (x>>8)%26)))
		if x%7 == 0 {
			b.WriteString("\n")
		}
	}
	return b.String()
}

func TestCrossRegionSaysWhatItCostsAndNotWhatItOnceDid(t *testing.T) {
	p, inr := 0.086, 95.0
	got := strings.Join(CrossRegion("ap-south-2", "ap-south-1", 163<<30, &p, &inr), "\n")
	for _, want := range []string{"!! the archive is in ap-south-2 but the box is in ap-south-1", "$0.086/GB - about INR 1332 for the 163 GB in it now, each pull.", "clear GAME_S3_BUCKET from .env"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q in:\n%s", want, got)
		}
	}
	// An empty archive is not a bill for games that are not there.
	got = strings.Join(CrossRegion("ap-south-2", "ap-south-1", 0, &p, &inr), "\n")
	if !strings.Contains(got, "nothing is archived there yet, so nothing is being billed to cross") || strings.Contains(got, "INR") {
		t.Errorf("%s", got)
	}
	got = strings.Join(CrossRegion("ap-south-2", "ap-south-1", -1, nil, nil), "\n")
	if !strings.Contains(got, "a per-GB price. The size could not be read - cg library list shows it.") {
		t.Errorf("%s", got)
	}
}
