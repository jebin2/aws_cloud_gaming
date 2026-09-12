# --- Headless virtual display ------------------------------------------------
# An L4 has no display outputs, so X must be told to start with no monitor
# attached. BusID comes from lspci (decimal) so this works before the module
# is loaded.
#
# Virtual MUST equal the mode below. X11 capture grabs the whole screen, so a
# screen larger than the active mode puts the desktop in the top-left corner of
# the frame with black filling the rest. (NvFBC happened to capture only the
# active output, which hid this until capture moved to X11.) The driver also
# clamps Virtual to its own mode pool - asking for 3840x2160 silently produced a
# 2560x1600 screen against a 1920x1080 mode, which is exactly that mismatch.
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
        # Keep these two identical - see the note at the top of this file.
        Virtual     1920 1080
        Modes      "1920x1080"
    EndSubSection
EndSection
EOF

verify "xorg.conf written with a BusID" grep -q BusID /etc/X11/xorg.conf
