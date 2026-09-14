#!/usr/bin/env bash
# Asks which archived games to restore, and prints the chosen appids as a csv.
#
# It runs on the LAPTOP, before the instance launches. The restore itself runs
# on the box at boot, started --no-block so it overlaps the build - there is no
# terminal there, and waiting until there is would cost the overlap that makes a
# 160 GB restore invisible. So the choice has to be made here and travel in
# user-data.
#
# Sizes come from s3://<bucket>/<prefix>/index.json, one small object written by
# each push, rather than by listing a few hundred thousand keys.
set -uo pipefail

BUCKET="${GAME_S3_BUCKET:-}"
PREFIX="${GAME_S3_PREFIX:-steam}"
# A g6.xlarge's instance store is 250 GB raw, 229 GB after ext4. The reserve
# covers what is NOT archived but still has to fit: Proton and the Steam runtime
# (~2.1 GB, deliberately re-downloaded), shader cache growth - Wukong made
# 854 MB in minutes - and room for Steam to stage an install without filling the
# disk. 20 GB, so ~209 GB is selectable.
DISK_GB="${CG_DISK_GB:-229}"
RESERVE_GB="${CG_RESERVE_GB:-20}"
AVAIL_GB=$(( DISK_GB - RESERVE_GB ))

[[ -n $BUCKET ]] && command -v aws >/dev/null || { echo "all"; exit 0; }

idx=$(aws s3 cp "s3://$BUCKET/$PREFIX/index.json" - 2>/dev/null || echo '{"apps":[]}')

# Nothing archived yet: no question worth asking.
if ! printf '%s' "$idx" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("apps") else 1)' 2>/dev/null; then
  echo "all"; exit 0
fi

# Not a terminal (a script, CI, a pipe): honour .env and do not block. "all" is
# the fallback only here, where a human already made a choice once and it was
# written to .env; the interactive default is "none" - see below.
if [[ ! -t 0 ]]; then
  echo "${GAME_APPS:-all}"; exit 0
fi

# stdout carries ONLY the chosen csv; the table and every prompt go to stderr.
# It used to push prompts at /dev/tty, which reads naturally and cannot be
# tested - and a prompt nobody can test is a prompt whose capacity arithmetic
# nobody can check.
# The interactive default is NONE, deliberately, and not the last selection.
#
# Enter is what people press to get past a prompt, and here that would start a
# 158 GB transfer - minutes of build time and an S3 bill - for a box they might
# have wanted empty. Restoring a game is cheap to ask for and annoying to undo,
# so it costs one deliberate keystroke. Nothing is lost by defaulting low: the
# archive is untouched, and `cg library pull --apps <id>` fetches it later.
choice=$(python3 lib/choose-games.py "$idx" "$AVAIL_GB" none)
echo "${choice:-all}"
