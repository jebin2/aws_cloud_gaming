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
	return assemble(fsys, names, vars)
}

// Select is Bootstrap for chosen files only (paths in fsys, in the order given):
// what the AWS box gets as user-data, which joins the tailnet and hands the rest of
// the build to the supervisor.
func Select(fsys fs.FS, files []string, vars map[string]string) (string, error) {
	return assemble(fsys, files, vars)
}

func assemble(fsys fs.FS, names []string, vars map[string]string) (string, error) {
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

// Markers around the part of the header that is only functions and variables.
const (
	preludeBegin = "# cg:prelude-begin"
	preludeEnd   = "# cg:prelude-end"
)

// Glue is added to the prelude of a supervised stage: the few values one stage
// hands to a later one (a variable a module sets and another reads), kept in files
// because each stage is a process of its own.
const Glue = `
CG_SUPERVISED=1
cg_vars=${CG_BUILD_STATE:-/var/lib/cg-build}/vars
for _v in "$cg_vars"/*; do [ -f "$_v" ] && export "$(basename "$_v")=$(cat "$_v")"; done
cg_save_vars() { for _n in NVIDIA_ADDED DESKTOP_ADDED; do [ -n "${!_n:-}" ] && printf '%s' "${!_n}" > "$cg_vars/$_n"; done; return 0; }
trap cg_save_vars EXIT
# A package install that was cut off (a reboot, a kill) leaves the installer half-way
# through, and refuses everything until it is finished. A stage that installs
# packages starts by finishing it; there is nothing to finish the first time.
if [ "${CG_STAGE_LOCK:-}" = apt ]; then dpkg --configure -a >/dev/null 2>&1 || true; fi
`

// Prelude is what every stage of a supervised build starts with: the header's
// functions and variables (between its markers, so the one copy serves the single
// script a machine of yours still gets) and the release helper. Placeholders are
// left in; the box fills them from its own environment file.
func Prelude(fsys fs.FS) (string, error) {
	h, err := fs.ReadFile(fsys, Dir+"/00-header.sh")
	if err != nil {
		return "", err
	}
	text := string(h)
	i, j := strings.Index(text, preludeBegin), strings.Index(text, preludeEnd)
	if i < 0 || j < i {
		return "", fmt.Errorf("%s/00-header.sh has no %q ... %q region", Dir, preludeBegin, preludeEnd)
	}
	rel, err := fs.ReadFile(fsys, Dir+"/01-release.sh")
	if err != nil {
		return "", err
	}
	return Strip(text[i+len(preludeBegin):j]+"\n"+string(rel)) + Glue, nil
}

// Strip removes whole-line comments, as Bootstrap does.
func Strip(s string) string {
	var out strings.Builder
	for _, part := range strings.SplitAfter(s, "\n") {
		if part == "" || comment.MatchString(strings.TrimSuffix(part, "\n")) {
			continue
		}
		out.WriteString(part)
	}
	return out.String()
}

// Placeholders are the names left to fill in a text.
func Placeholders(s string) []string {
	seen := map[string]bool{}
	var out []string
	for _, m := range placeholder.FindAllStringSubmatch(s, -1) {
		if !seen[m[1]] {
			seen[m[1]] = true
			out = append(out, m[1])
		}
	}
	sort.Strings(out)
	return out
}
