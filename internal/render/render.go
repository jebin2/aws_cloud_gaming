// Package render assembles the build: lib/bootstrap.d's modules as one script,
// for any machine cg sets up. The AWS box gets it as user-data; a machine of
// yours gets it over ssh. One assembly, so both run the same steps - the modules
// themselves decide what each kind of machine needs.
//
// Placeholders are __NAME__ and every one must have a value, or nothing is
// written: a placeholder left in the script is a build that fails on the
// machine, late.
package render

import (
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strings"
)

// Dir is where the modules are.
const Dir = "lib/bootstrap.d"

var (
	comment     = regexp.MustCompile(`^[ \t\r\f\v]*#([^!]|$)`)
	placeholder = regexp.MustCompile(`__([A-Z0-9_]+)__`)
)

// Bootstrap is the script with every placeholder replaced by its value.
//
// Comments are ~47% of the module source and the single most valuable thing in
// this repo - every one records a failure that cost a build. The machine does not
// need them, so whole-line comments are stripped here and kept in git. Shebangs
// are exempt: `#!` lines matter inside the heredocs that write the on-host
// scripts. On AWS this is what keeps user-data inside its 16 KB.
//
// Replacement is literal. A presigned URL is full of `&`, and in a sed
// replacement an unescaped `&` means "the entire matched text" - so every
// separator in the URL once came out as the literal placeholder, curl got a 400,
// and the build died before tailscale existed.
func Bootstrap(fsys fs.FS, vars map[string]string) (string, error) {
	names, err := fs.Glob(fsys, Dir+"/*.sh")
	if err != nil || len(names) == 0 {
		return "", fmt.Errorf("no bootstrap modules found in %s/", Dir)
	}
	sort.Strings(names)
	var kept []string
	for _, n := range names {
		b, err := fs.ReadFile(fsys, n)
		if err != nil {
			return "", err
		}
		// `cat` keeps the last line as it is; a module that does not end in a
		// newline runs into the next one, exactly as it did.
		kept = append(kept, string(b))
	}
	var out strings.Builder
	for _, part := range strings.SplitAfter(strings.Join(kept, ""), "\n") {
		if part == "" || comment.MatchString(strings.TrimSuffix(part, "\n")) {
			continue
		}
		out.WriteString(part)
	}
	s := out.String()
	seen := map[string]bool{}
	var unknown []string
	for _, m := range placeholder.FindAllStringSubmatch(s, -1) {
		if seen[m[1]] {
			continue
		}
		seen[m[1]] = true
		if _, ok := vars[m[1]]; !ok {
			unknown = append(unknown, m[1])
		}
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return "", fmt.Errorf("no value for placeholder(s): %s", strings.Join(unknown, ", "))
	}
	toks := make([]string, 0, len(seen))
	for t := range seen {
		toks = append(toks, t)
	}
	sort.Strings(toks)
	for _, t := range toks {
		s = strings.ReplaceAll(s, "__"+t+"__", vars[t])
	}
	return s, nil
}
