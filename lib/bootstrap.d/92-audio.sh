# Somewhere for the sound to go. The AWS box has no sound card at all; a machine
# of yours that already has an output is left alone.
has_sound_output() {
  [ "$(sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_UID" pactl list short sinks 2>/dev/null | wc -l)" -gt 0 ]
}
if aws_box || ! has_sound_output; then
progress "installing audio (pipewire + a virtual sink)"
# Sunshine's Ubuntu build initialises audio through PipeWire and spins forever
# in `pw.thread-loop: iterate error -22` if it is missing - while systemd still
# reports the unit as active, so it looks healthy and never binds its ports.
# A cloud VM also has no /dev/snd, hence the null sink: something must exist to
# capture, even though nobody is listening to it.
case $FAMILY in
  ubuntu|debian) pkg pipewire pipewire-pulse pipewire-audio wireplumber alsa-utils ;;
  arch)          pkg pipewire pipewire-pulse wireplumber alsa-utils ;;
  fedora)        pkg pipewire pipewire-pulseaudio wireplumber alsa-utils ;;
esac
# A cloud VM has no sound card, and Sunshine refuses to start without an audio
# device - it spins in `pw.thread-loop: iterate error -22` forever while systemd
# still reports the unit active, so it looks healthy and never binds its ports.
#
# A context.objects drop-in under ~/.config/pipewire/pipewire.conf.d/ does NOT
# reliably create the sink: wpctl showed zero sinks on a box where that file was
# present and correct. Load the module at runtime instead, which is a supported
# call, and verify a sink actually exists rather than trusting a config file.
cat > /usr/local/bin/ensure-audio-sink.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Wait for pipewire-pulse to answer; it is socket-activated and may lag login.
for _ in $(seq 1 40); do
  pactl info >/dev/null 2>&1 && break
  sleep 3
done
pactl info >/dev/null 2>&1 || { echo "pipewire-pulse never answered" >&2; exit 1; }

if ! pactl list short sinks 2>/dev/null | grep -q .; then
  pactl load-module module-null-sink \
    sink_name=sunshine \
    sink_properties=device.description=Sunshine >/dev/null 2>&1 || true
  sleep 2
fi

# The check that matters: a sink exists, not that a config file does.
if pactl list short sinks 2>/dev/null | grep -q .; then
  pactl set-default-sink sunshine 2>/dev/null || true
  exit 0
fi
echo "no audio sink could be created" >&2
exit 1
EOF
chmod 755 /usr/local/bin/ensure-audio-sink.sh

# Unquoted: the user and their runtime directory are this machine's - ubuntu
# and 1000 on the AWS box, you on a machine of yours.
cat > /etc/systemd/system/ensure-audio-sink.service <<EOF
[Unit]
Description=Guarantee an audio sink exists before Sunshine starts
After=graphical.target

[Service]
Type=oneshot
User=$USER_NAME
ExecStart=/usr/local/bin/ensure-audio-sink.sh
# Sunshine only reads its audio device at startup, so restart it once the sink
# is in place - otherwise it is already stuck in the retry loop. This runs as
# the same User=, so plain "systemctl --user" is correct; "-M ubuntu@" fails
# with "Failed to connect to bus: No medium found".
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus
ExecStartPost=/bin/sh -c 'systemctl --user restart app-dev.lizardbyte.app.Sunshine.service || systemctl --user restart sunshine.service || true'
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
systemctl enable ensure-audio-sink.service

WANTS_DIR="$USER_HOME/.config/systemd/user/default.target.wants"
install -d -o "$USER_NAME" -g "$USER_NAME" "$WANTS_DIR"
for u in pipewire.service pipewire-pulse.service wireplumber.service; do
  [[ -f "/usr/lib/systemd/user/$u" ]] || { echo "missing unit $u"; continue; }
  ln -sf "/usr/lib/systemd/user/$u" "$WANTS_DIR/$u"
  chown -h "$USER_NAME:$USER_NAME" "$WANTS_DIR/$u"
done

# Sunshine's own unit orders itself after the graphical session but says nothing
# about audio, so on a fresh boot it can start before PipeWire is ready, fail to
# initialise, and spin - the same failure, but only sometimes. Order it
# explicitly rather than relying on luck.
# Both names Sunshine's unit goes by: Ubuntu's package and the others.
for unit in app-dev.lizardbyte.app.Sunshine.service sunshine.service; do
DROPIN="$USER_HOME/.config/systemd/user/$unit.d"
install -d -o "$USER_NAME" -g "$USER_NAME" "$DROPIN"
cat > "$DROPIN/10-after-audio.conf" <<'EOF'
[Unit]
After=pipewire.service pipewire-pulse.service wireplumber.service
Wants=pipewire.service wireplumber.service
EOF
done

verify "audio sink service installed" test -x /usr/local/bin/ensure-audio-sink.sh
fi
