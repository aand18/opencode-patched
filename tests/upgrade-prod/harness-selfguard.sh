#!/usr/bin/env bash
# Ancestor-guard harness — the 18:46 incident, part 2.
# Reproduces the lethal topology safely: the script runs as a DIRECT CHILD of
# the listener it is told to stop (--foreground), exactly what bash's
# last-command exec did at 18:46 when the server's child sweep TERMed the
# script itself. Fake prod = plain python http.server on :4198.
# RED now: no refusal; the run proceeds (slow DB/gate path) instead of aborting.
# GREEN after: fast refusal naming the ancestor condition; the launching parent
# stays alive; child exit code is the script's own 1, not 143 (SIGTERM).
set -u
REPO=/home/dev/opencode-patched
BIN=/home/dev/.opencode/bin/opencode-v2.3.2-latest-202611191829
cat >/tmp/upgs-parent.py <<'PY'
import http.server, subprocess, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 4198), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
p = subprocess.Popen(["bash", "-c",
  "exec /home/dev/opencode-patched/scripts/upgrade-prod.sh "
  "/home/dev/.opencode/bin/opencode-v2.3.2-latest-202611191829 --model m/m "
  "--foreground --prod-port 4198 "
  "--config-file /tmp/upgs-cfg.json --last-good /tmp/upgs-lg"])
rc = p.wait()
print("CHILD_RC", rc)
print("PARENT_ALIVE yes")
PY
S=$(date +%s)
OUT=$(python3 /tmp/upgs-parent.py 2>&1); RC=$?
E=$(( $(date +%s) - S ))
echo "parent rc=$RC elapsed=${E}s"
echo "$OUT" | grep -E '^(CHILD_RC|PARENT_ALIVE)'
FAIL=0
grep -q "ancestor" <<<"$OUT" || { echo "FAIL: no ancestor-refusal"; FAIL=1; }
grep -q "PARENT_ALIVE" <<<"$OUT" || { echo "FAIL: launching parent was killed"; FAIL=1; }
grep -q "CHILD_RC 14[35]" <<<"$OUT" && { echo "FAIL: script died by signal (self-kill)"; FAIL=1; }
(( E < 30 )) || { echo "FAIL: took ${E}s — guard must refuse early, before the DB copy"; FAIL=1; }
rm -f /tmp/upgs-parent.py /tmp/upgs-cfg.json /tmp/upgs-lg
rm -rf /tmp/upgrade-prod.??????
[[ $FAIL -eq 0 ]] && { echo "HARNESS PASS"; exit 0; } || { echo "HARNESS FAIL"; exit 1; }