# --- Browser ------------------------------------------------------------------
# A desktop with no browser gives "failed to execute default browser" the first
# time anything opens a link. Mozilla's .deb rather than Ubuntu's snap: snaps
# are awkward under an autologin session started by lightdm.
progress "installing firefox"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
  -o /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
  > /etc/apt/sources.list.d/mozilla.list
# Without the pin, Ubuntu's snap transitional package outranks the real .deb.
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
  > /etc/apt/preferences.d/mozilla
apt-get update
apt-get install -y firefox xdg-utils
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/firefox 200 || true
# Downloads go to the NVMe too, so nothing large can fill the 50 GB root volume.
# Written to both known policy locations because which one Mozilla's .deb reads
# was not verifiable at the time; an unused one is ignored harmlessly.
for d in /etc/firefox/policies /usr/lib/firefox/distribution; do
  mkdir -p "$d"
  cat > "$d/policies.json" <<'EOF'
{
  "policies": {
    "DefaultDownloadDirectory": "/scratch/downloads",
    "PromptForDownloadLocation": false
  }
}
EOF
done
# XFCE's exo-open reads its own helper config; setting only xdg is not enough.
install -d -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/xfce4"
printf 'WebBrowser=firefox\n' > "/home/$USER_NAME/.config/xfce4/helpers.rc"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/xfce4/helpers.rc"

verify "firefox installed" test -x /usr/bin/firefox
