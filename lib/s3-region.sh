#!/usr/bin/env bash
# Which region a bucket is actually in.
#
# Not the same question as "which region is configured", and conflating them
# cost a 30-minute build. `cg config set GAME_REGION ap-south-1` moves the box,
# but the bucket name is derived from the account and the host - not the region -
# so a move finds the SAME bucket, still sitting in ap-south-2.
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
