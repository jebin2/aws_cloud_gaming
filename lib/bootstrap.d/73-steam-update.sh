# --- The Steam client, updated beside the rest of the build ---------------------
# The AWS box's. Its own stage, so that the plan can run it while the packages go in:
# the client's download and unpack takes about five minutes and wants only the
# network. Run as the user, on a virtual screen (72-steam-prewarm.sh writes the
# wrapper). Whatever it has not finished, the run after the reboot carries on from -
# so this never fails the build.
if aws_box; then
progress "updating the Steam client"
# Stopped by this, well inside the stage's own time limit: a stage that ran out of
# time would fail the build over something the run after the reboot finishes.
timeout 1380 sudo -u "$USER_NAME" -H /usr/local/bin/steam-prewarm-early.sh \
  || echo "note: the Steam client update did not finish here - it carries on after the reboot"
fi
