# AWS Cost Calculation, Usage Identification & Cost Leakage Audit Report

**Target Codebase:** `cloud_gaming` CLI (`cg`), helper libraries (`lib/`), on-host daemons (`host/`), cloud watchdog Lambda (`lambda/`), and desktop app (`app/`).  
**Audit Focus:** Cost calculation accuracy, AWS usage metric identification, and cost leakage risks.

---

## Executive Summary

| Category | Status | Primary Findings | Financial Impact |
| :--- | :---: | :--- | :--- |
| **Cost Calculation** | ❌ **Flawed** | • Snapshot costs underestimated by **456%** ($0.0125 vs $0.057/GB-mo)<br>• Spot compute "not yet billed" overestimated by **~480%** (uses OnDemand rate)<br>• Disk storage formula assumes volume existed all month (`day/30`)<br>• Hardcoded exchange rate (`INR 88` vs real `94.95`) understates rupees by **~7.5%** | Distorts budgeting, underreports standby storage costs, and miscalculates live session burn. |
| **Usage Identification** | ⚠️ **Inaccurate in Edge Cases** | • `split('-', 1)` string parsing breaks on non-prefixed usage types (e.g. `us-east-1` or global DataTransfer), dumping egress into "other"<br>• Account-wide Cost Explorer queries lack `REGION` or service filtering, contaminating bills if account has other AWS resources<br>• CloudWatch CPU queries single instance ID, ignoring prior month sessions | Egress and storage misclassified; unrelated account costs pollute gaming totals. |
| **Cost Leakage** | 🚨 **High Risk** | • **Stopped on-demand box leak cascade**: stopped boxes are never auto-terminated, root volume bills $4.56/mo forever, and S3 archive expiry is permanently suppressed (~$8.56/mo silent leak)<br>• Incomplete multipart uploads block bucket deletion in `cg destroy --all`<br>• `destroy_all` deletes ANY unattached volume in region | Can result in indefinite recurring monthly charges after user thinks they stopped or destroyed. |

---

## 1. Cost Calculation Accuracy Audit

### 1.1. EBS Snapshot & Image Underestimation (456% Error)
* **Code Reference:** [`lib/rates.sh#L13`](file:///home/jebin/cloud_gaming/lib/rates.sh#L13), [`lib/game#L323-L326`](file:///home/jebin/cloud_gaming/lib/game#L323-L326), [`lib/setup#L581`](file:///home/jebin/cloud_gaming/lib/setup#L581)
* **The Bug:**
  In [`lib/rates.sh`](file:///home/jebin/cloud_gaming/lib/rates.sh#L13), snapshot pricing is configured as:
  ```bash
  CG_SNAPSHOT_USD_GB_MONTH="${CG_SNAPSHOT_USD_GB_MONTH:-0.0125}"
  ```
  [`lib/game`](file:///home/jebin/cloud_gaming/lib/game#L326) tells the user:
  > *"It costs ~10% of the volume's monthly price."*
* **AWS Reality:**
  $0.0125/GB-month is the AWS **EBS Snapshot Archive tier** price. However, images created via `aws ec2 create-image` land in the **Standard Snapshot Tier**.
  - In `ap-south-2` (Hyderabad), Standard EBS Snapshot storage is **$0.057 per GB-month**.
  - In `us-east-1` (N. Virginia), Standard EBS Snapshot storage is **$0.050 per GB-month**.
* **Code Contradiction:**
  In [`cg#L1320`](file:///home/jebin/cloud_gaming/cg#L1320) (`cmd_snapshot`), the author used `mo = gb * 0.05`, but in [`lib/rates.sh`](file:///home/jebin/cloud_gaming/lib/rates.sh#L13), [`lib/setup`](file:///home/jebin/cloud_gaming/lib/setup#L581), and [`docs/cost.md`](file:///home/jebin/cloud_gaming/docs/cost.md#L13), it was hardcoded as `$0.0125`.
* **Impact:**
  For a 50 GB saved image, the codebase estimates **$0.625/month**, while AWS actually bills **$2.85/month** in `ap-south-2`. The real charge is **4.56x higher** than reported.

---

### 1.2. Spot "Not Yet Billed" Compute Overestimated by ~480%
* **Code Reference:** [`lib/setup#L653-L661`](file:///home/jebin/cloud_gaming/lib/setup#L653-L661), [`lib/setup#L683-L684`](file:///home/jebin/cloud_gaming/lib/setup#L683-L684)
* **The Bug:**
  In `cost()`, `rate` is extracted using the Pricing API:
  ```python
  # Always extracts terms["OnDemand"]!
  print([x["pricePerUnit"]["USD"] for t in d["terms"]["OnDemand"].values() 
         for x in t["priceDimensions"].values()][0])
  ```
  Then compute cost is computed as:
  ```bash
  c = h * r;  # where r is OnDemand rate ($0.9664/hr)
  ```
* **AWS Reality:**
  Spot is the primary default for this project. Spot for `g6.xlarge` runs at **$0.19 – $0.21/hr**.
* **Impact:**
  If a user runs a spot box for 10 hours, the "not yet billed" estimate shows **$9.66** instead of **~$2.00**, causing false panic that spot savings are not working.

---

### 1.3. Inaccurate Accrual Formula for Disk Storage in `cg cost`
* **Code Reference:** [`lib/setup#L683`](file:///home/jebin/cloud_gaming/lib/setup#L683)
* **The Bug:**
  ```awk
  s = g * ebs * (day / 30.0);
  ```
  Here `g` is `disk_gb = sum(Volumes[].Size)` (the currently existing volumes).
* **Flaw:**
  - If a user launches a spot box on day 25 of the month for 1 hour, `g = 50 GB`. The formula charges `50 * 0.0912 * (25 / 30) = $3.80` as the estimated storage cost so far. In reality, a 1-hour spot volume costs **$0.0063**.
  - Conversely, once the spot box is destroyed, `g = 0`, so the estimate drops to **$0.00**, wiping out any visibility of storage costs until Cost Explorer catches up 24h later.

---

### 1.4. Hardcoded Rupee Conversion Rate (`88` vs `94.95`)
* **Code Reference:** [`lib/cost-report.py#L33`](file:///home/jebin/cloud_gaming/lib/cost-report.py#L33), [`lib/cost-daily.py#L15`](file:///home/jebin/cloud_gaming/lib/cost-daily.py#L15), [`lambda/cloud_watchdog.py#L63`](file:///home/jebin/cloud_gaming/lambda/cloud_watchdog.py#L63), [`lib/aws-setup.sh#L94`](file:///home/jebin/cloud_gaming/lib/aws-setup.sh#L94), [`host/cg-library#L641`](file:///home/jebin/cloud_gaming/host/cg-library#L641)
* **The Bug:**
  While [`lib/rates.sh`](file:///home/jebin/cloud_gaming/lib/rates.sh#L23-L43) was designed to fetch and cache dynamic forex rates (currently **94.95 INR/USD**), almost all downstream Python scripts and shell utilities hardcode `88`:
  - `lib/cost-report.py`: `c * 88`, `tot * 88`, `od_c * 88`, `sp_c * 88`.
  - `lib/cost-daily.py`: `INR = 88`.
  - `lambda/cloud_watchdog.py`: `INR_PER_USD = 88`.
  - `lib/aws-setup.sh`: `USD=$(awk -v i="$BUDGET_INR" 'BEGIN{printf "%.0f", i/88}')`.
* **Impact:**
  All rupee figures across reports and daily breakdowns are **understated by ~7.5% - 8%**. For example, a $50 spend is shown as ₹4,400 instead of ₹4,748.

---

### 1.5. Missing Public IPv4 Fee ($0.005/hr) in Pre-Billing Estimates
* **Code Reference:** [`lib/setup#L681-L689`](file:///home/jebin/cloud_gaming/lib/setup#L681-L689)
* **The Bug:**
  AWS charges $0.005/hr for public IPv4. While defined in [`lib/rates.sh#L46`](file:///home/jebin/cloud_gaming/lib/rates.sh#L46) (`CG_IPV4_USD_HOUR`), it is omitted from the hourly estimate calculation in `lib/setup cost`.

---

## 2. AWS Usage Identification Audit

### 2.1. String Split Bug on Non-Prefixed AWS Usage Types
* **Code Reference:** [`lib/cost-daily.py#L19-L29`](file:///home/jebin/cloud_gaming/lib/cost-daily.py#L19-L29)
* **The Logic:**
  ```python
  def bucket(usage_type):
      u = usage_type.split("-", 1)[-1]
      if u.startswith(("BoxUsage", "SpotUsage")):        return "compute"
      if u.startswith("DataTransfer-Out-Bytes"):         return "egress"
      if u.startswith(("TimedStorage", "Requests-Tier")): return "s3"
      if "VolumeUsage" in u or "SnapshotUsage" in u:     return "disk"
      if u.startswith("APIRequest"):                     return "api"
      return "other"
  ```
* **The Failure:**
  In `us-east-1` (or for global AWS usage items), AWS Cost Explorer does **not** prepend a region code with a hyphen.
  - `DataTransfer-Out-Bytes.split("-", 1)[-1]` produces `"Out-Bytes"` (splits on the hyphen inside `DataTransfer`).
    - Does `"Out-Bytes".startswith("DataTransfer-Out-Bytes")`? **False!**
    - Classified as: `"other"` instead of `"egress"`.
    - In `as_json` ([`lib/cost-daily.py#L150`](file:///home/jebin/cloud_gaming/lib/cost-daily.py#L150)), `out_gb` is never incremented, reporting **0 GB egress**!
  - `TimedStorage-ByteHrs.split("-", 1)[-1]` produces `"ByteHrs"`.
    - Classified as: `"other"` instead of `"s3"`.
  - `Requests-Tier1.split("-", 1)[-1]` produces `"Tier1"`.
    - Classified as: `"other"` instead of `"s3"`.

---

### 2.2. Unfiltered Account-Wide Cost Explorer Query
* **Code Reference:** [`lib/setup#L509-L515`](file:///home/jebin/cloud_gaming/lib/setup#L509-L515), [`lib/setup#L714-L720`](file:///home/jebin/cloud_gaming/lib/setup#L714-L720)
* **The Query:**
  ```bash
  aws ce get-cost-and-usage --region us-east-1 \
    --time-period "Start=...,End=..." \
    --granularity DAILY --metrics UnblendedCost UsageQuantity \
    --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE
  ```
* **The Flaw:**
  The filter **only** specifies `RECORD_TYPE=Usage`. It does **not** filter by:
  - `REGION`
  - `SERVICE`
  - Cost Allocation Tags (`tag:Name` or `tag:Project`)
* **Impact:**
  If the user's AWS account has any other resource (e.g., a `t3.micro` EC2 in `us-east-1`, another S3 bucket, Route 53, or an RDS instance), all those usage types will be pulled into the cloud gaming breakdown. Unrelated EC2 instances will appear under compute hours, and unrelated S3 storage will be lumped into game storage.

---

### 2.3. Single Instance Limitation in CloudWatch Runtime Metric
* **Code Reference:** [`lib/setup#L668-L672`](file:///home/jebin/cloud_gaming/lib/setup#L668-L672)
* **The Logic:**
  ```bash
  hours=$(aws cloudwatch get-metric-statistics --region "$REGION" --namespace AWS/EC2 \
    --metric-name CPUUtilization --dimensions "Name=InstanceId,Value=${id:-$GAME_INSTANCE_ID}" \
    --start-time "$(date -u +%Y-%m-01)T00:00:00" ... --period 3600 --statistics Average \
    --query 'length(Datapoints)' --output text 2>/dev/null || echo 0)
  ```
* **The Flaw:**
  It explicitly queries only **one** instance ID (`${id:-$GAME_INSTANCE_ID}`). Because spot boxes are ephemeral and destroyed after every session, each gaming session has a unique instance ID.
* **Impact:**
  Past sessions within the current month are completely dropped from `hours`. If no box exists at the moment of running `cg cost`, `hours` is 0, leaving users blind to all unbilled sessions run that day.

---

### 2.4. `app.js` "Today" Card Misattribution
* **Code Reference:** [`app/renderer/app.js#L754-L756`](file:///home/jebin/cloud_gaming/app/renderer/app.js#L754-L756)
* **The Logic:**
  ```javascript
  const today = (m.days || []).at(-1);
  $('c-today').textContent = today ? INR(today.total * inr) : '—';
  ```
* **The Flaw:**
  `m.days` only contains days with billed activity > $0.0005. Because Cost Explorer lags by ~24 hours, today is never present in `m.days`. As a result, `m.days.at(-1)` is actually **yesterday** (or the last active day). The UI labels the tile as "TODAY", but displays yesterday's date and spend.

---

## 3. Cost Leakage Analysis

### 3.1. Major Cost Leak: Stopped On-Demand Box Cascade (~$8.56/mo)
* **Code Reference:** [`lambda/cloud_watchdog.py#L189-L192`](file:///home/jebin/cloud_gaming/lambda/cloud_watchdog.py#L189-L192), [`lambda/cloud_watchdog.py#L430-L434`](file:///home/jebin/cloud_gaming/lambda/cloud_watchdog.py#L430-L434), [`lambda/cloud_watchdog.py#L590-L597`](file:///home/jebin/cloud_gaming/lambda/cloud_watchdog.py#L590-L597)
* **The Chain of Events:**
  1. If a user runs on-demand (`GAME_SPOT=0`) and stops the box via `cg stop` or the watchdog stops it for inactivity:
  2. The instance transitions to `stopped`.
  3. The Lambda idle checker ([`lambda/cloud_watchdog.py#L192`](file:///home/jebin/cloud_gaming/lambda/cloud_watchdog.py#L192)) only searches for:
     ```python
     "Values": ["pending", "running", "stopping", "shutting-down"]
     ```
     It **never terminates stopped instances**.
  4. The 50 GB root volume continues to bill **$4.56/month** ($0.0912/GB-mo) continuously.
  5. In [`boxes(ec2)`](file:///home/jebin/cloud_gaming/lambda/cloud_watchdog.py#L433):
     ```python
     "Values": ["pending", "running", "shutting-down", "stopping", "stopped"]
     ```
     `boxes()` includes `"stopped"` instances!
  6. In `expire_archive()`:
     ```python
     if live:
         say("archive: kept - a box exists (%s)" % ", ".join(live))
         return "in-use"
     ```
     Because a stopped box exists, **the 14-day S3 archive expiry countdown is disabled forever**.
* **Total Leak:**
  The stopped box and the 160 GB S3 game archive bill **~$8.56/month (₹813/month)** indefinitely.

---

### 3.2. S3 Incomplete Multipart Upload Leaks & Bucket Deletion Failure
* **Code Reference:** [`cg#L1042-L1048`](file:///home/jebin/cloud_gaming/cg#L1042-L1048), [`lib/library-aws.sh#L106-L112`](file:///home/jebin/cloud_gaming/lib/library-aws.sh#L106-L112)
* **The Bug:**
  - Large game files uploaded via `s5cmd` use multipart uploads.
  - S3 charges standard storage rates for incomplete multipart parts until completed or aborted.
  - [`lib/library-aws.sh`](file:///home/jebin/cloud_gaming/lib/library-aws.sh#L111) sets a lifecycle rule to abort incomplete uploads after 3 days. However, during those 3 days, tens of gigabytes can accrue storage fees.
  - In `cg destroy --all`:
    ```bash
    aws s3 rb "s3://$b" --force
    ```
    `aws s3 rb --force` **only deletes normal object versions; it does NOT abort incomplete multipart uploads**.
    If an incomplete multipart upload exists, AWS S3 rejects the deletion with `BucketNotEmpty`.
    `cg` catches this error, prints a warning, and then:
    ```bash
    grep -vE '^GAME_S3_BUCKET=' "$envf" > "$tmp"
    ```
    It deletes `GAME_S3_BUCKET` from `.env`!
* **Impact:**
  The S3 bucket is left behind, unmanaged, holding data that continues to bill storage fees indefinitely.

---

### 3.3. Orphaned S3 Data from Interrupted Pushes
* **Code Reference:** [`host/cg-library#L614-L617`](file:///home/jebin/cloud_gaming/host/cg-library#L614-L617), [`cg#L519-L545`](file:///home/jebin/cloud_gaming/cg#L519-L545)
* **The Mechanism:**
  When a push fails or gets killed mid-transfer:
  ```bash
  "$S5" rm "$S3/steamapps/appmanifest_$id.acf"
  ```
  The manifest is deleted to prevent Steam from loading an incomplete game.
  However, the partially uploaded game data (which can be 50–100 GB) remains stored in S3.
  `cg library list` reads `index.json`, so these files do **not** appear in the game list.
* **Leak Risk:**
  Unless the user explicitly runs `cg library clean`, these unindexed files sit in S3 billing $0.025/GB-month.

---

### 3.4. Overly Aggressive Volume Cleanup Deleting Unrelated Disks
* **Code Reference:** [`lib/setup#L901-L902`](file:///home/jebin/cloud_gaming/lib/setup#L901-L902)
* **The Bug:**
  In `destroy_all`:
  ```bash
  ec2 describe-volumes --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Tags[?Key==`Name`]|[0].Value]' --output text
  ```
  It deletes any unattached volume that is not tagged `${TS_HOST}-games`.
* **Impact:**
  If the AWS account is used for anything else in that region, any unattached volume belonging to another project will be permanently destroyed.

---

### 3.5. Untagged EBS Snapshots
* **Code Reference:** [`lib/game#L333-L336`](file:///home/jebin/cloud_gaming/lib/game#L333-L336), [`cg#L1350-L1353`](file:///home/jebin/cloud_gaming/cg#L1350-L1353)
* **The Bug:**
  When `create-image` is executed, it specifies:
  ```bash
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=${TS_HOST}-image}]"
  ```
  It does **not** tag `ResourceType=snapshot`.
* **Impact:**
  If the AMI is ever deregistered directly in the AWS Console, the backing snapshot remains in AWS without tags, continuing to bill $0.057/GB-mo indefinitely.

---

## 4. Recommended Fixes & Action Plan

### Priority 1: Correct Pricing Constants & Formulas
1. **Fix Snapshot Pricing:**
   Update `CG_SNAPSHOT_USD_GB_MONTH` in [`lib/rates.sh`](file:///home/jebin/cloud_gaming/lib/rates.sh#L13) from `0.0125` to `0.057` (or query dynamic Pricing API for EBS snapshots). Update [`lib/game#L326`](file:///home/jebin/cloud_gaming/lib/game#L326) documentation.
2. **Fix Spot Runtime Estimation:**
   In [`lib/setup#L653-L661`](file:///home/jebin/cloud_gaming/lib/setup#L653-L661), check if the instance is spot (`InstanceLifecycle == "spot"`). If spot, use `describe-spot-price-history` for the current rate (~$0.20/hr) rather than `terms.OnDemand` ($0.9664/hr). Add `$0.005/hr` for public IPv4.
3. **Fix Storage Accrual Formula:**
   In [`lib/setup#L683`](file:///home/jebin/cloud_gaming/lib/setup#L683), do not multiply `g * ebs * (day / 30.0)` for ephemeral spot volumes. Accrue storage based on actual instance uptime hours: `g * ebs * (hours / 720.0)`.
4. **Propagate Dynamic FX Rate:**
   Replace all hardcoded `88` constants in `lib/cost-report.py`, `lib/cost-daily.py`, `lambda/cloud_watchdog.py`, and `host/cg-library` with `os.environ.get("CG_INR_PER_USD", 88)`.

### Priority 2: Fix Usage Identification
1. **Fix Prefix Stripping in `lib/cost-daily.py`:**
   Instead of `u = usage_type.split("-", 1)[-1]`, inspect the string with regex or `in` checks:
   ```python
   def bucket(usage_type):
       if "BoxUsage" in usage_type or "SpotUsage" in usage_type: return "compute"
       if "DataTransfer-Out-Bytes" in usage_type:               return "egress"
       if "TimedStorage" in usage_type or "Requests-Tier" in usage_type: return "s3"
       if "VolumeUsage" in usage_type or "SnapshotUsage" in usage_type: return "disk"
       if "APIRequest" in usage_type:                           return "api"
       return "other"
   ```
2. **Scope Cost Explorer Query:**
   Add `{"Dimensions": {"Key": "REGION", "Values": [REGION]}}` to the Cost Explorer filter in `lib/setup` to avoid pulling costs from other regions in the account.

### Priority 3: Eliminate Cost Leaks
1. **Prevent Stopped On-Demand Box Leaks:**
   In `lambda/cloud_watchdog.py`, add a maximum stopped grace period (e.g. 7 days). If an on-demand box remains stopped for > 7 days, trigger a notification or auto-termination so EBS and S3 do not bill indefinitely.
2. **Abort Incomplete Multipart Uploads Before Deletion:**
   In `cg destroy --all`, call `aws s3api list-multipart-uploads` and abort all pending uploads before calling `aws s3 rb --force`.
3. **Scope Available Volume Deletion in `destroy_all`:**
   Only delete unattached volumes that have a matching project tag or were created by `cloud_gaming`.
4. **Tag Backing Snapshots on AMI Creation:**
   In `create-image`, add `ResourceType=snapshot` to `--tag-specifications`.
