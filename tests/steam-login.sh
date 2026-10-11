#!/usr/bin/env bash
# The archived Steam login: shown, named, and deletable on its own.
#
# It is a ~22 KB tarball at steam/account/steam-account.tgz - the thing that
# makes a rebuilt box come up already signed in, and the reason a region move
# carried the login to Mumbai while leaving 163 GB of games in Hyderabad.
#
# It was invisible on every screen while being COUNTED AS A GAME: both
# archive_line and status_facts summed the whole steam/ prefix, so an account
# with nothing archived was told "game library ... 1 objects, 22KB". The fix
# partitions one listing instead of adding a second request.
#
# Deleting is all-or-nothing on purpose. Removing one account from the tarball
# means editing loginusers.vdf, that account's ConnectCache entry in local.vdf
# and its userdata/<id>/ - undocumented Steam internals where a near miss leaves
# an archive that restores a BROKEN login, which is worse than having none.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/cache"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# A real tarball with a real loginusers.vdf, so the parser is exercised rather
# than mocked. Two accounts, and the MostRecent one is NOT the first written.
mkdir -p "$T/fix/.local/share/Steam/config"
cat > "$T/fix/.local/share/Steam/config/loginusers.vdf" <<'VDF'
"users"
{
	"76561198000000001"
	{
		"AccountName"		"alice"
		"PersonaName"		"Alice A"
		"RememberPassword"		"1"
		"MostRecent"		"0"
		"Timestamp"		"1700000000"
	}
	"76561198000000002"
	{
		"AccountName"		"bob"
		"PersonaName"		"Bob B"
		"RememberPassword"		"1"
		"MostRecent"		"1"
		"Timestamp"		"1790000000"
	}
}
VDF
tar -czf "$T/account.tgz" -C "$T/fix" .local 2>/dev/null
# One account, and NO MostRecent key - which is what Steam writes when there is
# no choice to record.
mkdir -p "$T/fix1/.local/share/Steam/config"
cat > "$T/fix1/.local/share/Steam/config/loginusers.vdf" <<'VDF'
"users"
{
	"76561198000000009"
	{
		"AccountName"		"solo"
		"PersonaName"		"Solo"
		"RememberPassword"		"1"
		"Timestamp"		"1791000000"
	}
}
VDF
tar -czf "$T/account1.tgz" -C "$T/fix1" .local 2>/dev/null

cat > "$T/bin/aws" <<FAKE
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"sts get-caller-identity"*) echo 123456789012 ;;
  *get-bucket-location*)       echo ap-south-1 ;;
  *"s3api head-object"*)
    [[ -n \${NO_LOGIN:-} ]] && { echo "An error occurred (404)" >&2; exit 254; }
    printf '%s\t%s\t%s\n' "\${LOGIN_BYTES:-22458}" "2026-10-10T16:30:03+00:00" "\"etag\${ETAG_N:-1}\"" ;;
  *"s3 cp s3://"*steam-account.tgz*)
    [[ -n \${NO_TGZ:-} ]] && exit 1
    # s3 cp <src> <dst> --region <r>: the destination is \$4, NOT the last
    # argument - that is the region, and copying the tarball over a string
    # called "ap-south-1" is how this stub first "proved" the parser broken.
    echo cp >> "$T/downloads.log"
    cp "\${TGZ:-$T/account.tgz}" "\$4" ;;
  *"s3 cp s3://"*index.json*) echo "An error occurred (404)" >&2; exit 1 ;;
  *"s3 rm s3://"*steam-account.tgz*) echo "\$args" >> "$T/deleted.log" ;;
  *"s3 ls s3://"*steam/account/*--summarize*)
    [[ -n \${NO_LOGIN:-} ]] && { printf 'Total Objects: 0\n   Total Size: 0\n'; exit 0; }
    printf 'Total Objects: 1\n   Total Size: 22458\n' ;;
  *"s3 ls s3://"*steam/steamapps/*--summarize*)
    printf 'Total Objects: %s\n   Total Size: %s\n' "\${APPS_OBJECTS:-0}" "\${APPS_BYTES:-0}" ;;
  *"s3 ls s3://"*--recursive*)
    [[ -n \${LS_FAIL:-} ]] && { echo "An error occurred (AccessDenied)" >&2; exit 1; }
    # The login, plus a game key WITH SPACES - the reason the key is rebuilt by
    # stripping columns instead of being read as \$4.
    [[ -z \${NO_LOGIN:-} ]] && echo "2026-10-10 16:30:03      22458 steam/account/steam-account.tgz"
    [[ -n \${WITH_GAME:-} ]] && echo "2026-10-10 18:00:00 1073741824 steam/steamapps/common/Diablo IV/game.bin"
    exit 0 ;;
  *"s3 ls s3://"*) exit 0 ;;
  *iam*) exit 1 ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"; chmod +x "$T/bin/tailscale"

printf 'GAME_REGION=ap-south-1\nGAME_TS_HOST=gamevps\nGAME_S3_BUCKET=cg-library-test\n' > "$T/home/.env"

cg_() { env PATH="$T/bin:$PATH" HOME="$T/home" CG_ENV_FILE="$T/home/.env" \
          CG_CACHE_DIR="$T/cache" CG_COLOR=never "$@" ./cg "${CMD[@]}" 2>&1; }

echo "1. the login is reported, with the accounts inside it"
CMD=(library account)
out=$(cg_)
contains "the key is named"        "$out" "steam/account/steam-account.tgz"
contains "  the size"              "$out" "21.9 KB"
contains "  when it was pushed"    "$out" "2026-10-10T16:30:03"
contains "  both accounts"         "$out" "alice"
contains "  including the second"  "$out" "bob"
# Ordering is the useful part: the one a new box lands on comes first and is
# marked, and it is NOT the first one written to the file.
contains "the most recent is marked" "$out" "bob"
check "  and listed first" \
      "$(grep -oE '^  (alice|bob)' <<<"$out" | head -1 | tr -d ' ')" "bob"
contains "  with what that means"  "$out" "a new box signs in as this one"
# It exists mainly to say the number is nothing, so Forget is not read as saving.
contains "the cost is stated as nothing" "$out" "effectively nothing"
contains "  and the multi-account caveat" "$out" "restored whole"

echo "2. a lone account is the one a new box uses, with no MostRecent key"
# Steam writes MostRecent only when there is a choice to record. Leaving the row
# unmarked implied a new box would sign in as nobody.
CMD=(library account)
out=$(TGZ="$T/account1.tgz" ETAG_N=2 cg_)
contains "the single account is marked" "$out" "a new box signs in as this one"
contains "  and named"                  "$out" "solo"
lacks    "  with no multi-account note" "$out" "restored whole"

echo "3. no archived login is said plainly, and differs from unknown"
CMD=(library account)
out=$(NO_LOGIN=1 cg_)
contains "it says there is none"   "$out" "no archived Steam login"
contains "  and what happens next" "$out" "ask you to sign in"
lacks    "  and offers no size"    "$out" "21.9 KB"

echo "4. status counts games and the login SEPARATELY"
# The bug: both summed steam/, so 22 KB of login was reported as archived games.
CMD=(status)
out=$(cg_)
contains "no games is EMPTY"            "$out" "EMPTY - no games archived"
lacks    "  not 22KB of games"          "$out" "1 objects, 22KB"
contains "the login has its own line"   "$out" "steam login"
contains "  saying it is archived"      "$out" "archived"
contains "  and what it buys you"       "$out" "comes up signed in"
out=$(NO_LOGIN=1 cg_)
contains "and none when there is none"  "$out" "none archived"

echo "5. a failed listing is UNKNOWN, never 'none'"
# This is the lie the whole archive path keeps having to unlearn: reporting
# nothing archived on the strength of a request that failed.
CMD=(status --json)
out=$(LS_FAIL=1 cg_)
check "login.present is null" \
      "$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["login"]["present"])' <<<"$out" 2>/dev/null)" "None"
check "  and not false" \
      "$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["login"]["present"] is False)' <<<"$out" 2>/dev/null)" "False"
CMD=(status)
out=$(LS_FAIL=1 cg_)
contains "the text says unknown" "$out" "unknown - the archive could not be listed"
lacks    "  and never none"      "$out" "none archived"

echo "6. the json the app reads carries it, typed"
CMD=(status --json)
out=$(cg_)
check "bytes is a number"  "$(python3 -I -c 'import json,sys; print(type(json.load(sys.stdin)["login"]["bytes"]).__name__)' <<<"$out" 2>/dev/null)" "int"
check "present is a bool"  "$(python3 -I -c 'import json,sys; print(type(json.load(sys.stdin)["login"]["present"]).__name__)' <<<"$out" 2>/dev/null)" "bool"
CMD=(library list --json)
out=$(cg_)
check "library list carries the login too" \
      "$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["login"]["present"])' <<<"$out" 2>/dev/null)" "True"
check "  with the account names" \
      "$(python3 -I -c 'import json,sys; print([a["account"] for a in json.load(sys.stdin)["login"]["accounts"]])' <<<"$out" 2>/dev/null)" "['bob', 'alice']"

echo "7. a game key with spaces is still counted as a game"
# `aws s3 ls --recursive` prints "date time size key", and a key like
# "common/Diablo IV/game.bin" has spaces - read as \$4 it would be cut at the
# space and match no prefix, counting a real game as neither games nor login.
CMD=(status --json)
out=$(WITH_GAME=1 cg_)
check "the game is counted" \
      "$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["archive"]["objects"])' <<<"$out" 2>/dev/null)" "1"
check "  with its full size" \
      "$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["archive"]["bytes"])' <<<"$out" 2>/dev/null)" "1073741824"
check "  and the login is not in that total" \
      "$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["login"]["bytes"])' <<<"$out" 2>/dev/null)" "22458"

echo "8. deleting is refused without the typed word"
CMD=(library account forget)
out=$(printf 'no\n' | cg_); rc=$?
contains "it explains what is lost"   "$out" "signed-in state"
contains "  and that games are safe"  "$out" "games are NOT affected"
contains "  and that it saves nothing" "$out" "not to save money"
contains "  naming the accounts"      "$out" "alice"
# `read -p` prints its prompt only when stdin is a terminal, so a piped answer
# never sees it - assert the guard in source rather than in captured output.
check    "  the typed-word guard is in source" \
         "$(grep -c 'cg_ask_typed forget-login "type FORGET to confirm: " FORGET' cg)" "1"
contains "  and aborts"               "$out" "nothing was deleted"
check    "  non-zero"                 "$([[ $rc -ne 0 ]] && echo yes)" "yes"
check    "  and deleted nothing"      "$([[ -f $T/deleted.log ]] && echo yes || echo no)" "no"

echo "9. and performed when it is typed"
out=$(printf 'FORGET\n' | cg_)
contains "it says what it did" "$out" "deleted the archived Steam login"
contains "  and what happens next" "$out" "will ask you to sign in"
check    "  the object was deleted" "$([[ -f $T/deleted.log ]] && echo yes || echo no)" "yes"
contains "  by its exact key" "$(cat "$T/deleted.log" 2>/dev/null)" "steam/account/steam-account.tgz"
# The games must not be in the blast radius.
lacks    "  and nothing under steamapps" "$(cat "$T/deleted.log" 2>/dev/null)" "steamapps"
lacks    "  with no --recursive"         "$(cat "$T/deleted.log" 2>/dev/null)" "--recursive"

echo "10. nothing with no login to delete"
rm -f "$T/deleted.log"
out=$(NO_LOGIN=1 cg_)
contains "it says there is nothing" "$out" "nothing to delete"
check    "  and deletes nothing"    "$([[ -f $T/deleted.log ]] && echo yes || echo no)" "no"

echo "11. status and forget do NOT need the box"
# The whole point: the login outlives every box, so "which account would a new
# box use" has to be answerable when there is no box at all. tailscale exits 1
# in this sandbox, so a need_node on these paths would have failed above.
src=$(cat cg)
blk=$(awk '/^    account\|login\)/,/^      esac ;;/' cg)
contains "push still needs it"     "$blk" "push|pull|restore) need_node"
check    "  and status does not"   "$(grep -c 'status|"") *account_show' <<<"$blk")" "1"
lacks    "  nor does forget"       "$(grep 'forget|delete|rm' <<<"$blk")" "need_node"

echo "12. one listing, not two, and the reason is written down"
# A second request per refresh for a 22 KB answer is a cost with no benefit.
check "the facts come from a single ls" "$(grep -c 'aws s3 ls "s3://\$b/steam/" --recursive 2>"\$s3err"' lib/setup)" "1"
contains "the 22 KB fetch is cached by ETag" "$src" "Cached against the ETag"
contains "  and keyed by it"                 "$src" 'cache="account-${1:-none}.tsv"'

echo "13. the 22 KB fetch happens once per ETag, not once per screen"
# Found the hard way: this file's first draft emitted the ETag inside single
# quotes, so every call got one literal string as the key and the second case
# silently reused the first case's cached answer. The bug was in the test and
# the cache was behaving exactly as intended - so the behaviour is pinned here
# rather than left to be re-proved by accident.
rm -f "$T/downloads.log"
CMD=(library account)
out=$(ETAG_N=7 cg_ >/dev/null; ETAG_N=7 cg_)
check "the same ETag downloads once" "$(wc -l < "$T/downloads.log" 2>/dev/null | tr -d ' ')" "1"
contains "  and still answers"        "$out" "alice"
out=$(ETAG_N=8 TGZ="$T/account1.tgz" cg_)
check "a changed ETag downloads again" "$(wc -l < "$T/downloads.log" 2>/dev/null | tr -d ' ')" "2"
contains "  and reads the NEW archive" "$out" "solo"
lacks    "  not the stale one"         "$out" "alice"

echo "14. this file's own needles are safe"
bad=$(sed 's/\\\$//g' "$0" | grep -nE '^(contains|lacks|check) +"[^"]*" +"[^"]*" +"[^"]*(\$\{|\$\()' || true)
if [[ -z $bad ]]; then echo "  ok   every needle with a \$ is single-quoted"; pass=$((pass+1))
else echo "  FAIL double-quoted needles bash will expand:"; echo "$bad"; fail=$((fail+1)); fi

echo ""
echo "steam-login: $pass passed, $fail failed"
(( fail == 0 ))
