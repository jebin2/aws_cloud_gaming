# --- Readiness marker --------------------------------------------------------
# Written on the *next* boot, not here: the driver needs a reboot, and a marker
# written before it would let `setup` start copying files into a box that is
# about to drop its SSH connection.
# `install -d -o user` sets ownership on the leaf only, so /home/ubuntu/.config
# itself ends up root-owned and the user cannot write their own config into it.
# On the AWS box only: a machine of yours is not combed through - every folder
# this build makes there is handed to you as it is made.
aws_box && { chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.config" "$USER_HOME/.local" 2>/dev/null || true; }

progress "finishing up"
if aws_box; then
cat > /etc/systemd/system/cloud-gaming-ready.service <<'EOF'
[Unit]
Description=Signal that the streaming desktop is up
# Also after the library restore: the marker is what `cg init` waits for, and
# reporting the box ready while 140 GB is still arriving would send you to a
# Steam that thinks nothing is installed.
After=graphical.target cg-library-restore.service
Wants=cg-library-restore.service

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /var/lib/cloud-gaming-ready
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
systemctl enable cloud-gaming-ready.service

echo "bootstrap complete; rebooting into the desktop"
reboot
else
  # A machine of yours is ready now, and never rebooted by this build. A driver
  # added for an NVIDIA card loads at the next boot, which is yours to choose.
  [ -n "${NVIDIA_ADDED:-}" ] && progress "the NVIDIA driver loads at the next boot - restart this machine when it suits you"
  touch /var/lib/cloud-gaming-ready
  echo "bootstrap complete"
fi
