# A machine of yours keeps the desktop it has; one with none gets the AWS box's.
DESKTOP_ADDED=""
if aws_box || ! has_display_manager; then
  case $FAMILY in
    ubuntu|debian)
      progress "installing desktop (several minutes)"
      if aws_box; then
        # Without the recommended packages: the `xorg` meta-package alone brings a
        # video driver for every card ever made (AMD, Intel, VMware, QXL...), and
        # this box has one NVIDIA card. Named back in are the recommended ones this
        # desktop uses - the X wrapper, notifications, the volume manager, the
        # authentication agent, and what it LOOKS like: Xfce's own theme and icons
        # (xfce4-settings only recommends them, and without them the desktop falls
        # back to a pale default), the wallpaper, SVG icon rendering, thumbnails and
        # the folders a file manager expects. Measured on a build: dpkg was 77 of
        # the 86 seconds of this install.
        apt-get install -y --no-install-recommends xfce4 xfce4-goodies lightdm xserver-xorg \
          xserver-xorg-legacy x11-xserver-utils xclip xfce4-notifyd thunar-volman \
          tango-icon-theme policykit-1-gnome greybird-gtk-theme elementary-xfce-icon-theme \
          desktop-base librsvg2-common xdg-user-dirs tumbler gvfs x11-utils
      else
        apt-get install -y xfce4 xfce4-goodies lightdm xserver-xorg x11-xserver-utils xclip
      fi
      DESKTOP_ADDED=1 ;;
    *) echo ">>> FAILED: no desktop on this machine, and ayis installs one only on Ubuntu or Debian - install one, then run setup again"
       exit 1 ;;
  esac
fi

