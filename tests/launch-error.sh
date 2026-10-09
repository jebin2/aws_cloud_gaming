#!/usr/bin/env bash
# A failed launch must say WHY, in the first line, and only about the thing that
# actually happened.
#
# What this is guarding against: the old block printed AWS's message and then 25
# lines of "the things this is usually", listing every cause. On a terminal the
# real error scrolled off the top; in the desktop app every one of those lines
# arrived as `kind: cont`, indistinguishable from build progress, so the app's
# only report of a failed build was "stopped (exit 1)".
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# The real classifier, not a copy.
report() { # report <stderr text>   - SPOT= picks the purchase model
  printf '%s\n' "$1" > "$T/err"
  ( TYPE=g6.xlarge REGION=ap-south-2 INSTANCE_PROFILE=gamevps-box \
    KEY_NAME=gamevps KEY_FILE=/home/u/.ssh/gamevps.pem SPOT="${SPOT:-1}" \
    bash -c 'source lib/launch-error.sh; launch_error_report "$1"' _ "$T/err" 2>&1 )
}

AWSERR='aws: [ERROR]: An error occurred (%s) when calling the RunInstances operation: %s'

echo "1. the code and AWS's own sentence come first"
out=$(report "$(printf "$AWSERR" InsufficientInstanceCapacity \
       'There is no Spot capacity available that matches your request.')")
check    "first line is the marked failure, with the code" \
         "$(head -1 <<<"$out")" "!! launch failed: InsufficientInstanceCapacity"
contains "AWS's sentence is kept verbatim" "$out" "no Spot capacity available that matches your request"
lacks    "the CLI's framing is stripped"   "$out" "An error occurred ("

echo "1b. a retried call has extra framing, and it still comes off"
# The real message from a spot launch into a short region, verbatim: the CLI
# appends "(reached max retries: N)" after the operation name, which the first
# version of this stripper did not expect - so the whole "An error occurred ..."
# preamble survived into the one line meant to be AWS's own sentence.
out2=$(report 'aws: [ERROR]: An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation (reached max retries: 2): Insufficient capacity.')
check    "the message is just the sentence" \
         "$(sed -n 2p <<<"$out2" | sed 's/^ *//')" "Insufficient capacity."
lacks    "no CLI preamble survives"    "$out2" "An error occurred ("
lacks    "and no retry bookkeeping"    "$out2" "reached max retries"
contains "the code is still read"      "$out2" "!! launch failed: InsufficientInstanceCapacity"

echo "2. one cause, not the catalogue"
contains "names the region and type" "$out" "No spare g6.xlarge SPOT capacity in ap-south-2"
contains "offers on-demand"          "$out" "GAME_SPOT=0 cg init"
lacks    "says nothing about PassRole" "$out" "iam:PassRole"
lacks    "says nothing about the spot quota" "$out" "L-3819A6DF"
check    "and stays short" "$(( $(wc -l <<<"$out") < 12 ? 1 : 0 ))" "1"

echo "2b. the same shortage says different things on demand"
# The advice used to be "GAME_SPOT=0 cg init" whatever had been asked for, so
# someone already on demand was told to do the thing they had just done. On
# demand there is no fuller-priced model to fall back to, and saying so is the
# whole point of the message.
od=$(SPOT=0 report "$(printf "$AWSERR" InsufficientInstanceCapacity 'Insufficient capacity.')")
contains "on demand: says the region is short outright" "$od" "capacity in ap-south-2 at all"
contains "  and names the purchase model"   "$od" "ON DEMAND"
lacks    "  never suggests what is already set" "$od" "GAME_SPOT=0 cg init"
contains "  offers another GPU pool"        "$od" "cg machines"
contains "  and another region, with the catch" "$od" "your archive is not in it"
contains "  and says waiting works"         "$od" "capacity comes back without warning"
sp=$(SPOT=1 report "$(printf "$AWSERR" InsufficientInstanceCapacity 'Insufficient capacity.')")
contains "spot: on demand IS the way out"   "$sp" "GAME_SPOT=0 cg init"
contains "  and says why it should work"    "$sp" "first claim on the same machines"

echo "3. each code gets its own explanation"
out=$(report "$(printf "$AWSERR" MaxSpotInstanceCountExceeded 'Max spot instance count exceeded.')")
contains "spot count: tells you to wait"  "$out" "wait ~2 minutes"
contains "spot count: names the quota"    "$out" "L-3819A6DF"
lacks    "spot count: not a capacity story" "$out" "No spare g6.xlarge spot capacity"

out=$(report "$(printf "$AWSERR" VcpuLimitExceeded 'You have requested more vCPU capacity than your current limit.')")
contains "vcpu limit: names on-demand quota" "$out" "on-demand vCPU quota in ap-south-2"
lacks    "vcpu limit: does not suggest on-demand as the fix" "$out" "GAME_SPOT=0 cg init"

out=$(report "$(printf "$AWSERR" UnauthorizedOperation 'You are not authorized to perform this operation.')")
contains "unauthorized: explains PassRole"   "$out" "iam:PassRole"
contains "unauthorized: names the profile"   "$out" "gamevps-box"
contains "unauthorized: says what breaks"    "$out" "will not survive a stop"

out=$(report "$(printf "$AWSERR" InvalidKeyPair.NotFound "The key pair 'gamevps' does not exist")")
contains "missing key pair: names the repair" "$out" "cg check --fix"
contains "missing key pair: names the pem"    "$out" "/home/u/.ssh/gamevps.pem"

echo "4. an account-level refusal is not a retry"
out=$(report "$(printf "$AWSERR" AuthFailure 'AWS was not able to validate the provided access credentials')")
contains "says the account was refused" "$out" "refused the ACCOUNT"
contains "says retrying will not help"  "$out" "no amount of retrying fixes this one"

echo "5. an unknown code still names itself and falls back to the list"
out=$(report "$(printf "$AWSERR" SomeBrandNewError 'Something nobody has seen.')")
contains "the code is still reported"   "$out" "!! launch failed: SomeBrandNewError"
contains "AWS's sentence survives"      "$out" "Something nobody has seen"
contains "admits it is unknown"         "$out" "Not an error this script has been taught" 
contains "and lists the usual causes"   "$out" "MaxSpotInstanceCountExceeded"

echo "6. a message with no code at all still produces a marked failure"
out=$(report "Could not connect to the endpoint URL")
check    "still marked as a failure" "$(head -1 <<<"$out")" "!! launch failed"
contains "the text is kept"          "$out" "Could not connect to the endpoint URL"
contains "falls back to the list"    "$out" "usual causes"

echo "7. the marker is what the relay keys on"
contains "exactly one marked line" "$(grep -c '^!! ' <<<"$out")" "1"

echo "8. the report goes to stdout, where the relay can see it"
# lib/setup pipes provision.sh's stderr into cg_relay only on a terminal or
# under CG_JSON=1. A report written to stderr was therefore invisible to the
# app, which showed only die()'s "see the launch error above" with nothing
# above it. This is that bug, pinned down.
contains "provision.sh does not redirect it to stderr" \
         "$(grep -A1 'launch_error_report "\$ERRF"' lib/provision.sh | head -1)" 'launch_error_report "$ERRF"'
check    "  with no >&2 on the call" \
         "$(grep -c 'launch_error_report "\$ERRF" >&2' lib/provision.sh)" "0"
contains "and setup relays stderr under CG_JSON" \
         "$(cat lib/setup)" 'if _cg_styled || cg_json; then lib/provision.sh 2>&1 | cg_relay'

echo ""
echo "launch-error: $pass passed, $fail failed"
(( fail == 0 ))
