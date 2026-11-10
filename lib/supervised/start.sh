# --- Hand the rest of the build to the supervisor -----------------------------
# The AWS box's user-data ends here. Everything above is what has to happen before
# the box can be reached at all (the tailnet); everything the build is, is in the
# bundle, run by ayis-build as stages from a plan: in parallel where they allow it,
# started again if the machine or the supervisor is cut off, each with its own log.
# Fetched only AFTER tailscale, so a failure here leaves a box that can be reached.
progress "starting the build supervisor"
mkdir -p /opt/ayis-host
if ! curl -fsSL --retry 5 --retry-delay 3 '__HOST_TGZ_URL__' -o /tmp/host.tgz; then
  echo ">>> FAILED: could not download the build from S3 - the box is reachable, but nothing was built"
  exit 1
fi
tar -xz -C /opt/ayis-host -f /tmp/host.tgz
rm -f /tmp/host.tgz
# The values the stages are filled in with. Root-only: the tailnet key is one.
install -d -m 700 /etc/ayis-build
set +x
cat > /etc/ayis-build/env <<'CGENV'
__AYIS_ENV_LINES__
CGENV
chmod 600 /etc/ayis-build/env
set -x
install -m 755 /opt/ayis-host/ayis-build /usr/local/bin/ayis-build
install -m 644 /opt/ayis-host/ayis-build.service /etc/systemd/system/ayis-build.service
systemctl daemon-reload
systemctl enable --now ayis-build.service
verify "the build supervisor is running" systemctl is-active ayis-build.service
