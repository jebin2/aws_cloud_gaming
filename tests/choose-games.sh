#!/usr/bin/env bash
# The pre-launch prompt: which archived games to restore, and the arithmetic
# that refuses a selection bigger than the disk.
#
# This runs on the laptop before the instance exists, because the restore starts
# at boot with no terminal and has to overlap the build. So the capacity check
# is the only thing standing between "pick both" and a box that fills its disk
# mid-restore.
#
# It needs a pty, since the script deliberately does not prompt when stdin is
# not a terminal (scripts and CI must not block). `script -qec` provides one.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
command -v script >/dev/null || { echo "  SKIP - util-linux 'script' not available"; exit 0; }

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
cat > "$T/index.json" <<'JSON'
{"apps":[
 {"appid":"2344520","name":"Diablo IV","installdir":"Diablo IV","bytes":171798691840,"pushed":"2026-09-13T11:02:00Z"},
 {"appid":"2358720","name":"Black Myth: Wukong","installdir":"BlackMythWukong","bytes":137438953472,"pushed":"2026-09-13T09:14:00Z"},
 {"appid":"438040","name":"Shakes and Fidget","installdir":"Shakes & Fidget","bytes":2644378735,"pushed":"2026-09-12T20:44:00Z"}
]}
JSON
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *index.json*) cat "$IDX" ;; *) echo "" ;; esac
FAKE
chmod +x "$T/bin/aws"

# Feeds answers through a pty and returns ONLY stdout - the chosen csv.
ask() { # ask <answers...>
  local input="" a
  for a in "$@"; do input+="$a"$'\n'; done
  printf '%s' "$input" | \
    IDX="$T/index.json" PATH="$T/bin:$PATH" GAME_S3_BUCKET=b GAME_APPS=all \
    script -qec "bash lib/choose-games.sh 2>$T/err" /dev/null 2>/dev/null \
    | tr -d '\r' | tail -1
}
errs() { cat "$T/err" 2>/dev/null | tr -d '\r'; }

echo "1. two games that do not fit are refused, with the arithmetic shown"
got=$(ask "1,2" "2")
contains "names the shortfall"     "$(errs)" "over by"
contains "shows both sizes"        "$(errs)" "Diablo IV 160 GB"
contains "suggests what does fit"  "$(errs)" "fit on their own"
check    "and accepts the retry"   "$got" "2358720"

echo "2. a selection that fits is accepted first time"
got=$(ask "1,3")
check "Diablo + Shakes"            "$got" "2344520,438040"
contains "reports the spare room"  "$(errs)" "spare"

echo "3. appids work as well as numbers"
got=$(ask "2358720")
check "resolved by appid"          "$got" "2358720"

echo "4. 'all' is refused when the archive is bigger than the disk"
# 160 + 128 + 2.5 = 290 GB against 209 GB selectable.
got=$(ask "all" "3")
contains "explains why"            "$(errs)" "over by"
check    "then takes the retry"    "$got" "438040"

echo "5. 'none' skips the restore entirely"
got=$(ask "none")
check    "returns none"            "$got" "none"
contains "says what that means"    "$(errs)" "empty library"

echo "6. an unknown token is named rather than ignored"
got=$(ask "banana" "3")
contains "quotes the bad token"    "$(errs)" "'banana' is not one of"
check    "and continues"           "$got" "438040"

echo "7. pressing Enter restores NOTHING"
# Enter is what people press to get past a prompt. Defaulting to "all" would
# start a 158 GB transfer for a box someone might have wanted empty - and
# restoring a game is cheap to ask for and annoying to undo.
got=$(ask "")
check "Enter means none"     "$got" "none"
contains "and the prompt says so" "$(errs)" "Enter = none"

echo "8. no terminal: answers from .env without blocking"
got=$( IDX="$T/index.json" PATH="$T/bin:$PATH" GAME_S3_BUCKET=b GAME_APPS=2358720 \
       bash lib/choose-games.sh </dev/null )
check "honoured GAME_APPS"         "$got" "2358720"

echo "9. an empty archive asks nothing"
echo '{"apps":[]}' > "$T/index.json"
got=$( IDX="$T/index.json" PATH="$T/bin:$PATH" GAME_S3_BUCKET=b bash lib/choose-games.sh </dev/null )
check "defaults to all"            "$got" "all"

echo "10. on a terminal the picker is styled - and stdout stays a clean csv"
# stdout is the chosen appids, read by cg init and baked into user-data. An
# escape code there would reach the box as part of an appid, so the styled run
# must leave it byte-identical to the plain one.
cat > "$T/index.json" <<'JSON'
{"apps":[
 {"appid":"2344520","name":"Diablo IV","installdir":"Diablo IV","bytes":171798691840,"pushed":"2026-09-13T11:02:00Z"},
 {"appid":"1971870","name":"原神 Genshin","installdir":"Genshin","bytes":2644378735,"pushed":"2026-09-12T20:44:00Z"},
 {"appid":"2358720","name":"Black Myth: Wukong","installdir":"BlackMythWukong","bytes":137438953472,"pushed":"2026-09-13T09:14:00Z"}
]}
JSON
styled_ask() { # like ask, with CG_COLOR=always; stdout only
  local input="" a
  for a in "$@"; do input+="$a"$'\n'; done
  printf '%s' "$input" | \
    IDX="$T/index.json" PATH="$T/bin:$PATH" GAME_S3_BUCKET=b GAME_APPS=all CG_COLOR=always \
    script -qec "bash lib/choose-games.sh 2>$T/err" /dev/null 2>/dev/null \
    | tr -d '\r' | tail -1
}
ESC=$'\e'
plain_errs() { errs | sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g"; }
got=$(styled_ask "2")
check    "stdout is exactly the appid"       "$got" "1971870"
if [[ $got == *"$ESC"* ]]; then echo "  FAIL stdout carries an escape code"; fail=$((fail+1));
else echo "  ok   no escape code on stdout"; pass=$((pass+1)); fi
if [[ "$(errs)" == *"$ESC"* ]]; then echo "  ok   stderr IS styled"; pass=$((pass+1));
else echo "  FAIL stderr has no colour - the styled path did not run"; fail=$((fail+1)); fi
contains "the table is a box"                "$(plain_errs)" "╭─ 📦 Game archive"
contains "the prompt keeps its words"        "$(plain_errs)" "Enter = none"
contains "the result has a tick"             "$(plain_errs)" "✓ 2 GB selected"
# "原神" is two characters but four columns. Padding by character count would
# push this row's size two columns right of the row above it.
col() { plain_errs | grep -F "$1" | head -1 | awk -v n="GB" '{ i=index($0, " GB"); print i }'; }
d=$(plain_errs | grep -F "Diablo IV" | head -1); g=$(plain_errs | grep -F "Genshin" | head -1)
dw=$(python3 -c 'import sys,unicodedata as u; s=sys.argv[1]; i=s.index(" GB"); print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in s[:i]))' "$d")
gw=$(python3 -c 'import sys,unicodedata as u; s=sys.argv[1]; i=s.index(" GB"); print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in s[:i]))' "$g")
check    "a wide name keeps the SIZE column aligned" "$gw" "$dw"
got=$(styled_ask "1,3" "2")
contains "a refusal still says 'over by'"    "$(plain_errs)" "over by"
contains "  with a cross"                    "$(plain_errs)" "✗ 288 GB selected"
check    "  and the retry is what comes out" "$got" "1971870"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
