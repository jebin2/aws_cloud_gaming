# Getting a GPU quota out of AWS

A new AWS account can launch **zero** GPU instances. Both numbers start at 0:

| quota | code | what it covers |
|---|---|---|
| Running On-Demand G and VT instances | `L-DB2E81BA` | a g4dn/g5/g6 box you pay full price for |
| All G and VT Spot Instance Requests | `L-3819A6DF` | the same box at the spot price |

They are separate. Having one does not give you the other, and a build needs
whichever purchase model it is using.

    cg quota                     what you have, and whether it covers one box
    cg quota request ondemand    ask for exactly what one box needs
    cg quota appeal ondemand     the text that gets it approved

## What actually happens

This is the shape of every request this repo has made, including the ones that
worked:

```
you ask for 4 vCPU
      │  minutes
      ▼
"I am sorry but at this time we are unable to approve your service quota
 increase request. ... If you'd like to appeal this decision, please reopen
 this case and provide as detailed a use case as possible."
      │  you reopen the SAME case with the appeal below
      ▼
"I will need to collaborate with our Internal Service Team to get the
 approval. So I went ahead and submitted the request."
      │  2-4 days
      ▼
"I'm glad to inform you that your instance limit ... has been approved.
 Your new quota is 4 vCPUs, and it will be available within the next hour."
```

**The automatic refusal is not a rejection.** It is the first step of the
process. Nothing is wrong with your account, and asking again from scratch does
not help - AWS refuses duplicate requests. The appeal on the open case is the
step that gets a human involved, and a human is who approves it.

## What cg can and cannot do

`cg quota request` submits through the Service Quotas API, which is free and
works on any support plan. It cannot post the appeal: that is a support case
correspondence, and the Support API needs a Business or Enterprise plan. On the
Basic plan the API answers `SubscriptionRequiredException`.

So cg writes the appeal and opens the case; you paste and send. That is also
the right division of labour - the appeal is a letter to a person, and it works
because it is specific.

## The appeal that worked

`cg quota appeal` fills this in from your own rig: the instance type, the
measured latency from `cg sweep`, your budget, your watchdog timeouts. Every
number in it is checkable, which is why the agent escalated it.

```
Requesting an appeal with detailed use case.

WORKLOAD
<what you are doing, and why a GPU is required rather than nice to have>

INSTANCE AND SIZE
A single <type> (<n> vCPU). I am requesting exactly <n> vCPUs - the
minimum for one instance. I will never run more than one at a time.

USAGE PATTERN
<how often, how long, started and stopped rather than always on>

COST CONTROLS ALREADY IN PLACE
<budget, alarms, watchdogs - the things that make a runaway bill impossible>

REGION
<region> is <n>ms from me. Latency is the whole constraint for interactive
streaming: anything above about 40ms is unusable.

This is not for cryptocurrency mining, ML training, or resale of compute.
```

Five things carried the weight:

1. **Exactly what is needed, and saying so.** 4 vCPU is one instance. Asking for
   64 invites a conversation about what you plan to do with 16 GPUs.
2. **Why the GPU is required**, not preferred. NVENC encodes 1080p60 in real
   time; software encoding adds 30-40ms and saturates the CPU.
3. **Cost controls that already exist.** The quota is there to stop surprise
   bills - showing that you have solved that problem yourself removes the
   reason for the refusal.
4. **Latency as the reason for the region.** It explains why "use another
   region" is not an answer, with numbers.
5. **The last line.** The refusal is written by someone who sees mining and
   resale requests all day.

## Doing it by hand

1. <https://console.aws.amazon.com/servicequotas/home> → EC2 → the quota above
   → Request increase at account level → 4.
2. Wait for the refusal email. It carries a case id.
3. <https://console.aws.amazon.com/support/home#/case/?displayId=CASE_ID> →
   Reply → paste the appeal → send.
4. Wait. Two to four days is normal. The approval says "available within the
   next hour", and it is.

## If it is refused again

Reply on the same case asking what specifically is missing. A second refusal
with no detail is worth escalating politely; a request that has been open for
more than a week with no reply is worth a new case referencing the old one.
