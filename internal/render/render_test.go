package render

import (
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
