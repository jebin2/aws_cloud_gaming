# --- Headless virtual display ------------------------------------------------
# An L4 has no display outputs, so X must be told to start with no monitor
# attached. BusID comes from lspci (decimal) so this works before the module
# is loaded. Virtual size caps the largest resolution a client can request.
progress "configuring headless X"
BDF=$(lspci -d 10de: -mm | awk 'NR==1{print $1}')
[[ $BDF == *:*:* ]] && BDF=${BDF#*:}   # drop the domain prefix if lspci emits one
BUS=$((16#${BDF%%:*}))
REST=${BDF#*:}
DEV=$((16#${REST%%.*}))
FN=${REST#*.}
mkdir -p /etc/X11
cat > /etc/X11/xorg.conf <<EOF
Section "ServerLayout"
    Identifier     "layout"
    Screen      0  "nvidia"
EndSection

Section "Device"
    Identifier     "nvidia"
    Driver         "nvidia"
    BusID          "PCI:${BUS}:${DEV}:${FN}"
    Option         "AllowEmptyInitialConfiguration" "true"
    Option         "ConnectedMonitor" "DFP-0"
    Option         "ModeValidation" "NoDFPNativeResolutionCheck,NoVirtualSizeCheck,NoMaxPClkCheck,AllowNonEdidModes"
EndSection

Section "Screen"
    Identifier     "nvidia"
    Device         "nvidia"
    DefaultDepth    24
    SubSection     "Display"
        Depth       24
        Virtual     3840 2160
        # Boot at 1080p; set-resolution.sh raises it if a client asks for more.
        Modes      "1920x1080"
    EndSubSection
EndSection
EOF

verify "xorg.conf written with a BusID" grep -q BusID /etc/X11/xorg.conf
