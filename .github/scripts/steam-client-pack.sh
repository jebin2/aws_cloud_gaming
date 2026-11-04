#!/usr/bin/env bash
# Packs a Steam client folder into the archive a new box downloads instead of
# downloading the client from Valve (about 2.5 GB at 5 MB/s, the longest step of a
# build). steam-client-pack.sh <the Steam folder> <where to put the files>
#
# What goes in is the client itself: its programs, its update packages, its
# interface. What does not is anything that belongs to a person or a machine - the
# login, the account's settings, the logs, the games, the caches, the crash dumps.
# Whoever restores it gets a fresh client that signs in as nobody.
set -euo pipefail
src=${1:?usage: steam-client-pack.sh <steam folder> <out folder>}
out=${2:?usage: steam-client-pack.sh <steam folder> <out folder>}
src=$(readlink -f "$src")
[ -d "$src/ubuntu12_64" ] || { echo "no Steam client in $src (no ubuntu12_64)"; exit 1; }
mkdir -p "$out"
parent=$(dirname "$src"); base=$(basename "$src")

# The path from one folder to another, both absolute and inside this folder.
relpath() {
  local from=${1#/} to=${2#/} common=0 i out=
  local -a f t
  IFS=/ read -r -a f <<< "$from"
  IFS=/ read -r -a t <<< "$to"
  while [ "$common" -lt "${#f[@]}" ] && [ "$common" -lt "${#t[@]}" ] \
        && [ "${f[$common]}" = "${t[$common]}" ]; do
    common=$((common + 1))
  done
  for ((i = common; i < ${#f[@]}; i++)); do out+=../; done
  for ((i = common; i < ${#t[@]}; i++)); do out+="${t[$i]}/"; done
  [ -n "$out" ] || out=.
  printf '%s\n' "${out%/}"
}

# A link that points back into this folder by its full path would point nowhere on
# another machine. Steam's runtime makes several of its own that way
# (steam-runtime/pinned_libs_*), so make every one of them relative: the link then
# works wherever the archive is unpacked.
fixed=0
while IFS= read -r -d '' link; do
  ln -snf "$(relpath "$(dirname "$link")" "$(readlink "$link")")" "$link"
  fixed=$((fixed + 1))
done < <(find "$src" -type l \( -lname "$src" -o -lname "$src/*" \) -print0)
[ "$fixed" -eq 0 ] || echo "made $fixed link(s) inside the folder relative"

# Anything still naming this folder by its full path would break elsewhere; say so now.
bad=$(find "$src" -type l \( -lname "$src" -o -lname "$src/*" \) | head -5 || true)
if [ -n "$bad" ]; then
  echo "absolute links into $src - they would break on another machine:"
  echo "$bad"
  exit 1
fi

tar -C "$parent" -I 'zstd -15 -T0' -cf "$out/steam-client.tar.zst" \
  --exclude="$base/config" --exclude="$base/logs" --exclude="$base/userdata" \
  --exclude="$base/steamapps" --exclude="$base/appcache" --exclude="$base/depotcache" \
  --exclude="$base/dumps" --exclude="$base/ssfn*" --exclude="$base/htmlcache" \
  --exclude="$base/shadercache" --exclude='*.log' --exclude='*.crash' \
  "$base"

( cd "$out" && sha256sum steam-client.tar.zst > steam-client.sha256 )
bytes=$(stat -c %s "$out/steam-client.tar.zst")
sha=$(cut -d' ' -f1 "$out/steam-client.sha256")
version=$(sed -n 's/.*"version"[[:space:]]*"\([0-9]*\)".*/\1/p' "$src/package/steam_client_ubuntu12.manifest" 2>/dev/null | head -1 || true)
printf '{"created":"%s","bytes":%s,"sha256":"%s","client_version":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$bytes" "$sha" "${version:-}" > "$out/steam-client.json"
echo "packed $bytes bytes, sha256 $sha"
# One asset of a GitHub release may not pass 2 GiB.
[ "$bytes" -lt 2147483648 ] || { echo "the archive is over GitHub's 2 GiB limit for one file"; exit 1; }
