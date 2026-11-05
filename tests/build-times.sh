#!/usr/bin/env bash
# The package installer is hurried while the box builds and put back before it runs,
# and waits for a busy lock instead of failing. (Where the time went is the
# supervisor's: tests/supervisor.sh.)
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }

echo "1. dpkg is hurried while building and put back before the machine runs"
base=$(cat lib/bootstrap.d/10-base.sh)
contains "unsafe-io is set at the start"        "$base" "force-unsafe-io"
contains "  on the AWS box only"                  "$(sed -n '/^if aws_box; then/,/^fi/p' lib/bootstrap.d/10-base.sh)" "99-cg-build-unsafe-io"
contains "  and removed before the reboot"        "$(sed -n '/^progress "finishing up"/,/^cat > /p' lib/bootstrap.d/99-finish.sh)" "rm -f /etc/dpkg/dpkg.cfg.d/99-cg-build-unsafe-io"

echo "2. a busy package lock is waited for"
contains "the first boot has the image's own updater holding it" "$base" 'DPkg::Lock::Timeout "900"'

echo "3. the AWS box's desktop and browser leave out what they do not use"
aws_desk=$(sed -n '/^      if aws_box; then/,/^      else/p' lib/bootstrap.d/30-desktop.sh)
contains "the desktop is installed without recommends"  "$aws_desk" "--no-install-recommends xfce4"
for keep in xserver-xorg-legacy xfce4-notifyd thunar-volman tango-icon-theme policykit-1-gnome; do
  contains "  and keeps $keep" "$aws_desk" "$keep"
done
contains "a machine of yours still gets the full install" "$(sed -n '/^      else/,/^      fi/p' lib/bootstrap.d/30-desktop.sh)" "apt-get install -y xfce4 xfce4-goodies lightdm xserver-xorg x11-xserver-utils xclip"
contains "firefox is installed without recommends"       "$(cat lib/bootstrap.d/80-firefox.sh)" "--no-install-recommends firefox xdg-utils"

echo "4. apt's lists are refreshed once on the AWS box, with every source in place"
steam=$(cat lib/bootstrap.d/70-steam-pkg.sh); ff=$(cat lib/bootstrap.d/80-firefox.sh)
once=$(sed -n '/^if aws_box && \[ "\$FAMILY" = ubuntu \]; then/,/^fi$/p' lib/bootstrap.d/25-apt-lists.sh)
check    "the refresh is a stage of its own, after tailscale (20)" "$(ls lib/bootstrap.d | grep -c '^25-apt-lists.sh$')" "1"
check    "  and base no longer fetches from Mozilla"       "$(grep -c packages.mozilla lib/bootstrap.d/10-base.sh)" "0"
contains "the 32-bit architecture is added before the refresh" "$once" "dpkg --add-architecture i386"
contains "  and Mozilla's repository, with its pin"           "$once" "/etc/apt/preferences.d/mozilla"
contains "  then the refresh, then the marker"                "$(tr '\n' ' ' <<<"$once" | grep -o 'apt-get update *if .*touch /run/cg-apt-ready')" "touch /run/cg-apt-ready"
contains "no marker when Mozilla's key could not be fetched" "$once" 'CG_APT_ONCE=1'
contains "  and the key is fetched inside an if, so a failure is not fatal" "$once" 'if curl -fsSL https://packages.mozilla.org'

contains "steam skips its refreshes when the marker is there"  "$steam" '[ -e /run/cg-apt-ready ] || apt-get update'
check    "  both of them"                                      "$(grep -c '\[ -e /run/cg-apt-ready \] || apt-get update' lib/bootstrap.d/70-steam-pkg.sh)" "2"
check    "  and has no bare refresh left"                      "$(grep -v '^ *#' lib/bootstrap.d/70-steam-pkg.sh | grep -c '^ *apt-get update')" "0"
contains "firefox skips its refresh when the marker is there" "$ff" '[ -e /run/cg-apt-ready ] || apt-get update'
check    "  and has no bare refresh left"                      "$(grep -v '^ *#' lib/bootstrap.d/80-firefox.sh | grep -c '^apt-get update')" "0"

echo; echo "build-times: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
