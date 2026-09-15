#!/usr/bin/env bash
# Shared helpers. Sourced by lib/setup and lib/game - not run directly.

# ISO 8601 with offset, so a saved log is unambiguous about when things ran and
# how long each step took. Local time rather than UTC: these are read by the
# person who ran the command, usually while waiting.
ts() { date -Iseconds; }

# --- presentation ------------------------------------------------------------
# Colour, emoji, boxed steps and live lines - but ONLY on a terminal. Anything
# else (the test suites, a pipe, `cg init > build.log`) gets byte-for-byte the
# plain format each helper prints in its first branch. That rule is what keeps
# a saved log greppable, and it turns every existing suite into a regression
# test for this block: they all capture output, so they all see plain text.
#
#   CG_COLOR=auto|always|never   (default auto: a terminal, and NO_COLOR unset)
#   NO_COLOR=1                   https://no-color.org
_cg_styled() { # _cg_styled [fd]
  case ${CG_COLOR:-auto} in always) return 0 ;; never) return 1 ;; esac
  [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb && -t ${1:-1} ]]
}
_CG_R=$'\e[0m' _CG_B=$'\e[1m' _CG_D=$'\e[2m'
_CG_CYAN=$'\e[38;5;45m' _CG_BLUE=$'\e[38;5;75m' _CG_GREEN=$'\e[38;5;78m'
_CG_YEL=$'\e[38;5;220m' _CG_RED=$'\e[38;5;203m' _CG_MAG=$'\e[38;5;177m'
_CG_GREY=$'\e[38;5;245m' _CG_ORANGE=$'\e[38;5;214m' _CG_PINK=$'\e[38;5;211m'
_CG_SEC=0 _CG_SEC_T0=0 _CG_SEC_COL=""
_CG_PAD="         "   # detail lines start with "HH:MM:SS "; headers line up with them

_cg_dur() { local s=${1:-0}; (( s < 60 )) && { printf '%ds' "$s"; return; }; printf '%dm %02ds' $((s/60)) $((s%60)); }
_cg_cols() { local c=${COLUMNS:-}; [[ $c =~ ^[0-9]+$ ]] || c=$(tput cols 2>/dev/null); [[ $c =~ ^[0-9]+$ ]] || c=80; (( c > 100 )) && c=100; printf '%s' "$c"; }

# The emoji and colour for a step, chosen from its title, so the ~65 existing
# `say` calls need no changes. Order matters: the first match wins.
_cg_icon() {
  local t=${1,,}
  case $t in
    *deleted*|*complete*|*passed*|"everything "*) printf '🎉 %s' "$_CG_GREEN" ;;
    *terminat*|*destroy*|*delet*|*deregist*|*remov*) printf '🔥 %s' "$_CG_ORANGE" ;;
    *mirror*)                                     printf '💾 %s' "$_CG_CYAN" ;;
    *restor*|*library*)                           printf '📦 %s' "$_CG_CYAN" ;;
    *steam*|*game*)                               printf '🎮 %s' "$_CG_GREEN" ;;
    *tailnet*|*tailscale*)                        printf '🌐 %s' "$_CG_BLUE" ;;
    *pair*|*moonlight*|*sunshine*)                printf '🔗 %s' "$_CG_PINK" ;;
    *budget*|*cost*|*billing*)                    printf '💰 %s' "$_CG_YEL" ;;
    *watchdog*|*backstop*|*alarm*|*guard*)        printf '🔒 %s' "$_CG_BLUE" ;;
    *provision*|*launch*|*starting*)              printf '🚀 %s' "$_CG_MAG" ;;
    *build*|*install*)                            printf '🔧 %s' "$_CG_BLUE" ;;
    *preflight*|*confirm*|*check*)                printf '🧭 %s' "$_CG_BLUE" ;;
    *)                                            printf '▶ %s' "$_CG_CYAN" ;;
  esac
}

# What a detail line means, from its words. Whole words only: a substring test
# reads "broken" as "ok" and "token" as "ok" too. Failure is checked first, and
# "not <participle>" before the success words, so "NOT registered" is a warning
# rather than a tick - but a bare "not" is not: "it guards the account, not the
# box" is information, and flagging it put a warning sign on a routine message.
_CG_RE_FAIL='(^|[^a-z])(error|errors|failed|failure|could not|cannot|refused|refusing|incomplete|timeout|rejected|denied|unreachable|not paired)([^a-z]|$)'
_CG_RE_SKIP='(^|[^a-z])(not archiving|nothing to|skipped \(|no games installed)([^a-z]|$)'
_CG_RE_WARN='(^|[^a-z])(warning|skipping|still billing|expired|stale|relayed|not answering|not up yet|not [a-z]+ed)([^a-z]|$)'
_CG_RE_WAIT='^(still|waiting|retrying|reconnecting|shutting-down|stopping|pending|host rebooting)([^a-z]|$)|(^|[^a-z])(trying once more)([^a-z]|$)'
_CG_RE_KEPT='^(keeping|kept|reusing|already)([^a-z]|$)|(^|[^a-z])(kept)([^a-z]|$)'
_CG_RE_OK='(^|[^a-z])(ok|done|complete|completed|archived|pushed|restored|joined|paired|terminated|stopped|running|created|deleted|pruned|armed|disarmed|installed|ready|saved|updated|forgot|available|recorded|registered|succeeded|found|mounted|shipped|present|written|configured|disabled|enabled)([^a-z]|$)'
_cg_kind() {
  local t=${1,,}
  [[ ${1:0:2} == "  " ]] && { printf cont; return; }
  if   [[ $t =~ $_CG_RE_FAIL ]]; then printf fail
  elif [[ $t =~ $_CG_RE_SKIP ]]; then printf skip
  elif [[ $t =~ $_CG_RE_WAIT ]]; then printf wait
  elif [[ $t =~ $_CG_RE_KEPT ]]; then printf kept
  elif [[ $t =~ $_CG_RE_WARN ]]; then printf warn
  elif [[ $t =~ $_CG_RE_OK   ]]; then printf ok
  else printf info; fi
}

# One styled detail line: "HH:MM:SS │  ✓ text". Starts by clearing the current
# line, so it can follow a live line without leaving fragments of it behind.
_cg_line() { # _cg_line <ok|fail|warn|wait|kept|skip|step|cont|info|""> <text>
  local kind=${1:-} text=$2 sym col body gutter=" "
  [[ -z $kind ]] && kind=$(_cg_kind "$text")
  case $kind in
    ok)   sym='✓' col=$_CG_GREEN ;;  fail) sym='✗' col=$_CG_RED ;;
    warn) sym='!' col=$_CG_YEL ;;    wait) sym='◌' col=$_CG_YEL ;;
    kept) sym='↺' col=$_CG_BLUE ;;   step) sym='▸' col=$_CG_CYAN ;;
    cont) sym=' ' col=$_CG_GREY ;;   *)    sym='·' col=$_CG_GREY ;;
  esac
  case $kind in
    fail|warn) body="${col}${text}${_CG_R}" ;;
    skip|cont) body="${_CG_GREY}${text}${_CG_R}" ;;
    step)      body="${_CG_CYAN}${text}${_CG_R}" ;;
    *)         body=$text ;;
  esac
  (( _CG_SEC )) && gutter="${_CG_SEC_COL}│${_CG_R}"
  printf '\r\e[K%s%s%s %s  %s%s%s %s\n' "$_CG_D" "$(date +%H:%M:%S)" "$_CG_R" "$gutter" "$col" "$sym" "$_CG_R" "$body"
}

# A line rewritten in place while something is waited on - one line that counts
# up, instead of a heartbeat line every few seconds.
_cg_live() {
  local gutter=" "; (( _CG_SEC )) && gutter="${_CG_SEC_COL}│${_CG_R}"
  printf '\r\e[K%s%s%s %s  %s◌%s %s' "$_CG_D" "$(date +%H:%M:%S)" "$_CG_R" "$gutter" "$_CG_YEL" "$_CG_R" "$1"
}
_cg_live_clear() { printf '\r\e[K'; }

# Closes the open step with its duration. Called by the next step, before any
# child process prints (it cannot see this shell's state), and on exit.
_cg_section_end() { # _cg_section_end [exit-code]
  (( _CG_SEC )) || return 0
  _CG_SEC=0
  local d; d=$(_cg_dur $(( SECONDS - _CG_SEC_T0 )))
  if (( ${1:-0} == 0 )); then
    printf '%s%s╰─%s %s✓ done in %s%s\n' "$_CG_PAD" "$_CG_SEC_COL" "$_CG_R" "$_CG_GREEN" "$d" "$_CG_R"
  else
    printf '%s%s╰─%s %s✗ stopped after %s%s\n' "$_CG_PAD" "$_CG_SEC_COL" "$_CG_R" "$_CG_RED" "$d" "$_CG_R"
  fi
}
_cg_on_exit() {
  local rc=$? c
  (( ${_CG_INT:-0} )) && rc=130
  for c in "${_CG_ON_EXIT[@]}"; do eval "$c" || true; done
  _cg_section_end "$rc"
  return "$rc"
}
# Cleanup for exit. A script's own `trap ... EXIT` replaced the one below, and
# every step after it then ended with no closing line - even on Ctrl+C.
_CG_ON_EXIT=()
cg_on_exit() { _CG_ON_EXIT+=("$1"); trap _cg_on_exit EXIT; }
# Ctrl+C. Without a trap, the EXIT trap saw the status of the last command - often
# 0 - so a cancelled run closed its step with "done". Trapping it also stops a
# script whose child swallowed the signal: sudo and pacman catch it and exit 1,
# and the script carried on to the next install; bash runs this once they return.
_cg_on_int() { _CG_INT=1; printf '\n' >&2; exit 130; }
trap _cg_on_int INT
_cg_styled && trap _cg_on_exit EXIT

# Progress and action output. Reports (status, cost) deliberately do not go
# through these - a timestamp on every row of a table is noise, not context.
say() {
  if ! _cg_styled; then printf '\n%s  ==> %s\n' "$(ts)" "$1"; return; fi
  _cg_section_end 0
  local ic col icw=2 t fill
  read -r ic col <<<"$(_cg_icon "$1")"
  # A finishing line ("box deleted", "everything deleted") is an outcome, not a
  # step: nothing follows it, so a box around it only frames an empty body.
  if [[ $ic == '🎉' ]]; then
    printf '\n%s%s%s🎉 %s%s\n' "$_CG_PAD" "$_CG_B" "$_CG_GREEN" "$1" "$_CG_R"
    return
  fi
  [[ $ic == '▶' ]] && icw=1
  t=$(date +%H:%M:%S)
  fill=$(( $(_cg_cols) - ${#_CG_PAD} - 3 - icw - 1 - ${#1} - 2 - ${#t} ))
  (( fill < 3 )) && fill=3
  printf '\n%s%s╭─ %s %s%s%s %s%s %s%s\n' "$_CG_PAD" "$col" "$ic" "$_CG_B" "$1" "$_CG_R" \
    "$_CG_GREY" "$(printf '%*s' "$fill" '' | tr ' ' '.')" "$t" "$_CG_R"
  _CG_SEC=1 _CG_SEC_T0=$SECONDS _CG_SEC_COL=$col
}
log() {
  if ! _cg_styled; then printf '%s      %s\n' "$(ts)" "$*"; return; fi
  _cg_line "" "$*"
}
die() {
  if ! _cg_styled 2; then printf '%s  error: %s\n' "$(ts)" "$1" >&2; exit 1; fi
  local first=${1%%$'\n'*} rest line
  _cg_line fail "${_CG_B}error:${_CG_R}${_CG_RED} ${first}" >&2
  if [[ $1 == *$'\n'* ]]; then
    rest=${1#*$'\n'}
    while IFS= read -r line; do _cg_line cont "  ${line#"${line%%[![:space:]]*}"}" >&2; done <<<"$rest"
  fi
  exit 1
}

# A log line whose meaning the caller states, instead of it being read from the
# words. For report-like rows where the words mislead: a row saying something is
# NOT enabled still contains "enabled", and read as a success. Plain: log.
log_as() { # log_as <ok|fail|warn|wait|kept|skip|info|cont> <text>
  if ! _cg_styled; then log "$2"; return; fi
  _cg_line "$1" "$2"
}

# A blank line. Plain: an empty line, as `echo` printed. Styled: the gutter
# alone, so a gap inside a step does not break the box it sits in.
cg_gap() {
  if ! _cg_styled; then echo; return; fi
  if (( _CG_SEC )); then printf '%s%s│%s\n' "$_CG_PAD" "$_CG_SEC_COL" "$_CG_R"; else echo; fi
}

# echo that is plain off a terminal and a styled detail line on one.
cg_echo() {
  if ! _cg_styled; then echo "$*"; return; fi
  local t="$*"; _cg_line "" "${t#"${t%%[![:space:]]*}"}"
}

# Box-side output relayed to the laptop. Plain: indented exactly as the
# `sed 's/^/      /'` it replaces. Styled: the "<timestamp> cg-library:" prefix
# is dropped (this line already has a time) and each line gets its symbol.
cg_relay() { # cg_relay [indent]
  local indent=${1-      } line timers=0
  if ! _cg_styled; then sed "s/^/$indent/"; return; fi
  while IFS= read -r line; do
    [[ $line =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\ ]+\ [a-z-]+:\ (.*)$ ]] && line=${BASH_REMATCH[1]}
    [[ -z ${line//[[:space:]]/} ]] && continue
    # `systemctl list-timers`, from install-watchdog.sh. A six-column table
    # relayed line by line put a "·" on its header and on "Pass --all to see
    # loaded but inactive timers, too." Each timer becomes one line instead.
    if [[ $line =~ ^[[:space:]]*NEXT[[:space:]]+LEFT[[:space:]]+LAST ]]; then timers=1; continue; fi
    # The table ends at the first line that is neither a row nor its footer - NOT
    # at a blank line: systemctl puts one between the rows and "2 timers listed.",
    # and ending there let the footer through as two ordinary lines.
    if (( timers )); then
      if [[ $line =~ ^[0-9]+\ timers?\ listed || $line =~ ^Pass\ --all ]]; then continue; fi
      if [[ $line =~ ([A-Za-z0-9@._-]+\.timer)[[:space:]]+[A-Za-z0-9@._-]+\.service[[:space:]]*$ ]]; then
        local unit=${BASH_REMATCH[1]} left=""
        # NEXT is "Day YYYY-MM-DD HH:MM:SS TZ"; LEFT is whatever follows it up to
        # the next timestamp or "-" ("30s", "56min", "1h 2min").
        [[ $line =~ ^[A-Za-z]{3}\ [0-9-]{10}\ [0-9:]{8}\ [A-Z]+[[:space:]]+(.+[^[:space:]])[[:space:]]+([A-Za-z]{3}\ [0-9-]{10}|-) ]] && left=${BASH_REMATCH[1]}
        if [[ -n $left ]]; then _cg_line ok "$unit · next run in $left"; else _cg_line ok "$unit scheduled"; fi
        continue
      fi
      timers=0
    fi
    if   [[ $line =~ ^[[:space:]]*s5cmd: ]];    then _cg_line cont "  ${line#"${line%%[![:space:]]*}"}"
    elif [[ $line =~ ^[[:space:]]*==\>\ (.*)$ ]]; then _cg_line step "${BASH_REMATCH[1]}"
    elif [[ $line =~ ^[[:space:]]{4,}(.*)$ ]];  then _cg_line cont "  ${BASH_REMATCH[1]}"
    else
      line=${line#"${line%%[![:space:]]*}"}
      # Column padding meant for a fixed-width block ("armed.     follow with")
      # reads as a hole once the line has a symbol in front of it. One space, not
      # a separator: the line beneath it had no padding to begin with, and a
      # " · " on one of two identical sentences made them look different.
      while [[ $line =~ ^(.*[^[:space:]])[[:space:]]{3,}([^[:space:]].*)$ ]]; do
        line="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
      done
      _cg_line "" "$line"
    fi
  done
}

# A report (cg status, cg cost, cg games) redrawn for a terminal. Plain: cat.
#
# The reports are built from dozens of printf/awk/python fragments, and each
# already prints exactly what it should. So rather than restyling every one,
# this reads the finished text and adds only colour and a gutter:
#   a heading at column 0 ("ACCOUNT", "disk:", "billed so far (...):") opens a
#   box with an emoji; "key: value" at column 0 is one highlighted line;
#   rows keep every character in its column - colour codes take no width and the
#   gutter is the same on every line - so an aligned table stays aligned.
# [ok]/[--] become a same-width tick/cross; that is the only substitution.
# The optional arguments title a box for a report with no heading of its own.
cg_report() { # cg_report [emoji title]
  if ! _cg_styled; then cat; return; fi
  # The program is an argument, not stdin: stdin is the report. (Piping the
  # program in is what broke the restore prompt once - input() read the code.)
  # No "_" before "$@": that placeholder is a bash -c habit. python -c has no
  # $0 slot to fill, so it became argv[1] and shifted the title into the emoji.
  COLUMNS="$(_cg_cols)" python3 -u -c "$(cat <<'PY'
import re, sys
R, B, D = "\033[0m", "\033[1m", "\033[2m"
K = {"cyan": "\033[38;5;45m", "blue": "\033[38;5;75m", "green": "\033[38;5;78m",
     "yel": "\033[38;5;220m", "red": "\033[38;5;203m", "mag": "\033[38;5;177m",
     "grey": "\033[38;5;245m", "orange": "\033[38;5;214m", "pink": "\033[38;5;211m"}
PAD = " " * 9
ICONS = [
    (r"^account", "👤", "blue"), (r"^quota", "📊", "yel"), (r"^resources", "🧱", "cyan"),
    (r"^cost guard", "🔒", "blue"), (r"^local", "💻", "pink"), (r"^instance", "⚡", "green"),
    (r"^disk", "💾", "cyan"), (r"^game", "🎮", "green"), (r"^traffic", "📶", "mag"),
    (r"^not yet billed", "🧾", "yel"), (r"^billed", "💰", "yel"), (r"^credits", "💳", "green"),
]
def icon(title):
    t = title.lower()
    for rx, e, c in ICONS:
        if re.search(rx, t): return e, K[c]
    return "▶", K["cyan"]

# Words that carry a state, by what they mean. Whole words only, and the longer
# phrases first so "files missing" is red before "missing" is considered alone.
WORDS = [
    (r"RUNNING", B + K["mag"]),
    (r"files missing|files corrupt|INCOMPLETE|STRANDED|ORPHANED|MISSING|missing|FAILED|NO CREDENTIALS|NOT registered|EMPTY|no reply", K["red"]),
    (r"update needed|not calculated yet|INSUFFICIENT_DATA|disarmed|downloading|paused|stopping|shutting-down|pending|stopped|LEGACY|unknown|never|DERP relay", K["yel"]),
    (r"in S3 only|none", K["grey"]),
    (r"installed|running|armed|ACTIVE|present|online|configured|PAID|OK|yes|direct", K["green"]),
]
WORD_RX = [(re.compile(r"(?<![A-Za-z_-])(" + w + r")(?![A-Za-z_-])"), c) for w, c in WORDS]

def paint(line):
    """Colour spans of an unchanged line. Spans never overlap; earlier rules win."""
    if re.match(r"^\s*-{5,}\s*$", line): return D + line + R
    stripped = line.strip()
    toks = stripped.split()
    if re.match(r"^\s+Mounted on\b", line) or (
            len(toks) >= 2 and all(re.fullmatch(r"[A-Z#%?][A-Z%#?]*", t) for t in toks)):
        return B + K["grey"] + line + R
    if re.match(r"^\s*\(.*\)\s*$", line): return D + line + R
    spans = []
    def add(a, b, code):
        if a < b and not any(a < y and x < b for x, y, _ in spans): spans.append((a, b, code))
    m = re.search(r"<-.*$", line)
    if m: add(m.start(), m.end(), K["yel"])
    bold_row = re.match(r"^\s+(TOTAL|total|estimate)\b", line)
    kv = re.match(r"^(\s{2,})([a-z][A-Za-z0-9 ./()-]{1,20}?)(\s{2,})\S", line)
    if kv and not bold_row:
        add(kv.start(2), kv.end(2), K["grey"])
    for rx, code in WORD_RX:
        for w in rx.finditer(line): add(w.start(), w.end(), code)
    out, i = [], 0
    for a, b, code in sorted(spans):
        out += [line[i:a], code, line[a:b], R]; i = b
    out.append(line[i:])
    text = "".join(out)
    return (B + text + R) if bold_row else text

def is_heading(line):
    if not line or line[0].isspace(): return False
    if line.rstrip().endswith(":"): return True
    if re.match(r"^[A-Z]{3,}\b", line): return True
    return bool(re.fullmatch(r"[a-z]+( [a-z]+){0,2}", line.strip()))

col, open_, blanks, first, rows = K["cyan"], False, 0, True, 0
def close():
    global open_
    if open_: print("%s%s╰─%s" % (PAD, col, R), flush=True)
    open_ = False
def heading(title, emoji=None):
    global col, open_, first
    close()
    e, col = icon(title)
    if emoji: e = emoji
    m = re.match(r"^(.*?)\s*(\(.*\))?\s*:?\s*$", title)
    name, note = (m.group(1), m.group(2)) if m else (title, None)
    print("%s%s%s╭─ %s %s%s%s%s" % ("" if first else "\n", PAD, col, e, B, name, R,
          (" " + K["grey"] + note + R) if note else ""), flush=True)
    open_, first = True, False
    global rows
    rows = 0

# A report with no heading of its own (cg games) is titled by the caller - but
# the box opens with its first line, not before. Opened up front, a command that
# failed before printing anything had its error (on stderr, which does not come
# through here) land inside an empty box: "Games" around "could not read the box".
pending_title = (sys.argv[2], sys.argv[1] or None) if len(sys.argv) >= 3 else None

MARK = re.compile(r"^(\s*)\[(ok|--)\](.*)$")
for raw in iter(sys.stdin.readline, ""):
    line = raw.rstrip("\n")
    if not line.strip():
        blanks += 1; continue
    if pending_title and not is_heading(line):
        heading(*pending_title)
    pending_title = None
    if is_heading(line):
        blanks = 0; heading(line); continue
    ol = re.match(r"^([a-z][a-z ]{1,24}):\s+(\S.*)$", line)
    if ol:
        close(); blanks = 0
        e, c = icon(ol.group(1))
        print("\n%s%s %s%s%s %s" % (PAD, e, B, ol.group(1), R, paint(ol.group(2))), flush=True)
        first = False
        continue
    # A gap is kept only BETWEEN rows. Blank lines ahead of the first row - cg
    # ping's text starts with one - drew an empty gutter line under the title.
    if blanks and open_ and rows:
        for _ in range(blanks): print("%s%s│%s" % (PAD, col, R), flush=True)
    blanks = 0
    rows += 1
    # [ok]/[--] first, and the rest of the line painted on its own. Swapping in a
    # placeholder and painting the whole line let the word rules colour INSIDE
    # the placeholder, so it never turned back into a tick.
    mk = MARK.match(line)
    if mk:
        sym = (K["green"] + " ✓  ") if mk.group(2) == "ok" else (K["red"] + " ✗  ")
        painted = mk.group(1) + sym + R + paint(mk.group(3))
    else:
        painted = paint(line)
    gutter = ("%s│%s " % (col, R)) if open_ else "  "
    print("%s%s%s" % (PAD, gutter, painted), flush=True)
close()
PY
)" "$@"
}

# A block of explanatory text (a plan, a warning, the end-of-setup notes) drawn
# as its own box. Plain: passed through untouched.
#
# It does NOT close the open step, and cannot: it always sits on the right of a
# pipe, so it runs in a subshell, and a subshell cannot clear the parent's "a
# step is open" flag. The first version tried - it printed the closing line,
# the parent never learned the step was closed, and the next step closed it a
# second time while every line in between kept a gutter it should not have.
# A caller showing a block between steps closes the step itself first:
#     _cg_section_end 0; { ...; } | cg_block "🧾" "Plan"
cg_block() { # cg_block <emoji> <title>   - text on stdin
  if ! _cg_styled; then cat; return; fi
  local line col=$_CG_MAG hl
  printf '\n%s%s╭─ %s %s%s%s\n' "$_CG_PAD" "$col" "$1" "$_CG_B" "$2" "$_CG_R"
  while IFS= read -r line; do
    hl=$line
    if   [[ $line =~ ^[[:space:]]*$ ]]; then hl=""
    elif [[ ${line,,} =~ (kept|keep|nothing\ to\ do|\[done) ]]; then hl="${_CG_BLUE}${line}${_CG_R}"
    elif [[ $line =~ (WARNING|STILL|NEVER|cannot|ACTION\ NEEDED|no\ undo|No\ undo|billing) ]]; then hl="${_CG_YEL}${line}${_CG_R}"
    elif [[ $line =~ ^[[:space:]]{5,}(cg|\./cg|moonlight|https?://|ssh|aws|GAME_) ]]; then hl="${_CG_CYAN}${line}${_CG_R}"
    elif [[ $line =~ ^[[:space:]]*(STEP|-{10,}) ]]; then hl="${_CG_B}${line}${_CG_R}"
    fi
    printf '%s%s│%s  %s\n' "$_CG_PAD" "$col" "$_CG_R" "$hl"
  done
  printf '%s%s╰─%s\n' "$_CG_PAD" "$col" "$_CG_R"
}

# `aws ec2 wait` blocks silently, sometimes for minutes, which is
# indistinguishable from a hang. These poll instead and show the state as it
# changes, so a slow stop looks slow rather than broken.

# wait_instance_state <region> <instance-id> <desired-state> [timeout-seconds]
wait_instance_state() {
  local region=$1 id=$2 want=$3 timeout=${4:-600}
  local last="" now waited=0 beat=0
  if _cg_styled; then
    while (( waited < timeout )); do
      if (( waited % 3 == 0 )); then
        now=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
          --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")
        [[ $now == "$want" ]] && { _cg_line ok "$now after $(_cg_dur "$waited")"; return 0; }
      fi
      _cg_live "$now ${_CG_GREY}$(_cg_dur "$waited")${_CG_R}"
      sleep 1; waited=$(( waited + 1 ))
    done
    _cg_line fail "TIMEOUT after $(_cg_dur "$timeout"), last state: $now"
    return 1
  fi
  while (( waited < timeout )); do
    now=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")
    # A line per state change, plus a heartbeat, rather than one per poll -
    # timestamped lines are the point, but not 200 of them.
    if [[ $now != "$last" ]]; then
      log "$now"; last=$now; beat=$waited
    elif (( waited - beat >= 10 )); then
      log "still $now (${waited}s)"; beat=$waited
    fi
    [[ $now == "$want" ]] && { log "$now after ${waited}s"; return 0; }
    sleep 3; waited=$(( waited + 3 ))
  done
  log "TIMEOUT after ${timeout}s, last state: $last"
  return 1
}

# stream_build <ssh-target> <ssh-key> [timeout-seconds]
# Follows the bootstrap log on the box until it signals ready. The build takes
# 10-20 minutes and used to be entirely invisible from here, which made a hang
# indistinguishable from slow progress - the whole reason Tailscale now installs
# first is so this is possible at all.
#
# Reconnects on failure rather than giving up: the box reboots partway through
# to load the NVIDIA driver, so ssh dropping is expected, not an error.
stream_build() {
  local target=$1 key=$2 timeout=${3:-2400}
  if _cg_styled; then _stream_build_styled "$target" "$key" "$timeout"; return; fi
  local seen=0 waited=0 new count rebooted=0
  local ssh_opts=(-i "$key" -o StrictHostKeyChecking=accept-new
                  -o ConnectTimeout=8 -o BatchMode=yes)

  local err
  err=$(mktemp)
  while (( waited < timeout )); do
    if new=$(ssh "${ssh_opts[@]}" "$target" \
             "tail -n +$((seen+1)) /var/log/cloud-gaming-bootstrap.log 2>/dev/null" 2>"$err"); then
      if [[ -n $new ]]; then
        count=$(wc -l <<<"$new")
        seen=$(( seen + count ))
        # Only the progress markers and anything that looks like a failure -
        # `set -x` traces thousands of lines that are useless to watch.
        # Anchored and punctuated deliberately: a bare /error/ matches package
        # names like libgpg-error0 and floods the output with routine apt lines.
        while IFS= read -r line; do
          case $line in
            ">>> FAILED: "*) log "FAILED: ${line#>>> FAILED: }" ;;
            ">>> ok: "*)     log "  ok  ${line#>>> ok: }" ;;
            ">>> "*)         log "${line#>>> }" ;;
            *)               log "! $line" ;;
          esac
        done < <(grep -E '^>>> |^E: |^ERROR|[Ee]rror:|[Ff]ailed to |command not found|curl: \([0-9]+\)|No such file' <<<"$new" \
                 | grep -vE 'Setting up|Unpacking|Preparing to unpack|Selecting previously|^Get:|^info:|^ls: |usbmux|/nonexistent|NetworkManager' || true)
      fi
      if ssh "${ssh_opts[@]}" "$target" 'test -f /var/lib/cloud-gaming-ready' 2>/dev/null; then
        log "build complete after $(( waited / 60 ))m"
        rm -f "$err"
        return 0
      fi
    elif grep -q 'HOST IDENTIFICATION HAS CHANGED\|Host key verification failed' "$err" 2>/dev/null; then
      # Distinguish "cannot connect" from "refused to connect". Reporting a
      # reboot here was actively misleading: the box was building fine and only
      # our view of it was broken, which is the hardest kind of failure to see.
      log "ssh refused: the host key for this name changed"
      log "  a rebuilt box reclaims the hostname, so the old key is stale:"
      log "    ssh-keygen -R ${target#*@}"
      rm -f "$err"
      return 1
    elif (( rebooted == 0 && waited > 300 )); then
      # Only call it a reboot once the box has been reachable for a while -
      # ssh refusing in the first minutes is just sshd not up yet.
      log "host rebooting - reconnecting"
      rebooted=1
      # Do NOT reset `seen`: the log is a file that survives the reboot, so
      # starting over replays every line that was already printed.
    fi
    sleep 10; waited=$(( waited + 10 ))
  done
  log "TIMEOUT after $(( timeout / 60 ))m. Check on the box:"
  log "  ssh -i $key $target"
  log "  sudo tail -50 /var/log/cloud-gaming-bootstrap.log"
  return 1
}

# What the build's live line says. Pure - no I/O - so it can be tested directly.
#
# "116G of games on disk" was accurate and told you nothing you could act on:
# not of how much, not how fast, not how long. With the chosen games' archived
# size known (CG_RESTORE_BYTES, from the S3 index) it says all three.
#
# "finishing up" gets its own wording because it is where the time goes: that
# build step reboots the box and the ready marker is ordered after the library
# restore, so the build is really waiting for the games - the label hid that.
_cg_gb() { awk -v b="${1:-0}" 'BEGIN{printf "%.0f", b/1073741824}'; }
_cg_build_status() { # <step> <elapsed-s> <have-bytes> <total-bytes> <rate-bytes/s> <label>
  local step=$1 el=${2:-0} have=${3:-0} total=${4:-0} rate=${5:-0} label=${6:-games}
  local g=$_CG_GREY r=$_CG_R pct eta="" prog left
  if (( total > 0 )); then
    pct=$(( have * 100 / total )); (( pct > 100 )) && pct=100
    if (( rate > 0 && have < total )); then
      left=$(( (total - have) / rate ))
      if (( left < 60 )); then eta=" · <1 min left"; else eta=" · ~$(( (left + 59) / 60 )) min left"; fi
    fi
    prog="$(_cg_gb "$have") of $(_cg_gb "$total") GB (${pct}%)"
    if [[ $step == "finishing up" ]]; then
      # 98% is the restore's own threshold for "complete" (cg-library INCOMPLETE).
      if (( pct >= 98 )); then
        printf '%s' "games restored - waiting for the desktop to come up ${g}· $(_cg_dur "$el")${r}"
      else
        printf '%s' "restoring ${label} ${g}· ${prog}${eta} · $(_cg_dur "$el")${r}"
      fi
    else
      printf '%s' "${step} ${g}· $(_cg_dur "$el") · restoring ${label}: ${prog}${eta}${r}"
    fi
  elif (( have > 0 )); then
    printf '%s' "${step} ${g}· $(_cg_dur "$el") · $(_cg_gb "$have") GB of games restored so far${r}"
  else
    printf '%s' "${step} ${g}· $(_cg_dur "$el")${r}"
  fi
}

# The terminal version of stream_build: the same markers and failure lines, one
# live line between them - the step in progress, how long, and how the game
# restore that runs alongside the build is getting on.
_stream_build_styled() {
  local target=$1 key=$2 timeout=$3
  local seen=0 waited=0 new count rebooted=0 step="starting" out line err
  local have=0 prev_have=0 prev_t=0 rate=0 inst
  local ssh_opts=(-i "$key" -o StrictHostKeyChecking=accept-new
                  -o ConnectTimeout=8 -o BatchMode=yes)
  err=$(mktemp)
  while (( waited < timeout )); do
    if (( waited % 10 == 0 )); then
      if new=$(ssh "${ssh_opts[@]}" "$target" \
               "tail -n +$((seen+1)) /var/log/cloud-gaming-bootstrap.log 2>/dev/null" 2>"$err"); then
        if [[ -n $new ]]; then
          count=$(wc -l <<<"$new")
          seen=$(( seen + count ))
          while IFS= read -r line; do
            case $line in
              ">>> FAILED: "*) _cg_line fail "${line#>>> FAILED: }" ;;
              ">>> ok: "*)     _cg_line ok "${line#>>> ok: }" ;;
              ">>> "*)         step=${line#>>> }
                               if [[ $step == "finishing up" ]]; then
                                 if (( ${CG_RESTORE_BYTES:-0} > 0 )); then
                                   _cg_line step "finishing up ${_CG_GREY}(reboots, then waits for the game restore to finish)${_CG_R}"
                                 else
                                   _cg_line step "finishing up ${_CG_GREY}(reboots into the desktop)${_CG_R}"
                                 fi
                               else
                                 _cg_line step "$step"
                               fi ;;
              *)               _cg_line warn "$line" ;;
            esac
          done < <(grep -E '^>>> |^E: |^ERROR|[Ee]rror:|[Ff]ailed to |command not found|curl: \([0-9]+\)|No such file' <<<"$new" \
                   | grep -vE 'Setting up|Unpacking|Preparing to unpack|Selecting previously|^Get:|^info:|^ls: |usbmux|/nonexistent|NetworkManager' || true)
        fi
        # Exact bytes over the same three directories an archive's size counts,
        # so "of N GB" compares like with like.
        out=$(ssh "${ssh_opts[@]}" "$target" \
          'test -f /var/lib/cloud-gaming-ready && echo READY; du -sb --exclude=downloading --exclude=temp /scratch/steam/steamapps/common /scratch/steam/steamapps/compatdata /scratch/steam/steamapps/shadercache 2>/dev/null | awk "{t+=\$1} END{print t+0}"' 2>/dev/null) || out=""
        if [[ $out == *READY* ]]; then
          _cg_line ok "build complete after $(_cg_dur "$waited")"
          rm -f "$err"
          return 0
        fi
        have=$(tail -1 <<<"$out"); [[ $have =~ ^[0-9]+$ ]] || have=$prev_have
        # A smoothed rate: one sample is noisy - s5cmd lands files in bursts.
        if (( prev_t > 0 && waited > prev_t && have >= prev_have )); then
          inst=$(( (have - prev_have) / (waited - prev_t) ))
          if (( rate == 0 )); then rate=$inst; else rate=$(( (rate * 2 + inst) / 3 )); fi
        fi
        prev_have=$have prev_t=$waited
      elif grep -q 'HOST IDENTIFICATION HAS CHANGED\|Host key verification failed' "$err" 2>/dev/null; then
        _cg_line fail "ssh refused: the host key for this name changed"
        _cg_line cont "  a rebuilt box reclaims the hostname, so the old key is stale:"
        _cg_line cont "    ssh-keygen -R ${target#*@}"
        rm -f "$err"
        return 1
      elif (( rebooted == 0 && waited > 300 )); then
        _cg_line wait "host rebooting - reconnecting"
        rebooted=1
      fi
    fi
    _cg_live "$(_cg_build_status "$step" "$waited" "$have" "${CG_RESTORE_BYTES:-0}" "$rate" "${CG_RESTORE_LABEL:-games}")"
    sleep 1; waited=$(( waited + 1 ))
  done
  _cg_line fail "TIMEOUT after $(( timeout / 60 ))m. Check on the box:"
  _cg_line cont "  ssh -i $key $target"
  _cg_line cont "  sudo tail -50 /var/log/cloud-gaming-bootstrap.log"
  rm -f "$err"
  return 1
}

# Tailscale appends -1, -2, ... when a hostname is already registered, and a
# node's identity lives on the disk that a destroy deletes - so a rebuilt box
# can never reclaim its old name while the stale entry exists. Rather than
# demand the user prune the tailnet by hand, adopt whatever name the box
# actually joined under.

# tailnet_nodes  - one hostname per line
tailnet_nodes() { tailscale status 2>/dev/null | awk 'NF>1 && $1 ~ /^100\./ {print $2}'; }

# tailnet_node_keys - "<node key>\t<tailnet name>" per peer.
# The KEY is a node's identity; its name is not. The prune before a build deletes
# an offline node, which frees its name, and the new box then joins under
# exactly that name - so a list of names taken before the launch already
# contains the new box's name, and nothing new ever appears in it. That waited
# the full 30 minutes on a box that had joined in 47 seconds.
tailnet_node_keys() {
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for k, p in (d.get("Peer") or {}).items():
    name = (p.get("DNSName") or "").split(".")[0] or p.get("HostName") or ""
    if name: print("%s\t%s" % (p.get("PublicKey") or k, name))' 2>/dev/null || true
}

# wait_new_node <node-keys-before-file> <timeout-seconds>
# Prints the tailnet name of the node that appeared. Matching on "a node key that
# was not there before" rather than on an expected name is what makes this immune
# to the suffix problem - and to the pruned-name problem above. Only a name this
# host could take counts ($TS_HOST or $TS_HOST-N), so a phone joining the tailnet
# meanwhile is not mistaken for the box.
new_node() { # new_node <node-keys-before-file>
  tailnet_node_keys | awk -F'\t' -v f="$1" -v host="${TS_HOST:-}" '
    BEGIN { while ((getline l < f) > 0) { split(l, a, "\t"); seen[a[1]] = 1 } }
    !($1 in seen) && (host == "" || $2 == host || $2 ~ ("^" host "-[0-9]+$")) { print $2; exit }'
}
wait_new_node() {
  local before=$1 timeout=${2:-1800} waited=0 beat=0 found
  if _cg_styled 2; then
    while (( waited < timeout )); do
      if (( waited % 10 == 0 )); then
        found=$(new_node "$before" || true)
        if [[ -n $found ]]; then
          _cg_line ok "joined as '$found' after $(_cg_dur "$waited")" >&2
          printf '%s' "$found"
          return 0
        fi
      fi
      _cg_live "waiting for the box to join ${_CG_GREY}$(_cg_dur "$waited")${_CG_R}" >&2
      sleep 1; waited=$(( waited + 1 ))
    done
    _cg_line fail "TIMEOUT after $(( timeout / 60 ))m - no new node joined the tailnet" >&2
    return 1
  fi
  while (( waited < timeout )); do
    found=$(new_node "$before" || true)
    if [[ -n $found ]]; then
      log "joined as '$found' after ${waited}s" >&2
      printf '%s' "$found"
      return 0
    fi
    (( waited - beat >= 60 )) && { log "still waiting for the box to join (${waited}s)" >&2; beat=$waited; }
    sleep 10; waited=$(( waited + 10 ))
  done
  log "TIMEOUT after $(( timeout / 60 ))m - no new node joined the tailnet" >&2
  return 1
}

# wait_image_available <region> <ami-id> [timeout-seconds]
# Image creation is the slowest thing here - several minutes for a 50 GB volume.
wait_image_available() {
  local region=$1 ami=$2 timeout=${3:-1800}
  local last="" now waited=0 beat=0
  while (( waited < timeout )); do
    now=$(aws ec2 describe-images --region "$region" --image-ids "$ami" \
      --query 'Images[0].State' --output text 2>/dev/null || echo "?")
    if [[ $now != "$last" ]]; then
      log "$now"; last=$now; beat=$waited
    elif (( waited - beat >= 15 )); then
      log "still $now (${waited}s)"; beat=$waited
    fi
    [[ $now == available ]] && { log "available after ${waited}s"; return 0; }
    [[ $now == failed ]] && { log "image creation FAILED"; return 1; }
    sleep 5; waited=$(( waited + 5 ))
  done
  log "TIMEOUT after ${timeout}s, last state: $last"
  return 1
}

# wait_for_steam <ssh-target> <ssh-key> [timeout-seconds]
# The prewarm service runs after graphical.target and downloads ~500 MB, so it
# is still going long after `setup` would otherwise finish. Waiting means the
# completion message can tell the truth about whether Steam is ready.
wait_for_steam() {
  local target=$1 key=$2 timeout=${3:-1500}
  local waited=0 beat=0 size last="" phase cur
  local ssh_opts=(-i "$key" -o StrictHostKeyChecking=accept-new
                  -o ConnectTimeout=8 -o BatchMode=yes)

  if _cg_styled; then
    phase=working size=""
    while (( waited < timeout )); do
      if (( waited % 15 == 0 )); then
        if ssh "${ssh_opts[@]}" "$target" 'test -f ~/.steam-prewarmed' 2>/dev/null; then
          _cg_line ok "steam ready after $(_cg_dur "$waited")"
          return 0
        fi
        IFS='|' read -r phase size < <(ssh "${ssh_opts[@]}" "$target" \
          'printf "%s|%s\n" "$(cat ~/.steam-phase 2>/dev/null || echo working)" \
             "$(du -shcL ~/.steam ~/.local/share/Steam 2>/dev/null | tail -1 | cut -f1)"' 2>/dev/null || echo "working|")
      fi
      _cg_live "${phase:-working}${size:+ ($size)} ${_CG_GREY}· $(_cg_dur "$waited")${_CG_R}"
      sleep 1; waited=$(( waited + 1 ))
    done
    _cg_line fail "steam did not finish within $(( timeout / 60 ))m - check ~/steam-prewarm.log on the box"
    return 1
  fi

  while (( waited < timeout )); do
    if ssh "${ssh_opts[@]}" "$target" 'test -f ~/.steam-prewarmed' 2>/dev/null; then
      log "steam ready after $(( waited / 60 ))m"
      return 0
    fi
    # Report the phase, not just the size: after the download the client stops
    # growing while library adoption and the dock pin still run, which read as
    # a stall if all you print is an unchanging number.
    # '|'-separated, not space: phase names contain spaces, and `read a b` puts
    # the whole remainder in $b - which printed the phase text as if it were the
    # download size. Size follows symlinks and covers both client layouts.
    IFS='|' read -r phase size < <(ssh "${ssh_opts[@]}" "$target" \
      'printf "%s|%s\n" "$(cat ~/.steam-phase 2>/dev/null || echo working)" \
         "$(du -shcL ~/.steam ~/.local/share/Steam 2>/dev/null | tail -1 | cut -f1)"' 2>/dev/null || echo "working|")
    cur="${phase:-working} ${size:-}"
    if [[ $cur != "$last" ]]; then
      log "${phase:-working}${size:+ ($size)}"; last=$cur; beat=$waited
    elif (( waited - beat >= 60 )); then
      log "${phase:-working} (${waited}s)"; beat=$waited
    fi
    sleep 15; waited=$(( waited + 15 ))
  done
  log "steam did not finish within $(( timeout / 60 ))m - check ~/steam-prewarm.log on the box"
  return 1
}

# A stopped SPOT instance is not a parked box - it is a dead one that still
# bills. Stopping a spot instance disables its persistent request, and AWS
# refuses to start an instance whose request is not active, so the machine can
# never come back while its root volume keeps charging.
#
# Every cost guard produces exactly this state: the on-host watchdog's
# `shutdown -h`, and the external guards' ec2:stop actions. They cannot terminate instead - a persistent spot
# request relaunches the moment its instance dies, and no guard can cancel the
# request first (the on-host one holds no credentials at all). So stop is the
# right action there, and this is the leak it leaves behind.
#
# Nothing reported it. `cg status` said "instance stopped", which reads as
# normal and recoverable.
stranded_spot_note() {  # stranded_spot_note <region> <instance-id>; prints nothing if fine
  local region=$1 id=$2 out state life srs gb
  [[ -n ${id:-} ]] || return 0
  out=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[State.Name,InstanceLifecycle]' \
    --output text 2>/dev/null) || return 0
  read -r state life <<<"$out"
  [[ $state == stopped && $life == spot ]] || return 0
  srs=$(aws ec2 describe-spot-instance-requests --region "$region" \
    --filters "Name=instance-id,Values=$id" \
    --query 'SpotInstanceRequests[0].State' --output text 2>/dev/null) || srs=unknown
  [[ $srs == active ]] && return 0
  # Charge the real volume size rather than GAME_DISK_GB, which only describes
  # what the next build would ask for.
  gb=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
        --output text 2>/dev/null)
  gb=$(aws ec2 describe-volumes --region "$region" --volume-ids "$gb" \
        --query 'Volumes[0].Size' --output text 2>/dev/null)
  [[ $gb =~ ^[0-9]+$ ]] || gb=0
  awk -v g="$gb" -v s="$srs" 'BEGIN{
    u=g*0.0912;
    printf "  STRANDED       this stopped spot box can never start again (request: %s)\n", s;
    printf "                 its %d GB root volume still bills $%.2f/mo (INR %.0f)\n", g, u, u*88;
    printf "                 reclaim it: cg destroy\n";
  }'
}

# --- notifications ---------------------------------------------------------------
# GAME_NTFY_URL: a topic on ntfy.sh, or a full URL for any ntfy server. Prints the
# URL to post to, or nothing - unset and malformed are both "off".
cg_ntfy_url() {
  local v="${GAME_NTFY_URL:-}"
  [[ -n $v ]] || return 0
  [[ $v == http://* || $v == https://* ]] || v="https://ntfy.sh/$v"
  [[ $v =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_-]{1,64}$ ]] || return 0
  printf '%s' "$v"
}

# Best effort, and never fatal: a notification that cannot be sent is logged and
# the command carries on. The URL is never printed - on ntfy.sh, the topic is all
# it takes to read and post.
cg_notify() { # cg_notify <title> <message> [priority] [tags]
  local url; url=$(cg_ntfy_url)
  [[ -n $url ]] || return 0
  curl -fsS -m 5 -H "Title: ${TS_HOST:-gamevps}: $1" -H "Priority: ${3:-default}" \
       -H "Tags: ${4:-}" -d "$2" "$url" >/dev/null 2>&1 \
    || log "notification not sent (ignored)"
  return 0
}
