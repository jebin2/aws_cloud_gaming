#!/usr/bin/env bash
# A sandbox that copies a lib file must copy what that file sources.
#
# This has now broken three times, and each time it looked like the new feature
# was broken rather than the sandbox being short a file: cg or common.sh dies
# with "No such file or directory" before the first assertion runs, so the suite
# reports a wall of unrelated failures. lib/session.sh and lib/rates.sh did it,
# then lib/machines.sh, then lib/env-file.sh.
#
# Rather than a list to keep in step, the dependencies are read from the scripts
# themselves and compared with what each sandbox copies.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0

out=$(python3 - <<'PY'
import pathlib, re

root = pathlib.Path(".")
# What each script sources, by lib/ basename. Both spellings appear: a bare
# "source lib/x.sh" from the repo root, and a "$(dirname ...)/x.sh" from inside
# lib/ itself.
SRC = re.compile(r'source\s+(?:"?\$\([^)]*\)/)?(?:lib/)?([a-z0-9-]+\.sh)')

def sources(path):
    try:
        text = path.read_text()
    except Exception:
        return set()
    found = set()
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        # Only an UNINDENTED source runs on every invocation. An indented one is
        # inside a function - cg sources lib/pair.sh that way, and only `cg pair`
        # ever loads it, so a sandbox that never calls it does not need the file.
        if line[:1].isspace():
            continue
        for m in SRC.finditer(line):
            name = m.group(1)
            if (root / "lib" / name).exists():
                found.add(name)
    return found

deps = {p.name: sources(p) for p in (root / "lib").glob("*.sh")}
deps["cg"] = sources(root / "cg")
for extra in ("setup", "game"):
    deps[extra] = sources(root / "lib" / extra)

def closure(name, seen=None):
    seen = seen if seen is not None else set()
    for d in deps.get(name, ()):
        if d not in seen:
            seen.add(d)
            closure(d, seen)
    return seen

problems = []
for suite in sorted((root / "tests").glob("*.sh")):
    # This suite copies common.sh alone on purpose, to prove the failure mode.
    if suite.name == "sandbox-deps.sh":
        continue
    text = suite.read_text()
    copied, whole_lib = set(), False
    for line in text.splitlines():
        if not re.match(r'\s*cp\b', line):
            continue
        # `cp -r .../lib` takes the directory and everything in it, so there is
        # nothing to be missing. Only a file-by-file copy can fall behind.
        if re.search(r'/lib"?\s', line + " ") and not re.search(r'lib/[a-z0-9-]+\.sh', line):
            whole_lib = True
        copied.update(re.findall(r'lib/([a-z0-9-]+\.sh)', line))
        if re.search(r'/cg"', line):
            copied.add("cg")
    if whole_lib or not copied:
        continue
    need = set()
    for c in copied:
        need |= closure(c)
    missing = sorted(d for d in need if d not in copied)
    if missing:
        problems.append("%s does not copy %s" % (suite.name, ", ".join(missing)))

print("\n".join(problems))
PY
)

if [[ -z ${out//[[:space:]]/} ]]; then
  echo "  ok   every sandbox copies what its scripts source"; pass=$((pass+1))
else
  echo "  FAIL a sandbox is missing a dependency:"
  printf '       %s\n' $out
  fail=$((fail+1))
fi

# And the thing that makes the check worth having: a missing file is silent
# until something runs, so prove the failure mode is what we think it is.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lib"
cp lib/common.sh "$T/lib/"            # deliberately WITHOUT env-file.sh
err=$( cd "$T" && bash -c 'source lib/common.sh' 2>&1 )
if [[ $err == *"No such file"* ]]; then
  echo "  ok   and a sandbox missing one dies before any assertion"; pass=$((pass+1))
else
  echo "  FAIL expected a missing-file error, got: '$err'"; fail=$((fail+1))
fi

# A check that cannot fail is decoration. These are the copies it relies on
# seeing, so if a suite stops naming its files the green above stops meaning
# anything - and this says so.
for s in session spot-restart destroy-all init-watchdog; do
  if grep -qE 'cp .*lib/env-file\.sh' "tests/$s.sh"; then
    echo "  ok   tests/$s.sh names the file it copies"; pass=$((pass+1))
  else
    echo "  FAIL tests/$s.sh no longer copies lib/env-file.sh by name"; fail=$((fail+1))
  fi
done

echo
echo "sandbox-deps: $pass passed, $fail failed"
(( fail == 0 ))
