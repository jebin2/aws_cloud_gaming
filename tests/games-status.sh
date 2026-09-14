#!/usr/bin/env bash
# `cg games`: what Steam is actually doing.
#
# Two things here are easy to get wrong and were:
#
# StateFlags is a BITFIELD, not an enum. "1042" is 1024 UpdateStarted + 16
# Locked + 2 UpdateRequired, i.e. downloading - it means nothing read as a
# number, and a naive `== 4` test calls a downloading game "not installed".
#
# And Steam's own byte counters lag. BytesDownloaded read 0.6 GB while 67 GB
# sat on the disk, so a progress bar built on them showed 0% at 42% done.
# Progress is measured from the disk instead, against BytesToStage.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: output must not contain '$3'"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/home"
cp "$PWD/cg" "$T/cg"; cp -r "$PWD/lib" "$T/lib"
printf 'GAME_S3_BUCKET=b\nGAME_REGION=ap-south-2\nGAME_TS_HOST=gamevps\nGAME_INSTANCE_ID=i-t\n' > "$T/.env"
printf '#!/usr/bin/env bash\ncase "$*" in *ip*) echo 100.64.0.1 ;; *) exit 0 ;; esac\n' > "$T/bin/tailscale"
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *index.json*) cat "$IDX" ;; *) exit 1 ;; esac
FAKE
# ssh returns whatever the case under test put in $BOXOUT.
printf '#!/usr/bin/env bash\ncat "$BOXOUT"\n' > "$T/bin/ssh"
chmod +x "$T/bin"/*

echo '{"apps":[{"appid":"2358720","name":"Black Myth: Wukong","installdir":"BlackMythWukong","bytes":137438953472,"pushed":"2026-09-13T09:14:00Z"}]}' > "$T/index.json"

run() { ( cd "$T" && HOME="$T/home" IDX="$T/index.json" BOXOUT="$T/box.txt" \
            PATH="$T/bin:$PATH" timeout 30 bash ./cg games 2>&1 ); }

echo "1. a downloading game: progress from the DISK, not Steam's counters"
# 69 GB committed + 0 staged against a 161 GB target = 43%. Steam would say 0.4%.
{ printf 'APP\t2344520\tDiablo IV\t1042\t0\t74088284160\t673901856\t0\t172584496327\n'
  printf 'DISK\t73014444032\t158913789952\n'
  printf 'DL\t0\n'
  printf 'RATE\t90000000\n'; } > "$T/box.txt"
out=$(run)
contains "state is downloading"  "$out" "downloading"
contains "percentage from disk"  "$out" "43%"
contains "and the target size"   "$out" "161 GB"
contains "an ETA"                "$out" "min left"
lacks    "not 0%"                "$out" " 0% of"

echo "2. StateFlags 4 is installed"
printf 'APP\t2344520\tDiablo IV\t4\t172584496327\t172584496327\t0\t0\t0\nDISK\t1\t1\nDL\t0\nRATE\t0\n' > "$T/box.txt"
out=$(run)
contains "installed"        "$out" "installed"
lacks    "not downloading"  "$out" "downloading"

echo "3. a running game outranks every other flag"
printf 'APP\t2344520\tDiablo IV\t4\t172584496327\t172584496327\t0\t1\t0\nDISK\t1\t1\nDL\t0\nRATE\t0\n' > "$T/box.txt"
contains "shows RUNNING" "$(run)" "RUNNING"

echo "4. the other bitfield states are decoded, not printed as numbers"
for spec in "2:update needed" "32:files missing" "128:files corrupt" "512:paused"; do
  flag=${spec%%:*}; want=${spec##*:}
  printf 'APP\t1\tX\t%s\t100\t100\t0\t0\t0\nDISK\t1\t1\nDL\t0\nRATE\t0\n' "$flag" > "$T/box.txt"
  contains "flags=$flag -> $want" "$(run)" "$want"
done

echo "5. an archived game that is not installed is listed too"
printf 'DISK\t1\t1\nDL\t0\nRATE\t0\n' > "$T/box.txt"
out=$(run)
contains "names it"            "$out" "Black Myth: Wukong"
contains "says where it is"    "$out" "in S3 only"
contains "and its size"        "$out" "128.0 GB"

echo "6. an installed game is not ALSO listed as archived"
printf 'APP\t2358720\tBlack Myth: Wukong\t4\t137438953472\t137438953472\t0\t0\t0\nDISK\t1\t1\nDL\t0\nRATE\t0\n' > "$T/box.txt"
out=$(run)
contains "listed once, as installed" "$out" "installed"
lacks    "not also in S3 only"       "$out" "in S3 only"

echo "7. two games downloading: the shared downloading/ dir is not double-counted"
# steamapps/downloading is one directory for all apps, so attributing it to each
# would report both games as further along than they are.
{ printf 'APP\t1\tGame A\t1042\t0\t10737418240\t0\t0\t107374182400\n'
  printf 'APP\t2\tGame B\t1042\t0\t10737418240\t0\t0\t107374182400\n'
  printf 'DISK\t1\t1\nDL\t53687091200\nRATE\t0\n'; } > "$T/box.txt"
out=$(run)
contains "A at its own 10%"  "$out" "10% of 100 GB"
n=$(grep -c '10% of 100 GB' <<<"$out" || true)
if [[ ${n:-0} == 2 ]]; then echo "  ok   both, neither credited the shared 50 GB"; pass=$((pass+1));
else echo "  FAIL expected both at 10%, got $n lines"; fail=$((fail+1)); fi

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
