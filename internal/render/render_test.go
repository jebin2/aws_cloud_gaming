package render

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"testing/fstest"
)

func TestLiteralReplacementAndStrippedComments(t *testing.T) {
	fsys := fstest.MapFS{
		Dir + "/20-b.sh": {Data: []byte("echo __X__ and __X__\n# a comment\n  # indented comment\n#\n#!/bin/sh inside a heredoc\n")},
		Dir + "/10-a.sh": {Data: []byte("url='__U__'\n")},
	}
	got, err := Bootstrap(fsys, map[string]string{"X": "a&b\\1", "U": "https://s3/x?a=1&b=2&c=3"})
	if err != nil {
		t.Fatal(err)
	}
	want := "url='https://s3/x?a=1&b=2&c=3'\necho a&b\\1 and a&b\\1\n#!/bin/sh inside a heredoc\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestAMissingPlaceholderWritesNothing(t *testing.T) {
	fsys := fstest.MapFS{Dir + "/10.sh": {Data: []byte("__B__ __A__ __A__\n")}}
	got, err := Bootstrap(fsys, map[string]string{})
	if err == nil || got != "" || err.Error() != "no value for placeholder(s): A, B" {
		t.Errorf("%q %v", got, err)
	}
	// An empty value is a value.
	if _, err := Bootstrap(fsys, map[string]string{"A": "", "B": ""}); err != nil {
		t.Error(err)
	}
	if _, err := Bootstrap(fstest.MapFS{}, nil); err == nil {
		t.Error("no modules")
	}
}

// The Bash assembly is the oracle: the same modules and values must give the same bytes.
func TestMatchesTheBashAssemblyByteForByte(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("no python3")
	}
	root := os.DirFS("../..")
	if _, err := os.Stat("../../lib/render.sh"); err != nil {
		t.Skip("the Bash tree is gone")
	}
	vars := map[string]string{"TS_AUTHKEY": "tskey-auth-xyz", "TS_HOST": "my-pc", "HOST_TGZ_URL": "", "S3_BUCKET": "", "CG_APPS": "", "CG_LOGIN": "",
		"CG_RESERVE_GB": "", "CG_TARGET": "host", "CG_USER": "me", "CG_FAMILY": "arch"}
	for _, aws := range []bool{false, true} {
		v := map[string]string{}
		for k, x := range vars {
			v[k] = x
		}
		if aws {
			v["HOST_TGZ_URL"] = "https://bucket.s3.amazonaws.com/h.tgz?X-Amz-Signature=ab&X-Amz-Expires=3600"
			v["S3_BUCKET"], v["CG_APPS"], v["CG_LOGIN"], v["CG_RESERVE_GB"], v["CG_TARGET"] = "cg-bucket", "1091500,2", "a-login", "20", "aws"
		}
		cmd := exec.Command("bash", "-c", "source lib/render.sh; render_bootstrap")
		cmd.Dir = "../.."
		env := os.Environ()
		for k, x := range v {
			env = append(env, k+"="+x)
		}
		cmd.Env = env
		want, err := cmd.Output()
		if err != nil {
			t.Fatalf("bash: %v", err)
		}
		got, err := Bootstrap(root, v)
		if err != nil {
			t.Fatal(err)
		}
		if got != string(want) {
			i := 0
			for i < len(got) && i < len(want) && got[i] == want[i] {
				i++
			}
			t.Fatalf("aws=%v: differs at byte %d: go %q / bash %q", aws, i, got[max(0, i-30):min(len(got), i+30)], strings.TrimSpace(string(want[max(0, i-30):min(len(want), i+30)])))
		}
	}
}
