#!/usr/bin/env bash
# cg destroy deletes cg's resources and nothing else. It took every image the
# account owned and every unattached volume in the region: another project's
# AMI or disk went with an ordinary destroy. An image is cg's by the tag
# `cg snapshot` gives it, a volume by the box's name; anything else is named as
# left alone and never touched. The games volume is kept, as before.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home/.ssh"
cp -r "$REPO/lib" "$T/lib"
# The region holds cg's image and leftover disk, the games volume, and another
# project's image and volume. Filters are honoured, as AWS honours them.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *get-caller-identity*) echo "123456789012" ;;
  *describe-instances*) : ;;
  *describe-images*--image-ids*) echo "snap-cg" ;;
  *describe-images*tag:Name,Values=gamevps-image*) echo "ami-cg" ;;
  *describe-images*) printf 'ami-cg\tgamevps-image\nami-other\tNone\n' ;;
  *describe-volumes*tag:Name,Values=gamevps*) echo "vol-cg" ;;
  *describe-volumes*) printf 'vol-cg\tgamevps\nvol-games\tgamevps-games\nvol-other\tTheirs\n' ;;
  *) echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"; chmod +x "$T/bin/tailscale"
printf 'GAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\nGAME_INSTANCE_ID=i-old\n' > "$T/.env"
out=$( cd "$T" && HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" timeout 60 bash ./lib/setup destroy 2>&1 )
log=$(cat "$T/log")

echo "1. cg's own goes"
contains "cg's image is listed"           "$out" "images          ami-cg"
contains "  and its leftover volume"      "$out" "volumes         vol-cg"
contains "cg's image is deregistered"     "$log" "deregister-image --image-id ami-cg"
contains "  with its snapshot"            "$log" "delete-snapshot --snapshot-id snap-cg"
contains "  its leftover volume deleted"  "$log" "delete-volume --volume-id vol-cg"

echo "2. nothing else is touched"
check    "another project's image stays"  "$(grep -c 'deregister-image --image-id ami-other' <<<"$log")" "0"
check    "  and its volume"               "$(grep -c 'delete-volume --volume-id vol-other' <<<"$log")" "0"
check    "the games volume stays"         "$(grep -c 'delete-volume --volume-id vol-games' <<<"$log")" "0"
contains "what was left alone is said"    "$out" "Left alone - not cg's: ami-other vol-other"

echo "3. a launch names its disk, so a stray one is known as cg's"
contains "the disk is tagged at launch"   "$(cat lib/provision.sh)" '"ResourceType=volume,Tags=[{Key=Name,Value=$TS_HOST}]"'

echo; echo "destroy-scope: $pass passed, $fail failed"; (( fail == 0 ))
