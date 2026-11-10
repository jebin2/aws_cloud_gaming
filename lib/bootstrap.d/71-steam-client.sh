# --- Steam's client, from the archive ----------------------------------------------
# The AWS box's. The client is about 2.5 GB, and Valve's download of it took five to
# eight minutes of every build. The Steam client archive workflow publishes it on
# GitHub; this fetches and unpacks it, in a stage of its own that needs only the
# network, so it is done long before Steam is installed. If there is no archive (the
# first build ever, or GitHub is unreachable), nothing is lost: the box downloads
# the client from Valve as before. Never fails the build.
if aws_box; then
progress "fetching the Steam client archive"
bash /opt/ayis-host/steam-client-fetch '__AYIS_STEAM_CLIENT_URL__' "$USER_NAME" \
  && progress "the Steam client came from the archive" \
  || echo "note: no Steam client archive was used - Steam downloads its client itself"
fi
