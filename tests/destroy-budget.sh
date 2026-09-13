#!/usr/bin/env bash
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
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/lib"
cp "$REPO/lib/setup" "$T/lib/setup"
cp "$REPO/lib/common.sh" "$T/lib/common.sh"
printf 'GAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\n' > "$T/.env"

# Everything returns "nothing here", so destroy walks its whole path quickly.
#
# describe-instances must print NOTHING, not "None": destroy iterates its output
# as a list of instance ids, so "None" became an instance it then waited to see
# terminate - and the run never reached the alarm and budget section this file
# is about.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *get-caller-identity*) echo "123456789012" ;;
  *describe-instances*)  : ;;
  *describe-volumes*)    : ;;
  *)                     echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"; chmod +x "$T/bin/tailscale"

run() { # run <CG_DESTROY_ALL value>
  rm -f "$T/log"
  ( cd "$T" && LOG="$T/log" PATH="$T/bin:$PATH" CG_DESTROY_ALL="${1:-0}" \
      timeout 60 bash ./lib/setup destroy 2>&1 )
}
did() { grep -q "$1" "$T/log" 2>/dev/null && echo yes || echo no; }

echo "1. a plain destroy KEEPS the budget"
out=$(run 0)
check    "budget not deleted"     "$(did 'delete-budget')" "no"
contains "says it is kept"        "$out" "keeping the budget"
contains "says why"               "$out" "guards the account"
# The instance-scoped alarm still goes - it names one instance.
check    "idle alarm still deleted" "$(did 'delete-alarms')" "yes"

echo "2. the listing does not promise to delete something it keeps"
contains "listing says KEPT"      "$out" "budget          KEPT"

echo "3. destroy --all DOES delete the budget"
out=$(run 1)
check    "budget deleted"         "$(did 'delete-budget')" "yes"
contains "listing says it goes"   "$out" "budget          gamevps-monthly"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
