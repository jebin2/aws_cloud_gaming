#!/usr/bin/env bash
# Runs once, as root, as EC2 user-data on first boot.
# Turns a bare Ubuntu 24.04 GPU instance into a streamable desktop.
# provision.sh substitutes __TS_AUTHKEY__ and __TS_HOST__ before upload.
set -euxo pipefail

exec > >(tee /var/log/cloud-gaming-bootstrap.log) 2>&1

# Progress markers. `set -x` traces every command, which is far too noisy to
# watch remotely, so these give ./setup a clean line to stream instead.
progress() { set +x; echo ">>> $*"; set -x; }

# Assert that a step achieved its effect, not merely that it ran. Nearly every
# failure in this build has been something reporting success while broken - a
# config file written but never loaded, a unit "active" but stuck, a symlink
# made into a directory that did not exist yet. `verify` is where a step states
# what "worked" means, in terms of the running system.
verify() {  # verify <description> <command...>
  set +x
  if "${@:2}" >/dev/null 2>&1; then
    echo ">>> ok: $1"
    set -x
  else
    echo ">>> FAILED: $1"
    set -x
    return 1
  fi
}

USER_NAME=ubuntu
TS_AUTHKEY="__TS_AUTHKEY__"
TS_HOST="__TS_HOST__"

export DEBIAN_FRONTEND=noninteractive
apt-get update
