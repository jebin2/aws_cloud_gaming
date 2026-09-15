#!/usr/bin/env bash
# The styled output: colour, emoji, boxed steps, live lines.
#
# The rule this file exists to hold: styling happens ONLY on a terminal. Every
# other consumer - these suites, a pipe, a saved build log - must get the plain
# format byte for byte, because the other suites match on it and because a
# log you cannot grep is worse than an ugly one. So the plain cases come first,
# and the styled cases force a terminal (CG_COLOR=always, or a real pty from
# script(1)) rather than trusting the detection they are testing.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); pass=0; fail=0
trap 'rm -rf "$T"' EXIT

check()    { if [[ $2 == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
contains() { if [[ $2 == *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: lacks '$3'"; fail=$((fail+1)); fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: must not contain '$3'"; fail=$((fail+1)); fi; }
matches()  { if [[ $2 =~ $3 ]]; then echo "  ok   $1"; pass=$((pass+1));
             else echo "  FAIL $1: '$2' !~ /$3/"; fail=$((fail+1)); fi; }

ESC=$'\e'
strip() { sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g; s/\r//g"; }
# Run a snippet with lib/common.sh sourced. Output is captured, so NOT a tty.
sh_() { env -u NO_COLOR bash -c "source lib/common.sh; $1" 2>&1; }
styled() { CG_COLOR=always COLUMNS=80 bash -c "source lib/common.sh; $1" 2>&1; }
ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}'

echo "1. off a terminal, every helper prints exactly the old plain format"
out=$(sh_ 'say "provisioning instance"')
check   "say: leading blank line"      "$(head -1 <<<"$out")" ""
matches "say: 'ISO  ==> title'"        "$(sed -n 2p <<<"$out")" "^${ISO}  ==> provisioning instance$"
matches "log: 'ISO      text'"         "$(sh_ 'log "pushed 1 game(s) in 6s"')" "^${ISO}      pushed 1 game\(s\) in 6s$"
out=$(sh_ 'die "no bucket"'); rc=$?
matches "die: 'ISO  error: text'"      "$out" "^${ISO}  error: no bucket$"
check   "die: exits 1"                 "$rc" "1"
lacks   "no escape codes anywhere"     "$(sh_ 'say x; log y; cg_echo z')" "$ESC"
check   "cg_echo is plain echo"        "$(sh_ 'cg_echo "a  b"')" "a  b"
in=$'2026-09-14T16:44:23+00:00 cg-library: archived 21KB\n  s5cmd: cp x'
check   "cg_relay == the sed it replaced" "$(sh_ "printf '%s\n' \"$in\" | cg_relay '      '")" "$(printf '%s\n' "$in" | sed 's/^/      /')"
check   "cg_relay '' passes through"   "$(sh_ "printf 'a\n b\n' | cg_relay ''")" "$(printf 'a\n b\n')"
check   "cg_block passes through"      "$(sh_ "printf 'x\n  y\n' | cg_block '🧾' 'Plan'")" "$(printf 'x\n  y\n')"

echo "2. NO_COLOR and CG_COLOR=never win even on a real terminal"
# script(1) gives the snippet a real pty, so this is the actual detection, not
# CG_COLOR=always standing in for it. Every run must print SOMETHING first: a
# run that fails to start prints nothing, and nothing contains no "╭─" - the
# first version of this case passed three checks exactly that way.
if command -v script >/dev/null; then
  SNIP="bash -c 'source lib/common.sh; say demo; log done'"
  out=$(env -u NO_COLOR -u CG_COLOR TERM=xterm-256color script -qec "$SNIP" /dev/null 2>&1 | strip)
  contains "a pty with nothing set IS styled" "$out" "╭─"
  out=$(env -u CG_COLOR NO_COLOR=1 TERM=xterm-256color script -qec "$SNIP" /dev/null 2>&1 | strip)
  contains "NO_COLOR=1 on a pty still prints" "$out" "==> demo"
  lacks    "  but plain"                      "$out" "╭─"
  out=$(env -u NO_COLOR CG_COLOR=never TERM=xterm-256color script -qec "$SNIP" /dev/null 2>&1 | strip)
  contains "CG_COLOR=never on a pty prints"   "$out" "==> demo"
  lacks    "  but plain"                      "$out" "╭─"
  out=$(env -u NO_COLOR -u CG_COLOR TERM=dumb script -qec "$SNIP" /dev/null 2>&1 | strip)
  contains "TERM=dumb on a pty prints"        "$out" "==> demo"
  lacks    "  but plain"                      "$out" "╭─"
else
  echo "  skip: script(1) not installed"
fi

echo "3. a step is a box: emoji by keyword, closed by the next step and on exit"
out=$(styled 'say "mirroring the game library to S3"; log "pushed 1 game(s)"; say "terminating i-123"; log "x"' | strip)
contains "mirroring gets 💾"      "$out" "╭─ 💾 mirroring the game library to S3"
contains "terminating gets 🔥"     "$out" "╭─ 🔥 terminating i-123"
contains "time right-aligned"      "$out" "..."
first_close=$(grep -n '╰─' <<<"$out" | head -1 | cut -d: -f1)
second_open=$(grep -n '╭─ 🔥' <<<"$out" | cut -d: -f1)
if [[ -n $first_close && -n $second_open ]] && (( first_close < second_open )); then
  echo "  ok   the first box closes before the second opens"; pass=$((pass+1))
else echo "  FAIL box 1 closed at '${first_close:-never}', box 2 opened at '${second_open:-never}'"; fail=$((fail+1)); fi
check    "the last box closes on exit" "$(grep -c '╰─ ✓ done in' <<<"$out")" "2"
out=$(styled 'say "provisioning instance"; die "no bucket"' | strip)
contains "die inside a box: ✗ error"      "$out" "✗ error: no bucket"
contains "and the box closes as stopped"  "$out" "╰─ ✗ stopped after"
contains "default icon for unknown steps" "$(styled 'say "zzz"' | strip)" "╭─ ▶ zzz"
out=$(styled 'say "terminating i-1"; log "x"; say "box deleted - kept for cg init"' | strip)
contains "a finishing step is one 🎉 line"  "$out" "🎉 box deleted - kept for cg init"
lacks    "  not a box"                      "$out" "╭─ 🎉"
check    "  and it closes the step before it" "$(grep -c '╰─' <<<"$out")" "1"

echo "3b. a block cannot close a step - it runs in a subshell - so the caller does"
# The bug: cg_block closed the step itself, from the subshell a pipe puts it in.
# The parent never saw the step close, so the next step closed it AGAIN: three
# closing lines for two steps, and a gutter on every line in between.
out=$(styled 'say "one"; printf "note\n" | cg_block "🧾" "Plan"; say "two"' | strip)
check "a block mid-step does not add a closing line" "$(grep -c '╰─ ✓ done in' <<<"$out")" "2"
out=$(styled 'say "one"; _cg_section_end 0; printf "note\n" | cg_block "🧾" "Plan"; log "after"' | strip)
check "closing first: exactly one closing line"      "$(grep -c '╰─ ✓ done in' <<<"$out")" "1"
matches "  and the line after the block has no gutter" "$(grep 'after' <<<"$out")" "^[0-9:]+    · after$"

echo "4. each detail line gets its symbol from its words"
sym() { styled "log \"$1\"" | strip | sed -nE 's/^[0-9:]+ .  (.) .*/\1/p'; }
check "pushed -> ✓"                          "$(sym 'pushed 1 game(s) in 6s')" "✓"
check "WARNING -> !"                         "$(sym 'WARNING: stopping without a mirror')" "!"
check "FAILED -> ✗"                          "$(sym 'FAILED: library mirror install')" "✗"
check "not archiving (a tool) -> ·"          "$(sym 'not archiving Proton Experimental (1493710) - a Steam tool')" "·"
check "keeping -> ↺"                         "$(sym 'keeping the budget gamevps-monthly')" "↺"
check "still shutting-down -> ◌"             "$(sym 'still shutting-down (12s)')" "◌"
check "rejected -> ✗, not ✓"                 "$(sym 'TAILSCALE_API_KEY rejected (HTTP 403)')" "✗"
check "NOT registered -> !, not ✓"           "$(sym 'library NOT registered')" "!"
# Whole words. A substring test calls both of these a success.
check "'broken' is not 'ok'"                 "$(sym 'broken token')" "·"
check "'tokens' is not 'ok'"                 "$(sym 'rotating tokens')" "·"
# ...and the other end of the word. "broken" and "tokens" only exercise the
# boundary AFTER "ok"; a match that dropped the boundary BEFORE it still passed
# both. These end in a success word.
check "'notebook' is not 'ok'"               "$(sym 'open the notebook')" "·"
check "'undone' is not 'done'"               "$(sym 'the change was undone')" "·"
check "'outlook' is not 'ok'"                "$(sym 'outlook is unclear')" "·"
check "plain info -> ·"                      "$(sym 'copying host/ ...')" "·"
# "keeping" wins over the "not" later in the same line, and a bare "not" is not
# a warning - both showed a "!" on routine destroy output before this.
check "keeping ... not the box -> ↺"         "$(sym 'keeping the budget gamevps-monthly - it guards the account, not the box')" "↺"
check "bare 'not' is information"            "$(sym 'the desktop goes, not the games')" "·"
# A line that matches BOTH rules. "not the box" no longer matches the warning
# rule at all, so it could not tell which rule is checked first.
check "keeping ... not deleted -> ↺ (order)" "$(sym 'keeping the budget - it is not deleted')" "↺"
check "'not mirrored' -> !"                  "$(sym 'the library was not mirrored to S3')" "!"
out=$(styled 'log "  a continuation line"' | strip)
lacks "an indented line gets no symbol"      "$out" "✓"

echo "5. relayed box output loses its own timestamp prefix and gains a symbol"
in=$'2026-09-14T16:44:23+00:00 cg-library: steam account: archived 21KB\n2026-09-14T16:44:24+00:00 cg-library: SKIPPING Foo (1): Steam says StateFlags=1026'
out=$(styled "printf '%s\n' \"$in\" | cg_relay '      '" | strip)
contains "✓ on the archived line"      "$out" "✓ steam account: archived 21KB"
contains "! on the skipped line"       "$out" "! SKIPPING Foo"
lacks    "no duplicate timestamp"      "$out" "cg-library:"
out=$(styled "printf '==> budget\n    alerts to x\n' | cg_relay '    '" | strip)
contains "==> becomes a sub-step"      "$out" "▸ budget"

echo "5b. a systemctl timer table becomes one line per timer"
# Captured from install-watchdog.sh on a real box: header, two rows, footer.
tbl='NEXT                         LEFT LAST                              PASSED UNIT                ACTIVATES
Mon 2026-09-14 18:38:04 UTC   30s Mon 2026-09-14 18:37:04 UTC      29s ago idle-watchdog.timer idle-watchdog.service
Mon 2026-09-14 19:34:01 UTC 56min Mon 2026-09-14 18:34:01 UTC 3min 32s ago disk-monitor.timer  disk-monitor.service

2 timers listed.
Pass --all to see loaded but inactive timers, too.
watchdog armed.     follow with: journalctl -t idle-watchdog -f'
out=$(styled "printf '%s\n' \"\$1\" | cg_relay '    '" 2>&1 <<<"" ; true)
out=$(CG_COLOR=always COLUMNS=80 bash -c 'source lib/common.sh; printf "%s\n" "$1" | cg_relay "    "' _ "$tbl" | strip)
contains "timer 1, with when it next runs" "$out" "✓ idle-watchdog.timer · next run in 30s"
contains "timer 2"                          "$out" "✓ disk-monitor.timer · next run in 56min"
lacks    "no column header"                 "$out" "ACTIVATES"
lacks    "no 'timers listed' footer"        "$out" "timers listed"
lacks    "no 'Pass --all' hint"             "$out" "Pass --all"
contains "column padding collapses to a space" "$out" "watchdog armed. follow with: journalctl"
check    "plain: the table is untouched"    "$(bash -c 'source lib/common.sh; printf "%s\n" "$1" | cg_relay "    "' _ "$tbl")" "$(printf '%s\n' "$tbl" | sed 's/^/    /')"

echo "6. waiting is one live line, rewritten in place"
mkdir -p "$T/bin"
cat > "$T/bin/aws" <<'FAKE'
#!/usr/bin/env bash
n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$CNT"
(( n >= 3 )) && echo terminated || echo shutting-down
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin"/*
raw=$(CNT="$T/cnt" PATH="$T/bin:$PATH" CG_COLOR=always bash -c 'source lib/common.sh; wait_instance_state r i-1 terminated 60' 2>&1)
rc=$?
check    "returns 0 on reaching the state" "$rc" "0"
contains "rewrites in place (\\r)"        "$raw" $'\r'
check    "ends in exactly one printed line" "$(printf '%s' "$raw" | strip | grep -c .)" "1"
contains "and that line is the result"     "$(printf '%s' "$raw" | strip)" "✓ terminated after"
rm -f "$T/cnt"
out=$(CNT="$T/cnt" PATH="$T/bin:$PATH" bash -c 'source lib/common.sh; wait_instance_state r i-1 terminated 60' 2>&1)
contains "plain: still logs the state"     "$out" "shutting-down"
contains "plain: and the old final line"   "$out" "terminated after"
lacks    "plain: no carriage returns"      "$out" $'\r'

echo "7. the build's live line says of how much, how fast, and what it is waiting for"
# "116G of games on disk" was true and answered none of those.
bs() { CG_COLOR=always bash -c 'source lib/common.sh; _cg_build_status "$@"' _ "$@" | strip; }
G=1073741824; MB=1048576
out=$(bs "installing steam" 394 $((83*G)) $((160*G)) $((200*MB)) "Diablo IV")
contains "names the game, of how much, percent" "$out" "restoring Diablo IV: 83 of 160 GB (51%)"
contains "and the step it is running beside"    "$out" "installing steam · 6m 34s"
# (160-83) GB at 200 MB/s = 394 s -> rounds UP to 7 min, never down to an optimistic 6.
contains "time left from the rate, rounded up"  "$out" "~7 min left"
out=$(bs "finishing up" 666 $((109*G)) $((160*G)) $((200*MB)) "Diablo IV")
contains "finishing up says it is the restore"  "$out" "restoring Diablo IV · 109 of 160 GB (68%)"
contains "  with the time left"                 "$out" "~5 min left"
lacks    "  instead of the vague label"         "$out" "finishing up"
out=$(bs "finishing up" 700 $((158*G)) $((160*G)) $((50*MB)) "Diablo IV")
contains "at 98% it is done, waiting on the desktop" "$out" "games restored - waiting for the desktop"
out=$(bs "installing steam" 60 $((10*G)) $((160*G)) 0 "Diablo IV")
lacks    "no rate yet: no made-up time left"    "$out" "min left"
out=$(bs "installing steam" 60 $((5*G)) 0 0 "games")
contains "total unknown: still says what it knows" "$out" "5 GB of games restored so far"
out=$(bs "installing desktop" 30 0 0 0 "games")
lacks    "nothing restoring: no games clause"   "$out" "GB"

echo "8. reports (cg status / cost / games): boxed, coloured, and not one character moved"
# The fixtures are real output of all three commands, with account ids, keys,
# IPs and resource ids replaced. The property that matters: strip the colour and
# the gutter from every row and you get the original row back - so no value is
# lost and no column shifts. [ok]/[--] -> tick/cross is the only substitution.
cat > "$T/status.txt" <<'FX'
ACCOUNT
  id              123456789012
  plan            PAID
  credits         $122.29

QUOTAS in ap-south-2
  g6.xlarge needs 4 vCPU
  on-demand G/VT  4 vCPU
  spot G/VT       4 vCPU

RESOURCES in ap-south-2
  instance        i-0123456789abcdef0  g6.xlarge  running
  public ip       203.0.113.5
  launched        2026-09-14T18:19:12+00:00
  volumes         50 GB total
  snapshots       0
  saved images    0
  elastic ips     0
  key pair        gamevps
  security group  sg-0123456789abcdef0
  game library    s3://cg-library-example  6218 objects, 161GB  ($4.00/mo)
  instance role   gamevps-box  (lets the box read/write its library bucket)
  watchdog role   gamevps-cloud-watchdog  (the cloud watchdog: ends only the gamevps box)
    inbound       udp/41641 from 0.0.0.0/0

COST GUARDS
  idle-stop alarm OK, disarmed   (cg open arms it for a session)
  budget          $57 limit, AWS reports $0.00 spent - not calculated yet
                  (Budgets lags up to 24h after creation; real spend: cg cost)
  budget alerts   2 configured

LOCAL
  [ok]   tailscale up
  [ok]   moonlight installed
  [ok]   ssh key ~/.ssh/gamevps.pem
  [ok]   tailscale auth key in .env
  [ok]   tailnet node 100.64.0.1 online
instance: running
disk:
  Mounted on  Used  Size Use%
  /           9.6G   48G  21%
  /scratch    161G  229G  75%

game library
  bucket    s3://cg-library-example/steam
  local     161GB  at /scratch/steam
  restored  yes (this boot)
  this boot 2344520
  last push never
  steam login archived - a new box starts signed in
  archive:
  APPID      GAME                                    SIZE  ARCHIVED
  2344520    Diablo® IV                          160.2 GB  2026-09-14 17:49
             total                               160.2 GB   $4.00/month (INR 352)

TRAFFIC (this boot only - see cg cost for the billed month)
  stream out      0.00 GB   avg 0.0 Mbps over 0.4 h
  total out       0.12 GB   <- what AWS bills (adds wireguard overhead, ssh, apt)
  total in        90.51 GB   (free - game downloads land here)
  (above is this boot only)
  monthly egress  20.1 GB used, ~80 GB of 100 GB free left  (as of 9 h ago)
FX
cat > "$T/cost.txt" <<'FX'
resources in ap-south-2:
  instance        i-0123456789abcdef0  (running)
  volumes         50 GB 
  snapshots       0 GB
  images          0
  key pair        gamevps
  security group  gamevps-sg
  game library    s3://cg-library-example  6218 objects, 161GB  ($4.00/mo)
  instance role   gamevps-box  (lets the box read/write its library bucket)
  watchdog role   gamevps-cloud-watchdog  (the cloud watchdog: ends only the gamevps box)
  idle alarm      present
  budget          $57/month
not yet billed (Cost Explorer lags about a day):
  compute      1.0 hrs  $  0.97  (INR    85)  THIS instance only
  storage       50 GB   $  2.13  (INR   187)  month so far, accrues while stopped
  ---------------------------------------
  estimate              $  3.09  (INR   272)
  (egress is counted under 'billed so far' below, not in this estimate)

credits remaining: $122.29
billed so far (lags a day - these are the real charges):
  USAGE TYPE                            QTY      USD     INR
  BoxUsage:g6.xlarge                  10.96    10.59     932
  SpotUsage:g6.xlarge                 16.69     3.69     325
  Requests-Tier1                  139900.00     0.70      62
  APIRequest                          39.00     0.39      34
  DataTransfer-Regional-Bytes         34.49     0.33      29
  EBS:VolumeUsage.gp3                  3.47     0.32      28
  PublicIPv4:InUseAddress             33.76     0.17      15
  Requests-Tier2                  146503.00     0.06       5
  ---------------------------------------------------------
  TOTAL                                        16.25    1430

   11.0 h on demand  $ 10.59 (INR   932)   $0.966/hr
   16.7 h on spot    $  3.69 (INR   325)   $0.221/hr
  those on-demand hours would have been $2.42 (INR 213) on spot - 77% less

  egress (streaming) 22.8 GB of 100 GB free - 77 GB left
    ~8.6 more hours of streaming at 20 Mbps before it costs anything
    after that: $0.1093/GB, about $0.98 (INR 86) per streaming hour
FX
cat > "$T/games.txt" <<'FX'
  GAME                         STATE               SIZE  
  Diablo® IV                   installed       158.7 GB  

  disk   160 GB used, 56 GB free
FX
report() { CG_COLOR=always COLUMNS=100 bash -c 'source lib/common.sh; cg_report "$@"' _ "$@"; }
for f in status cost games; do
  check "plain: $f passes through untouched" "$(bash -c 'source lib/common.sh; cg_report' < "$T/$f.txt")" "$(cat "$T/$f.txt")"
done
out=$(report < "$T/status.txt" | strip)
contains "ACCOUNT is a box"               "$out" "╭─ 👤 ACCOUNT"
contains "COST GUARDS is a box"           "$out" "╭─ 🔒 COST GUARDS"
contains "a 'x:' heading loses its colon" "$out" "╭─ 💾 disk"
contains "a note in brackets stays"       "$out" "╭─ 📶 TRAFFIC (this boot only"
contains "instance: running is one line"  "$out" "⚡ instance running"
# "[ok]" is 4 wide and so is " ✓  "; the 3 spaces that followed it stay put.
contains "[ok] becomes a same-width tick" "$out" " ✓     tailscale up"
lacks    "  and no [ok] is left"          "$out" "[ok]"
lacks    "  nor a bare OK where it was"   "$out" "│    OK "
raw=$(report < "$T/status.txt")
contains "'running' is green"             "$raw" $'\e[38;5;78mrunning'
contains "'disarmed' is yellow"           "$raw" $'\e[38;5;220mdisarmed'
contains "'<- what AWS bills' is yellow"  "$raw" $'\e[38;5;220m<- what AWS bills'
# 'armed' must not match inside 'disarmed'.
lacks    "'armed' is not matched inside 'disarmed'" "$raw" $'dis\e[38;5;78marmed'
# ...but that case passes with no boundary at all: "disarmed" is a rule checked
# earlier and claims those characters first. A word inside one that NO rule
# claims is what the boundary alone protects.
raw=$(printf '  steam     uninstalled\n  path      overrunning\n' | report "🎮" "Games")
lacks    "'installed' not coloured inside 'uninstalled'" "$raw" $'un\e[38;5;78minstalled'
lacks    "'running' not coloured inside 'overrunning'"   "$raw" $'over\e[38;5;78mrunning'
out=$(report < "$T/cost.txt" | strip)
contains "billed so far is a box"         "$out" "╭─ 💰 billed so far"
contains "credits is one line"            "$out" "💳 credits remaining \$122.29"
out=$(report "🎮" "Games" < "$T/games.txt" | strip)
contains "games gets the caller's title"  "$out" "╭─ 🎮 Games"
# No input, no box: a command that dies before printing must leave its error on
# its own, not framed by an empty titled box.
check    "a title with no input prints nothing"   "$(printf '' | report "🎮" "Games" | strip)" ""
check    "  nor with only blank lines"            "$(printf '\n\n' | report "🎮" "Games" | strip)" ""
for f in status cost games; do
  args=(); [[ $f == games ]] && args=("🎮" "Games")
  verdict=$(report "${args[@]}" < "$T/$f.txt" | strip | python3 -c '
import re, sys
orig = [l.rstrip("\n") for l in open(sys.argv[1])]
PAD = " " * 9
want = []
for l in orig:
    if not l.strip(): continue
    if l[0] != " " and (l.rstrip().endswith(":") or re.match(r"^[A-Z]{3,}\b", l) or re.fullmatch(r"[a-z]+( [a-z]+){0,2}", l.strip())): continue
    if re.match(r"^([a-z][a-z ]{1,24}):\s+\S", l): continue
    want.append(re.sub(r"\[ok\]", " ✓  ", re.sub(r"\[--\]", " ✗  ", l)))
got = [l[len(PAD) + 2:] for l in sys.stdin.read().split("\n") if l.startswith(PAD + "│ ")]
if got == want: print("same")
else:
    for a, b in zip(got, want):
        if a != b: print("DIFF got=%r want=%r" % (a, b)); break
    else: print("DIFF count got=%d want=%d" % (len(got), len(want)))' "$T/$f.txt")
  check "$f: every row survives, character for character" "$verdict" "same"
done

echo "9. rows that state their meaning, and gaps that keep the box"
matches "log_as plain is exactly log"        "$(sh_ 'log_as ok "idle alarm        ALARM False"')" "^${ISO}      idle alarm        ALARM False$"
check   "cg_gap plain is an empty line"      "$(sh_ 'cg_gap' | od -c | head -1)" "$(echo | od -c | head -1)"
# The words say "enabled"; the caller says it is information. The caller wins.
out=$(styled 'log_as info "idle alarm        ALARM False  <- state, actions-enabled"' | strip)
contains "log_as: the stated kind wins over the words" "$out" "· idle alarm"
lacks    "  no tick from 'enabled'"          "$out" "✓"
out=$(styled 'say "guards"; log "a"; cg_gap; log "b"' | strip)
# Counted, not addressed by line number: the header starts with a blank line.
check   "a gap inside a step is the gutter"  "$(grep -c '^         │$' <<<"$out")" "1"
contains "'preflight passed' is a finishing line" "$(styled 'say "preflight passed - nothing was created"' | strip)" "🎉 preflight passed"
raw=$(printf '\n  node    gamevps (100.64.0.1)\n  path    unknown\n  latency no reply\n\n' | report "📡" "connection to gamevps")
contains "ping: 'no reply' is red"           "$raw" $'\e[38;5;203mno reply'
contains "ping: the box has its title"       "$(printf '%s' "$raw" | strip)" "╭─ 📡 connection to gamevps"
check    "ping: no empty gutter line before the first row" "$(printf '%s' "$raw" | strip | sed -n 2p)" "         │   node    gamevps (100.64.0.1)"
raw=$(printf '  path    direct\n' | report "📡" "x")
contains "ping: 'direct' is green"           "$raw" $'\e[38;5;78mdirect'

echo; echo "passed $pass, failed $fail"; [[ $fail -eq 0 ]]
