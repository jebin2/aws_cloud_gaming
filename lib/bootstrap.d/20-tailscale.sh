# --- Tailscale, first ---------------------------------------------------------
# Deliberately before the slow driver and desktop installs: joining the tailnet
# early is the only way to get a shell into this box while the rest runs. With
# it last, a hang during the driver build leaves you with no way in at all.
progress "installing tailscale"
# Installed and joined only when it is not already: a machine of yours may be on
# the tailnet already, and joining it again would rename it.
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled >/dev/null 2>&1 || true
if ! tailscale ip -4 >/dev/null 2>&1; then
set +x   # don't trace the auth key into the log
# No --ssh: it makes tailscaled intercept port 22 on the tailnet interface, and
# without an `ssh` section in the tailnet ACL those connections simply hang.
# Plain sshd over the tailnet works with the EC2 key and needs no inbound rule,
# because tunnelled traffic is decapsulated inside the host.
tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOST"
set -x
fi

verify "tailscale is up and has an address" tailscale ip -4
