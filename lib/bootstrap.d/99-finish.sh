# --- Readiness marker --------------------------------------------------------
# Written on the *next* boot, not here: the driver needs a reboot, and a marker
# written before it would let `setup` start copying files into a box that is
# about to drop its SSH connection.
# `install -d -o user` sets ownership on the leaf only, so /home/ubuntu/.config
# itself ends up root-owned and the user cannot write their own config into it.
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config" "/home/$USER_NAME/.local" 2>/dev/null || true

progress "finishing up"
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
