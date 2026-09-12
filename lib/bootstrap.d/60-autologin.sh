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

# xfce4-power-manager RE-ENABLES DPMS after X starts, overriding the ServerFlags
# in xorg.conf completely - the X log shows BlankTime=0 and NoPM=true parsed,
# and `xset q` still reports "timeout: 600, DPMS is Enabled" once the session is
# up. So the config has to be set where the power manager reads it. Written as
# XML directly because xfconfd is not running at build time.
install -d -m 755 "/home/$USER_NAME/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "/home/$USER_NAME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="uint" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
  </property>
</channel>
EOF

# light-locker blanks and locks the screen too, and a locked screen on a box
# with no keyboard is unrecoverable over a stream.
install -d -m 755 "/home/$USER_NAME/.config/autostart"
cat > "/home/$USER_NAME/.config/autostart/light-locker.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=light-locker
Hidden=true
EOF

# Third line of defence. xorg.conf sets BlankTime/OffTime to 0, the power
# manager is configured above, and this covers an X server started some other
# way. Cheap, and this failure is expensive: once a headless display blanks,
# the framebuffer never comes back - only restarting the session recovers it.
install -d -m 755 "/home/$USER_NAME/.config/autostart"
cat > "/home/$USER_NAME/.config/autostart/no-blank.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable screen blanking
Exec=/bin/sh -c "xset s off; xset s noblank; xset -dpms"
X-GNOME-Autostart-enabled=true
EOF
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/autostart"

verify "screen blanking disabled in xorg.conf" grep -q 'BlankTime' /etc/X11/xorg.conf
