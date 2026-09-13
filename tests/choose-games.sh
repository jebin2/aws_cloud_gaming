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

echo "7. pressing Enter takes the remembered default"
got=$(ask "")
check "used GAME_APPS=all... which does not fit, so it re-asks" \
  "$(grep -c 'over by' "$T/err" 2>/dev/null || true)" "1"

echo "8. no terminal: answers from .env without blocking"
got=$( IDX="$T/index.json" PATH="$T/bin:$PATH" GAME_S3_BUCKET=b GAME_APPS=2358720 \
       bash lib/choose-games.sh </dev/null )
check "honoured GAME_APPS"         "$got" "2358720"

echo "9. an empty archive asks nothing"
echo '{"apps":[]}' > "$T/index.json"
got=$( IDX="$T/index.json" PATH="$T/bin:$PATH" GAME_S3_BUCKET=b bash lib/choose-games.sh </dev/null )
check "defaults to all"            "$got" "all"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
