#!/usr/bin/env bash
# The rest of the reports: cg library list, cg watchdog status, cg snapshot --list.
#
# cg watchdog status reports the cloud watchdog; its expected output below was
# written for it rather than captured from an earlier cg.
#
# Same rule as every other report: on a terminal they are boxed and coloured by
# cg_report; anywhere else they print exactly what they did. The expected plain
# outputs below were captured from the cg BEFORE they were wired through
# cg_report, with these stubs - so the comparison is against the old behaviour,
# not against itself.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$2") | head -8; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }
ESC=$'\e'
strip() { sed -E "s/\r//g; s/${ESC}\[[0-9;]*[A-Za-z]//g"; }

mkdir -p "$T/bin" "$T/home/.ssh"
cp cg "$T/cg"; cp -r lib "$T/lib"
cat > "$T/.env" <<'EOF'
GAME_REGION=ap-south-2
GAME_TS_HOST=gamevps
GAME_S3_BUCKET=cg-library-example
EOF
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"s3 cp s3://cg-library-example/steam/index.json -"*)
    echo '{"apps":[{"appid":"2344520","name":"Diablo® IV","installdir":"Diablo IV","bytes":171985878943,"pushed":"2026-09-14T19:00:12Z"}]}' ;;
  *"s3 ls s3://cg-library-example/steam/index.json"*) echo "2026-09-14 19:00:12        171 index.json" ;;
  *"s3 ls s3://cg-library-example/steam/steamapps/ --recursive"*)
    echo "2026-09-14 19:00:00  171985878943 steam/steamapps/common/Diablo IV/Diablo IV.exe"
    [[ ${ORPHAN:-0} == 1 ]] && echo "2026-09-13 09:00:00   1073741824 steam/steamapps/common/Old Game/data.pak"
    true ;;
  *"s3 ls s3://cg-library-example/steam/ --recursive --summarize"*) printf 'Total Objects: 6218\n   Total Size: 171985878943\n' ;;
  *get-function-configuration*) printf 'Active\tpython3.13\n' ;;
  *"events describe-rule"*) echo ENABLED ;;
  *filter-log-events*)
    printf '1789412159000\tcg-watchdog: i-0123456789abcdef0 quiet (peak 0.9 MB per 5 min), but watched for only 25m of the 30m needed\n'
    printf '1789412484000\tcg-watchdog: no running instance tagged gamevps - nothing to do\n' ;;
  *describe-images*)
    if [[ ${IMAGES:-0} == 1 ]]; then echo '[{"id":"ami-0123456789abcdef0","name":"gamevps-2026-09-14","created":"2026-09-14T10:00:00.000Z","state":"available","gb":50}]'
    else echo '[]'; fi ;;
  *) exit 1 ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/ssh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"
chmod +x "$T/bin"/*
cg() { ( cd "$T" && HOME="$T/home" PATH="$T/bin:$PATH" COLUMNS=90 bash ./cg "$@" 2>&1 ); }
# Every styled row, with the gutter (and the indent it was given) removed, must
# be one of the plain rows - nothing lost, no column moved.
survives() { # survives <plain> <styled> <extra-indent>
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re
plain, styled, extra = sys.argv[1], sys.argv[2], int(sys.argv[3])
want = [l for l in plain.split("\n") if l.strip()]
got = [l[9 + 2 + extra:] for l in styled.split("\n") if l.startswith(" " * 9 + "│ ")]
got = [g for g in got if g.strip()]
print("same" if got == want else "DIFF got=%r want=%r" % (got[:3], want[:3]))
PY
}

echo "1. plain output is what it was before the wiring"
check "library list"                "$(CG_COLOR=never cg library list)" "$(cat <<'EXP'
  APPID      GAME                                  SIZE  ARCHIVED
  2344520    Diablo® IV                        160.2 GB  2026-09-14 19:00
             total                             160.2 GB   $4.00/month (INR 352)

  229 GB fits on the box at once (209 GB selectable after reserve)
EXP
)"
check "library list, with an orphan" "$(CG_COLOR=never ORPHAN=1 cg library list)" "$(cat <<'EXP'
  APPID      GAME                                  SIZE  ARCHIVED
  2344520    Diablo® IV                        160.2 GB  2026-09-14 19:00
             total                             160.2 GB   $4.00/month (INR 352)

  229 GB fits on the box at once (209 GB selectable after reserve)

  plus 1.0 GB of ORPHANED objects from an unfinished push
  costing $0.03/month and unusable - remove them: cg library clean
EXP
)"
# Local time, as the command prints it - computed here so the case holds in any timezone.
t1=$(date -d @1789412159 '+%Y-%m-%d %H:%M:%S'); t2=$(date -d @1789412484 '+%Y-%m-%d %H:%M:%S')
check "watchdog status"             "$(CG_COLOR=never cg watchdog status)" "$(cat <<EXP
  function  gamevps-cloud-watchdog  Active python3.13
  schedule  every 5 minutes, ENABLED
  can end   only the instance tagged gamevps
  archive   deleted after 14 days with no box - not checked yet (hourly)
  recent decisions:
    $t1 i-0123456789abcdef0 quiet (peak 0.9 MB per 5 min), but watched for only 25m of the 30m needed
    $t2 no running instance tagged gamevps - nothing to do
EXP
)"
check "snapshot --list, none"       "$(CG_COLOR=never cg snapshot --list)" "$(cat <<'EXP'
no saved images - nothing billing
EXP
)"
check "snapshot --list, one image"  "$(CG_COLOR=never IMAGES=1 cg snapshot --list)" "$(cat <<'EXP'
IMAGE                   CREATED                 GB   ~USD/mo  NAME
ami-0123456789abcdef0   2026-09-14T10:00:00     50      2.50  gamevps-2026-09-14

estimated 2.50 USD/month (~INR 220) for 1 image(s)
delete one with:  cg snapshot --delete <image-id>
EXP
)"
check "snapshot --list --json is untouched" "$(CG_COLOR=always IMAGES=1 cg snapshot --list --json)" '[{"id":"ami-0123456789abcdef0","name":"gamevps-2026-09-14","created":"2026-09-14T10:00:00.000Z","state":"available","gb":50}]'

echo "2. styled: each is a titled box, and every row survives"
out=$(CG_COLOR=always cg library list | strip)
contains "library list: 📦 Game archive" "$out" "╭─ 📦 Game archive"
check    "  rows survive"                 "$(survives "$(CG_COLOR=never cg library list)" "$out" 0)" "same"
raw=$(CG_COLOR=always ORPHAN=1 cg library list)
contains "  ORPHANED is red"              "$raw" $'\e[38;5;203mORPHANED'
out=$(CG_COLOR=always cg watchdog status | strip)
contains "watchdog status: 🔒 box"        "$out" "╭─ 🔒 Cloud watchdog"
check    "  rows survive"                 "$(survives "$(CG_COLOR=never cg watchdog status)" "$out" 0)" "same"
out=$(CG_COLOR=always IMAGES=1 cg snapshot --list | strip)
contains "snapshot --list: 💿 box"        "$out" "╭─ 💿 Saved images"
# Its header is at column 0 in plain output. Unindented, cg_report would read
# "IMAGE" as a section heading and open a second box.
check    "  one box, not two"             "$(grep -c '╭─' <<<"$out")" "1"
check    "  rows survive (under a 2-space indent)" "$(survives "$(CG_COLOR=never IMAGES=1 cg snapshot --list)" "$out" 2)" "same"

echo "3. cg status with the box registered but offline: no empty game-library section"
# tailscale ip answers for an offline node, so the section used to print its
# heading and nothing else - an empty box once styled.
cat > "$T/lib/setup" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$T/lib/setup"
printf '#!/usr/bin/env bash\ncase "$*" in *"ip -4"*) echo 100.64.0.1 ;; *) exit 1 ;; esac\n' > "$T/bin/tailscale"
out=$(CG_COLOR=never cg status)
contains "plain: the heading says why it is empty" "$out" $'game library\n  box not reachable - the archive is listed by: cg library list'
out=$(CG_COLOR=always cg status | strip)
contains "styled: the section has its row"   "$out" "│   box not reachable"
bare=$(python3 -c '
import sys
lines = sys.stdin.read().split("\n")
print(sum(1 for a, b in zip(lines, lines[1:]) if "╭─" in a and "╰─" in b))' <<<"$out")
check    "styled: no box opens and closes empty" "$bare" "0"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
