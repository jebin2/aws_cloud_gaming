# AWS account setup

The step-by-step path from a fresh AWS account to one that can launch the GPU instance this
project needs. It is written to be followed in order, by a person or with an AI assistant: every
step has the command or console page, **the output that means it passed**, and what to do when it
did not.

Do this first. Two of the steps wait on AWS, and one of those waits took three days here.

> Every "expected output" below is real output from the account this project was built on
> (`ap-south-2`, `g6.xlarge`), captured on 2026-09-15. Substitute your own region and instance type
> where they differ.

## Why there are several steps

Three things must all be true, and **none of them implies another**:

| Gate | What it controls | Default on a new account |
|---|---|---|
| Account plan | whether GPU instance *types* can be launched at all | Free Plan - **no GPU types** |
| On-demand GPU quota `L-DB2E81BA` | how many vCPUs of G/VT instances may run on demand | **0** |
| Spot GPU quota `L-3819A6DF` | how many vCPUs of G/VT spot instances may run | **0** |

None of them shows up in `aws ec2 run-instances --dry-run`, which checks permissions only and
reports "Request would have succeeded" right before a real launch fails. Check each gate
directly, as below.

## Before you start

- The AWS CLI v2 installed and configured with credentials for the account
  (`aws sts get-caller-identity` prints your account id). See [getting-started.md](getting-started.md#aws-credentials).
- Access to the AWS console as the **root user** for step 2. The rest can be an IAM user with
  Service Quotas and EC2 read access.
- Set these for the commands below:

      REGION=ap-south-2        # the region you will build in
      TYPE=g6.xlarge           # the instance type (GAME_INSTANCE_TYPE)

## Step 1 - Choose a region that offers the instance type

Not every region has every GPU type. `ap-south-2`, for example, has no `g4dn` at all, and quotas
are **per region**, so choose before requesting anything.

    aws ec2 describe-instance-type-offerings --region "$REGION" --location-type region \
      --filters Name=instance-type,Values="$TYPE" --query 'InstanceTypeOfferings[].InstanceType' --output text

**Passes when** it prints the type:

    g6.xlarge

**If it prints nothing**, the type is not offered there. List the GPU types that are:

    aws ec2 describe-instance-type-offerings --region "$REGION" \
      --filters Name=instance-type,Values='g*' --query 'InstanceTypeOfferings[].InstanceType' --output text

Also note **which availability zones** have it. Spot capacity runs out per zone, so fewer zones
means fewer fallbacks:

    aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
      --filters Name=instance-type,Values="$TYPE" --query 'InstanceTypeOfferings[].Location' --output text

    ap-south-2b	ap-south-2a            # offered in 2a and 2b, not 2c

## Step 2 - Move the account to a paid plan

A new-style AWS **Free Plan** account can launch only free-tier-eligible instance types. A GPU
launch fails with `not eligible for Free Tier` - whatever your quota says, and the message does not
point at the plan. Credits do not help: they decide who pays, not what you may run.

**Check:**

    aws freetier get-account-plan-state --region us-east-1 \
      --query '{plan:accountPlanType,status:accountPlanStatus}' --output json

**Passes when:**

    {"plan": "PAID", "status": "ACTIVE"}

**If it says `FREE`:** sign in to the console as the **root user**, open
[Billing and Cost Management](https://console.aws.amazon.com/billing/), and upgrade the account to
a paid plan.

- **The upgrade cannot be undone.** Read what the console says before confirming.
- Existing credits were kept here - they rose from $120 to $140 on upgrade - but that may not hold
  for every account or promotion.
- There is a CLI command for it (`aws freetier upgrade-account-plan`). Because the change is
  irreversible, do it in the console, deliberately, rather than from a script.

Run the check again; continue once it shows `PAID`.

## Step 3 - Work out how much quota to ask for

GPU quotas are measured in **vCPUs, not instances**. Ask for the vCPU count of the instance type:

    aws ec2 describe-instance-types --region "$REGION" --instance-types "$TYPE" \
      --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text

    4

So a `g6.xlarge` needs **4**. That is the value requested and granted here, for both quotas. Asking
for exactly what one instance needs is the easiest request to justify; ask for more only if you
really will run more than one box at once.

## Step 4 - Request the on-demand GPU quota

**Check the current value first:**

    aws service-quotas get-service-quota --region "$REGION" --service-code ec2 \
      --quota-code L-DB2E81BA --query '{name:Quota.QuotaName,value:Quota.Value}' --output json

    {"name": "Running On-Demand G and VT instances", "value": 0.0}     # before the request

**Request it in the console, not the CLI.** `aws service-quotas request-service-quota-increase`
has no field for a use case, so the support case it opens says only *"This support case was created
by Service Quotas"* - and a request with no justification is usually refused. That is exactly what
happened to this project's first spot request.

1. Sign in to the console and **switch the region selector** (top right) to your `$REGION`.
   Quotas are per region; a request filed in the wrong one does nothing for you.
2. Open the quota directly:
   <https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-DB2E81BA>
   (or Service Quotas → AWS services → Amazon Elastic Compute Cloud (Amazon EC2) → search
   *Running On-Demand G and VT instances*).
3. Choose **Request increase at account level**, and enter the value from step 3 (`4`).
4. If the console offers a description or opens a support case, give a real use case. For example:

   > Personal cloud gaming workstation. One g6.xlarge (4 vCPU, NVIDIA L4) in ap-south-2, running
   > Ubuntu with a streaming server, used interactively a few hours at a time and terminated
   > after each session. The instance is protected by an on-host idle watchdog, a CloudWatch alarm,
   > an off-site watchdog and an AWS Budget, so it cannot run unattended. 4 vCPU is exactly one
   > instance; no additional capacity is needed.

   Adjust it to what you will actually do - an honest, specific request is the point, not these
   words.

**How long:** filed 2026-09-06, granted 2026-09-09 here - three days.

## Step 5 - Request the spot GPU quota

Spot has a **separate** quota, also 0 by default. An approved on-demand quota tells you nothing
about it; a spot launch without it fails with `MaxSpotInstanceCountExceeded`. Spot is roughly a
quarter of the on-demand price (measured here: INR 19.8/hour against INR 85/hour), which is why
this project defaults to it - see [cost.md](cost.md).

Spot is optional. Without it `cg init` falls back to on-demand by itself and says so:

    spot quota 0 vCPU cannot cover g6.xlarge (4) - using on-demand
      spot is ~4x cheaper; request quota L-3819A6DF to enable it

**Wait until step 4 is granted**, then request spot the same way, in the same region:

<https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-3819A6DF>
(*All G and VT Spot Instance Requests*), value `4`.

The strongest argument for this one is that **the on-demand quota is already approved**, so a spot
quota of the same size adds no capacity - it only changes how the same instance is bought:

> Requesting spot capacity equal to my already-approved on-demand G and VT quota (4 vCPU in
> ap-south-2) so the same single g6.xlarge can run as a spot instance at lower cost. This does not
> increase my maximum concurrent capacity; it only changes the purchase model. The workload is a
> personal, interactive cloud gaming instance that is terminated after each session and guarded by
> idle watchdogs and an AWS Budget.

**If it is refused, re-file.** Spot is refused more often than on-demand. Here the first request
(filed from the CLI, so with no use case) was refused on 2026-09-09, and a request with a real use
case was granted the next day, 2026-09-10.

## Step 6 - Verify, don't trust the case status

A support case marked **Resolved**, or a quota request showing **`CASE_CLOSED`**, means the case
was *closed* - **not** that the quota was granted. Both of this project's requests show
`CASE_CLOSED`, and both were granted; a refused one closes the same way. Compare the applied value
with the default instead:

    for q in L-DB2E81BA L-3819A6DF; do
      printf '%s  applied=%s  default=%s\n' "$q" \
        "$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code $q --query Quota.Value --output text)" \
        "$(aws service-quotas get-aws-default-service-quota --region "$REGION" --service-code ec2 --quota-code $q --query Quota.Value --output text)"
    done

**Passes when** each quota you requested is at least the vCPU count from step 3:

    L-DB2E81BA  applied=4.0  default=0.0
    L-3819A6DF  applied=4.0  default=0.0

To see your requests and their status:

    aws service-quotas list-requested-service-quota-change-history --region "$REGION" --service-code ec2 \
      --query 'RequestedQuotas[?QuotaCode==`L-DB2E81BA` || QuotaCode==`L-3819A6DF`].[QuotaCode,DesiredValue,Status,Created]' \
      --output text

Track the conversation on a case in the console's **Support Center**. `aws support` commands need a
paid Support plan and fail with `SubscriptionRequiredException` without one.

## Step 7 - Let `cg check` confirm everything

With `.env` filled in (see [getting-started.md](getting-started.md)), run the preflight. It checks
the plan, the region, the instance type and the right quota for the purchase model, and creates
nothing:

    ./cg check

**Passes when** it ends like this:

    ╭─ 🧭 preflight
    │  · account plan: PAID
    │  · spot quota 4 vCPU covers g6.xlarge (4)

    🎉 preflight passed - nothing was created.

**What its failures mean:**

| `cg check` says | Go back to |
|---|---|
| `this AWS account is on the Free Plan, which can only launch free-tier-eligible instance types` | step 2 |
| `'<region>' is not a region you can use` | step 1, or `GAME_REGION` in `.env` |
| `<type> is not offered in <region>` | step 1 |
| `spot GPU quota in <region> is 0 vCPU; <type> needs 4` | step 5, or unset `GAME_SPOT` to use on-demand |
| `on-demand GPU quota in <region> is 0 vCPU; <type> needs 4` | step 4 |

Once it passes, `./cg init` builds the box.

## For AI assistants following this

- **Safe to run yourself:** every `aws ... describe-*`, `get-*` and `list-*` command above, and
  `./cg check`. They are read-only and free.
- **Leave to the person:** step 2's plan upgrade (irreversible, root user) and the quota requests in
  steps 4 and 5 (they need a console session, and a real use case only the person can give).
  Do not substitute `aws service-quotas request-service-quota-increase` or
  `aws freetier upgrade-account-plan` for them.
- **Report outcomes by the applied quota value**, never by a case status.
- Waiting on AWS is normal here - days, not minutes. Check again later rather than re-filing
  immediately, unless the request was refused.
