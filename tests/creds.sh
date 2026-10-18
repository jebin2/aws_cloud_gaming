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
      # What the CLI says with no network. Two lines, like the real thing.
      offline) echo "Could not connect to the endpoint URL: \"https://sts.ap-south-2.amazonaws.com/\"" >&2
               exit 255 ;;
      nokey)   echo "Unable to locate credentials. You can configure credentials by running \"aws configure\"." >&2
               exit 253 ;;
    esac ;;
esac
FAKE
chmod +x "$T/bin/aws"

# The Tailscale API, as a fake curl: TS_STATE picks the HTTP code, and the
# token it was given is logged so a test can prove WHICH one was checked.
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  case $a in "Authorization: Bearer "*) echo "token ${a#Authorization: Bearer }" >> "${CURL_LOG:-/dev/null}" ;; esac
done
case "${TS_STATE:-ok}" in
  ok)       printf '200' ;;
  rejected) printf '401' ;;
  *)        printf '000' ;;
esac
FAKE
chmod +x "$T/bin/curl"

# Tailscale itself: TS_UP=no means signed out, and `up` writes the login URL
# the way the real one does, then "signs in" by flipping TS_UP.
cat > "$T/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
echo "tailscale $*" >> "${TS_LOG:-/dev/null}"
case "$1" in
  status)
    [[ -e ${TS_UP_FILE:-/nonexistent} ]] || exit 1
    [[ $2 == --json ]] && echo '{"Self":{"DNSName":"laptop.tailnet.ts.net."}}'
    exit 0 ;;
  up)
    echo "To authenticate, visit:"
    echo ""
    echo "        https://login.tailscale.com/a/abc123def456"
    echo ""
    [[ ${TS_UP_FAILS:-0} == 1 ]] && exit 1
    : > "${TS_UP_FILE:?}"
    exit 0 ;;
esac
FAKE
chmod +x "$T/bin/tailscale"
# The daemon is verified by ASKING systemctl afterwards rather than by
# trusting the exit code of the thing that was meant to start it, so the fake
# needs a state to be asked about.
cat > "$T/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "${TS_LOG:-/dev/null}"
case "$1" in
  is-active) [[ -e ${TSD_FILE:-/nonexistent} ]] || exit 3 ;;
  enable)    : > "${TSD_FILE:?}" ;;
esac
exit 0
FAKE
chmod +x "$T/bin/systemctl"
printf '#!/usr/bin/env bash
echo "pkexec $*" >> "${TS_LOG:-/dev/null}"
exec "$@"
' > "$T/bin/pkexec"; chmod +x "$T/bin/pkexec"

cg_() { # cg_ <args...> - EXTRA passes env through
  # shellcheck disable=SC2086
  ( cd "$T/repo" && env -i CG_PRICES_FILE="${CG_PRICES_FILE:-}" CG_INR_PER_USD=88 PATH="$PATH_USE" HOME="$T/home" CG_COLOR=never \
      CFG="$T/key" AWS_LOG="$T/awslog" KEY_STATE="${KEY_STATE:-ok}" \
      CURL_LOG="$T/curllog" TS_STATE="${TS_STATE:-ok}" \
      TS_LOG="$T/tslog" TS_UP_FILE="$T/tsup" TS_UP_FAILS="${TS_UP_FAILS:-0}" \
      TSD_FILE="$T/tsd" \
      WAYLAND_DISPLAY="${WAYLAND_DISPLAY_FOR_TEST:-wayland-1}" \
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

echo "3b. a key that could not be checked at all"
# The window used to say "AWS rejected this access key" to a laptop with no
# network, which is a lie about a call that never arrived - and it sent people
# to replace a key that was fine. Only cg can tell these apart: the app sees
# one error string.
KEY_STATE=offline
out=$(cg_ creds --json)
check    "not valid, because it is unusable" "$(j valid <<<"$out")" "false"
check    "  but nothing rejected it"         "$(j reason <<<"$out")" '"unreachable"'
contains "  and the CLI's words are kept"    "$(j error <<<"$out")" "Could not connect to the endpoint"

echo "3c. no key on the laptop at all"
# Also not a rejection: there is nothing here to reject. It is the state a
# fresh laptop is in, and it takes a different sentence and a different button.
KEY_STATE=nokey
out=$(cg_ creds --json)
check    "not valid"                      "$(j valid <<<"$out")" "false"
check    "  and the reason is no key"     "$(j reason <<<"$out")" '"no-key"'

echo "3d. the reason for the other three states"
KEY_STATE=bad
check    "a refused key says rejected"    "$(j reason <<<"$(cg_ creds --json)")" '"rejected"'
KEY_STATE=ok
check    "a working key has no reason"    "$(j reason <<<"$(cg_ creds --json)")" "null"
mv "$T/bin/aws" "$T/bin/aws.disabled"
check    "no CLI is its own reason"       "$(j reason <<<"$(cg_ creds --json)")" '"no-cli"'
mv "$T/bin/aws.disabled" "$T/bin/aws"
KEY_STATE=ok

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

echo "9b. the Tailscale API token"
# The other key only a person can give cg, and the one thing .env cannot answer:
# a token that is set and a token that is set and refused look identical there,
# which is why this asks Tailscale.
PATH_USE="$T/bin:/nonexistent"
printf 'TAILSCALE_API_KEY=tskey-api-oldoldold\n' > "$T/repo/.env"
j=$(cg_ creds tailscale --json)
check    "a working token is valid"       "$(j valid <<<"$j")" "true"
check    "  and present"                  "$(j present <<<"$j")" "true"
j=$(TS_STATE=rejected cg_ creds tailscale --json)
check    "a refused token is not"         "$(j valid <<<"$j")" "false"
contains "  with the code"                "$(j detail <<<"$j")" "401"
# Unreachable is the third answer, and it says nothing about the token: a new
# token is not the fix for a network that is down.
j=$(TS_STATE=down cg_ creds tailscale --json)
check    "unreachable is neither"         "$(j valid <<<"$j")" "null"
check    "  still present"                "$(j present <<<"$j")" "true"
printf '\n' > "$T/repo/.env"
j=$(cg_ creds tailscale --json)
check    "no token at all"                "$(j present <<<"$j")" "false"
check    "  and valid says nothing"       "$(j valid <<<"$j")" "null"

echo "9c. setting a token checks it first"
printf 'TAILSCALE_API_KEY=tskey-api-oldoldold\n' > "$T/repo/.env"
rm -f "$T/curllog"
out=$(printf 'tskey-api-newnewnew\n' | EXTRA="CG_JSON=1 TS_STATE=rejected" cg_ creds set tailscale)
rc=$?
contains "it asks for the token"          "$out" '"id":"tailscale-api-token"'
contains "  as a secret"                  "$out" '"secret":1'
contains "the refusal is reported"        "$out" "Tailscale rejected that token"
contains "  and nothing was saved"        "$out" "nothing was saved"
check    "  it fails"                     "$rc" "1"
check    "the old token is untouched"     "$(grep TAILSCALE "$T/repo/.env")" "TAILSCALE_API_KEY=tskey-api-oldoldold"
contains "  and the NEW one was checked"  "$(cat "$T/curllog")" "tskey-api-newnewnew"
out=$(printf 'tskey-api-newnewnew\n' | EXTRA="CG_JSON=1" cg_ creds set tailscale)
contains "a good token is saved"          "$(grep TAILSCALE "$T/repo/.env")" "TAILSCALE_API_KEY=tskey-api-newnewnew"
contains "  and confirmed"                "$out" "the token works"
out=$(printf 'not-a-token\n' | EXTRA="CG_JSON=1" cg_ creds set tailscale)
contains "a token must look like one"     "$out" "they start with tskey-"
contains "and the status says both halves" "$(cg_ creds tailscale)" "api token        works"
rm -f "$T/repo/.env"

echo "9d. the .csv import is gone, and stays gone"
# cg used to search $HOME for the access-key .csv the console hands out, offer
# to import it, and tell you to delete the file afterwards. That made a
# plaintext key in a home directory a supported way to carry a credential, and
# a found-file prompt is a surprising thing for a build to do. The key is
# pasted now, and checked before it is written.
src=$(cat lib/setup lib/laptop.sh cg)
lacks "no csv importer"                  "$src" "import_key_csv"
lacks "  and no env var for one"         "$src" "AWS_KEY_CSV"
lacks "  nothing hunts for the file"     "$src" "accessKeys"
lacks "  and nothing asks to import"     "$src" "import-key-csv"
contains "the failure names the way in"  "$(cat lib/setup)" "Paste a key:  cg creds set"
lacks "the docs do not offer it either"  "$(cat docs/getting-started.md)" "AWS_KEY_CSV"
# The .csv is still gitignored: the file is no longer part of any flow, and
# that is exactly when a stray copy gets committed by accident.
contains "a stray csv still cannot be committed" "$(cat .gitignore)" "*.csv"

echo "9e. signing in to Tailscale, without a terminal"
# `sudo tailscale up` was the only answer the app could give, and it is not an
# answer in a window. Root here is polkit's job, exactly as it is for installs.
rm -f "$T/tsup" "$T/tslog" "$T/tsd"
out=$(EXTRA="CG_JSON=1" cg_ creds tailscale signin)
rc=$?
check    "it succeeds"                    "$rc" "0"
contains "it starts the daemon first"     "$(cat "$T/tslog")" "systemctl enable --now tailscaled"
check    "  through polkit, not sudo"     "$(grep -cE '^pkexec .*/tailscale up$' "$T/tslog")" "1"
check    "  tailscale up ran"             "$(grep -c '^tailscale up' "$T/tslog")" "1"
# The URL is the whole point and it is useless after the command returns, so it
# is relayed while the command is still waiting on it.
contains "the login link is relayed"      "$out" "https://login.tailscale.com/a/abc123def456"
contains "  on a line of its own"         "$out" "sign in here: https://login.tailscale.com/a/abc123def456"
contains "  and the end is confirmed"     "$out" "signed in"
out=$(EXTRA="CG_JSON=1" cg_ creds tailscale signin)
contains "running it again says so"       "$out" "already signed in"
# A sign-in that did not take must not be reported as one.
rm -f "$T/tsup"
out=$(EXTRA="CG_JSON=1 TS_UP_FAILS=1" cg_ creds tailscale signin); rc=$?
contains "a failed sign-in says so"       "$out" "still not signed in"
lacks    "  and never claims success"     "$out" "ok signed in"
check    "  and fails"                    "$rc" "1"
# With no polkit and no terminal there is nothing to do but say the command.
rm -f "$T/bin/pkexec" "$T/tsup"
out=$(EXTRA="CG_JSON=1 WAYLAND_DISPLAY_FOR_TEST=" cg_ creds tailscale signin)
contains "no root: it says why"           "$out" "cannot sign in from here"
contains "  and what to type"             "$out" "sudo tailscale up"
printf '#!/usr/bin/env bash\necho "pkexec $*" >> "${TS_LOG:-/dev/null}"\nexec "$@"\n' > "$T/bin/pkexec"; chmod +x "$T/bin/pkexec"

# The likeliest way this fails on a fresh desktop: pkexec is installed and
# nothing is listening to authenticate, which says nothing useful on its own.
cat > "$T/bin/pkexec" <<'FAKE'
#!/usr/bin/env bash
echo "Error executing command as another user: No authentication agent found." >&2
exit 127
FAKE
chmod +x "$T/bin/pkexec"
rm -f "$T/tsup" "$T/tsd"
out=$(EXTRA="CG_JSON=1" cg_ creds tailscale signin)
contains "polkit's refusal is relayed"    "$out" "No authentication agent found"
contains "  and the daemon is not claimed" "$out" "could not start tailscaled"
contains "  and explained"                "$out" "no polkit agent is answering"
contains "  with how to start one"        "$out" "hyprpolkitagent"
contains "  and the way round it"         "$out" "sudo tailscale up"
printf '#!/usr/bin/env bash\necho "pkexec $*" >> "${TS_LOG:-/dev/null}"\nexec "$@"\n' > "$T/bin/pkexec"; chmod +x "$T/bin/pkexec"

echo "9f. the one web address the app may open"
# The window denies every navigation and every new window; Tailscale's sign-in
# cannot finish without a browser, so exactly that host is allowed - and the
# main process checks it rather than trusting the renderer.
main=$(cat app/main/index.js)
contains "the host is pinned"             "$main" "login.tailscale.com"
contains "  https only"                   "$main" "u.protocol !== 'https:'"
contains "  checked in the main process"  "$main" "ipcMain.handle('cg:open-signin'"
contains "  and nothing else opens"       "$main" "setWindowOpenHandler(() => ({ action: 'deny' }))"
contains "the preload exposes just that"  "$(cat app/main/preload.js)" "openSignIn:"

echo "10. it is wired in"
contains "cg dispatches creds"           "$(cat cg)" "creds|credentials)"
contains "  and help names it"           "$(cat cg)" "cg creds [set [aws|tailscale]]"
contains "setup has the mode"            "$(cat lib/setup)" "creds)   shift"
contains "  and the tailscale one"        "$(cat lib/setup)" "tailscale)     shift"
contains "the app reads the token state"  "$(cat app/renderer/app.js)" "[['creds', 'tailscale', '--json'], 'tskey']"

echo ""
echo "creds: $pass passed, $fail failed"
(( fail == 0 ))
