# --- Autologin ---------------------------------------------------------------
# Sunshine captures an existing X session, so one must come up unattended.
progress "configuring autologin"
groupadd -f autologin
usermod -aG autologin,input,video "$USER_NAME"
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=$USER_NAME
autologin-user-timeout=0
user-session=xfce
EOF
systemctl set-default graphical.target
systemctl enable lightdm

verify "lightdm autologin configured" grep -q autologin-user /etc/lightdm/lightdm.conf.d/50-autologin.conf
