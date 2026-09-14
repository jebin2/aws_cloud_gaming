# AWS account setup

The step-by-step path from a fresh AWS account to one that can launch the GPU instance this
project needs. It is written to be followed in order, by a person or with an AI assistant: every
step has the command or console page, **the output that means it passed**, and what to do when it
did not.

Do this first. Two of the steps wait on AWS - here, every quota request was refused first and
granted only after an appeal, and the longest took three to four days after that.

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

**File the request.** Either route opens the same kind of case:

- **Console:** switch the region selector (top right) to your `$REGION` - quotas are per region, and a
  request filed in the wrong one does nothing for you - then open
  <https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-DB2E81BA>
  (Service Quotas → AWS services → Amazon Elastic Compute Cloud (Amazon EC2) → *Running On-Demand G
  and VT instances*), choose **Request increase at account level** and enter the value from step 3.
- **CLI:**

      aws service-quotas request-service-quota-increase --region "$REGION" \
        --service-code ec2 --quota-code L-DB2E81BA --desired-value 4

**Expect it to be refused the first time.** A request filed through Service Quotas - from the
console *or* the CLI - opens a support case whose only text is *"This support case was created by
Service Quotas"*. There is no field for a use case, so the reviewer has nothing to judge. Every
request here was refused first, with the same reply:

> I am sorry but at this time we are unable to approve your service quota increase request. Service
> quotas are put in place to help you gradually ramp up activity and decrease the likelihood of
> large bills due to sudden, unexpected spikes. If you'd like to appeal this decision, please reopen
> this case and provide as detailed a use case as possible.

**Appeal on that same case - this is the step that gets it granted.** Do not file a new request.

1. Open **Support Center → Your support cases** and the case titled *Quota Increase: EC2 Instances*.
2. Choose **Reopen case** / reply.
3. Write the use case. What the successful appeal covered, and why each part is there:
   - **what runs, and why it needs a GPU** - hardware video encoding; software encoding adds latency
     and saturates the vCPUs
   - **the size** - one instance, exactly its vCPU count, never more than one at a time
   - **the usage pattern** - roughly how many hours a month, started and stopped per session
   - **the cost controls already in place**, named concretely
   - **why this region** - measured latency from where you are
   - **what it is not** - not mining, not ML training, not resold compute

   The message that worked is reproduced below, under
   [The appeals we actually sent](#the-appeals-we-actually-sent). Describe **your** setup - a
   reviewer is assessing your account, and a copied description of someone else's will not match it.

You can file in more than one usable region at once. Here Mumbai (`ap-south-1`) and Hyderabad
(`ap-south-2`) were requested together, refused together, appealed with the same message, and
reviewed as separate cases.

**How long, measured here:** requested 2026-09-06 14:59, refused, appealed 15:24. Hyderabad was
granted 2026-09-09 15:35 and Mumbai 2026-09-10 03:44 - three to four days after the appeal. AWS asks
you to allow up to an hour after approval for the new value to take effect.

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

Expect the same refusal, and appeal on the same case the same way. For spot, lead with the argument
that carries most weight: **the on-demand quota is already approved**, so a spot quota of the same
size adds no capacity - it only changes how the same instance is bought. The appeal that worked
says exactly that, and offers to have the on-demand quota reduced to match.

**How long, measured here:** case opened 2026-09-09 17:38, refused 19:13, appealed 19:17, granted
2026-09-10 18:19 - under a day after the appeal.

A quota granted in one region is not granted in another. Mumbai still shows spot `applied=0.0`,
because spot was only ever requested in Hyderabad.

## Step 6 - Verify, don't trust the case status

A support case marked **Resolved**, or a quota request showing **`CASE_CLOSED`**, means the case
was *closed* - **not** that the quota was granted. Every request here shows `CASE_CLOSED`, and each
was refused before it was granted; a request that stays refused closes exactly the same way. Compare the applied value
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

## The appeals we actually sent

Both were sent as replies on the refused case. They are reproduced as written, with three changes
for a public repository: the sender's city is `[your city]`, a case number is a placeholder, and the
AWS staff who replied are not named.

> **They describe this setup as it was in September 2026, and some of it has changed since.** At
> the time the spot plan was a persistent request with `InstanceInterruptionBehavior=stop` on an EBS
> root volume, the budget was $70 with a Budget Action, and the CloudWatch alarm stopped the box.
> Today a spot box is one-time and terminates, the games live in S3, the budget is $57 and the alarm
> is armed only during a session - see [cost-guards.md](cost-guards.md). Write yours about what you
> actually run.

### On-demand: `Running On-Demand G and VT instances` - granted in two regions

```text
Requesting an appeal with detailed use case.

WORKLOAD
Low-latency remote desktop and game streaming for personal use, using
Sunshine (host) and Moonlight (client) over a private Tailscale network.
The GPU is required for NVENC hardware video encoding - encoding a 1080p60
H.265 stream in real time. Software encoding is not viable: it adds 30-40ms
of latency and saturates all vCPUs, which defeats the purpose.

INSTANCE AND SIZE
A single g6.xlarge (4 vCPU, NVIDIA L4). I am requesting exactly 4 vCPUs -
the minimum for one instance. I will never run more than one at a time.

USAGE PATTERN
Roughly 20-25 hours per month. The instance is started on demand for a
session and stopped immediately afterwards. It is not a persistent workload.

COST CONTROLS ALREADY IN PLACE
- AWS Budget "gaming-rig-guard" at $70/month
- Budget Action (APPLY_IAM_POLICY) that automatically denies ec2:RunInstances
  and ec2:StartInstances at 100% of budget
- CloudWatch NetworkOut alarm that stops the instance after 30 minutes idle
- An on-instance watchdog that shuts down after 15 minutes without stream traffic

REGION
Mumbai and Hyderabad are the only AWS regions with acceptable network latency
from my location in [your city] (measured 29ms and 19ms respectively). Other
regions are 40-400ms, which is unusable for interactive streaming.

This is not for cryptocurrency mining, ML training, or resale of compute.
```

AWS's replies, in order: the appeal was escalated to the service team the next day ("I will need to
collaborate with our Internal Service Team to get the approval"), and the quota was granted -
Hyderabad on 2026-09-09, Mumbai on 2026-09-10 - with "Your new quota is 4 vCPUs, and it will be
available within the next hour."

### Spot: `All G and VT Spot Instance Requests` - granted the next day

```text
Hello,

Thank you for the response. I would like to appeal this decision and provide
the detailed use case that was missing from the original request.

The original case was created automatically by the Service Quotas console,
which submitted it with the placeholder text "This support case was created by
Service Quotas" and no use case description. The Service Quotas API does not
accept a justification field, so no detail was ever attached for your team to
assess. The full context is below.

USE CASE

A single-user personal remote desktop and game-streaming workstation. One
g6.xlarge instance (4 vCPU, 1x NVIDIA L4) running Sunshine, streamed over a
private Tailscale network to my own devices. This is entirely personal use.
Nothing is resold, shared, or offered as a service to third parties.

WHY SPOT IS APPROPRIATE FOR THIS WORKLOAD

Sessions are short, initiated manually by me, and completely tolerant of
interruption. I launch with InstanceInterruptionBehavior=stop, so a capacity
reclaim stops the instance and preserves the EBS root volume rather than
destroying it. If spot capacity is unavailable when I want to use the machine,
I simply do not use it that day. There is no availability requirement of any
kind.

THIS REQUEST DOES NOT INCREASE MY CAPACITY

I already hold an approved quota of 4 vCPU for "Running On-Demand G and VT
instances" in ap-south-2 (approved 2026-09-09, case <on-demand case id>). I run
exactly one instance at a time.

Granting 4 vCPU of spot quota would not raise my maximum concurrent vCPU count
above what is already approved. It only allows the same single instance to run
under a less expensive purchase model. I am happy for my on-demand quota to
remain at 4, or to be reduced correspondingly, if that helps.

COST CONTROLS ALREADY IN PLACE

I understand service quotas exist to prevent unexpected spend. My setup was
built specifically around that concern and already has four independent
safeguards:

1. An on-host idle watchdog that shuts the instance down after 15 minutes with
   no stream traffic.
2. A CloudWatch NetworkOut alarm that stops the instance after 30 minutes of
   inactivity, as a backstop if the watchdog fails.
3. A billing alarm with email notification against a monthly budget.
4. instance-initiated-shutdown-behavior set to stop, so an in-guest shutdown
   parks the instance rather than terminating it.

The account has been on a paid plan since 2026-09-09 and has a valid payment
method on file.

I would be grateful if you could reconsider this request. Please let me know if
any further detail would help.

Thank you for your time.
```

AWS's reply the next day: "We were able to process and apply the limit increase that you have
requested ... Region: Asia Pacific (Hyderabad) ... New limit value: 4. Note: Your new quota will be
available within the next hour."

## For AI assistants following this

- **Safe to run yourself:** every `aws ... describe-*`, `get-*` and `list-*` command above, and
  `./cg check`. They are read-only and free.
- **Leave to the person:** step 2's plan upgrade (irreversible, root user - do not run
  `aws freetier upgrade-account-plan`), and **sending** the appeals in steps 4 and 5. An appeal is a
  statement about the person's own workload and account, made to AWS in their name.
- **You can help with:** filing the initial quota request once the person agrees, and **drafting**
  the appeal from the structure in step 4 and the messages below - with the person's real details,
  never these ones.
- **Report outcomes by the applied quota value**, never by a case status.
- Waiting on AWS is normal here - days, not minutes. Check again later rather than re-filing
  immediately, unless the request was refused.
