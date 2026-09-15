#!/usr/bin/env bash
# Drives `cg init`'s pre-launch arming of the cloud watchdog (layer 4) against a
# fake AWS CLI that KEEPS STATE - a function created on one run is there on the
# next - so "nothing changed" is tested against what an install actually wrote,
# not against a copy of how it is computed.
#
# What must hold:
#   - a first init builds every piece, proves it with a dry run, and launches
#   - an unchanged init redeploys nothing and runs no new check
#   - each kind of drift is noticed and repaired, and only that piece
#   - no failure here stops the launch
#   - nothing here looks up an IAM user or uses ssh: there is no key to manage
#
# Its predecessor exists because of a bug that only ran on the "nothing exists
# yet" branch - `cg init` died after arming the watchdog and before launching.
# Case 1 is that branch.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output contains '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.ssh" "$T/lib" "$T/lambda" "$T/aws"
cp "$REPO/cg" "$T/cg"
cp "$REPO/lib/common.sh" "$REPO/lib/cloud-watchdog.sh" "$T/lib/"
cp "$REPO/lambda/cloud_watchdog.py" "$T/lambda/"
seed_env() {
  cat > "$T/.env" <<EOF
GAME_INSTANCE_ID=i-test
GAME_REGION=ap-south-2
GAME_TS_HOST=gamevps
EOF
}
seed_env

# The thing init hands off to. If this never runs, init died on the way.
cat > "$T/lib/setup" <<'FAKE'
#!/usr/bin/env bash
echo "SETUP-REACHED" >> "$LOG"
FAKE
chmod +x "$T/lib/setup"

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env python3
import sys, os, json, hashlib, base64
S, LOG = os.environ["AWS_STATE"], os.environ["LOG"]
a = sys.argv[1:]
open(LOG, "a").write("aws " + " ".join(a) + "\n")
ACCT, R, NAME = "123456789012", "ap-south-2", "gamevps-cloud-watchdog"
def opt(n, d=None): return a[a.index(n) + 1] if n in a else d
def get(n, d=None):
    try: return open(os.path.join(S, n)).read()
    except FileNotFoundError: return d
def put(n, v): open(os.path.join(S, n), "w").write(v)
def rm(n):
    p = os.path.join(S, n)
    if os.path.exists(p): os.remove(p); return True
    return False
def gone(): sys.stderr.write("ResourceNotFoundException\n"); sys.exit(254)
if os.environ.get("AWS_DOWN") == "1": sys.stderr.write("Could not connect\n"); sys.exit(255)
words = [x for i, x in enumerate(a) if x != "--region" and (i == 0 or a[i-1] != "--region")]
cmd = " ".join(words[:2])

if cmd == "sts get-caller-identity": print(ACCT)
elif cmd == "iam get-role":
    get("role") or gone(); print("arn:aws:iam::%s:role/%s" % (ACCT, NAME))
elif cmd == "iam create-role":
    if os.environ.get("NO_IAM") == "1": sys.stderr.write("AccessDenied\n"); sys.exit(254)
    put("role", "1")
elif cmd == "iam put-role-policy": put("policy", opt("--policy-document"))
elif cmd == "iam get-role-policy":
    p = get("policy") or gone(); print(json.dumps(json.loads(p)))
elif cmd == "iam delete-role-policy": rm("policy") or gone()
elif cmd == "iam delete-role": rm("role") or gone()
elif cmd == "logs create-log-group":
    if get("loggroup"): sys.exit(254)
    put("loggroup", "1")
elif cmd == "logs put-retention-policy": put("retention", opt("--retention-in-days"))
elif cmd == "logs delete-log-group": rm("loggroup") or gone()
elif cmd == "logs filter-log-events":
    get("loggroup") or gone()
    ms = os.environ.get("LAST_MS", "")
    print("%s\tcg-watchdog: %s" % (ms, os.environ.get("LAST_MSG", "no running instance tagged gamevps - nothing to do")) if ms else "None")
elif cmd == "lambda get-function-configuration":
    d = json.loads(get("fn") or gone())
    q = opt("--query", "")
    if q == "[CodeSha256,Description]": print("%s\t%s" % (d["sha"], d["desc"]))
    elif q.startswith("[CodeSha256,State"): print("\t".join([d["sha"], "Active", "Successful", d["role"], d["desc"]]))
    elif q == "[State,Runtime]": print("Active\tpython3.13")
    else: print(json.dumps(d))
elif cmd in ("lambda create-function", "lambda update-function-code", "lambda update-function-configuration"):
    if cmd == "lambda create-function" and os.environ.get("ROLE_LAG") == "1" and not get("lagged"):
        put("lagged", "1")
        sys.stderr.write("An error occurred (InvalidParameterValueException): The role defined for the function cannot be assumed by Lambda.\n")
        sys.exit(254)
    d = json.loads(get("fn") or "{}")
    z = opt("--zip-file")
    if z: d["sha"] = base64.b64encode(hashlib.sha256(open(z[len("fileb://"):], "rb").read()).digest()).decode()
    for k, o in (("desc", "--description"), ("role", "--role"), ("env", "--environment")):
        if opt(o): d[k] = opt(o)
    put("fn", json.dumps(d))
elif cmd == "lambda wait": pass
elif cmd == "lambda delete-function": rm("fn") or gone()
elif cmd == "lambda get-policy":
    p = get("perm") or gone()
    print(json.dumps({"Statement": [{"Condition": {"ArnLike": {"AWS:SourceArn": p}}}]}))
elif cmd == "lambda add-permission": put("perm", opt("--source-arn"))
elif cmd == "lambda remove-permission": rm("perm") or gone()
elif cmd == "lambda invoke":
    open(a[-1], "w").write("{}")
    msg = os.environ.get("PROVE_MSG", "i-abc quiet for 30m: peak 0.0 MB per 5 min over 6 periods, under 10.0 MB - WOULD terminate (dry run; permission to terminate: ok)")
    tail = base64.b64encode(("START RequestId: x\ncg-watchdog: %s\nEND RequestId: x\n" % msg).encode()).decode()
    print("%s\t%s" % (os.environ.get("PROVE_ERR", "None"), tail))
elif cmd == "events put-rule":
    put("rule", opt("--state")); print("arn:aws:events:%s:%s:rule/%s" % (R, ACCT, NAME))
elif cmd == "events describe-rule":
    r = get("rule") or gone()
    print("%s\trate(5 minutes)" % r if "Schedule" in opt("--query", "") else r)
elif cmd == "events put-targets": put("target", opt("--targets").split("Arn=", 1)[1]); print("0")
elif cmd == "events list-targets-by-rule": print(get("target", "None"))
elif cmd == "events remove-targets": rm("target") or gone()
elif cmd == "events delete-rule": rm("rule") or gone()
else: print("None")
FAKE
chmod +x "$T/bin/aws"

cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "ssh $*" >> "$LOG"
exit 0
FAKE
for c in scp tailscale; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\n' "$c" > "$T/bin/$c"; done
chmod +x "$T/bin"/*

run() {
  rm -f "$T/log"
  ( cd "$T" && HOME="$T/home" LOG="$T/log" AWS_STATE="$T/aws" PATH="$T/bin:$PATH" \
      CG_CW_RETRY_SLEEP=0 bash ./cg init 2>&1 )
}
did()  { grep -qE -- "$1" "$T/log" 2>/dev/null && echo yes || echo no; }
cnt()  { grep -cE -- "$1" "$T/log" 2>/dev/null || true; }
now_ms() { echo $(( $(date +%s) * 1000 - ${1:-60} * 1000 )); }
WRITES='create-role|put-role-policy|create-log-group|create-function|update-function|put-rule|put-targets|add-permission|lambda invoke'

echo "1. nothing exists yet: every piece is built, proved with a dry run, and init launches"
out=$(run)
lacks    "no unbound variable"       "$out" "unbound variable"
lacks    "no bash error"             "$out" "cg: line"
check    "created the role"          "$(did 'iam create-role')" "yes"
check    "attached the scoped policy" "$(did 'put-role-policy')|$(grep -c '"ec2:ResourceTag/Name":"gamevps"' "$T/aws/policy")" "yes|2"
check    "log group, with a retention" "$(did 'create-log-group')|$(cat "$T/aws/retention" 2>/dev/null)" "yes|14"
check    "created the function"      "$(did 'create-function')" "yes"
check    "schedule enabled, every 5 min" "$(did "put-rule .*rate\(5 minutes\) --state ENABLED")" "yes"
check    "schedule targets the function" "$(cat "$T/aws/target")" "arn:aws:lambda:ap-south-2:123456789012:function:gamevps-cloud-watchdog"
check    "schedule may invoke it"    "$(cat "$T/aws/perm")" "arn:aws:events:ap-south-2:123456789012:rule/gamevps-cloud-watchdog"
check    "proved with a DRY run"     "$(did 'lambda invoke .*"dry_run":true')" "yes"
contains "shows what the check decided" "$out" "cloud watchdog: i-abc quiet for 30m"
check    "REACHED the launch"        "$(did SETUP-REACHED)" "yes"

echo "2. nothing changed: no writes, no new check, and it shows the last decision"
out=$(LAST_MS=$(now_ms 120) run)
check    "wrote nothing, invoked nothing" "$(cnt "$WRITES")" "0"
contains "says it is up to date"     "$out" "cloud watchdog: up to date - last check 2 min ago"
lacks    "a recent check is not called stale" "$out" "not running"
check    "REACHED the launch"        "$(did SETUP-REACHED)" "yes"

echo "3. a last decision older than the schedule allows is flagged"
out=$(LAST_MS=$(now_ms 1500) run)
contains "says it is not running"    "$out" "it is not running"
out=$(run)
contains "no decision at all in the hour is flagged too" "$out" "logged nothing in the last hour"

echo "4. a blind last decision is flagged on the fast path"
out=$(LAST_MS=$(now_ms 60) LAST_MSG="CANNOT QUERY AWS - this watchdog is blind: AccessDenied" run)
contains "says it cannot act"        "$out" "layer 4 is decoration"

echo "5. changed code: only the code is redeployed"
echo "# changed" >> "$T/lambda/cloud_watchdog.py"
out=$(LAST_MS=$(now_ms 60) run)
contains "names the drift"           "$out" "code changed"
check    "code updated"              "$(did 'update-function-code')" "yes"
check    "settings NOT touched"      "$(did 'update-function-configuration')" "no"
check    "nothing recreated"         "$(did 'create-function|create-role')" "no"
check    "proved again"              "$(did 'lambda invoke')" "yes"
out=$(LAST_MS=$(now_ms 60) run)
check    "and the next run is quiet" "$(cnt "$WRITES")" "0"

echo "6. changed settings: the idle window from .env reaches the function"
echo "GAME_WATCHDOG_IDLE_MIN=45" >> "$T/.env"
out=$(LAST_MS=$(now_ms 60) run)
contains "names the drift"           "$out" "settings changed"
check    "settings updated with 45"  "$(did 'update-function-configuration .*CG_IDLE_MINUTES=45')" "yes"
check    "code NOT redeployed"       "$(did 'update-function-code')" "no"
seed_env; out=$(LAST_MS=$(now_ms 60) run)

echo "7. a schedule disabled by hand is re-enabled"
echo DISABLED > "$T/aws/rule"
out=$(LAST_MS=$(now_ms 60) run)
contains "names the drift"           "$out" "schedule not enabled"
check    "enabled again"             "$(cat "$T/aws/rule")" "ENABLED"

echo "8. a role policy edited by hand is put back"
echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}' > "$T/aws/policy"
out=$(LAST_MS=$(now_ms 60) run)
contains "names the drift"           "$out" "role policy changed"
check    "scoped policy restored"    "$(grep -c 'EndOnlyTheTaggedBox' "$T/aws/policy")" "1"

echo "9. a removed invoke permission is restored"
rm -f "$T/aws/perm"
out=$(LAST_MS=$(now_ms 60) run)
contains "names the drift"           "$out" "schedule cannot invoke it"
check    "permission back"           "$(did 'add-permission')" "yes"

echo "10. a role Lambda cannot assume YET is waited out, not reported as failure"
rm -rf "$T/aws"; mkdir -p "$T/aws"
out=$(ROLE_LAG=1 run)
check    "created on the second try" "$(cnt 'create-function')" "2"
lacks    "no failure reported"       "$out" "not installed"

echo "11. a dry run that cannot see the account is flagged"
rm -rf "$T/aws"; mkdir -p "$T/aws"
out=$(PROVE_MSG="CANNOT QUERY AWS - this watchdog is blind: AccessDenied" run)
contains "says it cannot act"        "$out" "layer 4 is decoration"
check    "retried the check first"   "$(cnt 'lambda invoke')" "3"

echo "12. AWS unreachable: not fatal"
rm -rf "$T/aws"; mkdir -p "$T/aws"
out=$(AWS_DOWN=1 run)
contains "says the layer is missing" "$out" "cloud watchdog not installed - the other three layers still apply"
check    "REACHED the launch"        "$(did SETUP-REACHED)" "yes"

echo "13. no permission to create the role: not fatal either"
out=$(NO_IAM=1 run)
contains "says why"                  "$out" "could not create the role"
check    "REACHED the launch"        "$(did SETUP-REACHED)" "yes"

echo "14. no IAM user lookup and no ssh, on an install or on the fast path"
# The watchdog runs on a role: there is no user, no key and no remote host.
rm -rf "$T/aws"; mkdir -p "$T/aws"; out=$(run)
check    "install: no user lookup"   "$(did 'iam get-user')" "no"
check    "install: no ssh"           "$(did '^ssh ')" "no"
out=$(LAST_MS=$(now_ms 60) run)
check    "no user lookup"            "$(did 'iam get-user')" "no"
check    "no ssh"                    "$(did '^ssh ')" "no"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
