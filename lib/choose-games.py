#!/usr/bin/env python3
"""Interactive pick of which archived games to restore.

A FILE, not a heredoc. It used to be `python3 - <<'PY'`, which makes python read
its *program* from stdin - so input() saw the end of the program text and raised
EOFError on the first keystroke. The prompt could never have worked
interactively; it printed the table and gave up. Nothing caught it because the
prompt was written to /dev/tty and therefore untestable, which is the second
half of the same mistake.

argv: <index-json> <available-gb> <default-selection>
stdout: the chosen csv of appids, or "none"
stderr: everything a human reads
"""
import json, os, sys, unicodedata
idx, avail_gb, default = sys.argv[1], float(sys.argv[2]), sys.argv[3]
apps = json.loads(idx).get("apps", [])
GB = 1073741824.0
def gb(a): return a.get("bytes", 0) / GB

# Styled only when a person is reading - and everything a person reads goes to
# STDERR here, so that is the stream tested. stdout carries the chosen appids
# to the caller and must never contain an escape code, styled or not. Same
# rules as _cg_styled in lib/common.sh.
def styled():
    c = os.environ.get("CG_COLOR", "auto")
    if c == "always": return True
    if c == "never" or os.environ.get("NO_COLOR"): return False
    return os.environ.get("TERM", "dumb") != "dumb" and sys.stderr.isatty()
STYLED = styled()
def esc(code): return ("\033[%sm" % code) if STYLED else ""
R, B, D = esc("0"), esc("1"), esc("2")
CYAN, GREEN, YEL, RED, MAG, GREY = esc("38;5;45"), esc("38;5;78"), esc("38;5;220"), esc("38;5;203"), esc("38;5;177"), esc("38;5;245")
PAD = " " * 9

def width(t):
    """Terminal columns: a wide character takes two, a combining mark none."""
    return sum(0 if unicodedata.combining(ch) else (2 if unicodedata.east_asian_width(ch) in "WF" else 1) for ch in t)
def fit(t, n):
    """Truncate to n columns, then pad to exactly n. ljust counts characters and
    misaligns the column the moment a name holds a wide one."""
    out = ""
    for ch in t:
        if width(out + ch) > n: break
        out += ch
    return out + " " * (n - width(out))
def say(sym, col, text):
    """A picker line: symbol and colour when styled; the plain two-space indent otherwise."""
    if STYLED: print("%s%s%s%s %s" % (PAD, col, sym, R, text), file=sys.stderr)
    else:      print("  %s" % text, file=sys.stderr)

def table():
    if STYLED:
        line = "%s│%s" % (MAG, R)
        head = "📦 %sGame archive%s" % (B, R)
        print("\n%s%s╭─ %s %s· %.0f of %.0f GB selectable%s"
              % (PAD, MAG, head, GREY, avail_gb, avail_gb + 20, R), file=sys.stderr)
        print("%s%s  %s%-3s %s %-10s %9s  %s%s" % (PAD, line, B, "#", fit("GAME", 32), "APPID", "SIZE", "ARCHIVED", R), file=sys.stderr)
        for i, a in enumerate(apps, 1):
            print("%s%s  %s%-3d%s %s %s%-10s%s %s%6.1f GB%s  %s%s%s"
                  % (PAD, line, CYAN, i, R, fit(a.get("name", "?"), 32), GREY, a["appid"], R,
                     B, gb(a), R, GREY, a.get("pushed", "?")[:16].replace("T", " "), R), file=sys.stderr)
        print("%s%s  %s20 GB stays free for Proton, shader caches and headroom%s" % (PAD, line, GREY, R), file=sys.stderr)
        print("%s%s╰─%s\n" % (PAD, MAG, R), file=sys.stderr)
        return
    print("\nArchive (%.0f GB selectable of %.0f GB - %.0f GB reserved for Proton, shaders, headroom):\n"
          % (avail_gb, avail_gb + 20, 20), file=sys.stderr)
    print("  %-3s %-10s %-32s %9s  %s" % ("#", "APPID", "GAME", "SIZE", "ARCHIVED"), file=sys.stderr)
    for i, a in enumerate(apps, 1):
        print("  %-3d %-10s %-32s %6.1f GB  %s"
              % (i, a["appid"], a.get("name", "?")[:32], gb(a),
                 a.get("pushed", "?")[:16].replace("T", " ")), file=sys.stderr)
    print(file=sys.stderr)

def resolve(text):
    """numbers or appids -> list of apps; raises ValueError naming what was wrong."""
    out, seen = [], set()
    for tok in (t.strip() for t in text.split(",")):
        if not tok: continue
        a = None
        if tok.isdigit() and 1 <= int(tok) <= len(apps) and len(tok) <= 2:
            a = apps[int(tok) - 1]
        else:
            a = next((x for x in apps if str(x["appid"]) == tok), None)
        if a is None:
            raise ValueError("'%s' is not one of the numbers or appids above" % tok)
        if a["appid"] not in seen:
            seen.add(a["appid"]); out.append(a)
    return out

table()
while True:
    try:
        if STYLED:
            print("%s%s?%s %sRestore which?%s %snumbers or appids, comma separated · all · none%s\n"
                  "%s  %sEnter = %s%s\n%s%s›%s " % (PAD, B + YEL, R, B, R, GREY, R, PAD, GREY, default, R, PAD, CYAN, R),
                  end="", file=sys.stderr, flush=True)
        else:
            print("Restore which? (numbers or appids, comma separated | all | none)\n"
                  "Enter = %s\n> " % default, end="", file=sys.stderr, flush=True)
        raw = input()
    except EOFError:
        # No more input. Re-asking would spin forever whenever the default does
        # not fit - which is the normal state once the archive outgrows the
        # disk. Fail loudly and let the caller decide, rather than looping or
        # guessing which games to restore.
        print(file=sys.stderr)
        say("✗", RED, "no answer (input ended) - not guessing which games to restore")
        sys.exit(2)
    raw = (raw.strip() or default)
    low = raw.lower()
    if low == "none":
        say("✓", GREEN, "restoring nothing - the box will boot with an empty library"); print(file=sys.stderr)
        print("none"); break
    sel = apps if low == "all" else None
    if sel is None:
        try:
            sel = resolve(raw)
        except ValueError as e:
            say("✗", RED, str(e)); print(file=sys.stderr); continue
        if not sel:
            say("!", YEL, "nothing selected - type numbers, 'all', or 'none'"); print(file=sys.stderr); continue
    total = sum(gb(a) for a in sel)
    if total > avail_gb:
        # Refuse and explain, rather than silently picking a subset: which game
        # to drop is not a decision a tool should make for you.
        over = total - avail_gb
        say("✗", RED, "%.0f GB selected, %.0f GB available - over by %.0f GB." % (total, avail_gb, over))
        say(" ", GREY, " + ".join("%s %.0f GB" % (a.get("name", "?")[:20], gb(a)) for a in sel))
        fits = [a for a in apps if gb(a) <= avail_gb]
        if fits:
            say("·", CYAN, "These fit on their own: %s"
                % ", ".join("%s (%.0f GB)" % (a.get("name", "?")[:20], gb(a)) for a in fits))
        print(file=sys.stderr)
        continue
    say("✓", GREEN, "%.0f GB selected, %.0f GB spare. Restoring: %s"
        % (total, avail_gb - total, ", ".join(a.get("name", "?") for a in sel)))
    print(file=sys.stderr)
    print(",".join(str(a["appid"]) for a in sel)); break
