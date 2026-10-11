#!/usr/bin/env bash
# `exec` on a file without its executable bit is exit 126 and NO output.
#
# cg dispatches by handing control over: `exec lib/game up`, `exec lib/setup`.
# If the target is not executable, bash exits 126 before the target prints a
# single line - so `cg open` died instantly with a bare "exited 126" and an
# empty log, which says nothing about why and looks like a crash in the engine.
#
# It happened because a file was rewritten with `mv new old`, which creates a
# fresh file at the umask default and silently drops the bit. Nothing in the
# suite noticed, because every other test runs these files with `bash <file>` -
# which works perfectly well on a non-executable file. Only `exec` cares.
#
# Both halves are checked, because the two failures are opposite and a fix for
# one hides the other: the bit on disk is what a developer's own run uses, and
# the mode in git's index is what everyone else receives.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

echo "1. every file the source execs is executable on disk"
# Derived from the source, not a list typed here, so a new exec target is
# covered the day it is added.
# Matches both the bare `exec` and the checking wrapper `cg_exec`, so routing a
# call site through the wrapper does not quietly empty this list.
targets=$(grep -rhoE '\b(cg_)?exec +\.?/?(lib|host)/[A-Za-z0-9._-]+' cg lib/* 2>/dev/null \
          | sed -E 's/^(cg_)?exec +//; s#^\./##' | sort -u)
check "the scan found targets" "$([[ -n $targets ]] && echo yes)" "yes"
for t in $targets; do
  check "$t is executable" "$([[ -x $t ]] && echo yes || echo no)" "yes"
done

echo "2. and cg itself, which lib/game execs back into"
check "cg is executable" "$([[ -x cg ]] && echo yes || echo no)" "yes"

echo "3. git ships the same bit, because that is what everyone else gets"
# A file can be +x in a working tree and 100644 in the index. Then it works for
# whoever fixed it and is broken for every clone and every package built from
# one - which is the harder version of this bug to see.
for t in $targets cg; do
  check "  $t is 100755 in the index" \
        "$(git ls-files -s -- "$t" 2>/dev/null | awk '{print $1}')" "100755"
done

echo "4. nothing tracked disagrees with its own index mode"
# The general form: catches the next file rewritten with `mv`, whether or not
# anything execs it today.
drift=$(git ls-files -s | while read -r mode _ _ path; do
          [[ -e $path ]] || continue
          if   [[ $mode == 100755 && ! -x $path ]]; then echo "lost:$path"
          elif [[ $mode == 100644 && -x $path ]];   then echo "gained:$path"; fi
        done)
check "no exec-bit drift anywhere" "${drift:-none}" "none"
[[ -n $drift ]] && printf '       %s\n' $drift

echo "5. the dispatch really does exec, so this test guards something real"
# If cg ever stops exec-ing and starts sourcing, 126 is no longer reachable and
# this file is dead weight - it should be deleted, not quietly kept passing.
check "cg execs lib/game"  "$(grep -c 'exec lib/game' cg)"  "2"
check "cg execs lib/setup" "$([[ $(grep -c 'exec lib/setup' cg) -ge 1 ]] && echo yes)" "yes"

echo "6. and if the bit is lost anyway, it is a sentence, not a bare 126"
# tests/exec-bits.sh keeps THIS repo honest. cg_exec keeps a PACKAGE honest -
# a build step that does not preserve modes lands on a user, not on a developer,
# and 126 with an empty log tells them nothing.
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
src=$(cat cg)
contains "the wrapper exists"        "$src" "cg_exec() {"
contains "  and tests before exec"   "$src" 'if [[ ! -x $1 ]]; then'
check    "every repo exec goes through it" "$(grep -cE '^\s*(exec) lib/(setup|game)' cg)" "0"
check    "  and there are several"   "$([[ $(grep -c 'cg_exec lib/' cg) -ge 7 ]] && echo yes)" "yes"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
WRAPPER_SRC=$(sed -n '/^cg_exec() {/,/^}/p' cg)
run_wrapper() { # run_wrapper <mode: none|noexec|ok>
  mkdir -p "$T/lib"
  case $1 in
    none)   rm -f "$T/lib/game" ;;
    noexec) printf '#!/usr/bin/env bash
echo RAN
' > "$T/lib/game"; chmod -x "$T/lib/game" ;;
    ok)     printf '#!/usr/bin/env bash
echo RAN
' > "$T/lib/game"; chmod +x "$T/lib/game" ;;
  esac
  # Captured BEFORE the cd: the substitution runs in the subshell, where a
  # relative path to cg no longer resolves.
  ( cd "$T" && bash -c "
      die() { echo \"\$*\" >&2; exit 1; }
      $WRAPPER_SRC
      cg_exec lib/game" 2>&1 )
}
out=$(run_wrapper noexec)
contains "a non-executable target is named"  "$out" "lib/game is not executable"
contains "  with its mode"                   "$out" "mode 644"
contains "  and the one-line remedy"         "$out" "chmod +x lib/game"
out=$(run_wrapper none)
contains "a missing target says so instead"  "$out" "lib/game is missing"
lacks2() { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
           else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
lacks2 "  and does not blame the mode"       "$out" "not executable"
out=$(run_wrapper ok)
contains "a good target still runs"          "$out" "RAN"

echo ""
echo "exec-bits: $pass passed, $fail failed"
(( fail == 0 ))
