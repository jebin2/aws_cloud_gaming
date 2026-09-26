#!/usr/bin/env bash
# `cg status --json`: the same facts as the report, as data.
#
# One round of queries fills a table of facts; the report and the JSON both
# render from it. That is the point of the refactor - an app reading the JSON
# is reading exactly what the report shows, so the two cannot drift apart.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.ssh" "$T/repo"
cp -r lib lambda "$T/repo/"
printf 'GAME_S3_BUCKET=cg-library-test\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\nTAILSCALE_AUTH_KEY=tskey-auth-x\n' > "$T/repo/.env"
: > "$T/home/.ssh/gamevps.pem"

# BOX=none|running decides whether an instance exists.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"sts get-caller-identity"*)        echo 123456789012 ;;
  *accountPlanType*)                  echo PAID ;;
  *accountPlanRemainingCredits*)      echo 139.35 ;;
  *describe-instance-types*)          printf '4\t16384\tL4\t22888\t1\n' ;;
  *L-DB2E81BA*)                       echo 4.0 ;;
  *L-3819A6DF*)                       echo 4.0 ;;
  *"describe-instances"*"tag:Name"*)  [[ ${BOX:-none} == none ]] && echo None || echo i-0abc123 ;;
  *"describe-instances --instance-ids"*State.Name*InstanceType*)
                                      printf 'running\tg6.xlarge\t13.1.1.1\t2026-09-26T10:00:00+00:00\n' ;;
  *"describe-volumes"*tag:Name*)      echo "None	None	None" ;;
  *"describe-volumes"*sum*)           [[ ${BOX:-none} == none ]] && echo 0 || echo 50 ;;
  *describe-snapshots*)               echo 0 ;;
  *describe-images*)                  echo 0 ;;
  *describe-addresses*)               echo 0 ;;
  *describe-key-pairs*)               echo gamevps ;;
  *"describe-security-groups"*group-name*) echo sg-test ;;
  *"describe-security-groups"*IpPermissions*) printf 'udp\t41641\t0.0.0.0/0\n' ;;
  *"s3 ls"*)                          printf 'Total Objects: 6218\n   Total Size: 172000000000\n' ;;
  *"describe-budget"*BudgetLimit*)    echo 57.0 ;;
  *"describe-budget"*CalculatedSpend*) echo 0 ;;
  *describe-notifications-for-budget*) echo 2 ;;
  *"lambda get-function"*)            echo Active ;;
  *"logs filter-log-events"*)         # the real query returns <epoch-ms>\t<message>
                                      printf '%s\tcg-watchdog: archive: kept - last used 2d ago; deleted in 12d unless a box is launched\n' "$(( ($(date +%s) - 600) * 1000 ))" ;;
  *)                                  echo None ;;
esac
FAKE
cat > "$T/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
[[ $1 == status ]] || exit 0
printf '100.64.0.9  gamevps  you@  linux  %s\n' "${TS_STATE:-offline, last seen 2d ago}"
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/moonlight"
chmod +x "$T/bin"/*

run() { # run [--json]
  ( cd "$T/repo" && env -i PATH="$T/bin:$PATH" HOME="$T/home" BOX="${BOX:-none}" TS_STATE="${TS_STATE-}" \
      CG_COLOR=never bash lib/setup status ${1:+--json} 2>&1 )
}
jq_() { python3 -c 'import json,sys;d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d))' "$1"; }

echo "1. no box: the report and the JSON say the same thing"
text=$(run); json=$(run --json)
contains "report: no instance"          "$text" "instance        none"
check    "json: box is null"            "$(jq_ box <<<"$json")" "null"
contains "report: the archive line"     "$text" "6218 objects"
check    "json: the same object count"  "$(jq_ archive.objects <<<"$json")" "6218"
check    "  bytes as a number"          "$(jq_ archive.bytes <<<"$json")" "172000000000"
check    "  and its monthly cost"       "$(jq_ archive.usd_month <<<"$json")" "4.0"
check    "json: the account plan"       "$(jq_ account.plan <<<"$json")" '"PAID"'
check    "  credits"                    "$(jq_ account.credits <<<"$json")" '"139.35"'
check    "json: the budget limit"       "$(jq_ budget.limit <<<"$json")" "57.0"
check    "  and its alert count"        "$(jq_ budget.alerts <<<"$json")" "2"
check    "json: quota numbers"          "$(jq_ quota.spot <<<"$json")" "4.0"
check    "json: the host"               "$(jq_ host <<<"$json")" '"gamevps"'
# The Build screen names the machine from these, so nothing about g6.xlarge is
# written into the app: one describe-instance-types call answers both.
check    "json: the machine's vCPUs"    "$(jq_ spec.vcpus <<<"$json")" "4"
check    "  its memory"                 "$(jq_ spec.memory_mib <<<"$json")" "16384"
check    "  its GPU"                    "$(jq_ spec.gpu <<<"$json")" '"L4"'
check    "  and the GPU's memory"       "$(jq_ spec.gpu_memory_mib <<<"$json")" "22888"
check    "  the quota reuses that call" "$(jq_ quota.vcpus <<<"$json")" "4"
# Nothing streaming from this laptop: the app asks here rather than looking for
# a Moonlight process of its own.
check    "json: no session is null"     "$(jq_ session <<<"$json")" "null"

echo "2. a running box"
text=$(BOX=running run); json=$(BOX=running run --json)
contains "report: the instance line"    "$text" "instance        i-0abc123  g6.xlarge  running"
check    "json: its id"                 "$(jq_ box.id <<<"$json")" '"i-0abc123"'
check    "  state"                      "$(jq_ box.state <<<"$json")" '"running"'
check    "  type"                       "$(jq_ box.type <<<"$json")" '"g6.xlarge"'
check    "  and when it launched"       "$(jq_ box.launched <<<"$json")" '"2026-09-26T10:00:00+00:00"'
check    "json: volumes follow the box" "$(jq_ res.volumes_gb <<<"$json")" "50"

echo "3. the local side, as booleans"
json=$(run --json)
check "tailscale is up"                 "$(jq_ local.tailscale <<<"$json")" "true"
check "moonlight is installed"          "$(jq_ local.moonlight <<<"$json")" "true"
check "the ssh key is here"             "$(jq_ local.ssh_key <<<"$json")" "true"
check "the auth key is in .env"         "$(jq_ local.auth_key <<<"$json")" "true"
check "the node is named, not addressed" "$(jq_ tailnet.node <<<"$json")" '"gamevps"'
check "  offline is false, not a string" "$(jq_ tailnet.online <<<"$json")" "false"
json=$(TS_STATE="active; direct" run --json)
check "  and online is true"            "$(jq_ tailnet.online <<<"$json")" "true"

echo "4. the archive countdown, in the watchdog's own words"
json=$(run --json)
contains "the decision is carried through" "$(jq_ archive.decision <<<"$json")" "deleted in 12d"
check    "expiry days as a number"         "$(jq_ archive.expiry_days <<<"$json")" "14"

echo "5. it is one object, and valid"
check "valid JSON"                      "$(run --json | python3 -c 'import json,sys; json.load(sys.stdin); print("yes")')" "yes"
check "cg passes --json through"        "$(grep -c 'exec lib/setup status --json' cg)" "1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
