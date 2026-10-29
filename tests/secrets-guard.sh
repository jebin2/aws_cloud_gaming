#!/usr/bin/env bash
# No secret, and nothing that names the owner's account, is committed.
#
# The shapes below are generic: they say what a key or a private address LOOKS like,
# so they are safe to publish. The owner's own identifiers (account id, tailnet name,
# e-mail, node addresses) must not be written into this file - a guard that contains
# them is itself the leak - so they arrive from outside, as a regex in GUARD_EXTRA:
#
#     GUARD_EXTRA='one|two|three' bash tests/secrets-guard.sh
#
# In CI that is the repository secret GUARD_EXTRA. Without it only the shapes run.
#
# The tests use fake values on purpose (a key id that ends in 1234, account
# 123456789012). Those are listed in ALLOWED, exactly, so a real value next to them
# is still caught. The suite first proves each shape fires on a deliberately bad
# string, because a guard that quietly matches nothing is worse than none.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }

# name|regex (extended, case-sensitive unless noted)
SHAPES=(
  'an AWS access key id|\b(AKIA|ASIA)[A-Z0-9]{16}\b'
  'an AWS secret key|aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+=]{40}'
  'a Tailscale key|tskey-(auth|api|client)-[A-Za-z0-9]{10,}'
  'a private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'a tailnet host name|[a-z0-9-]+\.tail[0-9a-f]{6}\.ts\.net'
  'an ntfy topic|ntfy\.sh/[A-Za-z0-9_-]{10,}'
  'an account id in an ARN|arn:aws:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}:'
  'a security group id|\bsg-[0-9a-f]{17}\b'
)

# The fake values the tests and examples use. A line is let through only when
# everything the shape matched on it is one of these.
ALLOWED='AKIABADBADBADBAD9999|AKIAGOODGOODGOOD1234|AKIAIOSFODNN7EXAMPLE|tskey-(auth|api|client)-x+|tskey-auth-kABC123CNTRL|tskey-(auth|api|client)-[A-Za-z]*(live|dead|fresh|old|new)[A-Za-z0-9]*|arn:aws:[a-z0-9-]*:[a-z0-9-]*:(123456789012|000000000000|111111111111):|sg-0123456789abcdef0|ntfy\.sh/(your-topic|example-topic|topic-[a-z]+)'

# Reads text on stdin; prints each line that holds a shape that is not an allowed fake.
flag() {   # flag <regex>
  local re=$1 line m left
  while IFS= read -r line; do
    left=$(printf '%s' "$line" | grep -oE -e "$re" | grep -vxE -e "$ALLOWED" || true)
    [[ -z $left ]] || printf '%s\n' "$line"
  done
}

# 1. Each shape fires on a bad string. Assembled from parts so this file does not
#    contain one.
p() { printf '%s' "$1$2"; }
samples=(
  "$(p AKIA ZZZZZZZZZZZZZZZZ)"
  "aws_secret_access_key = $(p abcdefghijklmnopqrst abcdefghijklmnopqrst)"
  "$(p tskey-auth- k3J9sd8fh2K4lMn)"
  "$(p '-----BEGIN ' 'RSA PRIVATE KEY-----')"
  "box.$(p tail 0a1b2c).ts.net"
  "https://ntfy.sh/$(p realtopic 123456)"
  "arn:aws:iam::$(p 4829 17365402):role/x"
  "$(p sg- 0a1b2c3d4e5f60718)"
)
i=0
for s in "${SHAPES[@]}"; do
  name=${s%%|*}; re=${s#*|}
  if [[ -n $(printf '%s\n' "${samples[$i]}" | flag "$re") ]]; then ok "the guard catches $name"
  else bad "the guard misses $name"; fi
  i=$((i+1))
done
# ...and lets the fakes through.
for fake in 'AKIABADBADBADBAD9999' 'tskey-auth-xxxxxxxxxxxx' 'arn:aws:iam::123456789012:user/example' 'sg-0123456789abcdef0'; do
  hit=
  for s in "${SHAPES[@]}"; do [[ -z $(printf '%s\n' "$fake" | flag "${s#*|}") ]] || hit=1; done
  [[ -z $hit ]] && ok "the fake $fake is let through" || bad "the fake $fake is flagged"
done

# 2. The tree. git grep reads tracked files only and skips binaries.
for s in "${SHAPES[@]}"; do
  name=${s%%|*}; re=${s#*|}
  found=$(git grep -InE -e "$re" -- . ':!tests/secrets-guard.sh' 2>/dev/null | flag "$re")
  if [[ -z $found ]]; then ok "no tracked file holds $name"
  else bad "a tracked file holds $name"; printf '%s\n' "$found" | cut -c1-120 | sed 's/^/        /'; fi
done

# 3. Files that should never be tracked at all.
files=$(git ls-files | grep -E '(^|/)\.env$|\.pem$|(^|/)id_(rsa|ed25519)$|(^|/)credentials$' || true)
[[ -z $files ]] && ok "no .env, .pem, ssh key or credentials file is tracked" || { bad "tracked secret files:"; echo "$files" | sed 's/^/        /'; }

# 4. The owner's own identifiers, if the caller has them.
if [[ -n ${GUARD_EXTRA:-} ]]; then
  found=$(git grep -InEi -e "$GUARD_EXTRA" -- . ':!tests/secrets-guard.sh' 2>/dev/null | cut -d: -f1-2 || true)
  [[ -z $found ]] && ok "no tracked file holds the owner's own identifiers (GUARD_EXTRA)" \
    || { bad "GUARD_EXTRA matches (file:line only; the values are not printed)"; printf '%s\n' "$found" | sed 's/^/        /'; }
else
  echo "  (GUARD_EXTRA is not set: the owner's own identifiers were not checked)"
fi

echo ""
echo "secrets-guard: $pass passed, $fail failed"
(( fail == 0 ))
