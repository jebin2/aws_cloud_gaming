#!/usr/bin/env bash
# The AWS access key: the one thing cg cannot install for you.
#
# A new laptop has no credentials, and every number on every screen is then
# UNKNOWN - not empty. What it used to say was "AWS rejected these credentials
# ... Settings - or cg check --fix - takes a new key", and all three parts of
# that were wrong at once:
#
#   - nothing had been rejected: there was no AWS CLI to reject anything
#   - Settings had no field for a key
#   - cg check --fix skipped the question, because laptop_tty tested [ -t 0 ]
#     and the app's stdin is a pipe - so --fix installed tools and then quietly
#     did not ask for the one thing it cannot install
#
# So this covers the three states apart (no CLI, rejected, working), that the
# secret is never printed, and that the app counts as somewhere to ask.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output has '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home" "$T/repo"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
# A PATH with the ordinary tools and NO aws: a laptop straight out of the box.
for b in bash sh grep sed awk python3 cut tr sort head tail cat date stat mktemp \
         rm mv cp chmod id uname timeout dirname basename env readlink wc find \
         sleep mkdir tee touch; do
  p=$(command -v "$b") && ln -sf "$p" "$T/bin/$b"
done

# The fake aws. KEY_STATE decides what sts says, and every call is logged so a
# test can assert that the secret never reached a command line it should not.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "${AWS_LOG:-/dev/null}"
case "$*" in
  *"configure get aws_access_key_id"*)
    [[ -s $CFG ]] && sed -n '1p' "$CFG" ;;
  *"configure set aws_access_key_id"*)     printf '%s\n' "${@: -1}" > "$CFG" ;;
  *"configure set aws_secret_access_key"*) printf '%s\n' "${@: -1}" >> "$CFG" ;;
  *"configure set region"*) ;;
  *"configure list"*)
    printf '      access_key     ****************1234 shared-credentials-file\n'
    printf '      profile        default            manual\n' ;;
  *"get-caller-identity"*)
    case "${KEY_STATE:-ok}" in
      ok)  case "$*" in
             *"--query Account"*) echo "123456789012" ;;
             *)                   echo "123456789012|arn:aws:iam::123456789012:user/example" ;;
           esac ;;
      bad) echo "An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid." >&2
           exit 254 ;;
    esac ;;
esac
FAKE
chmod +x "$T/bin/aws"

cg_() { # cg_ <args...> - EXTRA passes env through
  # shellcheck disable=SC2086
  ( cd "$T/repo" && env -i PATH="$PATH_USE" HOME="$T/home" CG_COLOR=never \
      CFG="$T/key" AWS_LOG="$T/awslog" KEY_STATE="${KEY_STATE:-ok}" \
      GAME_REGION=ap-south-1 ${EXTRA:-} bash ./cg "$@" 2>&1 )
}
j() { python3 -I -c 'import json,sys
d = json.load(sys.stdin)
k = sys.argv[1]
print(json.dumps(d[k]))' "$1"; }

echo "1. no AWS CLI at all"
PATH_USE="$T/bin:/nonexistent"
rm -f "$T/bin/aws.disabled"; mv "$T/bin/aws" "$T/bin/aws.disabled"
out=$(cg_ creds --json)
check    "it is valid JSON"              "$(python3 -I -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$out")" "yes"
check    "  the CLI is reported missing"  "$(j cli <<<"$out")" "false"
# Not false. Nothing was rejected, because nothing was asked - the same
# distinction the archived login needs between "none" and "could not look".
check    "  valid is null, not false"     "$(j valid <<<"$out")" "null"
contains "  and it says what to run"      "$(j error <<<"$out")" "cg check --fix"
out=$(cg_ creds)
contains "the human view says so too"     "$out" "not installed"
contains "  naming the fix"               "$out" "cg check --fix"
mv "$T/bin/aws.disabled" "$T/bin/aws"

echo "2. a key AWS will not take"
KEY_STATE=bad
printf 'AKIAFAKEFAKEFAKE1234\nsecret-should-never-be-printed\n' > "$T/key"
out=$(cg_ creds --json)
check    "the CLI is there"               "$(j cli <<<"$out")" "true"
check    "  but the key is not valid"     "$(j valid <<<"$out")" "false"
contains "  and AWS's own words are kept" "$(j error <<<"$out")" "InvalidClientTokenId"
check    "  no account is claimed"        "$(j account <<<"$out")" "null"
# The last four, which is what the IAM console shows: enough to tell two keys
# apart, useless to anyone reading over your shoulder.
check    "the key id is masked"           "$(j key_id <<<"$out")" '"****1234"'
lacks    "  never the whole key"          "$out" "AKIAFAKEFAKEFAKE1234"
lacks    "  and never the secret"         "$out" "secret-should-never-be-printed"
out=$(cg_ creds)
contains "the human view explains"        "$out" "accepted         no"
contains "  and points at the fix"        "$out" "cg creds set"
lacks    "  without the secret"           "$out" "secret-should-never-be-printed"

echo "3. a key that works"
KEY_STATE=ok
out=$(cg_ creds --json)
check    "it is valid"                    "$(j valid <<<"$out")" "true"
check    "  the account is named"         "$(j account <<<"$out")" '"123456789012"'
contains "  with the identity"            "$(j arn <<<"$out")" "user/example"
check    "  and no error"                 "$(j error <<<"$out")" "null"
contains "  saying where it came from"    "$(j source <<<"$out")" "credentials"
out=$(cg_ creds)
contains "the human view confirms"        "$out" "accepted         yes"
lacks    "  and still hides the secret"   "$out" "secret-should-never-be-printed"

echo "4. setting a key"
# CG_JSON=1 is how the app runs cg: questions become events, answers arrive on
# stdin. Two answers, in order: the id, then the secret.
rm -f "$T/key" "$T/awslog"; KEY_STATE=ok
out=$(printf 'AKIANEWKEYNEWKEY5678\nnew-secret-value\n' \
      | EXTRA="CG_JSON=1" cg_ creds set)
contains "it asks for the key id"         "$out" '"id":"aws-access-key-id"'
contains "  and for the secret"           "$out" '"id":"aws-secret-access-key"'
contains "  marking it secret"            "$out" '"secret":1'
check    "the id is saved"                "$(sed -n 1p "$T/key")" "AKIANEWKEYNEWKEY5678"
check    "  and the secret with it"       "$(sed -n 2p "$T/key")" "new-secret-value"
# Verified BEFORE the write, so the order in the log is the contract.
check    "  verified before it was written" \
         "$(grep -oE 'get-caller-identity|configure set aws_access_key_id' "$T/awslog" | head -1)" \
         "get-caller-identity"
contains "  and confirmed with the account" "$out" "credentials work (account 123456789012)"
# The event stream is what the app shows in its log pane. A secret that reaches
# it is a secret on screen and in a copied log.
lacks    "the secret is never echoed"     "$out" "new-secret-value"

echo "5. a key AWS rejects is never written"
# The old order wrote first and checked after, so one mistyped character
# replaced a key that worked - and every screen then reported rejected
# credentials about the key you had just destroyed.
printf 'AKIAOLDOLDOLDOLD0000\nthe-key-that-works\n' > "$T/key"
rm -f "$T/awslog"; KEY_STATE=bad
out=$(printf 'AKIABADBADBADBAD9999\nbad-secret\n' | EXTRA="CG_JSON=1" cg_ creds set)
rc=$?
contains "it says AWS refused it"         "$out" "AWS rejected that key"
contains "  keeping AWS's reason"         "$out" "InvalidClientTokenId"
contains "  and says nothing was saved"   "$out" "nothing was saved"
lacks    "  never claiming it works"      "$out" "credentials work"
check    "  and it fails"                 "$rc" "1"
check    "the old key is untouched"       "$(sed -n 1p "$T/key")" "AKIAOLDOLDOLDOLD0000"
check    "  secret and all"               "$(sed -n 2p "$T/key")" "the-key-that-works"
lacks    "  and nothing was written"      "$(cat "$T/awslog")" "configure set"
# The check happens with the candidate in the environment of that one call,
# where it beats the file without touching it.
contains "the candidate was checked"      "$(cat "$T/awslog")" "get-caller-identity"

echo "6. an empty answer saves nothing"
rm -f "$T/key"; KEY_STATE=ok
out=$(printf '\n\n' | EXTRA="CG_JSON=1" cg_ creds set)
contains "it says nothing was saved"     "$out" "nothing saved"
check    "  and wrote no key"            "$([[ -e $T/key ]] && echo wrote || echo none)" "none"

echo "7. asking and sudo are different questions"
# One test used to answer both, and it answered wrongly in both directions:
# `cg check --fix` in the app installed everything it could and then silently
# skipped the access key - which needs no terminal and no sudo at all - while a
# single -t test is also what sudo genuinely does need.
contains "there is a test for asking"    "$(cat lib/common.sh)" 'cg_can_ask() { [[ -t 0 ]] || cg_json; }'
contains "  and a separate one for sudo" "$(cat lib/laptop.sh)" 'laptop_tty() { [[ -t 0 ]]; }'
contains "the key question uses asking"  "$(cat lib/setup)" '&& cg_can_ask; then'
contains "  and so does creds set"       "$(cat lib/laptop.sh)" 'cg_can_ask || die "cg creds set'
# The sudo half must NOT accept the app: there is nowhere for sudo to print its
# password prompt, and it exits with "no tty present and no askpass program".
contains "installing still wants a terminal" "$(cat lib/laptop.sh)" "needs a terminal to ask for your password"
check "asking under CG_JSON works"       "$(printf 'x\ny\n' | EXTRA="CG_JSON=1" cg_ creds set | grep -c '"t":"ask"')" "2"

echo "8. status tells the two causes apart"
# Same symptom, different fix: with no CLI there is nothing to re-create.
PATH_USE="$T/bin:/nonexistent"; mv "$T/bin/aws" "$T/bin/aws.disabled"
st=$(cg_ status --json)
check    "no CLI is its own cause"       "$(python3 -I -c 'import json,sys;print(json.load(sys.stdin)["error"]["cause"])' <<<"$st")" "no-cli"
contains "  and says so in words"        "$(python3 -I -c 'import json,sys;print(json.load(sys.stdin)["error"]["credentials"])' <<<"$st")" "AWS CLI is not installed"
lacks    "  without blaming the key"     "$(python3 -I -c 'import json,sys;print(json.load(sys.stdin)["error"]["credentials"])' <<<"$st")" "rejected"
mv "$T/bin/aws.disabled" "$T/bin/aws"
KEY_STATE=bad
st=$(cg_ status --json)
check    "a dead key is the other"       "$(python3 -I -c 'import json,sys;print(json.load(sys.stdin)["error"]["cause"])' <<<"$st")" "rejected"

echo "9. a read with no CLI still answers"
# cg watcher --json died at exit 127 printing NOTHING, because an assignment
# from a command that does not exist is a failure and the script runs under
# set -e. The app had only "cg watcher failed (exit 127)" to show.
mv "$T/bin/aws" "$T/bin/aws.disabled"
out=$(cg_ watcher --json); rc=$?
check    "it exits 0"                    "$rc" "0"
check    "  with JSON"                   "$(python3 -I -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$out")" "yes"
out=$(cg_ library list --json)
check    "the library answers with its reason" \
         "$(python3 -I -c 'import json,sys;print("yes" if json.load(sys.stdin)["error"] else "no")' <<<"$out")" "yes"
check    "  and no games, rather than none" \
         "$(python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["games"]))' <<<"$out")" "null"
mv "$T/bin/aws.disabled" "$T/bin/aws"

echo "10. it is wired in"
contains "cg dispatches creds"           "$(cat cg)" "creds|credentials)"
contains "  and help names it"           "$(cat cg)" "cg creds [set]"
contains "setup has the mode"            "$(cat lib/setup)" "creds)   shift"

echo ""
echo "creds: $pass passed, $fail failed"
(( fail == 0 ))
