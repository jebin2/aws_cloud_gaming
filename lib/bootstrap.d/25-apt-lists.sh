# --- apt's lists, refreshed once ------------------------------------------------
# One refresh for the whole build, with every source the later stages need already
# in place: the 32-bit architecture Steam wants, and Mozilla's repository for Firefox.
# Those stages used to add theirs and refresh again - three refreshes, about 30
# seconds on the critical path, since nothing else installs while apt is busy. The
# marker says it was done: a stage that finds it skips its own refresh, and one that
# does not (Mozilla's key could not be fetched, or this run restarted after a reboot,
# which empties /run) refreshes as it always did.
#
# A stage of its own, after tailscale (25): it fetches from a third party, and a box
# that cannot must still join the tailnet to be looked at (tests/bootstrap-order.sh).
if aws_box && [ "$FAMILY" = ubuntu ]; then
  command -v curl >/dev/null 2>&1 || pkg curl
  dpkg --add-architecture i386
  install -d -m 0755 /etc/apt/keyrings
  # Without Mozilla's key there is no Mozilla source, and no marker: the stages then
  # add what they need and refresh for themselves.
  CG_APT_ONCE=""
  if curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc; then
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
      > /etc/apt/sources.list.d/mozilla.list
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
    CG_APT_ONCE=1
  fi
  apt-get update
  if [ -n "$CG_APT_ONCE" ]; then touch /run/cg-apt-ready; fi
fi
