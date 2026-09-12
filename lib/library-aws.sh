#!/usr/bin/env bash
# Ensures the durable half of the game library: an S3 bucket to hold it, and an
# EC2 instance profile that lets the box read and write that one bucket.
#
# Why S3 and not the EBS volume this replaces: a 160 GB gp3 volume bills
# INR 1,284/month whether or not the box exists, and it pins every launch to one
# AZ because EBS cannot cross one. The same library in S3 Standard is
# INR ~310/month and unpins the AZ. Measured on a g6.xlarge, S3 restores at
# 235 MB/s and uploads at 508 MB/s, so ~140 GB comes back in about 10 minutes -
# which is why the restore is started at the top of bootstrap and runs while the
# NVIDIA driver installs, rather than being something you wait for afterwards.
#
# Credentials: an instance ROLE, not an access key. The box is the one machine
# here that can borrow an identity from EC2, so it should - there is no secret to
# leak, rotate or accidentally commit. (The off-site watchdog runs outside AWS
# and genuinely has no role to borrow; that is why it still uses a key.)
set -euo pipefail

cd "$(dirname "$0")/.."

REGION="${GAME_REGION:-ap-south-2}"
TS_HOST="${GAME_TS_HOST:-gamevps}"
ROLE="${TS_HOST}-box"
PROFILE="$ROLE"

# STDERR, not stdout. This script's stdout IS its return value - the bucket
# name - and provision.sh substitutes that straight into user-data. Logging to
# stdout made $S3_BUCKET a multi-line blob, which sed rejected as an
# unterminated 's' command. Any script whose output is consumed has exactly one
# thing on stdout.
quiet() { [[ ${LIBRARY_QUIET:-0} == 1 ]]; }
note() { quiet || echo "    $*" >&2; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Bucket names are globally unique, so it cannot just be "cg-library". Derived
# from the account and host so it is the SAME name every time this runs - and
# hashed rather than embedding the account number, which does not belong in a
# name that is effectively public.
if [[ -n ${GAME_S3_BUCKET:-} ]]; then
  BUCKET="$GAME_S3_BUCKET"
else
  suffix=$(printf '%s' "$ACCOUNT-$TS_HOST" | sha256sum | cut -c1-12)
  BUCKET="cg-library-$suffix"
fi

# --- bucket -------------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  note "bucket $BUCKET exists"
else
  note "creating bucket $BUCKET in $REGION"
  create_bucket() {
    # us-east-1 is the one region that rejects a LocationConstraint.
    if [[ $REGION == us-east-1 ]]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null 2>&1
    fi
  }
  # The name is derived from the account, so `cg destroy --all` followed by
  # `cg init` recreates the SAME name - and S3 refuses that for a short while
  # after a delete with OperationAborted, "a conflicting conditional operation
  # is currently in progress". It is a propagation delay, not a failure, so it
  # is waited out here rather than surfaced as an init that works on the second
  # try and looks flaky on the first.
  for attempt in 1 2 3 4 5 6 7 8; do
    create_bucket && break
    if (( attempt == 8 )); then
      echo "could not create bucket $BUCKET after $attempt attempts." >&2
      echo "If you just ran 'cg destroy --all', S3 can hold the name for a few" >&2
      echo "minutes. Wait and run cg init again; nothing else is wrong." >&2
      exit 1
    fi
    note "S3 has not released the name yet (attempt $attempt) - waiting 15s"
    sleep 15
  done
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
fi

# Abandoned multipart uploads bill as storage forever and appear in no listing -
# the classic S3 leak. A 140 GB push that dies halfway would otherwise cost real
# money invisibly.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{"Rules":[{
      "ID":"abort-incomplete-multipart",
      "Status":"Enabled",
      "Filter":{},
      "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":3}}]}' >/dev/null 2>&1 \
  || note "could not set the lifecycle rule (not fatal)"

# --- role the box assumes ------------------------------------------------------
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  note "creating role $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --description "cloud_gaming box: read/write its own game library bucket" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"ec2.amazonaws.com"},
        "Action":"sts:AssumeRole"}]}' >/dev/null
fi

# put-role-policy overwrites, so this also repairs a policy edited by hand.
# Deliberately narrow: this one bucket, nothing else in the account. The worst a
# compromised box can do to AWS is damage its own game library - which S3
# versioning is NOT enabled to protect, because a versioned 140 GB library
# doubles the bill. The guards in cg-library are what protect it.
aws iam put-role-policy --role-name "$ROLE" --policy-name library-rw \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],
     \"Resource\":\"arn:aws:s3:::$BUCKET\"},
    {\"Effect\":\"Allow\",
     \"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",
                 \"s3:AbortMultipartUpload\",\"s3:ListMultipartUploadParts\"],
     \"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" >/dev/null

# --- instance profile ----------------------------------------------------------
# An instance profile is a separate object that wraps the role; run-instances
# takes the profile, not the role, and the two are easy to confuse.
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
  note "creating instance profile $PROFILE"
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null
fi
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE" \
      --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null | grep -qx "$ROLE"; then
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" \
    --role-name "$ROLE" >/dev/null 2>&1 || true
fi

# Remember the bucket so every later run resolves the same name without another
# sts call, and so `cg library` can find it.
touch .env
tmp=$(mktemp)
grep -vE '^GAME_S3_BUCKET=' .env > "$tmp" 2>/dev/null || true
echo "GAME_S3_BUCKET=$BUCKET" >> "$tmp"
cat "$tmp" > .env
rm -f "$tmp"
chmod 600 .env

echo "$BUCKET"
