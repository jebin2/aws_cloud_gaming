#!/usr/bin/env bash
# Ctrl+C. A cancelled `cg check --fix` once closed its step with "done in 8s": the
# EXIT trap saw the status of the last command, not the interrupt. And sudo or
# pacman catching the signal let --fix carry on to the next install.
#
# A real Ctrl+C signals the whole foreground process group, so each case starts
# in its own group, with SIGINT at its default, and the group gets the signal.
set -uo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import os, re, signal, subprocess, sys, time

passed = failed = 0
def check(name, ok, detail=""):
    global passed, failed
    if ok: print("  ok   " + name); passed += 1
    else:  print("  FAIL %s: %s" % (name, detail)); failed += 1

PRELUDE = 'source lib/common.sh; source lib/laptop.sh; say "preflight"; log "working"; '
def interrupt(body, color="always", stdin=b"", after=1.5):
    p = subprocess.Popen(["bash", "-c", PRELUDE + body], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         env=dict(os.environ, CG_COLOR=color), start_new_session=True,
                         preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    if stdin: p.stdin.write(stdin); p.stdin.flush()
    time.sleep(after)
    os.killpg(p.pid, signal.SIGINT)
    out, _ = p.communicate(timeout=20)
    return p.returncode, re.sub(r"\x1b\[[0-9;]*m", "", out.decode())

print("1. a command that dies of the signal")
rc, out = interrupt('sleep 8; log "after"')
check("the step says stopped", "stopped after" in out, out[-200:])
check("  never done", "done in" not in out, out[-200:])
check("  exit 130", rc == 130, rc)
check("  nothing after it runs", "after" not in out.replace("stopped after", ""), out[-200:])

print("2. a child that catches it and exits 1, like sudo or pacman")
rc, out = interrupt('bash -c "trap \\"exit 1\\" INT; sleep 8" || log "could not install"; log "carried on"')
check("the script stops too", "carried on" not in out, out[-200:])
check("  and says stopped", "stopped after" in out, out[-200:])
check("  exit 130", rc == 130, rc)

print("3. at a prompt")
rc, out = interrupt('read -rp "go ahead? [Y/n] " a || [[ -n ${a:-} ]] || a=n; log "answer=$a"')
check("no answer is taken", "answer=" not in out, out[-200:])
check("  stopped, not done", "stopped after" in out and "done in" not in out, out[-200:])

print("4. plain output: still stops, with 130")
rc, out = interrupt('bash -c "trap \\"exit 1\\" INT; sleep 8" || echo "could not install"; echo "carried on"', color="never")
check("stops", "carried on" not in out, out[-200:])
check("  exit 130", rc == 130, rc)

print("5. cg check --fix, cancelled during the first install")
rc, out = interrupt('laptop_tty() { true; }; laptop_pm() { echo pacman; }; laptop_missing() { printf "aws\\ntailscale\\n"; }; '
                    'laptop_tailscale_down() { false; }; '
                    'laptop_install() { log "start $2"; bash -c "trap \\"exit 1\\" INT; sleep 8"; }; '
                    'laptop_fix || true; log "went on to the report"', stdin=b"y\n")
check("the first install started", "start aws" in out, out[-300:])
check("  the second never did", "start tailscale" not in out, out[-300:])
check("  nor anything after --fix", "went on" not in out, out[-300:])
check("  and it says stopped", "stopped after" in out and "done in" not in out, out[-300:])

print("6. without Ctrl+C, a finished step still says done")
p = subprocess.run(["bash", "-c", PRELUDE + 'log "finished"'], capture_output=True,
                   env=dict(os.environ, CG_COLOR="always"))
out = re.sub(r"\x1b\[[0-9;]*m", "", p.stdout.decode() + p.stderr.decode())
check("done", "done in" in out and "stopped" not in out, out[-200:])
check("  exit 0", p.returncode == 0, p.returncode)

print("\npassed %d, failed %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
