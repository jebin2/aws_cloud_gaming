# A machine of yours keeps the desktop it has; one with none gets the AWS box's.
DESKTOP_ADDED=""
if aws_box || ! has_display_manager; then
  case $FAMILY in
    ubuntu|debian)
      progress "installing desktop (several minutes)"
      apt-get install -y xfce4 xfce4-goodies lightdm xserver-xorg x11-xserver-utils
      DESKTOP_ADDED=1 ;;
    *) echo ">>> FAILED: no desktop on this machine, and cg installs one only on Ubuntu or Debian - install one, then run setup again"
       exit 1 ;;
  esac
fi

