#!/usr/bin/env bash
# Pairing: success means Sunshine SAVED a client, not that it accepted a PIN.
#
# On 2026-09-14 `cg init` printed "paired" and Moonlight then refused to stream:
# Sunshine had accepted the PIN and saved no client. The function trusted the
# request. These cases give it a Sunshine that says yes and saves nothing.
#
# The stubbed API returns the live response shapes, captured from the box:
#   GET  /api/pin           {"pairings":[{"id":...}]}
#   GET  /api/clients/list  {"named_certs":[{"name","uuid","enabled"}],"status":true}
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }
mkdir -p "$T/bin"

cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url=${@: -1}; post=0; for a in "$@"; do [[ $a == POST ]] && post=1; done
case "$url" in
  */api/pin)
    if (( post )); then
      if [[ ${PIN_OK:-1} == 1 ]]; then
        [[ ${SAVE_CLIENT:-1} == 1 ]] && touch "$T/saved"
        echo '{"status":true}'
      else echo '{"status":false}'; fi
    elif [[ -f $T/pending ]]; then echo '{"pairings":[{"id":"req-1"}]}'
    else echo '{"pairings":[]}'; fi ;;
  */api/clients/list)
    printf '{"named_certs":[{"name":"old","uuid":"u-old","enabled":true}'
    [[ -f $T/saved ]] && printf ',{"name":"laptop","uuid":"u-new","enabled":true}'
    echo '],"status":true}' ;;
esac
FAKE
# Moonlight opens a pairing request - unless it is the offscreen run and the
# case says offscreen is broken, which is what drives the windowed fallback.
cat > "$T/bin/moonlight" <<'FAKE'
#!/usr/bin/env bash
[[ ${QT_QPA_PLATFORM:-} == offscreen && ${OFFSCREEN_BROKEN:-0} == 1 ]] && exit 0
touch "$T/pending"
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin"/*

run() {
  rm -f "$T/pending" "$T/saved"
  ( export T PATH="$T/bin:$PATH" PAIR_TRIES=3 PAIR_VERIFY_TRIES=3
    log() { echo "LOG: $*"; }
    source lib/pair.sh
    pair_moonlight 100.64.0.9 user pass; echo "rc=$?" ) 2>&1
}

echo "1. a client is saved: paired"
out=$(SAVE_CLIENT=1 run)
contains "succeeds" "$out" "rc=0"

echo "2. the PIN is accepted but no client is saved: NOT paired"
# The exact 2026-09-14 failure. The old code returned 0 here.
out=$(SAVE_CLIENT=0 run)
contains "fails"          "$out" "rc=1"
contains "and says why"   "$out" "saved no client"

echo "3. offscreen opens no request: the windowed fallback pairs"
# The fallback parsed /api/pin as a list with "uniqueid" - a shape the API does
# not return - so it could never find the request it was retrying for.
out=$(OFFSCREEN_BROKEN=1 SAVE_CLIENT=1 run)
contains "falls back"   "$out" "retrying with a window"
contains "and succeeds" "$out" "rc=0"

echo "4. Sunshine rejects the PIN: not paired"
out=$(PIN_OK=0 run)
contains "fails"        "$out" "rc=1"
contains "and says why" "$out" "rejected the PIN"

echo "5. a client that was ALREADY saved does not count as this pairing"
# u-old is present before and after; only a new uuid is proof.
out=$(SAVE_CLIENT=0 run)
contains "old client alone is not success" "$out" "rc=1"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
