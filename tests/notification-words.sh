#!/usr/bin/env bash
# The phone messages are for a person, not for a log: no instance ids, setting
# names, AWS service names or commands in what ntfy shows. The log lines beside
# each call keep all of that.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
BAD='S3|EC2|GAME_[A-Z_]+|instance|mirror|\bcg (init|destroy|check|open)|\bi-[0-9a-f]|OS shutdown|compute'

echo "1. lambda/cloud_watchdog.py: every notify() title and text"
out=$(python3 -I - "$BAD" <<'PY'
import ast, re, sys
bad = re.compile(sys.argv[1])
tree = ast.parse(open("lambda/cloud_watchdog.py").read())
n = 0
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "notify":
        n += 1
        text = " ".join(c.value for a in node.args[:2] for c in ast.walk(a)
                        if isinstance(c, ast.Constant) and isinstance(c.value, str))
        if bad.search(text):
            print("  FAIL line %d: %s" % (node.lineno, text[:100])); sys.exit(1)
print("  ok   %d messages" % n)
PY
) || fail=1
echo "$out"

echo "2. host scripts: every notify call"
for f in host/idle-watchdog.sh host/cg-shutdown-push.sh; do
  if grep -E '^\s*(\[\[.*\|\| )?notify ' -A1 "$f" | grep -E "$BAD"; then
    echo "  FAIL $f"; fail=1
  else echo "  ok   $f"; fi
done
# The game-ready notice calls the notifier directly, not through notify().
if grep -E '"\$NOTIFY" ' host/game-notify.sh | grep -E "$BAD"; then
  echo "  FAIL host/game-notify.sh"; fail=1
else echo "  ok   host/game-notify.sh"; fi
exit $fail
