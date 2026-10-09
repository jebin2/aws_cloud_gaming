#!/usr/bin/env bash
# The one loader that reads cg's settings, and where it looks for them.
#
# The unterminated-last-line bug: `while read line; do ... done < file` skips a
# final line with no newline - `read` fills the variable but returns non-zero,
# and the loop ends before the body runs. An editor that does not add a final
# newline, or a paste, left the newest setting silently ignored. It showed up as
# `cg notify` insisting GAME_NTFY_URL was unset while the file plainly had it.
#
# There used to be FOUR copies of that loop - in cg, lib/setup, lib/game and
# lib/aws-setup.sh - and this suite lifted each one out by pattern to prove they
# all had the fix. There is one now, in lib/env-file.sh, so the test runs it
# directly; what the four callers share is that they all call it.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD            # resolved before any cd, or $PWD becomes the sandbox
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
          else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# Two entries, the second with NO newline after it.
printf 'GAME_REGION=ap-south-2\nGAME_NTFY_URL=https://ntfy.sh/last-line' > "$T/.env"
check "the fixture really lacks a final newline" "$(tail -c1 "$T/.env" | od -An -c | tr -d ' ')" "e"

load() { # load [prefix] -> "<ntfy>|<region>" as the loader leaves them
  ( cd "$T" && env -u GAME_NTFY_URL -u GAME_REGION CG_ENV_FILE="$T/.env" \
      bash -c 'source '"$REPO"'/lib/env-file.sh
               cg_env_load '"${1:-}"'
               echo "${GAME_NTFY_URL:-unset}|${GAME_REGION:-unset}"' 2>&1 )
}

echo "1. an unterminated last line is read"
check "both entries arrive" "$(load)" "https://ntfy.sh/last-line|ap-south-2"

echo "2. and a normal file, newline included, is unchanged"
printf 'GAME_REGION=ap-south-2\nGAME_NTFY_URL=https://ntfy.sh/with-newline\n' > "$T/.env"
check "both entries arrive" "$(load)" "https://ntfy.sh/with-newline|ap-south-2"

echo "3. anything already exported wins over the file"
# This is what makes `cg --region X` work, and what lib/setup's own copy of the
# loop used to get wrong: it overwrote the exported value with the file's.
got=$( cd "$T" && env -u GAME_NTFY_URL GAME_REGION=ap-south-1 CG_ENV_FILE="$T/.env" \
         bash -c 'source '"$REPO"'/lib/env-file.sh; cg_env_load; echo "$GAME_REGION"' 2>&1 )
check "the override survives" "$got" "ap-south-1"

echo "4. a prefix limits what is loaded"
# lib/game and lib/aws-setup.sh take only GAME_*, as they always did.
printf 'GAME_REGION=ap-south-2\nSUNSHINE_PASS=secret\n' > "$T/.env"
got=$( cd "$T" && env -u GAME_REGION -u SUNSHINE_PASS CG_ENV_FILE="$T/.env" \
         bash -c 'source '"$REPO"'/lib/env-file.sh; cg_env_load GAME_
                  echo "${GAME_REGION:-unset}|${SUNSHINE_PASS:-unset}"' 2>&1 )
check "only the prefix is taken" "$got" "ap-south-2|unset"

echo "5. a malformed line cannot become a command"
# A corrupted value once left a bare hostname on its own line and every run died
# with "gamevps: command not found" - because the file was being sourced.
printf 'gamevps\nrm -rf /tmp/should-not-run\nGAME_REGION=ap-south-2\n' > "$T/.env"
got=$( cd "$T" && env -u GAME_REGION CG_ENV_FILE="$T/.env" \
         bash -c 'source '"$REPO"'/lib/env-file.sh; cg_env_load; echo "${GAME_REGION:-unset}"' 2>&1 )
check "the junk is skipped, the setting is read" "$got" "ap-south-2"

echo "6. every caller uses it, and none keeps a loop of its own"
for script in cg lib/setup lib/game lib/aws-setup.sh; do
  if grep -q 'cg_env_load' "$script"; then
    echo "  ok   $script calls the loader"; pass=$((pass+1))
  else
    echo "  FAIL $script does not call cg_env_load"; fail=$((fail+1))
  fi
  if grep -qE 'done < *"?\$?\{?[A-Za-z_]*\}?/?\.env"?' "$script"; then
    echo "  FAIL $script still reads .env with a loop of its own"; fail=$((fail+1))
  else
    echo "  ok     and has no loop of its own"; pass=$((pass+1))
  fi
done

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
