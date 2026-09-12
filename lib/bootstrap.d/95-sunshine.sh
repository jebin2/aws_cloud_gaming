progress "installing sunshine"
SUNSHINE_DEB=/tmp/sunshine.deb
# The asset filename embeds the release version, so there is no stable
# latest/download/ URL to hard-code - resolve it from the release API.
SUNSHINE_URL=$(curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
  | jq -r '.assets[] | select(.name | test("ubuntu24\\.04_amd64\\.deb$")) | .browser_download_url' \
  | head -1)
[[ -n $SUNSHINE_URL ]] || { echo "could not resolve a Sunshine .deb for ubuntu 24.04"; exit 1; }
curl -fsSL -o "$SUNSHINE_DEB" "$SUNSHINE_URL"
apt-get install -y "$SUNSHINE_DEB"
rm -f "$SUNSHINE_DEB"

# Match the desktop to whatever screen the client is streaming from. This is
# what lets one desktop serve a phone, a tablet and a laptop.
cat > /usr/local/bin/set-resolution.sh <<'EOF'
#!/usr/bin/env bash
# Sunshine passes the client's requested geometry in these variables.
set -eu
W=${SUNSHINE_CLIENT_WIDTH:-1920}
H=${SUNSHINE_CLIENT_HEIGHT:-1080}
R=${SUNSHINE_CLIENT_FPS:-60}
export DISPLAY=:0
OUT=$(xrandr --query | awk '/ connected/{print $1; exit}')

# What is on screen right now: the mode marked '*' under this output.
current() { xrandr --query | awk -v o="$OUT" '$1==o{f=1;next} f&&/\*/{print $1; exit}'; }

# Changing mode at all is what creates the risk below, so do not change it when
# the client already matches. This is the common case at the default 1080p.
[[ $(current) == "${W}x${H}" ]] && exit 0

# X already advertises a long mode list, so use the existing entry whenever the
# size is offered. Creating a duplicate modeline fails with BadName ("a mode of
# that name exists"), --addmode then fails BadMatch, and nothing says why.
if xrandr --query | sed -n "/^$OUT/,/^[^ ]/p" | grep -qE "^ +${W}x${H}[ +]"; then
  err=$(xrandr --output "$OUT" --mode "${W}x${H}" 2>&1) || true
else
  MODE="${W}x${H}_${R}"
  xrandr --newmode "$MODE" $(cvt "$W" "$H" "$R" | sed -n '2s/^Modeline "[^"]*" //p') 2>/dev/null || true
  xrandr --addmode "$OUT" "$MODE" 2>/dev/null || true
  err=$(xrandr --output "$OUT" --mode "$MODE" 2>&1) || true
fi

# This headless X server will not reconfigure its CRTC at all - every mode
# change fails with "Configure crtc 0 failed / BadMatch", including setting the
# mode it is already in. Stop immediately when it refuses, because each attempt
# puts the server in modeset, and NvFBC capture fails outright while it is:
#   Failed to start capture session: the display server is in modeset
# The session then connects, sends no video, and the client is dropped a second
# later - which looks like a network fault and is not one. Sunshine simply
# captures at 1080p instead and the client scales, which costs nothing.
if grep -q 'Configure crtc\|BadMatch\|cannot find mode' <<<"${err:-}"; then
  echo "$(date -Iseconds) cannot switch to ${W}x${H}: display is fixed at $(current)" \
    >> /var/log/set-resolution.log 2>/dev/null || true
  exit 0
fi

# It was accepted, so wait for it to actually be current before returning -
# Sunshine starts capture the instant this exits.
for _ in $(seq 1 15); do                 # ~3s
  if [[ $(current) == "${W}x${H}" ]]; then
    sleep 0.4                            # let the server settle once it reports
    break
  fi
  sleep 0.2
done
EOF
chmod 755 /usr/local/bin/set-resolution.sh

install -d -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/sunshine"
# Sunshine's CSRF protection only trusts localhost by default, so the web UI
# rejects every request made over the tailnet. Both the MagicDNS name and the
# raw IP need listing - which host you type in the browser is what gets checked.
# Ask tailscale what this node is actually called rather than assuming it got
# the requested hostname: if the name was already taken it joins as <host>-1,
# and a csrf list naming the wrong host blocks the web UI with an error that
# says nothing about names.
TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
TS_FQDN=$(tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || echo "")
TS_SELF="${TS_FQDN%%.*}"
: "${TS_SELF:=$TS_HOST}"
ORIGINS="https://${TS_SELF},https://${TS_SELF}:47990"
[[ -n $TS_FQDN ]] && ORIGINS="$ORIGINS,https://${TS_FQDN},https://${TS_FQDN}:47990"
[[ -n $TS_IP   ]] && ORIGINS="$ORIGINS,https://${TS_IP},https://${TS_IP}:47990"
ORIGINS="$ORIGINS,https://localhost:47990"
cat > "/home/$USER_NAME/.config/sunshine/sunshine.conf" <<EOF
# Tailscale's MTU is 1280; Sunshine's default 1392 fragments and reads as stutter.
packet_size = 1024
# No resolution prep command, deliberately. Once xrandr changes the mode at
# runtime, NvFBC reports the display server as permanently "in modeset" and
# cannot create a capture session again until X restarts - so every session
# after the first switch connects, sends no video, and is dropped. Verified:
# a fresh X captures fine, and the first session that switches mode is the last
# one that works.
#
# The box therefore stays at the xorg.conf mode (1920x1080) and the client
# scales if it asked for something else. set-resolution.sh is still installed
# for manual use, just not wired into a session.
global_prep_cmd = []
csrf_allowed_origins = $ORIGINS
EOF
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/sunshine"

loginctl enable-linger "$USER_NAME"
# Enable by symlink rather than `systemctl --user`: there is no user session
# yet at cloud-init time, so there is no user manager to talk to.
# The unit is named app-dev.lizardbyte.app.Sunshine.service, not sunshine.service,
# and the package may rename it again - so match on the path rather than assume.
UNIT=$(ls /usr/lib/systemd/user/*[Ss]unshine*.service /lib/systemd/user/*[Ss]unshine*.service 2>/dev/null | head -1)
[[ -n $UNIT ]] || { echo "no Sunshine systemd user unit found"; exit 1; }
WANTS="/home/$USER_NAME/.config/systemd/user/default.target.wants"
install -d -o "$USER_NAME" -g "$USER_NAME" "$WANTS"
ln -sf "$UNIT" "$WANTS/$(basename "$UNIT")"
chown -h "$USER_NAME:$USER_NAME" "$WANTS/$(basename "$UNIT")"

verify "sunshine binary installed" test -x /usr/bin/sunshine
