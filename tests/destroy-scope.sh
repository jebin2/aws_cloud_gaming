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
# The region holds cg's image and leftover disk (cg's tag), an image cg made
# before the tag (its old name only), the games volume, another project's image
# and volume - and one of theirs NAMED like ours, "gamevps", but without cg's
# tag. Filters are honoured, as AWS honours them.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *get-caller-identity*) echo "123456789012" ;;
  *describe-instances*) : ;;
  *describe-images*--image-ids*) echo "snap-cg" ;;
  *describe-images*tag:cg:host,Values=gamevps*) echo "ami-cg" ;;
  *describe-images*tag:Name,Values=gamevps-image*) echo "ami-legacy" ;;
  *describe-images*) printf 'ami-cg\tami-legacy\tami-other\n' ;;
  *describe-volumes*tag:cg:host,Values=gamevps*) echo "vol-cg" ;;
  *describe-volumes*tag:Name,Values=gamevps-games*) echo "vol-games" ;;
  *describe-volumes*) printf 'vol-cg\tvol-games\tvol-other\tvol-named\n' ;;
  *) echo "None" ;;
esac
FAKE
chmod +x "$T/bin/aws"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tailscale"; chmod +x "$T/bin/tailscale"
printf 'GAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\nGAME_INSTANCE_ID=i-old\n' > "$T/.env"
out=$( cd "$T" && HOME="$T/home" LOG="$T/log" PATH="$T/bin:$PATH" timeout 60 bash ./lib/setup destroy 2>&1 )
log=$(cat "$T/log")

echo "1. cg's own goes"
contains "cg's images are listed"         "$out" "images          ami-cg ami-legacy"
contains "  and its leftover volume"      "$out" "volumes         vol-cg"
contains "cg's tagged image deregistered" "$log" "deregister-image --image-id ami-cg"
contains "  one from before the tag too"  "$log" "deregister-image --image-id ami-legacy"
contains "  with its snapshot"            "$log" "delete-snapshot --snapshot-id snap-cg"
contains "  its leftover volume deleted"  "$log" "delete-volume --volume-id vol-cg"

echo "2. nothing else is touched - a Name alone is not cg's"
check    "another project's image stays"  "$(grep -c 'deregister-image --image-id ami-other' <<<"$log")" "0"
check    "  and its volume"               "$(grep -c 'delete-volume --volume-id vol-other' <<<"$log")" "0"
check    "  and one named like ours"      "$(grep -c 'delete-volume --volume-id vol-named' <<<"$log")" "0"
check    "the games volume stays"         "$(grep -c 'delete-volume --volume-id vol-games' <<<"$log")" "0"
contains "what was left alone is said"    "$out" "Left alone - not cg's: ami-other vol-other vol-named"

echo "3. everything cg creates carries its tag"
contains "the machine and its disk"       "$(cat lib/provision.sh)" '"ResourceType=volume,Tags=[{Key=Name,Value=$TS_HOST},{Key=$CG_TAG_KEY,Value=$TS_HOST}]"'
contains "  the security group"           "$(cat lib/provision.sh)" '"ResourceType=security-group,Tags=[{Key=$CG_TAG_KEY,Value=$TS_HOST}]"'
contains "  the key pair"                 "$(cat lib/ssh-key.sh)" 'ResourceType=key-pair'
check    "  images and their snapshots"   "$(grep -c 'ResourceType=snapshot,Tags=\[{Key=$CG_TAG_KEY' cg lib/game | grep -c ':1')" "2"
contains "  the box's role and the bucket" "$(cat lib/library-aws.sh)" 'put-bucket-tagging'
contains "  the watchdog"                 "$(cat lib/cloud-watchdog.sh)" 'lambda tag-resource'
check    "the tag is defined once"        "$(grep -rc '^CG_TAG_KEY=' lib cg | grep -vc ':0')" "1"

echo; echo "destroy-scope: $pass passed, $fail failed"; (( fail == 0 ))
