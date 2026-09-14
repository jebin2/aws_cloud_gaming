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
import json, sys
idx, avail_gb, default = sys.argv[1], float(sys.argv[2]), sys.argv[3]
apps = json.loads(idx).get("apps", [])
GB = 1073741824.0
def gb(a): return a.get("bytes", 0) / GB

def table():
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
        print("Restore which? (numbers or appids, comma separated | all | none)\n"
              "Enter = %s\n> " % default, end="", file=sys.stderr, flush=True)
        raw = input()
    except EOFError:
        # No more input. Re-asking would spin forever whenever the default does
        # not fit - which is the normal state once the archive outgrows the
        # disk. Fail loudly and let the caller decide, rather than looping or
        # guessing which games to restore.
        print("\n  no answer (input ended) - not guessing which games to restore",
              file=sys.stderr)
        sys.exit(2)
    raw = (raw.strip() or default)
    low = raw.lower()
    if low == "none":
        print("  restoring nothing - the box will boot with an empty library\n", file=sys.stderr)
        print("none"); break
    sel = apps if low == "all" else None
    if sel is None:
        try:
            sel = resolve(raw)
        except ValueError as e:
            print("  %s\n" % e, file=sys.stderr); continue
        if not sel:
            print("  nothing selected - type numbers, 'all', or 'none'\n", file=sys.stderr); continue
    total = sum(gb(a) for a in sel)
    if total > avail_gb:
        # Refuse and explain, rather than silently picking a subset: which game
        # to drop is not a decision a tool should make for you.
        over = total - avail_gb
        print("  %.0f GB selected, %.0f GB available - over by %.0f GB." % (total, avail_gb, over), file=sys.stderr)
        print("  " + " + ".join("%s %.0f GB" % (a.get("name", "?")[:20], gb(a)) for a in sel), file=sys.stderr)
        fits = [a for a in apps if gb(a) <= avail_gb]
        if fits:
            print("  These fit on their own: %s"
                  % ", ".join("%s (%.0f GB)" % (a.get("name", "?")[:20], gb(a)) for a in fits), file=sys.stderr)
        print(file=sys.stderr)
        continue
    print("  %.0f GB selected, %.0f GB spare. Restoring: %s\n"
          % (total, avail_gb - total, ", ".join(a.get("name", "?") for a in sel)), file=sys.stderr)
    print(",".join(str(a["appid"]) for a in sel)); break
