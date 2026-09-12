#!/usr/bin/env bash
# Shared helpers. Sourced by lib/setup and lib/game - not run directly.

# ISO 8601 with offset, so a saved log is unambiguous about when things ran and
# how long each step took. Local time rather than UTC: these are read by the
# person who ran the command, usually while waiting.
ts() { date -Iseconds; }

# Progress and action output. Reports (status, cost) deliberately do not go
# through these - a timestamp on every row of a table is noise, not context.
say() { printf '\n%s  ==> %s\n' "$(ts)" "$1"; }
log() { printf '%s      %s\n' "$(ts)" "$*"; }
die() { printf '%s  error: %s\n' "$(ts)" "$1" >&2; exit 1; }

# `aws ec2 wait` blocks silently, sometimes for minutes, which is
# indistinguishable from a hang. These poll instead and show the state as it
# changes, so a slow stop looks slow rather than broken.

# wait_instance_state <region> <instance-id> <desired-state> [timeout-seconds]
wait_instance_state() {
  local region=$1 id=$2 want=$3 timeout=${4:-600}
  local last="" now waited=0 beat=0
  while (( waited < timeout )); do
    now=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")
    # A line per state change, plus a heartbeat, rather than one per poll -
    # timestamped lines are the point, but not 200 of them.
    if [[ $now != "$last" ]]; then
      log "$now"; last=$now; beat=$waited
    elif (( waited - beat >= 10 )); then
      log "still $now (${waited}s)"; beat=$waited
    fi
    [[ $now == "$want" ]] && { log "$now after ${waited}s"; return 0; }
    sleep 3; waited=$(( waited + 3 ))
  done
  log "TIMEOUT after ${timeout}s, last state: $last"
  return 1
}

# stream_build <ssh-target> <ssh-key> [timeout-seconds]
# Follows the bootstrap log on the box until it signals ready. The build takes
# 10-20 minutes and used to be entirely invisible from here, which made a hang
# indistinguishable from slow progress - the whole reason Tailscale now installs
# first is so this is possible at all.
#
# Reconnects on failure rather than giving up: the box reboots partway through
# to load the NVIDIA driver, so ssh dropping is expected, not an error.
stream_build() {
  local target=$1 key=$2 timeout=${3:-2400}
  local seen=0 waited=0 new count rebooted=0
  local ssh_opts=(-i "$key" -o StrictHostKeyChecking=accept-new
                  -o ConnectTimeout=8 -o BatchMode=yes)

  local err
  err=$(mktemp)
  while (( waited < timeout )); do
    if new=$(ssh "${ssh_opts[@]}" "$target" \
             "tail -n +$((seen+1)) /var/log/cloud-gaming-bootstrap.log 2>/dev/null" 2>"$err"); then
      if [[ -n $new ]]; then
        count=$(wc -l <<<"$new")
        seen=$(( seen + count ))
        # Only the progress markers and anything that looks like a failure -
        # `set -x` traces thousands of lines that are useless to watch.
        # Anchored and punctuated deliberately: a bare /error/ matches package
        # names like libgpg-error0 and floods the output with routine apt lines.
        while IFS= read -r line; do
          case $line in
            ">>> FAILED: "*) log "FAILED: ${line#>>> FAILED: }" ;;
            ">>> ok: "*)     log "  ok  ${line#>>> ok: }" ;;
            ">>> "*)         log "${line#>>> }" ;;
            *)               log "! $line" ;;
          esac
        done < <(grep -E '^>>> |^E: |^ERROR|[Ee]rror:|[Ff]ailed to |command not found|curl: \([0-9]+\)|No such file' <<<"$new" \
                 | grep -vE 'Setting up|Unpacking|Preparing to unpack|Selecting previously|^Get:|^info:|^ls: |usbmux|/nonexistent|NetworkManager' || true)
      fi
      if ssh "${ssh_opts[@]}" "$target" 'test -f /var/lib/cloud-gaming-ready' 2>/dev/null; then
        log "build complete after $(( waited / 60 ))m"
        rm -f "$err"
        return 0
      fi
    elif grep -q 'HOST IDENTIFICATION HAS CHANGED\|Host key verification failed' "$err" 2>/dev/null; then
      # Distinguish "cannot connect" from "refused to connect". Reporting a
      # reboot here was actively misleading: the box was building fine and only
      # our view of it was broken, which is the hardest kind of failure to see.
      log "ssh refused: the host key for this name changed"
      log "  a rebuilt box reclaims the hostname, so the old key is stale:"
      log "    ssh-keygen -R ${target#*@}"
      rm -f "$err"
      return 1
    elif (( rebooted == 0 && waited > 300 )); then
      # Only call it a reboot once the box has been reachable for a while -
      # ssh refusing in the first minutes is just sshd not up yet.
      log "host rebooting - reconnecting"
      rebooted=1
      # Do NOT reset `seen`: the log is a file that survives the reboot, so
      # starting over replays every line that was already printed.
    fi
    sleep 10; waited=$(( waited + 10 ))
  done
  log "TIMEOUT after $(( timeout / 60 ))m. Check on the box:"
  log "  ssh -i $key $target"
  log "  sudo tail -50 /var/log/cloud-gaming-bootstrap.log"
  return 1
}

# Tailscale appends -1, -2, ... when a hostname is already registered, and a
# node's identity lives on the disk that a destroy deletes - so a rebuilt box
# can never reclaim its old name while the stale entry exists. Rather than
# demand the user prune the tailnet by hand, adopt whatever name the box
# actually joined under.

# tailnet_nodes  - one hostname per line
tailnet_nodes() { tailscale status 2>/dev/null | awk 'NF>1 && $1 ~ /^100\./ {print $2}'; }

# wait_new_node <nodes-before-file> <timeout-seconds>
# Prints the hostname of the node that appeared. Matching on "something new
# showed up" rather than on an expected name is what makes this immune to the
# suffix problem entirely.
wait_new_node() {
  local before=$1 timeout=${2:-1800} waited=0 beat=0 found
  while (( waited < timeout )); do
    found=$(tailnet_nodes | grep -vxF -f "$before" 2>/dev/null | head -1 || true)
    if [[ -n $found ]]; then
      log "joined as '$found' after ${waited}s" >&2
      printf '%s' "$found"
      return 0
    fi
    (( waited - beat >= 60 )) && { log "still waiting for the box to join (${waited}s)" >&2; beat=$waited; }
    sleep 10; waited=$(( waited + 10 ))
  done
  log "TIMEOUT after $(( timeout / 60 ))m - no new node joined the tailnet" >&2
  return 1
}

# wait_image_available <region> <ami-id> [timeout-seconds]
# Image creation is the slowest thing here - several minutes for a 50 GB volume.
wait_image_available() {
  local region=$1 ami=$2 timeout=${3:-1800}
  local last="" now waited=0 beat=0
  while (( waited < timeout )); do
    now=$(aws ec2 describe-images --region "$region" --image-ids "$ami" \
      --query 'Images[0].State' --output text 2>/dev/null || echo "?")
    if [[ $now != "$last" ]]; then
      log "$now"; last=$now; beat=$waited
    elif (( waited - beat >= 15 )); then
      log "still $now (${waited}s)"; beat=$waited
    fi
    [[ $now == available ]] && { log "available after ${waited}s"; return 0; }
    [[ $now == failed ]] && { log "image creation FAILED"; return 1; }
    sleep 5; waited=$(( waited + 5 ))
  done
  log "TIMEOUT after ${timeout}s, last state: $last"
  return 1
}

# wait_for_steam <ssh-target> <ssh-key> [timeout-seconds]
# The prewarm service runs after graphical.target and downloads ~500 MB, so it
# is still going long after `setup` would otherwise finish. Waiting means the
# completion message can tell the truth about whether Steam is ready.
wait_for_steam() {
  local target=$1 key=$2 timeout=${3:-1500}
  local waited=0 beat=0 size last="" phase cur
  local ssh_opts=(-i "$key" -o StrictHostKeyChecking=accept-new
                  -o ConnectTimeout=8 -o BatchMode=yes)

  while (( waited < timeout )); do
    if ssh "${ssh_opts[@]}" "$target" 'test -f ~/.steam-prewarmed' 2>/dev/null; then
      log "steam ready after $(( waited / 60 ))m"
      return 0
    fi
    # Report the phase, not just the size: after the download the client stops
    # growing while library adoption and the dock pin still run, which read as
    # a stall if all you print is an unchanging number.
    # '|'-separated, not space: phase names contain spaces, and `read a b` puts
    # the whole remainder in $b - which printed the phase text as if it were the
    # download size. Size follows symlinks and covers both client layouts.
    IFS='|' read -r phase size < <(ssh "${ssh_opts[@]}" "$target" \
      'printf "%s|%s\n" "$(cat ~/.steam-phase 2>/dev/null || echo working)" \
         "$(du -shcL ~/.steam ~/.local/share/Steam 2>/dev/null | tail -1 | cut -f1)"' 2>/dev/null || echo "working|")
    cur="${phase:-working} ${size:-}"
    if [[ $cur != "$last" ]]; then
      log "${phase:-working}${size:+ ($size)}"; last=$cur; beat=$waited
    elif (( waited - beat >= 60 )); then
      log "${phase:-working} (${waited}s)"; beat=$waited
    fi
    sleep 15; waited=$(( waited + 15 ))
  done
  log "steam did not finish within $(( timeout / 60 ))m - check ~/steam-prewarm.log on the box"
  return 1
}

# A stopped SPOT instance is not a parked box - it is a dead one that still
# bills. Stopping a spot instance disables its persistent request, and AWS
# refuses to start an instance whose request is not active, so the machine can
# never come back while its root volume keeps charging.
#
# Every cost guard produces exactly this state: the on-host watchdog's
# `shutdown -h`, the CloudWatch alarm's ec2:stop action, and the off-site
# watchdog's StopInstances. They cannot terminate instead - a persistent spot
# request relaunches the moment its instance dies, and no guard can cancel the
# request first (the on-host one holds no credentials at all). So stop is the
# right action there, and this is the leak it leaves behind.
#
# Nothing reported it. `cg status` said "instance stopped", which reads as
# normal and recoverable.
stranded_spot_note() {  # stranded_spot_note <region> <instance-id>; prints nothing if fine
  local region=$1 id=$2 out state life srs gb
  [[ -n ${id:-} ]] || return 0
  out=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[State.Name,InstanceLifecycle]' \
    --output text 2>/dev/null) || return 0
  read -r state life <<<"$out"
  [[ $state == stopped && $life == spot ]] || return 0
  srs=$(aws ec2 describe-spot-instance-requests --region "$region" \
    --filters "Name=instance-id,Values=$id" \
    --query 'SpotInstanceRequests[0].State' --output text 2>/dev/null) || srs=unknown
  [[ $srs == active ]] && return 0
  # Charge the real volume size rather than GAME_DISK_GB, which only describes
  # what the next build would ask for.
  gb=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
        --output text 2>/dev/null)
  gb=$(aws ec2 describe-volumes --region "$region" --volume-ids "$gb" \
        --query 'Volumes[0].Size' --output text 2>/dev/null)
  [[ $gb =~ ^[0-9]+$ ]] || gb=0
  awk -v g="$gb" -v s="$srs" 'BEGIN{
    u=g*0.0912;
    printf "  STRANDED       this stopped spot box can never start again (request: %s)\n", s;
    printf "                 its %d GB root volume still bills $%.2f/mo (INR %.0f)\n", g, u, u*88;
    printf "                 reclaim it: cg destroy\n";
  }'
}
