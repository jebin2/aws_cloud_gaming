#!/usr/bin/env bash
# Which region a bucket is actually in.
#
# Not the same question as "which region is configured", and conflating them
# cost a 30-minute build. `cg config set GAME_REGION ap-south-1` moved the box,
# but the bucket name was then derived from the account and the host alone, so
# the move found the SAME bucket, still sitting in ap-south-2. The region is in
# the name now (cg_bucket_name below), but an older bucket can still be asked
# about from another region, so the question stays.
#
# `aws s3 cp` survives that: the CLI follows S3's redirect and retries against
# the right region, so the upload worked and looked fine. `aws s3 presign` does
# not - it signs for whatever --region it is given, and a URL signed for
# ap-south-1 against an ap-south-2 bucket is rejected with HTTP 400. The box
# got that 400 for its host bundle in the first 30 seconds, user-data aborted
# before tailscale was installed, and the build then spent half an hour waiting
# for a node that could never appear.
#
# Free: get-bucket-location is not charged.

# s3_bucket_region <bucket> - the region, or nothing if it cannot be read.
s3_bucket_region() {
  local r
  r=$(aws s3api get-bucket-location --bucket "$1" \
        --query LocationConstraint --output text 2>/dev/null) || return 1
  # us-east-1 predates the location constraint and reports it as empty.
  [[ -z $r || $r == None || $r == null ]] && r=us-east-1
  printf '%s' "$r"
}

# cg_bucket_name <account> <host> <region> - the archive bucket's derived name.
#
# THE one copy. It lived in both lib/library-aws.sh and lib/cloud-watchdog.sh,
# guarded by a test asserting the two agreed - and when the region went into the
# hash, that test caught the drift immediately. A formula kept in two places
# will drift again, so there is now one and both callers use it.
#
# The region is in the hash because a bucket IS regional. Hashed rather than
# spelling out the account number, which ends up in URLs and logs. Names are
# globally unique, so it cannot just be "cg-library".
# cg_bucket_ours <bucket> <region> <account> <host> - 0 when cg made it for this
# account and host: the name it derives for the bucket's own region, or the form
# from before the region went into the hash. The cg-library- prefix alone is
# anyone's; the watchdog applies the same rule (own_buckets).
cg_bucket_ours() {
  [[ $1 == "$(cg_bucket_name "$3" "$4" "$2")" ]] && return 0
  [[ $1 == "cg-library-$(printf '%s' "$3-$4" | sha256sum | cut -c1-12)" ]]
}

cg_bucket_name() {
  printf 'cg-library-%s' "$(printf '%s' "$1-$2-$3" | sha256sum | cut -c1-12)"
}
