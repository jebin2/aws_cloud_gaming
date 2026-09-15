#!/usr/bin/env bash
# lib/ssh-key.sh: reuse the box's key pair only when this laptop holds its private
# key. On a second laptop, or after losing the .pem, `cg init` reused the pair and
# every ssh step of the build failed.
#
# The keys are real RSA keys made here, and the fingerprint is computed the way
# AWS does for a pair it created (checked against a real pair on 2026-09-15). AWS
# itself is a fake.
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

mkdir -p "$T/bin" "$T/keys"
# AWS writes the traditional "BEGIN RSA PRIVATE KEY" form.
for k in a b; do
  openssl genrsa -traditional -out "$T/keys/$k.pem" 2048 2>/dev/null \
    || openssl genrsa -out "$T/keys/$k.pem" 2048 2>/dev/null
done
fp() { openssl pkcs8 -in "$1" -inform PEM -outform DER -topk8 -nocrypt | openssl sha1 -c | awk '{print $NF}'; }
fp "$T/keys/a.pem" > "$T/keys/a.fp"
check "a 59-character fingerprint, as AWS gives" "$(tr -d '\n' < "$T/keys/a.fp" | wc -c)" "59"

# KP: none | down | a file holding the pair's fingerprint. BOX: an instance id.
# CREATE_FAIL=1: create-key-pair fails.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *describe-key-pairs*)
    case $KP in
      none) echo "An error occurred (InvalidKeyPair.NotFound) when calling the DescribeKeyPairs operation: The key pair 'gamevps' does not exist" >&2; exit 254 ;;
      down) echo "Could not connect to the endpoint URL" >&2; exit 255 ;;
      *)    cat "$KP" ;;
    esac ;;
  *delete-key-pair*)    exit 0 ;;
  *create-key-pair*)    [[ ${CREATE_FAIL:-0} == 1 ]] && { echo "boom" >&2; exit 254; }; cat "$NEWKEY" ;;
  *describe-instances*) echo "${BOX:-None}" ;;
esac
FAKE
chmod +x "$T/bin/aws"

PEM="$T/home/.ssh/gamevps.pem"
fresh() { # fresh <pem: none|a|b|junk>
  rm -rf "$T/home" "$T/log"; mkdir -p "$T/home/.ssh"; touch "$T/log"
  case $1 in
    a|b)  cp "$T/keys/$1.pem" "$PEM"; chmod 600 "$PEM" ;;
    junk) echo "not a key" > "$PEM" ;;
  esac
}
run() { # run <KP> '<code>'
  env HOME="$T/home" LOG="$T/log" KP="$1" NEWKEY="$T/keys/b.pem" BOX="${BOX:-None}" \
      CREATE_FAIL="${CREATE_FAIL:-0}" PATH="$T/bin:$PATH" CG_COLOR=never \
      bash -c 'source lib/common.sh; source lib/ssh-key.sh; '"$2" 2>&1
}
state() { run "$1" 'key_state ap-south-2 gamevps "$HOME/.ssh/gamevps.pem"'; }

echo "1. key_state"
fresh a;    check "the pair's own key: match"        "$(state "$T/keys/a.fp")" "match"
fresh b;    check "another key: mismatch"            "$(state "$T/keys/a.fp")" "mismatch"
fresh junk; check "a file that is not a key: mismatch" "$(state "$T/keys/a.fp")" "mismatch"
fresh none; check "no .pem here: missing"            "$(state "$T/keys/a.fp")" "missing"
fresh a;    check "no pair in AWS: none"             "$(state none)" "none"
fresh a;    check "AWS not answering: unknown"       "$(state down)" "unknown"
echo "1f:51:ae:28:bf:89:e9:d8:1f:25:5d:37:2d:7d:b8:ca" > "$T/keys/imported.fp"
fresh a;    check "an imported pair: unknown"        "$(state "$T/keys/imported.fp")" "unknown"

echo "2. key_ensure - what cg init does, where no box exists"
ensure() { run "$1" 'key_ensure ap-south-2 gamevps "$HOME/.ssh/gamevps.pem"; echo "rc=$?"'; }
fresh a; r=$(ensure "$T/keys/a.fp")
contains "match: reused"                     "$r" "rc=0"
lacks    "  nothing created or deleted"      "$(cat "$T/log")" "key-pair --"
fresh none; r=$(ensure none)
contains "no pair: created"                  "$(cat "$T/log")" "create-key-pair"
lacks    "  nothing deleted"                 "$(cat "$T/log")" "delete-key-pair"
check    "  the .pem is the new key"         "$(cmp -s "$PEM" "$T/keys/b.pem" && echo same)" "same"
check    "  readable by you alone"           "$(stat -c %a "$PEM")" "600"
fresh none; r=$(ensure "$T/keys/a.fp")
contains "missing: said"                     "$r" "is not on this laptop"
check    "  deleted, then created"           "$(grep -o 'delete-key-pair\|create-key-pair' "$T/log" | tr '\n' ' ')" "delete-key-pair create-key-pair "
check    "  and the new .pem is there"       "$(cmp -s "$PEM" "$T/keys/b.pem" && echo same)" "same"
fresh b; cp "$T/keys/a.pem" "$PEM"; cp "$T/keys/a.fp" "$T/keys/other.fp"
openssl genrsa -traditional -out "$T/keys/c.pem" 2048 2>/dev/null || openssl genrsa -out "$T/keys/c.pem" 2048 2>/dev/null
cp "$T/keys/c.pem" "$PEM"
r=$(ensure "$T/keys/a.fp")
contains "mismatch: said"                    "$r" "is not the key pair's private key"
kept=$(ls "$T/home/.ssh/" | grep -- '-replaced-' || true)
contains "  the old file is kept"            "$r" "the old file is kept as"
check    "  with its contents"               "$(cmp -s "$T/home/.ssh/$kept" "$T/keys/c.pem" && echo same)" "same"
check    "  and the new .pem is the new key" "$(cmp -s "$PEM" "$T/keys/b.pem" && echo same)" "same"
fresh a; r=$(ensure down)
contains "AWS not answering: left alone"     "$r" "rc=0"
lacks    "  nothing deleted"                 "$(cat "$T/log")" "delete-key-pair"
fresh none; r=$(CREATE_FAIL=1 ensure none)
contains "create fails: fails"               "$r" "rc=1"
check    "  and leaves no empty .pem"        "$([[ -e $PEM ]] && echo there || echo gone)" "gone"

echo "3. key_report - cg check's line"
report() { run "$1" 'key_report ap-south-2 gamevps "$HOME/.ssh/gamevps.pem"; echo "rc=$?"'; }
fresh a; r=$(report "$T/keys/a.fp")
contains "match: said"                       "$r" "ssh key ~/.ssh/gamevps.pem matches the key pair"
lacks    "  no need to look for a box"       "$(cat "$T/log")" "describe-instances"
fresh none; r=$(report none)
contains "no pair: init creates one"         "$r" "cg init creates one"
fresh none; r=$(report "$T/keys/a.fp")
contains "missing, no box: init replaces it" "$r" "cg init replaces the key pair"
contains "  and says what that breaks"       "$r" "the .pem on any other laptop stops working"
contains "  not an error"                    "$r" "rc=0"
fresh b; r=$(BOX=i-0abc report "$T/keys/a.fp")
contains "mismatch with a box: stops"        "$r" "cannot log in to it"
contains "  says to copy the .pem"           "$r" "Copy ~/.ssh/gamevps.pem from the laptop that built the box"
lacks    "  and never reaches rc"            "$r" "rc=0"
fresh a; r=$(report down)
contains "AWS not answering: a warning"      "$r" "could not compare"

echo "4. wired in"
check "cg check reports it"                  "$(grep -c '^key_report "$REGION" "$TS_HOST"' lib/setup)" "1"
check "provision ensures it"                 "$(grep -c '^  key_ensure "$REGION" "$KEY_NAME" "$KEY_FILE"' lib/provision.sh)" "1"
check "provision no longer creates it alone" "$(grep -c 'create-key-pair' lib/provision.sh)" "0"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
