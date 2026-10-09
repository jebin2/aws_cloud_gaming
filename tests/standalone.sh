#!/usr/bin/env bash
# cg must work from an installed, READ-ONLY copy of itself.
#
# This is what a packaged app is: an AppImage mounts squashfs read-only, so a
# bundled cg cannot write anything next to its own scripts. Settings used to be
# a bare relative `.env` in eleven places, which made the checkout the only
# possible home for them - the app could be shipped, but the first time anyone
# changed a setting it would fail.
#
# The rule: a WRITABLE checkout keeps its settings in itself, exactly as before.
# Only a copy cg cannot write to falls back to the user's config directory.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
# The install is made read-only, so it has to be made writable again to remove.
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

# An "installed" copy: the scripts, no .env, nothing writable.
install=$T/opt/cg
mkdir -p "$install"
cp -r "$REPO/cg" "$REPO/lib" "$install/"
rm -f "$install/.env"
chmod -R a-w "$install"

run() { # run <command...>  - as the installed copy, with its own HOME
  ( cd "$install" && env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" \
      CG_REPO="$install" bash -c 'source lib/env-file.sh; '"$*" 2>&1 )
}

echo "1. a read-only install keeps its settings in the user's config directory"
check "nothing is writable in the install" \
      "$([[ -w $install ]] && echo writable || echo read-only)" "read-only"
got=$(run 'cg_env_file')
check "the settings land under XDG" "$got" "$T/home/.config/cg/.env"

echo "2. and it can actually save one"
out=$(run 'cg_env_set GAME_INSTANCE_TYPE g6e.xlarge && cat "$(cg_env_file)"')
contains "the value is written"       "$out" "GAME_INSTANCE_TYPE=g6e.xlarge"
check    "the file exists afterwards" \
         "$([[ -f $T/home/.config/cg/.env ]] && echo yes || echo no)" "yes"
check    "readable by its owner alone" \
         "$(stat -c '%a' "$T/home/.config/cg/.env" 2>/dev/null)" "600"
check    "and nothing was written into the install" \
         "$([[ -e $install/.env ]] && echo leaked || echo clean)" "clean"

echo "3. what it saved, it reads back"
got=$(run 'cg_env_load; echo "${GAME_INSTANCE_TYPE:-unset}"')
check "the setting survives a new run" "$got" "g6e.xlarge"

echo "4. a writable checkout is untouched by any of this"
# The whole point: nobody's settings move because they updated.
clone=$T/clone
mkdir -p "$clone"
cp -r "$REPO/cg" "$REPO/lib" "$clone/"
got=$( cd "$clone" && env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" CG_REPO="$clone" \
         bash -c 'source lib/env-file.sh; cg_env_file' )
check "a fresh clone still uses its own .env" "$got" "$clone/.env"
( cd "$clone" && env HOME="$T/home" CG_REPO="$clone" \
    bash -c 'source lib/env-file.sh; cg_env_set GAME_REGION ap-south-2' ) >/dev/null
check "  and writes it there" "$([[ -f $clone/.env ]] && echo yes || echo no)" "yes"
check "  not into the config directory" \
      "$(grep -c GAME_REGION "$T/home/.config/cg/.env" 2>/dev/null || true)" "0"

echo "5. an existing .env wins wherever it is"
# Someone who already has one keeps using it even if the repo became read-only
# - losing settings on upgrade would be worse than refusing to start.
chmod -R u+w "$install"
printf 'GAME_REGION=ap-south-1\n' > "$install/.env"
chmod -R a-w "$install"
got=$(run 'cg_env_file')
check "the one already there is used" "$got" "$install/.env"
chmod -R u+w "$install"; rm -f "$install/.env"; chmod -R a-w "$install"

echo "6. and the overrides still win over everything"
got=$( CG_ENV_FILE=/tmp/said-outright/.env run 'cg_env_file' )
check "CG_ENV_FILE is taken as given" "$got" "/tmp/said-outright/.env"
got=$( CG_HOME=/tmp/state-dir run 'cg_env_file' )
check "CG_HOME chooses the directory"  "$got" "/tmp/state-dir/.env"

echo "7. real cg commands, not just the resolver"
# The resolver being right is not the same as cg working. This runs the actual
# command the app's dropdown runs, from the read-only install.
out=$(cd "$install" && env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" \
        CG_REPO="$install" ./cg config set GAME_INSTANCE_TYPE g6e.xlarge 2>&1)
contains "cg config set works read-only" "$out" "GAME_INSTANCE_TYPE = g6e.xlarge"
got=$(cd "$install" && env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" \
        CG_REPO="$install" ./cg config get GAME_INSTANCE_TYPE 2>&1 | tail -1)
check "  and cg config get reads it back" "$got" "g6e.xlarge"
check "  with the install still untouched" \
      "$([[ -e $install/.env ]] && echo leaked || echo clean)" "clean"

echo "8. the app ships those scripts, and knows where they are"
# Without this the package is a window onto nothing: the app shells out to cg,
# so a build that does not carry it only works next to a checkout.
contains "the package carries cg"     "$(cat app/package.json)" '"to": "cg/cg"'
contains "  and lib"                  "$(cat app/package.json)" '"to": "cg/lib"'
contains "  and the lambda"           "$(cat app/package.json)" '"to": "cg/lambda"'
contains "the app looks in resources" "$(cat app/main/index.js)" "process.resourcesPath, 'cg'"
# A checkout beside the app comes first: someone running from source is editing
# that one and must see their edits, not a stale bundled copy.
check "  but a checkout beside it wins" \
      "$(awk '/path.resolve\(__dirname/{a=NR} /process.resourcesPath/{b=NR} END{print (a && b && a < b) ? "yes" : "no"}' app/main/index.js)" "yes"

echo
echo "standalone: $pass passed, $fail failed"
(( fail == 0 ))
