#!/usr/bin/env bash
# The driver check asked for a package name, and Ubuntu's archive moved on.
#
# 40-nvidia.sh installs the NEWEST nvidia-driver-NNN-open the archive offers -
# deliberately, because Sunshine's ffmpeg needs NVENC API 13.1 and the distro's
# "recommended" driver was 595, which silently falls back to libx264 and gives a
# black screen. Then it verified `dpkg -l nvidia-driver-610-open`.
#
# The day the archive's newest became 615, the install did exactly what it was
# told and the verify demanded a package that was deliberately not installed.
# `verify` returns 1, user-data runs under `set -e`, so the build aborted right
# there - after the driver, before xorg, steam and sunshine. The box joined the
# tailnet and then stopped, and the only visible line was
# "FAILED: nvidia driver packages installed" on a driver that was fine.
#
# The fix is to check the thing that is actually required: a version floor.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export HOME="$T"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

MOD=lib/bootstrap.d/40-nvidia.sh

# A dpkg-query that prints what the real one prints for -W -f '${Package} ${db:Status-Status}'.
# PKGS is a space-separated list of "name:status" pairs.
cat > "$T/bin/dpkg-query" <<'FAKE'
#!/usr/bin/env bash
[[ -z ${PKGS:-} ]] && { echo "dpkg-query: no packages found matching nvidia-driver-*" >&2; exit 1; }
for p in $PKGS; do printf '%s %s\n' "${p%%:*}" "${p##*:}"; done
FAKE
chmod +x "$T/bin/dpkg-query"

# Just the two functions and the floor, lifted from the module so the test runs
# the shipped code rather than a copy of it.
ver() { env PATH="$T/bin:$PATH" PKGS="${1:-}" bash -c '
  set -uo pipefail
  '"$(sed -n '/^NVIDIA_MIN=/p;/^nvidia_driver_version()/,/^}/p;/^nvidia_driver_ok()/,/^}/p' "$MOD")"'
  v=$(nvidia_driver_version) || v=
  nvidia_driver_ok && echo "ok=yes v=$v" || echo "ok=no v=$v"' 2>&1
}

echo "1. the version installed is found whatever the package is called"
check "615, the one that broke it"  "$(ver 'nvidia-driver-615-open:installed')" "ok=yes v=615"
check "610, the old pinned name"    "$(ver 'nvidia-driver-610-open:installed')" "ok=yes v=610"
check "a future 700"                "$(ver 'nvidia-driver-700-open:installed')" "ok=yes v=700"
# The non-open build satisfies the floor just as well - the floor is about NVENC.
check "the proprietary build counts" "$(ver 'nvidia-driver-615:installed')"      "ok=yes v=615"

echo "2. the floor is still a floor"
check "595 is refused"  "$(ver 'nvidia-driver-595-open:installed')" "ok=no v=595"
check "  and 609"       "$(ver 'nvidia-driver-609-open:installed')" "ok=no v=609"

echo "3. nothing installed is a failure, not an empty pass"
# This is the case the whole verify exists for, so it must not pass vacuously.
check "no nvidia packages at all" "$(ver '')" "ok=no v="
# Present in dpkg but NOT installed - deinstalled, or config-files only. The
# old `dpkg -l name` test passed on these, because dpkg -l lists them.
check "a removed package does not count" \
      "$(ver 'nvidia-driver-615-open:deinstall')" "ok=no v="
check "  nor one only half-unpacked" \
      "$(ver 'nvidia-driver-615-open:unpacked')" "ok=no v="

echo "4. with several present the highest wins, numerically"
check "615 beats 595"        "$(ver 'nvidia-driver-595-open:installed nvidia-driver-615-open:installed')" "ok=yes v=615"
# A plain `sort` would put 95 above 615. The sort has to be -n.
check "  and 1000 beats 615" "$(ver 'nvidia-driver-615-open:installed nvidia-driver-1000-open:installed')" "ok=yes v=1000"
check "  an uninstalled newer one is ignored" \
      "$(ver 'nvidia-driver-615-open:installed nvidia-driver-700-open:deinstall')" "ok=yes v=615"

echo "5. the module no longer pins a package name"
src=$(cat "$MOD")
lacks    "no dpkg -l on a fixed version" "$src" "dpkg -l nvidia-driver-610-open"
contains "the floor is named once"       "$src" "NVIDIA_MIN=610"
contains "and the verify uses the check" "$src" "verify \"nvidia driver \$NVIDIA_MIN or newer installed\" nvidia_driver_ok"
# The found version is printed BEFORE the verify, so a floor failure says what
# it actually found instead of only that it failed.
contains "the version found is reported" "$src" 'progress "installed nvidia driver:'
# The pipeline exits 0 with no output when nothing matches, so a `|| echo none`
# on the end never fires and the line reads blank where it matters most.
lacks "  and 'none' is not behind a || that cannot fire" "$src" 'nvidia_driver_version || echo none'
contains "  it uses the captured value"  "$src" 'NV_FOUND:-none}'
ln_p=$(grep -n 'progress "installed nvidia driver:' "$MOD" | cut -d: -f1)
ln_v=$(grep -n '^verify "nvidia driver' "$MOD" | cut -d: -f1)
check "  and before the verify" "$([[ ${ln_p:-0} -lt ${ln_v:-0} ]] && echo yes)" "yes"

echo "6. the install still reaches for the newest, which is why the floor is a floor"
contains "newest open driver is chosen" "$src" "sort -uV | tail -1"
contains "  with ubuntu-drivers as fallback" "$src" "|| ubuntu-drivers install || ubuntu-drivers autoinstall"

echo "7. this file's own needles are safe"
# A needle containing ${...} or $(...) inside DOUBLE quotes is expanded by bash
# before the search, so it silently looks for the wrong thing. This guard has
# caught me four times now; it belongs in every suite that greps source.
bad=$(sed 's/\\\$//g' "$0" | grep -nE '^(contains|lacks|check) +"[^"]*" +"[^"]*" +"[^"]*(\$\{|\$\()' || true)
if [[ -z $bad ]]; then echo "  ok   every needle with a \$ is single-quoted"; pass=$((pass+1))
else echo "  FAIL double-quoted needles bash will expand:"; echo "$bad"; fail=$((fail+1)); fi

echo ""
echo "nvidia-driver: $pass passed, $fail failed"
(( fail == 0 ))
