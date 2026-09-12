# --- Tailscale, first ---------------------------------------------------------
# Deliberately before the slow driver and desktop installs: joining the tailnet
# early is the only way to get a shell into this box while the rest runs. With
# it last, a hang during the driver build leaves you with no way in at all.
progress "installing tailscale"
curl -fsSL https://tailscale.com/install.sh | sh
set +x   # don't trace the auth key into the log
# No --ssh: it makes tailscaled intercept port 22 on the tailnet interface, and
# without an `ssh` section in the tailnet ACL those connections simply hang.
# Plain sshd over the tailnet works with the EC2 key and needs no inbound rule,
# because tunnelled traffic is decapsulated inside the host.
tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOST"
set -x

verify "tailscale is up and has an address" tailscale ip -4
