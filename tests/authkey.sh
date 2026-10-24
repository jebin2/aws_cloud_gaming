#!/usr/bin/env bash
# The box's own Tailscale key: kept while it works, replaced when it does not.
#
# Two keys are easy to confuse and they are not interchangeable:
#
#   tskey-api-...   yours. Lists and deletes devices, creates keys. `tailscale
#                   up` will not take it, and it must never travel in EC2
#                   user-data, which is readable from inside the instance.
#   tskey-auth-...  the box's. Registers one machine and nothing else.
#
# So the token stays on the laptop and mints what the box needs. A build used to
# stop and ask for the second one by hand, and a stored one that had expired was
# found out at BOOT - after the instance was launched and billing.
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

mkdir -p "$T/bin" "$T/home"
for b in bash sh env grep sed awk python3 cat cut tr sort head tail date stat \
         mktemp rm mv cp chmod id uname dirname basename readlink wc find sleep \
         mkdir tee touch timeout; do
  p=$(command -v "$b") && ln -sf "$p" "$T/bin/$b"
done

# api.tailscale.com, as a fake curl. One file per answer, so a case can set up
# exactly the tailnet it needs:
#   KEYGET   the body for GET /keys/<id>, or the literal 404
#   KEYPOST  the body for POST /keys, or a code to fail with
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url=""; method=GET
for a in "$@"; do
  case $a in
    https://*) url=$a ;;
    -d)        method=POST ;;
    DELETE)    method=DELETE ;;
  esac
done
echo "$method $url" >> "${API_LOG:-/dev/null}"
case "$method $url" in
  *"DELETE"*/keys/*) printf '200'; exit 0 ;;
  *POST*/keys)
    if [[ -n ${POST_FAIL:-} ]]; then printf '%s\n%s' "${POST_BODY:-{\"message\":\"calling user does not have access\"}}" "$POST_FAIL"; exit 0; fi
    printf '%s\n200' "${POST_BODY:-{\"key\":\"tskey-auth-kNEW111CNTRL-freshsecret\",\"id\":\"kNEW111CNTRL\"}}"; exit 0 ;;
  *GET*/keys/*)
    [[ ${KEYGET:-} == 404 ]] && { printf '{"message":"key not found"}\n404'; exit 0; }
    [[ ${KEYGET:-} == 401 ]] && { printf '{"message":"API token invalid"}\n401'; exit 0; }
    [[ ${KEYGET:-} == down ]] && exit 7
    printf '%s\n200' "${KEYGET:?}"; exit 0 ;;
  *GET*/tailnet/-/devices) printf '200'; exit 0 ;;
esac
printf '000'
FAKE
chmod +x "$T/bin/curl"

run() { # run '<code>' - with lib/ loaded and the fake API on PATH
  # shellcheck disable=SC2086
  ( cd "$PWD" && env -i CG_PRICES_FILE="${CG_PRICES_FILE:-}" CG_INR_PER_USD=88 PATH="$T/bin" HOME="$T/home" CG_COLOR=never \
      API_LOG="$T/apilog" KEYGET="${KEYGET:-}" POST_FAIL="${POST_FAIL:-}" \
      POST_BODY="${POST_BODY:-}" \
      TAILSCALE_API_KEY="${TAILSCALE_API_KEY-tskey-api-tok1-secret}" \
      TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY-}" \
      CG_ENV_FILE="$T/home/.env" \
      bash -c 'source lib/common.sh; source lib/env-file.sh; source lib/laptop.sh; '"$1" 2>&1 )
}
future() { python3 -I -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=d)).isoformat().replace("+00:00","Z"))' 2>/dev/null; }
at_days() { python3 -I -c "
import datetime, sys
d = int(sys.argv[1])
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=d)).isoformat().replace('+00:00','Z'))" "$1"; }

echo "1. the id, which is what the API knows a key by"
check "an auth key"      "$(run 'tskey_auth_id tskey-auth-kABC123CNTRL-thesecret')" "kABC123CNTRL"
check "  an api token"   "$(run 'tskey_auth_id tskey-api-kWHAT456-thesecret')"      "kWHAT456"
check "  and nothing"    "$(run 'tskey_auth_id ""')"                                 ""

echo "2. a key that is still good is kept"
KEYGET="{\"id\":\"kOLD1\",\"expires\":\"$(at_days 60)\"}"
out=$(TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps')
contains "it says so"              "$out" "still valid"
contains "  and hands it back"     "$out" "tskey-auth-kOLD1-sec"
lacks    "  minting nothing"       "$(cat "$T/apilog")" "POST"
lacks    "  and deleting nothing"  "$(cat "$T/apilog")" "DELETE"

echo "3. an expired key is replaced, and the dead one deleted"
rm -f "$T/apilog"
KEYGET="{\"id\":\"kOLD1\",\"expires\":\"$(at_days -1)\"}"
out=$(TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps')
contains "it says what happened"   "$out" "has expired - replacing it"
contains "  mints a new one"       "$(cat "$T/apilog")" "POST https://api.tailscale.com/api/v2/tailnet/-/keys"
contains "  deletes the old one"   "$(cat "$T/apilog")" "DELETE https://api.tailscale.com/api/v2/tailnet/-/keys/kOLD1"
contains "  and says so"           "$out" "the old key was deleted"
contains "  handing back the new"  "$out" "tskey-auth-kNEW111CNTRL-freshsecret"
# Order matters: deleting first and then failing to mint would leave the laptop
# with no key at all.
check "the new key exists before the old one goes" \
      "$(grep -oE 'POST|DELETE' "$T/apilog" | head -1)" "POST"

echo "4. a key that expires DURING a build counts as expired"
# A key with minutes left is a box that never joins - and that is found out
# after the instance is running and billing.
rm -f "$T/apilog"
KEYGET="{\"id\":\"kOLD1\",\"expires\":\"$(python3 -I -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=20)).isoformat().replace("+00:00","Z"))')\"}"
out=$(TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps')
contains "it is replaced too"      "$out" "replacing it"

echo "5. a key the console deleted"
rm -f "$T/apilog"
KEYGET=404
out=$(TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps')
contains "it says it is gone"      "$out" "no longer exists - replacing it"
contains "  and mints one"         "$(cat "$T/apilog")" "POST"

echo "6. a revoked key"
KEYGET='{"id":"kOLD1","invalid":true,"expires":"2099-01-01T00:00:00Z"}'
out=$(TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps')
contains "invalid counts as expired" "$out" "expired - replacing it"

echo "7. no key stored at all"
rm -f "$T/apilog"
out=$(run 'tskey_auth_ensure gamevps')
contains "one is minted"           "$out" "minted a Tailscale auth key"
contains "  and saved"             "$out" "saved"
contains "  from a POST"           "$(cat "$T/apilog")" "POST"
lacks    "  with nothing to delete" "$(cat "$T/apilog")" "DELETE"
contains "it is written to .env"   "$(cat "$T/home/.env" 2>/dev/null)" "TAILSCALE_AUTH_KEY=tskey-auth-kNEW111CNTRL-freshsecret"

echo "8. the API cannot be asked: the stored key is used, not thrown away"
# A flat network would otherwise delete a working key and then fail to mint its
# replacement - leaving nothing at all.
rm -f "$T/apilog"
KEYGET="" POST_FAIL=000
out=$(TAILSCALE_API_KEY= TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps'; echo "rc=$?")
contains "the stored key comes back" "$out" "tskey-auth-kOLD1-sec"
lacks    "  nothing is deleted"      "$(cat "$T/apilog" 2>/dev/null)" "DELETE"

echo "9. no token and no key: the build has to ask"
out=$(TAILSCALE_API_KEY= TAILSCALE_AUTH_KEY= run 'tskey_auth_ensure gamevps; echo "rc=$?"')
contains "it gives up, for the prompt" "$out" "rc=1"

echo "10. the mint is refused"
# Tags are the usual reason: a tailnet whose ACLs require them will not issue an
# untagged key, and cg cannot guess what tag to ask for.
rm -f "$T/apilog"
KEYGET=404 POST_FAIL=403 POST_BODY='{"message":"requested tags [] are invalid or not permitted"}'
out=$(TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps; echo "rc=$?"')
contains "it says it could not"    "$out" "could not mint an auth key (403)"
contains "  quoting Tailscale"     "$out" "not permitted"
contains "  and where to make one" "$out" "login.tailscale.com/admin/settings/keys"
contains "  then gives up"         "$out" "rc=1"
# The dead key is NOT deleted when there is no replacement for it.
lacks    "nothing was deleted"     "$(cat "$T/apilog")" "DELETE"

echo "11. the key is never printed where it can be read back"
rm -f "$T/apilog"
KEYGET="{\"id\":\"kOLD1\",\"expires\":\"$(at_days 60)\"}"
out=$(TAILSCALE_AUTH_KEY=tskey-auth-kOLD1-sec run 'tskey_auth_ensure gamevps >/dev/null')
lacks "the log does not carry it"  "$out" "tskey-auth-kOLD1-sec"

echo "12. what the build does with all this"
s=$(cat lib/settings.sh)
contains "the build tries this first"  "$s" "tskey_auth_ensure"
contains "  before asking for a key"   "$s" "paste auth key"
contains "a stored key is checked too" "$s" "answerable here, before anything starts"
contains "cg reports it"               "$(cat lib/laptop.sh)" "box auth key"

echo "13. every build checks the key first, and stops when it cannot"
# A key revoked with its token went unchecked - no token, no check - and the
# box it was given never joined, half an hour into the bill.
KEYGET="{\"id\":\"kOLD1\",\"expires\":\"$(at_days 60)\"}"
out=$(run 'tskey_preflight tskey-auth-kOLD1-sec; echo "rc=$?"')
contains "a working key passes"        "$out" "the Tailscale auth key works"
contains "  and the build goes on"     "$out" "rc=0"
out=$(TAILSCALE_API_KEY= run 'tskey_preflight tskey-auth-kOLD1-sec; echo "rc=$?"')
contains "no token: it stops"          "$out" "no Tailscale API token is saved"
contains "  before anything launched"  "$out" "Nothing was launched"
lacks    "  and goes no further"       "$out" "rc=0"
KEYGET=401
out=$(run 'tskey_preflight tskey-auth-kOLD1-sec; echo "rc=$?"')
contains "a refused token: it says so" "$out" "Tailscale refused the API token"
lacks    "  and stops"                 "$out" "rc=0"
KEYGET=down
out=$(run 'tskey_preflight tskey-auth-kOLD1-sec; echo "rc=$?"')
contains "Tailscale unreachable"       "$out" "api.tailscale.com did not answer"
lacks    "  stops too"                 "$out" "rc=0"
KEYGET=404
out=$(run 'tskey_preflight tskey-auth-kOLD1-sec; echo "rc=$?"')
contains "a dead key stops it"         "$out" "expired or been revoked"
lacks    "  as well"                   "$out" "rc=0"
contains "the build runs it"           "$(cat lib/setup)" 'tskey_preflight "${GAME_TS_AUTHKEY:-}"'
# Asked first: a build with no token used to ask for an auth key, save it, and
# then refuse to build with it.
s=$(cat lib/setup)
pre=${s%%settings_prompts \"\$FIX\"*}
contains "no token: stopped before the questions" "$pre" "tskey_need_token"
out=$(TAILSCALE_API_KEY= run 'tskey_need_token; echo "rc=$?"')
contains "  saying where to add one"   "$out" "Settings > Private network"
lacks    "  and goes no further"       "$out" "rc=0"
out=$(run 'tskey_need_token; echo "rc=$?"')
contains "with a token it passes"      "$out" "rc=0"
KEYGET='<html>sign in to this wifi</html>'
out=$(run 'tskey_preflight tskey-auth-kOLD1-sec; echo "rc=$?"')
contains "an answer that is not Tailscale's, said" "$out" "answered with something that is not Tailscale's"
lacks    "  and stops"                 "$out" "rc=0"

echo ""
echo "authkey: $pass passed, $fail failed"
(( fail == 0 ))
