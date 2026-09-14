#!/usr/bin/env bash
# What a plain `cg destroy` keeps, and what only `--all` removes.
#
# The monthly budget must survive `cg destroy` and die only with `--all`.
#
# It used to be deleted on every destroy. AWS Budgets populates CalculatedSpend
# up to 24h AFTER a budget is created, and cg init recreates it on every build -
# so a rig rebuilt several times a day reset it before it ever populated. It
# reported "$0.00 spent" against a real month of $12.17 and could never have
# fired an alert. A cost guard that has never been able to fire.
#
# It is also account-level, not instance-level, and costs nothing to keep. The
# moment it was most needed - no instance running, the user away - was exactly
# when destroy removed it.
#
# The same now holds for the security group, the key pair (with its .pem), the
# idle-stop alarm and the tailnet node: all free, all reused or rewritten by
# cg init, so a plain destroy terminates only what bills.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
# The WHOLE lib/, not a hand-picked pair of files. Copying just setup and
# common.sh meant that adding `source lib/pair.sh` to lib/setup killed this
# suite under `set -e` - the script died on a missing file before reaching
# anything it was meant to test, and every assertion failed for that one reason.
# A sandbox that mirrors the real layout does not care what the code adds next.
cp -r "$REPO/lib" "$T/lib"
# Everything returns "nothing here" except the free resources this file is
# about, so destroy walks its whole path quickly.
#
# describe-instances must print NOTHING, not "None": destroy iterates its output
# as a list of instance ids, so "None" became an instance it then waited to see
# terminate - and the run never reached the alarm and budget section.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *get-caller-identity*)      echo "123456789012" ;;
  *describe-instances*)       : ;;
  *describe-volumes*)         : ;;
  *describe-security-groups*) echo "sg-test" ;;
  *describe-key-pairs*)       echo "gamevps" ;;
  *delete-security-group*)    : ;;
  *)                          echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"; chmod +x "$T/bin/tailscale"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
# The Tailscale API: one gamevps node listed, and DELETE recorded.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >> "$LOG"
if [[ "$*" == *"-X DELETE"* ]]; then printf 200
else printf '{"devices":[{"nodeId":"n1","hostname":"gamevps"}]}\n200'; fi
FAKE
chmod +x "$T/bin/curl"

# HOME is redirected into the sandbox. This file runs the REAL lib/setup
# destroy, and stubbing only `aws` and `tailscale` left every filesystem
# operation pointed at the real machine - including
#
#     rm -f "$HOME/.ssh/${TS_HOST}.pem"
#
# which deleted the actual private key for a running box, unrecoverably. A test
# that executes a destroy script must isolate the filesystem as carefully as the
# API, and $HOME is the one that bites: nothing in the command line mentions it.
run() { # run <CG_DESTROY_ALL value>
  rm -f "$T/log"
  mkdir -p "$T/home/.ssh"
  printf 'GAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\nGAME_INSTANCE_ID=i-old\nGAME_TS_NODE=gamevps\nSUNSHINE_USER=admin\nSUNSHINE_PASS=old-pass\nGAME_S3_BUCKET=bucket-kept\n' > "$T/.env"
  ( cd "$T" && HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" TAILSCALE_API_KEY=tskey-api-test \
      CG_DESTROY_ALL="${1:-0}" timeout 60 bash ./lib/setup destroy 2>&1 )
}
did()   { grep -q -- "$1" "$T/log" 2>/dev/null && echo yes || echo no; }
lacks() { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: output must not contain '$3'"; fail=$((fail+1)); fi; }
exists() { test -e "$1" && echo yes || echo no; }

echo "1. a plain destroy KEEPS the budget"
mkdir -p "$T/home/.ssh"; : > "$T/home/.ssh/gamevps.pem"
out=$(run 0)
check    "budget not deleted"     "$(did 'delete-budget')" "no"
contains "says why"               "$out" "guards the account"

echo "2. a plain destroy KEEPS every free resource cg init reuses"
# Free, and reused or rewritten by the next build: deleting them only cost time
# (the security group waited up to a minute for its network interface).
check "security group not deleted"   "$(did 'delete-security-group')" "no"
check "key pair not deleted"         "$(did 'delete-key-pair')" "no"
check "the .pem kept WITH the key"   "$(exists "$T/home/.ssh/gamevps.pem")" "yes"
check "idle alarm not deleted"       "$(did 'delete-alarms')" "no"
check "tailnet node not deleted"     "$(did '-X DELETE')" "no"
# Not even looked up: the describes were only there to feed the deletes.
check "security group not queried"   "$(did 'describe-security-groups')" "no"
contains "says what it kept"         "$out" "security group, key pair, alarm and tailnet node kept"

echo "3. the listing does not promise to delete something it keeps"
head=$(sed -n '/This permanently deletes/,/^$/p' <<<"$out")
lacks    "no security group under 'deletes'" "$head" "security group"
lacks    "no key pair under 'deletes'"       "$head" "key pair"
contains "listed as kept instead"            "$out"  "Kept, because they are free"

echo "4. per-box .env pointers are still cleared, account-level ones kept"
# Not AWS resources and free to clear - left in place, cg ssh and cg status
# would point at a terminated instance until the next init.
check "instance id cleared"      "$(grep -c '^GAME_INSTANCE_ID=' "$T/.env")" "0"
check "sunshine password cleared" "$(grep -c '^SUNSHINE_PASS=' "$T/.env")" "0"
check "bucket kept"              "$(grep -c '^GAME_S3_BUCKET=' "$T/.env")" "1"

echo "5. destroy --all removes all of it, budget included"
: > "$T/home/.ssh/gamevps.pem"; : > "$T/home/.ssh/gamevss.pem"
out=$(run 1)
check    "budget deleted"          "$(did 'delete-budget')" "yes"
contains "listing says it goes"    "$out" "budget          gamevps-monthly"
check    "security group deleted"  "$(did 'delete-security-group')" "yes"
check    "key pair deleted"        "$(did 'delete-key-pair')" "yes"
check    "idle alarm deleted"      "$(did 'delete-alarms')" "yes"
check    "tailnet node deleted"    "$(did '-X DELETE')" "yes"

echo "6. the sandbox really is isolated from the real home"
# The guard for the mistake above: --all deleted the key inside $T, and a real
# file beside it survived.
check "deleted the sandboxed key"      "$(exists "$T/home/.ssh/gamevps.pem")" "no"
check "left unrelated files alone"     "$(exists "$T/home/.ssh/gamevss.pem")" "yes"
check "HOME was redirected, not real"  "$([[ $T/home != "$HOME" ]] && echo yes || echo no)" "yes"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
