#!/usr/bin/env bash
# Games saved somewhere cg is not looking - found, kept, moved, forgotten.
#
# Every library read used ONE bucket, the one .env names. A region move made a
# new one and left 162.8 GB of Diablo IV in the old region, billing Rs 386 a
# month with nothing pointing at it. cg now finds this host's other buckets by
# the name it derives (not by the cg-library- prefix), says what is in them, and
# can keep a game longer (reset), bring it to the machine's region (move) or
# delete it (forget --from) - each only on a bucket of this host's.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/repo" "$T/put"
cp -r lib "$T/repo/"; cp cg "$T/repo/"

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# Real names, from the real formula: the one in use (Mumbai), one an old region
# left (current formula), one from before the region went into the name, and a
# look-alike from another account that must never be touched.
name() { bash -c 'source lib/s3-region.sh; cg_bucket_name "$@"' _ "$@"; }
NOWB=$(name 123456789012 gamevps ap-south-1)
OLDB=$(name 123456789012 gamevps ap-south-2)
LEGB="cg-library-$(printf '%s' 123456789012-gamevps | sha256sum | cut -c1-12)"
FORB=$(name 999999999999 gamevps ap-south-2)
export NOWB OLDB LEGB FORB
# A real login archive: a tarball holding Steam's loginusers.vdf.
mkdir -p "$T/acct/config"
printf '"users"\n{\n\t"76561190000000001"\n\t{\n\t\t"AccountName"\t\t"player"\n\t\t"PersonaName"\t\t"Player"\n\t\t"Timestamp"\t\t"1790425149"\n\t}\n}\n' \
  > "$T/acct/config/loginusers.vdf"
tar -czf "$T/acct.tgz" -C "$T/acct" config
export TGZ="$T/acct.tgz"
printf 'GAME_S3_BUCKET=%s\nGAME_REGION=ap-south-1\nGAME_TS_HOST=gamevps\n' "$NOWB" > "$T/repo/.env"

cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
D4='{"apps":[{"appid":"2344520","name":"Diablo IV","installdir":"Diablo IV","bytes":174813206488,"pushed":"2026-09-26T10:38:58Z"}]}'
case "$*" in
  *"sts get-caller-identity"*) echo 123456789012 ;;
  *"list-buckets"*)
    [[ -n ${NO_LIST:-} ]] && { echo "AccessDenied" >&2; exit 255; }
    printf '%s\t%s\tsomeone-elses\t%s\t%s\n' "$NOWB" "$OLDB" "$LEGB" "$FORB" ;;
  *"get-bucket-location"*"$NOWB"*) echo ap-south-1 ;;
  *"get-bucket-location"*) echo ap-south-2 ;;
  *"head-bucket"*) exit 0 ;;
  *"head-object"*"$LEGB"*) printf '22290\t2026-09-26T12:20:10+00:00\t"etag-old"\n' ;;
  *"head-object"*) exit 254 ;;
  *"s3 cp s3://$LEGB/steam/account/steam-account.tgz "*) cp "$TGZ" "$4" ;;
  *"ssm get-parameters-by-path"*)
    printf '[["/cloud-gaming/gamevps/archive-last-seen","2026-10-16T09:27:52Z"],["/cloud-gaming/gamevps/kept/%s/2344520","2026-10-20T00:00:00Z"]]\n' "$LEGB" ;;
  *"ssm put-parameter"*|*"ssm delete-parameter"*) exit 0 ;;
  *"s3 ls s3://$LEGB/steam/ --recursive"*)
    printf '2026-10-01 10:00:00 100000000000 steam/steamapps/common/Diablo IV/a.pak\n'
    printf '2026-10-01 10:00:00 74813206488 steam/steamapps/common/Diablo IV/b b.pak\n'
    printf '2026-10-01 10:00:00      249442 steam/account/local.vdf\n' ;;
  *"s3 ls s3://$OLDB/steam/"*) exit 1 ;;
  *"s3 ls s3://$FORB/steam/"*) printf '2026-10-01 10:00:00 5 steam/steamapps/common/X/a\n' ;;
  *"s3 ls s3://"*"--summarize"*)
    if [[ -n ${MISMATCH:-} && $* == *"$NOWB"* ]]; then printf 'Total Objects: 3\n   Total Size: 99\n'
    else printf 'Total Objects: 3\n   Total Size: 174813206488\n'; fi ;;
  *"s3 cp s3://$LEGB/steam/index.json -"*) echo "$D4" ;;
  *"s3 cp s3://$NOWB/steam/index.json -"*) echo '{"apps":[]}' ;;
  *"s3 cp s3://"*"/steam/index.json -"*) echo "An error occurred (NoSuchKey)" >&2; exit 1 ;;
  *"s3 cp /"*"/steam/index.json"*)
    src=$3; dst=${4#s3://}; cp "$src" "$PUT/${dst%%/*}" ;;
  *"s3 sync"*) [[ -n ${SYNC_FAILS:-} ]] && exit 1; exit 0 ;;
  *"s3 rm"*|*"s3 rb"*|*"s3 cp s3://"*) exit 0 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$T/bin/aws"
run() { ( cd "$T/repo" && printf '%s\n' "${ANSWER:-}" | env -i CG_INR_PER_USD=94.95 CALLS="$T/calls" PUT="$T/put" \
            NOWB="$NOWB" OLDB="$OLDB" LEGB="$LEGB" FORB="$FORB" TGZ="$TGZ" PATH="$T/bin:$PATH" HOME="$T/home" \
            CG_COLOR=never "${EXTRA[@]}" bash ./cg "$@" 2>&1 ); }
EXTRA=()
jq_() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k)
print(json.dumps(d))' "$1" <<<"$j"; }

echo "1. it finds this host's other buckets, and only those"
j=$(run library elsewhere --json)
check    "valid JSON"                     "$(python3 -c 'import json,sys;json.load(sys.stdin);print("yes")' <<<"$j")" "yes"
check    "not the one in use, not another account's, not someone else's" \
         "$(python3 -c 'import json,sys;print(" ".join(sorted(p["bucket"] for p in json.load(sys.stdin)["places"])))' <<<"$j")" \
         "$(printf '%s\n' "$OLDB" "$LEGB" | sort | tr '\n' ' ' | sed 's/ $//')"
p=$(python3 -c 'import json,sys,os; print([i for i,p in enumerate(json.load(sys.stdin)["places"]) if p["bucket"]==os.environ["LEGB"]][0])' <<<"$j")
check    "with the region it is in"       "$(jq_ places.$p.region)" '"ap-south-2"'
check    "its size"                       "$(jq_ places.$p.bytes)" "174813455930"
check    "what it costs a month"          "$(jq_ places.$p.usd_month)" "4.07"
check    "each game, by id and name"      "$(jq_ places.$p.games.0.appid) $(jq_ places.$p.games.0.name)" '"2344520" "Diablo IV"'
check    "  when it was saved"            "$(jq_ places.$p.games.0.pushed)" '"2026-09-26T10:38:58Z"'
check    "  and its Reset, from the watchdog's marks" "$(jq_ places.$p.games.0.kept)" '"2026-10-20T00:00:00Z"'
check    "a Steam login there is said"    "$(jq_ places.$p.login)" "true"
check    "  who it signs in as"           "$(jq_ places.$p.login_detail.accounts.0.account)" '"player"'
check    "  when it was saved, and its size" "$(jq_ places.$p.login_detail.modified) $(jq_ places.$p.login_detail.bytes)" '"2026-09-26T12:20:10+00:00" 22290'
q=$(python3 -c 'import json,sys,os; print([i for i,p in enumerate(json.load(sys.stdin)["places"]) if p["bucket"]==os.environ["OLDB"]][0])' <<<"$j")
check    "an empty place has no login to read" "$(jq_ places.$q.login_detail)" "null"
check    "where the machine is built"     "$(jq_ region)" '"ap-south-1"'
check    "the rate, the copy price, the days" "$(jq_ inr_per_usd) $(jq_ xregion_usd_gb) $(jq_ expiry_days)" "94.95 0.086 14"
check    "when a machine was last seen"   "$(jq_ last_seen)" '"2026-10-16T09:27:52Z"'
EXTRA=(NO_LIST=1); j=$(run library elsewhere --json); EXTRA=()
check    "no bucket list is an error, not 'none'" "$(jq_ places)" "null"

echo "2. reading it is a read"
: > "$T/calls"; run library elsewhere --json >/dev/null; calls=$(cat "$T/calls")
lacks    "nothing is deleted"             "$calls" " rb "
lacks    "  or removed"                   "$calls" " rm "
lacks    "  or marked"                    "$calls" "put-parameter"

echo "3. the human view"
out=$(run library elsewhere)
contains "the place and what it costs"    "$out" "162.8 GB   INR 386 a month"
contains "  the game, with its id"        "$out" "2344520    Diablo IV"
contains "  and what to do about it"      "$out" "cg library move <appid> --from <bucket>"

echo "4. reset: the countdown starts again today, only on this host's buckets"
: > "$T/calls"
out=$(run library reset 2344520 --from "$LEGB")
contains "it writes the mark for that game, there" "$(cat "$T/calls")" "ssm put-parameter --name /cloud-gaming/gamevps/kept/$LEGB/2344520"
contains "  and says so"                  "$out" "counted from today - 14 days"
out=$(run library reset 2344520 --from "$FORB")
contains "another account's look-alike is refused" "$out" "not one of this rig's buckets"
out=$(run library reset 2344520)
contains "no --from means the bucket in use" "$(cat "$T/calls")" "kept/$NOWB/2344520"

echo "5. forget --from: one game, there, after FORGET; an emptied bucket goes"
: > "$T/calls"
out=$(ANSWER=nope run library forget 2344520 --from "$LEGB")
contains "it says what goes, and where"   "$out" "Diablo IV (2344520, 162.8 GB) from the archive in ap-south-2"
contains "a wrong word aborts"            "$out" "aborted - nothing was deleted"
lacks    "  and nothing was removed"      "$(cat "$T/calls")" "s3 rm"
out=$(ANSWER=FORGET run library forget 2344520 --from "$LEGB"); calls=$(cat "$T/calls")
contains "FORGET removes its folder there" "$calls" "s3 rm s3://$LEGB/steam/steamapps/common/Diablo IV/ --recursive --region ap-south-2"
contains "  drops it from that index"     "$(cat "$T/put/$LEGB")" '"apps": []'
contains "  and its Reset mark"           "$calls" "ssm delete-parameter --name /cloud-gaming/gamevps/kept/$LEGB/2344520"
contains "  and the emptied bucket"       "$calls" "s3 rb s3://$LEGB --force --region ap-south-2"
contains "  said plainly"                 "$out" "nothing else was saved in ap-south-2 - removed it"
out=$(ANSWER=FORGET run library forget 2344520 --from "$FORB")
contains "another account's: refused"     "$out" "not one of this rig's buckets"

echo "5b. a login copy in another place is forgotten there, after FORGET"
: > "$T/calls"
out=$(ANSWER=FORGET run library account forget --from "$LEGB"); calls=$(cat "$T/calls")
contains "it names the account"           "$out" "player"
contains "it deletes the copy there"      "$calls" "s3 rm s3://$LEGB/steam/account/steam-account.tgz --region ap-south-2"
lacks    "  not the one in use"           "$calls" "s3 rm s3://$NOWB"
lacks    "  and the place stays while a game is in it" "$calls" "s3 rb s3://$LEGB"
out=$(ANSWER=FORGET run library account forget --from "$FORB")
contains "another account's: refused"     "$out" "not one of this rig's buckets"

echo "6. move: copied, checked, then deleted at the source"
: > "$T/calls"; rm -f "$T/put/"*
out=$(ANSWER=nope run library move 2344520 --from "$LEGB")
contains "it says the copy price first"   "$out" "AWS charges about INR 1329 once"
contains "a wrong word aborts"            "$out" "aborted - nothing was copied"
lacks    "  and nothing was copied"       "$(cat "$T/calls")" "s3 sync"
out=$(ANSWER=MOVE run library move 2344520 --from "$LEGB"); calls=$(cat "$T/calls")
contains "MOVE copies server to server"   "$calls" "s3 sync s3://$LEGB/steam/steamapps/common/Diablo IV/ s3://$NOWB/steam/steamapps/common/Diablo IV/ --source-region ap-south-2 --region ap-south-1"
contains "  checks the copy"              "$out" "checking the copy"
contains "  puts it in the machine's index" "$(cat "$T/put/$NOWB")" '"Diablo IV"'
contains "  then removes it at the source" "$calls" "s3 rm s3://$LEGB/steam/steamapps/common/Diablo IV/"
contains "  and says where it went"       "$out" "moved Diablo IV to ap-south-1"
: > "$T/calls"; rm -f "$T/put/"*
EXTRA=(MISMATCH=1); out=$(ANSWER=MOVE run library move 2344520 --from "$LEGB"); EXTRA=()
contains "a copy that does not match stops" "$out" "does not match"
lacks    "  and nothing is deleted at the source" "$(cat "$T/calls")" "s3 rm s3://$LEGB"
lacks    "  nor written to the machine's index"   "$(ls "$T/put")" "$NOWB"
: > "$T/calls"
EXTRA=(SYNC_FAILS=1); out=$(ANSWER=MOVE run library move 2344520 --from "$LEGB"); EXTRA=()
contains "a copy that stops says so"      "$out" "nothing was deleted from ap-south-2"
lacks    "  and deletes nothing"          "$(cat "$T/calls")" "s3 rm"
out=$(ANSWER=MOVE run library move 2344520 --from "$NOWB")
contains "moving from the machine's own place is refused" "$out" "already where your machine is built"

echo "6b. keep-for: the days, saved and applied together"
out=$(run library keep-for soon)
contains "a word that is not days is refused" "$out" "how many days?"
out=$(run library keep-for 30)
contains "the setting is saved"           "$(cat "$T/repo/.env")" "GAME_ARCHIVE_EXPIRY_DAYS=30"
# This fake AWS cannot install a function, so the watchdog step fails - and
# says the setting is not live yet, rather than claiming it is.
contains "  and an install that fails says so" "$out" "still counts the old days - run: cg watchdog install"
out=$(run library keep-for forever)
contains "forever is 0"                   "$(cat "$T/repo/.env")" "GAME_ARCHIVE_EXPIRY_DAYS=0"
c=$(cd "$T/repo" && bash ./cg --contract)
contains "it runs alone, as do reset"     "$c" '["library", "reset"], ["library", "keep-for"]'

echo "7. under the app, each question has its id"
out=$(cd "$T/repo" && printf 'MOVE\n' | env -i CG_JSON=1 CG_INR_PER_USD=94.95 CALLS="$T/calls" PUT="$T/put" \
        NOWB="$NOWB" OLDB="$OLDB" LEGB="$LEGB" FORB="$FORB" PATH="$T/bin:$PATH" HOME="$T/home" \
        CG_COLOR=never bash ./cg library move 2344520 --from "$LEGB" 2>&1)
contains "move asks by id"                "$out" '"id":"move-game"'
c=$(cd "$T/repo" && bash ./cg --contract)
contains "move runs alone"                "$c" '["library", "move"]'
contains "  and its question is known"    "$c" '"move-game"'
lacks    "the old bucket-wide delete is gone" "$c" "delete-elsewhere"

echo ""
echo "library-elsewhere: $pass passed, $fail failed"
(( fail == 0 ))
