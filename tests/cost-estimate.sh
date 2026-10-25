#!/usr/bin/env bash
# cg cost's "not yet billed" estimate. It priced every box at the on-demand rate -
# a spot rig's estimate read four or five times what it cost - fell back to a
# price written in the code when AWS would not say, charged a disk made
# yesterday as if it had existed all month, and counted every disk, snapshot
# and image in the region, another project's too, as cg's.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: should not mention '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home" "$T/repo"
cp -r lib "$T/repo/"; cp cg "$T/repo/"
printf 'GAME_S3_BUCKET=cg-library-test\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\nGAME_INSTANCE_TYPE=g6.xlarge\n' > "$T/repo/.env"
TODAY=$(date -u +%Y-%m-%dT00:00:00.000Z)
export TODAY
# One g6.xlarge box (spot, or on demand with ONDEMAND=1): its 100 GB disk made
# on the 1st, a 50 GB cg leftover made today, and another project's 500 GB disk.
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
a="$*"
case "$a" in
  *"sts get-caller-identity"*) echo 123456789012 ;;
  *describe-instances*"instance-ids"*InstanceLifecycle*)
    printf 'g6.xlarge\t%s\tap-south-2a\n' "$([[ -n ${ONDEMAND:-} ]] && echo None || echo spot)" ;;
  *describe-instances*"instance-ids"*) echo running ;;
  *describe-instances*) echo i-box ;;
  *describe-spot-price-history*) [[ -n ${NOPRICE:-} ]] && exit 255; echo 0.2000 ;;
  *"pricing get-products"*) [[ -n ${NOPRICE:-} ]] && exit 255
    echo '{"terms":{"OnDemand":{"x":{"priceDimensions":{"y":{"pricePerUnit":{"USD":"0.9664"}}}}}}}' ;;
  *get-metric-statistics*) echo 10 ;;
  *describe-volumes*"attachment.instance-id"*) printf 'vol-root\t100\t%s\n' "$(date -u +%Y-%m-01T00:00:00.000Z)" ;;
  *describe-volumes*"tag:cg:host"*) printf 'vol-left\t50\t%s\n' "$TODAY" ;;
  # No old games volume: a [0] query answers None, as AWS does; a list, nothing.
  *describe-volumes*gamevps-games*"Volumes[0]"*) printf 'None\tNone\tNone\n' ;;
  *describe-volumes*gamevps-games*) : ;;
  *describe-volumes*) printf 'vol-theirs\t500\t2026-01-01T00:00:00.000Z\n' ;;
  *"ce get-cost-and-usage"*) echo '[]' ;;
  *) echo None ;;
esac
FAKE
chmod +x "$T/bin/aws"
run() { ( cd "$T/repo" && env -i CG_PRICES_FILE="$OLDPWD/tests/prices.env" CG_INR_PER_USD=88 PATH="$T/bin:$PATH" \
            HOME="$T/home" CG_COLOR=never TODAY="$TODAY" "$@" bash lib/setup cost 2>&1 ); }

echo "1. the machine as it is"
out=$(run)
contains "spot is priced at the spot price"   "$out" "THIS instance only, spot, price now"
contains "  10 hours at \$0.20, and its IPv4 at \$0.005" "$out" "10.0 hrs  \$  2.05"
out=$(run ONDEMAND=1)
contains "on demand at the on-demand price"   "$out" "THIS instance only, on demand"
contains "  10 hours at \$0.9664 and \$0.005"  "$out" "10.0 hrs  \$  9.71"
out=$(run NOPRICE=1)
contains "a price AWS would not give is ?"    "$out" "10.0 hrs        ?"
lacks    "  never the one written in the code" "$out" "9.71"
grep -v '^CG_IPV4_USD_HOUR=' tests/prices.env > "$T/no-ip.env"
out=$( cd "$T/repo" && env -i CG_PRICES_FILE="$T/no-ip.env" CG_INR_PER_USD=88 PATH="$T/bin:$PATH" \
         HOME="$T/home" CG_COLOR=never TODAY="$TODAY" bash lib/setup cost 2>&1 )
contains "an IPv4 price AWS would not give is ? too" "$out" "10.0 hrs        ?"

echo "2. cg's disks, by when each was made"
out=$(run)
contains "the box's disk and cg's leftover: 150 GB" "$out" "volumes         150 GB"
lacks    "  another project's is not counted" "$out" "650 GB"
# 100 GB since the 1st is this month's share of it; the 50 GB made today adds
# under a day's - so the storage line is no more than 100 GB's month-so-far
# plus a day of 50 GB, never 150 GB's month-so-far.
st=$(grep -o 'storage .*' <<<"$out" | head -1)
want=$(python3 -c 'import calendar,datetime as d
n=d.datetime.now(d.timezone.utc); days=calendar.monthrange(n.year,n.month)[1]
s=n.replace(day=1,hour=0,minute=0,second=0,microsecond=0); f=(n-s).total_seconds()/(days*86400)
print("%.2f" % ((100*f + 50*(n.hour*3600+n.minute*60)/(days*86400))*0.0912))')
contains "storage accrues each disk from when it was made" "$st" "\$ $(printf '%5s' "$want")"

echo; echo "cost-estimate: $pass passed, $fail failed"; (( fail == 0 ))
