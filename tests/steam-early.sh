#!/usr/bin/env bash
# The Steam client is updated beside the rest of the build, not after it: started
# during the build on a virtual screen, not held up by the game restore, and
# stopped short of everything that needs the desktop or the restored games.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: has '$3'"; fail=$((fail+1)); fi; }
M=lib/bootstrap.d/72-steam-prewarm.sh
mod=$(cat $M)
unit=$(sed -n "/steam-prewarm.service <<'EOF'/,/^EOF$/p" $M)
line() { grep -n "$1" $M | head -1 | cut -d: -f1; }

echo "1. the update is not held up by the game restore"
lacks    "the unit is not ordered after it" "$unit" "After=graphical.target cg-library-restore.service"
lacks    "  nor does it require it"        "$unit" "Requires=cg-library-restore.service"
contains "  and has the time to wait for a long restore" "$unit" "TimeoutStartSec=7200"

echo "2. what does need the games waits for them, inside the script"
contains "it waits for the restore before registering the library" "$mod" 'phase "waiting for your games to finish restoring"'
check    "  and that comes before the library is registered" "$(( $(line 'waiting for your games to finish restoring') < $(line 'phase "registering NVMe library"') ))" "1"
contains "the saved login is waited for before Steam starts" "$mod" '/var/lib/cg-library/account-done'
check    "  and that comes before the client is started"   "$(( $(line 'account-done') < $(line 'phase "unpacking client and downloading update"') ))" "1"

echo "3. the early run stops after the client is installed"
check    "it leaves before the library, the dock and the marker" "$(( $(line '\[\[ -n \${CG_EARLY:-} \]\] && exit 0') < $(line 'phase "registering NVMe library"') ))" "1"
check    "  and before the marker is written"  "$(( $(line 'CG_EARLY:-} \]\] && exit 0') < $(line 'touch "\$MARK"') ))" "1"
contains "it uses a virtual screen"            "$mod" 'export DISPLAY="${CG_DISPLAY:-:0}"'
contains "  started with the build, as the user" "$mod" 'systemd-run --quiet --unit=cg-steam-early --uid="$USER_NAME"'
contains "  on its own screen"                  "$mod" 'CG_EARLY=1 CG_DISPLAY=:99'

echo "4. the build waits for it before the reboot, and not for ever"
fin=$(cat lib/bootstrap.d/99-finish.sh)
contains "it is waited for"                    "$fin" 'systemctl is-active --quiet cg-steam-early.service'
contains "  then stopped if it is still going"  "$fin" 'systemctl stop cg-steam-early.service'
check    "  before the reboot"                 "$(( $(grep -n 'cg-steam-early.service' lib/bootstrap.d/99-finish.sh | head -1 | cut -d: -f1) < $(grep -n '^reboot' lib/bootstrap.d/99-finish.sh | cut -d: -f1) ))" "1"

echo "5. it is the AWS box's only"
check    "a machine of yours is left alone" "$(( $(line 'pkg xvfb') > $(line '^if aws_box; then') && $(line 'pkg xvfb') < $(line '^else') ))" "1"

echo; echo "steam-early: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
