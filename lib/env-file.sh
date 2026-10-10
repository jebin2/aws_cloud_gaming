#!/usr/bin/env bash
# Where cg keeps its settings, and the one loader that reads them.
#
# `.env` used to be a bare relative path in eight places, read after a cd to the
# repo root. That made the checkout the only possible home for it - which is
# fine for a clone you own, and impossible for an installed app: an AppImage
# mounts read-only, so a bundled cg could not save a single setting. Nor should
# a published artifact ever carry a .env; it holds the Tailscale keys.
#
# Resolution, first hit wins:
#   $CG_ENV_FILE              said outright - tests use this
#   $CG_HOME/.env             a chosen state directory
#   <repo>/.env               an existing checkout that already has one
#   <repo>/.env               a checkout cg can WRITE to - the normal case
#   $XDG_CONFIG_HOME/cg/.env  otherwise: an installed, read-only copy
#
# The checkout comes before XDG deliberately, and not only when a .env is
# already there: a fresh `git clone` plus `cg check --fix` must keep putting
# settings beside .env.example, where the docs have always said they live.
# XDG is for the case the repo cannot serve - scripts installed read-only,
# where there is nowhere in the install to write.

# Where the scripts live. CG_REPO wins, so a packaged app can say.
cg_repo_dir() {
  if [[ -n ${CG_REPO:-} ]]; then printf '%s' "$CG_REPO"; return 0; fi
  ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )
}

cg_env_file() {
  if [[ -n ${CG_ENV_FILE:-} ]]; then printf '%s' "$CG_ENV_FILE"; return 0; fi
  if [[ -n ${CG_HOME:-} ]]; then printf '%s/.env' "$CG_HOME"; return 0; fi
  local repo; repo=$(cg_repo_dir)
  if [[ -f "$repo/.env" ]]; then printf '%s/.env' "$repo"; return 0; fi
  # Writable means a clone, which keeps its settings in itself. Not writable
  # means an installed copy, and those go to the user's own config directory.
  if [[ -d $repo && -w $repo ]]; then printf '%s/.env' "$repo"; return 0; fi
  printf '%s/cg/.env' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Where throwaway answers live. NOT beside .env: a cache is not a setting, and
# an installed copy of the scripts is read-only anyway. XDG_CACHE_HOME so that
# clearing a cache is the one thing a user already knows how to do.
#
# This exists for `cg sweep`, which is free but takes a minute and a half - too
# slow for a screen to wait on, and its answer changes over hours rather than
# seconds. Nothing in here is ever required: every reader must work when the
# cache is absent, stale or unreadable.
cg_cache_dir() {
  if [[ -n ${CG_CACHE_DIR:-} ]]; then printf '%s' "$CG_CACHE_DIR"; return 0; fi
  printf '%s/cg' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

# cg_cache_write <name> - stdin to the named cache file, atomically. Silent on
# failure: a cache that cannot be written must never break the command.
cg_cache_write() {
  local d f tmp; d=$(cg_cache_dir); f="$d/$1"
  mkdir -p "$d" 2>/dev/null || return 0
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 0
  if cat > "$tmp" 2>/dev/null && [[ -s $tmp ]]; then mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else rm -f "$tmp"; fi
  return 0
}

# cg_cache_read <name> - the file, or nothing.
cg_cache_read() {
  local f; f="$(cg_cache_dir)/$1"
  [[ -s $f ]] || return 1
  cat "$f" 2>/dev/null
}

# cg_cache_age <name> - seconds since it was written, or nothing.
cg_cache_age() {
  local f; f="$(cg_cache_dir)/$1"
  [[ -s $f ]] || return 1
  local m now; m=$(stat -c %Y "$f" 2>/dev/null) || return 1
  now=$(date +%s); printf '%s' "$(( now - m ))"
}

# The file, created with its directory, 0600. Printed, so a writer can use it.
# Fails loudly rather than writing settings somewhere nobody will look again.
cg_env_ensure() {
  local f; f=$(cg_env_file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  if [[ ! -e $f ]]; then : > "$f" 2>/dev/null || return 1; fi
  chmod 600 "$f" 2>/dev/null || true
  printf '%s' "$f"
}

# Load it into the environment. Anything already exported WINS - that is what
# makes `cg --region X` and a test's exported value beat the file.
#
# KEY=VALUE lines are read rather than sourced: `source` executes any stray line
# as a command, so one malformed entry turns a config file into a script. A
# corrupted value once left a bare hostname on its own line and every run died
# with "gamevps: command not found".
cg_env_load() { # cg_env_load [key-prefix]
  local only=${1:-} f line k
  f=$(cg_env_file)
  [[ -f $f ]] || return 0
  # `|| [[ -n $line ]]`: `read` returns non-zero on a last line with no newline,
  # so without it the final entry - usually the one just added - was ignored.
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    k="${line%%=*}"
    [[ -n $only && $k != "$only"* ]] && continue
    [[ -n ${!k:-} ]] && continue
    export "$k=${line#*=}"
  done < "$f"
}

# Replace one key in place, keeping every other line and the file's mode.
# Every writer used to open-code this against a relative path.
cg_env_set() { # cg_env_set <KEY> <value>
  local f tmp
  f=$(cg_env_ensure) || return 1
  tmp=$(mktemp) || return 1
  grep -v "^$1=" "$f" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$f" && rm -f "$tmp" && chmod 600 "$f"
}
