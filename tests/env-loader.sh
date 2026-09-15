#!/usr/bin/env bash
# Every .env loader must read the LAST line even when it has no trailing newline.
#
# `while read line; do ... done < .env` skips a final line that is not
# newline-terminated: `read` fills the variable but returns non-zero, and the
# loop ends before the body runs. An editor that does not add a final newline -
# or `echo -n`, or a paste - left the newest setting silently ignored. It showed
# up as `cg notify` insisting GAME_NTFY_URL was unset while .env plainly had it.
#
# Each loader is lifted out of its script and run against such a file, so the
# test exercises the real loop rather than a copy of it.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/lib"
# Two entries, the second with NO newline after it.
printf 'GAME_REGION=ap-south-2\nGAME_NTFY_URL=https://ntfy.sh/last-line' > "$T/.env"
check "the fixture really lacks a final newline" "$(tail -c1 "$T/.env" | od -An -c | tr -d ' ')" "e"

loader() { # loader <script>  -> the .env-reading block, from its while to its done
  awk '/while .*read -r/ {grab=1} grab {print} grab && /done < / {exit}' "$1"
}

echo "1. each loader reads an unterminated last line"
for script in cg lib/setup lib/game lib/aws-setup.sh; do
  block=$(loader "$script")
  if [[ -z $block ]]; then check "$script: loader found" "missing" "found"; continue; fi
  # aws-setup reads "$(dirname "$0")/../.env", so $0 is a script inside $T/lib.
  got=$( cd "$T" && env -u GAME_NTFY_URL -u GAME_REGION bash -c "$block
    echo \"\${GAME_NTFY_URL:-unset}|\${GAME_REGION:-unset}\"" "$T/lib/script" 2>&1 )
  check "$script: both lines, the last included" "$got" "https://ntfy.sh/last-line|ap-south-2"
done

echo "2. and a normal file, newline included, is unchanged"
printf 'GAME_REGION=ap-south-2\nGAME_NTFY_URL=https://ntfy.sh/with-newline\n' > "$T/.env"
for script in cg lib/setup lib/game lib/aws-setup.sh; do
  # Read the loop before the cd: the script path is relative to the repo.
  block=$(loader "$script")
  got=$( cd "$T" && env -u GAME_NTFY_URL -u GAME_REGION bash -c "$block
    echo \"\${GAME_NTFY_URL:-unset}\"" "$T/lib/script" 2>&1 )
  check "$script" "$got" "https://ntfy.sh/with-newline"
done

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
