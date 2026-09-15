#!/usr/bin/env bash
# Whether this laptop holds the private key of the box's EC2 key pair.
# Sourced by lib/setup (cg check's line) and lib/provision.sh (the replacement).
#
# AWS hands a key pair's private key out once, when the pair is created. A second
# laptop, or a lost .pem, therefore had no way in to a box launched with that
# pair: `cg init` reused the pair, and every ssh step of the build failed. The
# pair is now reused only when the .pem here is its private key.

# key_state <region> <name> <pem> -> one of
#   none      AWS has no key pair of that name
#   match     the .pem here is its private key
#   missing   AWS has the pair, and there is no .pem here
#   mismatch  AWS has the pair, and the .pem here is some other key
#   unknown   they cannot be compared: AWS did not answer, or the pair was imported
key_state() {
  local region=$1 name=$2 pem=$3 out fp mine
  if ! out=$(aws ec2 describe-key-pairs --region "$region" --key-names "$name" \
               --query 'KeyPairs[0].KeyFingerprint' --output text 2>&1); then
    [[ $out == *InvalidKeyPair.NotFound* ]] && echo none || echo unknown
    return 0
  fi
  [[ -f $pem ]] || { echo missing; return 0; }
  fp=${out//[[:space:]]/}
  # For a pair AWS created, the fingerprint is the SHA-1 of the private key as
  # PKCS#8 DER: 59 characters. Checked against a real pair on 2026-09-15. An
  # imported pair's is an MD5 of the public key instead, and is not compared.
  if (( ${#fp} != 59 )) || ! command -v openssl >/dev/null 2>&1; then
    echo unknown
    return 0
  fi
  mine=$(openssl pkcs8 -in "$pem" -inform PEM -outform DER -topk8 -nocrypt 2>/dev/null \
           | openssl sha1 -c 2>/dev/null | awk '{print $NF}') || true
  [[ -n $mine && ${mine,,} == "${fp,,}" ]] && echo match || echo mismatch
}

key_words() {
  case $1 in
    missing)  echo "not on this laptop" ;;
    mismatch) echo "not the key pair's private key" ;;
  esac
}

# key_ensure <region> <name> <pem>: a key pair this laptop can log in with.
# Only where no box uses the pair - lib/setup stops a build that would reuse one.
key_ensure() {
  local region=$1 name=$2 pem=$3 state keep
  state=$(key_state "$region" "$name" "$pem")
  case $state in
    match|unknown) return 0 ;;
    missing|mismatch)
      echo "==> replacing key pair $name - $pem is $(key_words "$state")"
      aws ec2 delete-key-pair --region "$region" --key-name "$name" >/dev/null || return 1 ;;
  esac
  if [[ -e $pem ]]; then
    keep="${pem%.pem}-replaced-$(date +%Y%m%d%H%M%S).pem"
    mv "$pem" "$keep" && echo "    the old file is kept as $keep"
  fi
  echo "==> creating key pair -> $pem"
  mkdir -p "$(dirname "$pem")"
  if ! ( umask 077; aws ec2 create-key-pair --region "$region" --key-name "$name" \
           --query KeyMaterial --output text > "$pem" ); then
    rm -f "$pem"
    return 1
  fi
  chmod 600 "$pem"
}

# key_report <region> <name> <pem>: cg check's line. Stops when a box exists that
# this laptop cannot log in to, since replacing the pair would not change that box.
key_report() {
  local region=$1 name=$2 pem=$3 state box short="~/.ssh/${3##*/}"
  state=$(key_state "$region" "$name" "$pem")
  case $state in
    match)   log_as ok "ssh key $short matches the key pair" ;;
    none)    log_as info "no key pair yet - cg init creates one, saved as $short" ;;
    unknown) log_as warn "could not compare $short with the key pair - it is used as it is" ;;
    *)
      box=$(aws ec2 describe-instances --region "$region" \
              --filters "Name=tag:Name,Values=$name" \
                        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
              --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null \
              | grep -v '^None$' || true)
      if [[ -n $box ]]; then
        die "a box exists, but $short is $(key_words "$state"), so this laptop cannot log in to it.
       Copy $short from the laptop that built the box, then: chmod 600 $short
       Or destroy the box from that laptop; cg init here then makes a new key."
      fi
      log_as warn "$short is $(key_words "$state") - cg init replaces the key pair (free), and the .pem on any other laptop stops working" ;;
  esac
}
