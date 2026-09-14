#!/usr/bin/env bash
# Tests `cg destroy` and `cg destroy --all` against a stubbed AWS CLI.
#
# --all is the only command here that can delete the game archive, which is the
# only copy of every game. It earns a test because it has already been wrong
# twice: it once promised "nothing left billing" while ignoring S3 entirely, and
# once - after the EBS volume it was written for no longer existed - it was
# silently identical to a plain destroy.
#
# It is also the reason this file exists rather than a manual check: verifying
# that prompt by running the real command against real infrastructure destroyed
# a live box. A destructive path should be provable without being performed.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.ssh" "$T/lib"
cp "$REPO/cg" "$T/cg"
cp "$REPO/lib/common.sh" "$T/lib/common.sh"
seed_env() {
  cat > "$T/.env" <<EOF
GAME_INSTANCE_ID=i-test
GAME_REGION=ap-south-2
GAME_TS_HOST=gamevps
GAME_S3_BUCKET=bucket-test
GAME_WATCHDOG_AWS_KEY_ID=AKIAFAKE
GAME_WATCHDOG_AWS_SECRET=secretfake
EOF
}
seed_env

# Stand-ins for the two things that actually destroy something.
cat > "$T/lib/setup" <<'FAKE'
#!/usr/bin/env bash
echo "SETUP-DESTROY-CALLED" >> "$LOG"
FAKE
chmod +x "$T/lib/setup"

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
args="$*"
echo "aws $args" >> "$LOG"
case "$args" in
  *"s3 rb"*)            echo "remove_bucket: s3://bucket-test" ;;
  *"s3 rm"*)            echo "delete: s3://bucket-test/steam/x" ;;
  *"s3 ls"*)            printf 'Total Objects: 13271\n   Total Size: 3106357075\n' ;;
  *describe-instances*) echo "${BOX_STATE:-stopped}" ;;
  *describe-volumes*)   echo "None	None" ;;
  *"iam get-user"*)     [[ ${WD_USER:-1} == 1 ]] || exit 1; echo "gamevps-watchdog" ;;
  *"iam get-role"*)     [[ ${ROLE_EXISTS:-1} == 1 ]] || exit 1; echo "gamevps-box" ;;
  *put-role-policy*)    [[ ${IAM_FAILS:-0} == 1 ]] && exit 1; : ;;
  *list-access-keys*)   echo "AKIAFAKE" ;;
  *)                    echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"
cat > "$T/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
exit 1      # box unreachable: no push path is exercised here
FAKE
chmod +x "$T/bin/tailscale"
# Lets the remote-removal path be asserted without a remote host.
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "ssh $*" >> "$LOG"
FAKE
chmod +x "$T/bin/ssh"
cat > "$T/bin/scp" <<'FAKE'
#!/usr/bin/env bash
echo "scp $*" >> "$LOG"
FAKE
chmod +x "$T/bin/scp"

run() { # run <stdin> <args...>
  local input=$1; shift
  LOG="$T/log" rm -f "$T/log"
  printf '%s\n' "$input" | ( cd "$T" && HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" \
    BOX_STATE="${BOX_STATE:-stopped}" WD_USER="${WD_USER:-1}" \
    ROLE_EXISTS="${ROLE_EXISTS:-1}" IAM_FAILS="${IAM_FAILS:-0}" \
    bash ./cg destroy "$@" 2>&1 )
}
did()   { grep -q "$1" "$T/log" 2>/dev/null && echo yes || echo no; }

echo "1. --all with the wrong word deletes NOTHING"
out=$(run "no" --all)
check "says it aborted"       "$(grep -c 'aborted' <<<"$out")" "1"
check "box NOT destroyed"     "$(did SETUP-DESTROY-CALLED)" "no"
check "archive NOT deleted"   "$(did 's3 rm')" "no"

echo "2. --all shows what it is about to delete, from the real object count"
out=$(run "no" --all)
check "names the archive"     "$(grep -c 's3://bucket-test/steam' <<<"$out")" "1"
check "shows the count"       "$(grep -c '13271 objects' <<<"$out")" "1"
check "warns it is the only copy" "$(grep -c 'ONLY COPY' <<<"$out")" "1"

echo "3. --all with the typed word removes the box, the bucket and the IAM role"
out=$(run "DESTROY-ALL" --all)
check "box destroyed"         "$(did SETUP-DESTROY-CALLED)" "yes"
check "bucket removed"        "$(did 's3 rb')" "yes"
check "instance profile gone" "$(did 'delete-instance-profile')" "yes"
check "role policy gone"      "$(did 'delete-role-policy')" "yes"
check "role gone"             "$(did 'delete-role')" "yes"
# A bucket name left in .env would have status printing a name for something
# that no longer exists - which is the bug that prompted deleting it at all.
check "bucket cleared from .env" "$(grep -c GAME_S3_BUCKET "$T/.env")" "0"
# Not about cost: this user holds a long-lived key that can stop instances, on
# an internet-facing host. It survived --all until someone audited IAM by hand.
check "watchdog key revoked"  "$(did 'delete-access-key')" "yes"
check "watchdog user deleted" "$(did 'delete-user --user-name')" "yes"
check "watchdog key cleared from .env" "$(grep -c GAME_WATCHDOG_AWS "$T/.env")" "0"
# The reassurance that games are safe must NOT be printed on the path that
# deletes them.
check "setup told games go too" "$(did 'CG_DESTROY_ALL=1')" "no"

echo "4. --all --force skips the prompt (for scripts), and still removes everything"
seed_env
out=$(run "" --all --force)
check "box destroyed"         "$(did SETUP-DESTROY-CALLED)" "yes"
check "bucket removed"        "$(did 's3 rb')" "yes"
check "role gone"             "$(did 'delete-role')" "yes"

echo "5. a PLAIN destroy never touches the archive, the bucket or the role"
seed_env
out=$(run "" )
check "box destroyed"         "$(did SETUP-DESTROY-CALLED)" "yes"
check "archive UNTOUCHED"     "$(did 's3 rm')" "no"
check "bucket UNTOUCHED"      "$(did 's3 rb')" "no"
check "role UNTOUCHED"        "$(did 'delete-role')" "no"
check "watchdog user UNTOUCHED" "$(did 'delete-user --user-name')" "no"
check "bucket kept in .env"   "$(grep -c GAME_S3_BUCKET "$T/.env")" "1"
check "watchdog key kept in .env" "$(grep -c GAME_WATCHDOG_AWS "$T/.env")" "2"
check "no prompt was shown"   "$(grep -c 'DESTROY-ALL' <<<"$out")" "0"

echo "6. with an off-site host configured, --all removes the REMOTE units too"
# This used to reimplement the IAM half and skip the remote half, leaving a
# timer running on the VPS every few minutes against a key that no longer
# existed. It now calls `cg watchdog remove`, which does both.
seed_env; printf 'GAME_WATCHDOG_HOST=ubuntu@10.0.0.1\n' >> "$T/.env"
out=$(run "" --all --force)
check "watchdog user deleted"   "$(did 'delete-user --user-name')" "yes"
check "remote units removed"    "$(did 'remote-watchdog.timer')" "yes"
check "remote conf removed"     "$(did 'cloud-gaming-watchdog.conf')" "yes"

echo "8. the summary lists only IAM objects that actually exist"
# It used to announce the role and the watchdog user unconditionally, so a run
# with neither present read as though both were about to be deleted - and then
# said nothing more about the watchdog.
seed_env
out=$(WD_USER=0 ROLE_EXISTS=0 run "no" --all)
check "says there is no IAM to remove" "$(grep -c 'IAM             nothing' <<<"$out")" "1"
lacks_out=$(grep -c 'watchdog key    gamevps-watchdog' <<<"$out" || true)
check "does not list a watchdog that is absent" "$lacks_out" "0"

echo "9. every step reports an outcome, including doing nothing"
# A step listed in the summary that then prints nothing is indistinguishable
# from a step that silently failed.
seed_env
out=$(WD_USER=0 ROLE_EXISTS=0 run "" --all --force)
check "says why the watchdog was skipped" \
  "$(grep -c 'nothing to remove' <<<"$out")" "1"

echo "10. an existing watchdog IS listed, with what its key can do"
seed_env
out=$(WD_USER=1 ROLE_EXISTS=1 run "no" --all)
check "lists the role"     "$(grep -c 'instance role   gamevps-box' <<<"$out")" "1"
check "lists the key"      "$(grep -c 'watchdog key    gamevps-watchdog' <<<"$out")" "1"
check "says what it can do" "$(grep -c 'can stop' <<<"$out")" "1"

echo "11. --no-push locks the archive before terminating"
# Skipping the laptop-side push is only half the job: the box runs its own
# mirror from ExecStop when it shuts down, so --no-push has to make that
# physically impossible. It revokes the role's write access, which works even
# when the box is too busy to answer ssh - the usual reason for wanting it.
seed_env
out=$(run "" --no-push)
check "box destroyed"          "$(did SETUP-DESTROY-CALLED)" "yes"
check "no push attempted"      "$(did 'cg-library push')" "no"
check "revoked write access"   "$(grep -c 'put-role-policy' "$T/log" || true)" "2"
contains "says what it did"    "$out" "archive is left exactly as it is"
contains "and that it locked"  "$out" "read-only"
contains "and unlocked after"  "$out" "writable again"
# The lock must not include write verbs; the unlock must.
ro=$(grep 'put-role-policy' "$T/log" | head -1)
rw=$(grep 'put-role-policy' "$T/log" | tail -1)
if [[ $ro != *PutObject* ]]; then echo "  ok   lock has no PutObject"; pass=$((pass+1));
else echo "  FAIL the read-only policy still allows PutObject"; fail=$((fail+1)); fi
if [[ $rw == *PutObject* ]]; then echo "  ok   unlock restores PutObject"; pass=$((pass+1));
else echo "  FAIL the restore policy is missing PutObject"; fail=$((fail+1)); fi

echo "11b. if the lock cannot be applied, nothing is destroyed"
# Refusing is right: the alternative is terminating a box whose shutdown mirror
# is still free to overwrite the archive.
seed_env
out=$(IAM_FAILS=1 run "" --no-push); rc=$?
check    "exits non-zero"   "$rc" "1"
check    "box NOT destroyed" "$(did SETUP-DESTROY-CALLED)" "no"
contains "explains why"     "$out" "could not revoke"

echo "12. an unknown flag destroys nothing at all"
out=$(run "" --everything)
check "refused"               "$(grep -c "unknown option" <<<"$out")" "1"
check "box NOT destroyed"     "$(did SETUP-DESTROY-CALLED)" "no"
check "archive NOT deleted"   "$(did 's3 rm')" "no"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
