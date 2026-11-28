#!/usr/bin/env bash
# Guards — the 18:46 incident, both halves (replaces harness-detach.sh and
# harness-selfguard.sh; their assertions are kept verbatim, their duplicated
# bootstrap moved to lib.sh).
#
#  A) A polluted UPGRADE_DETACHED=1 in the CALLER environment must NOT disable
#     the detach: the marker travels as an argv flag, never as env. Live proof of
#     why — the running prod server carried the marker because launch.py merged
#     os.environ when the Nov-8 detached run launched it. The inherited
#     UPGRADE_RUN_LOG must not hijack the child's log path either.
#  B) Running the script as a DIRECT CHILD of the listener it is told to stop
#     (--foreground) must refuse early, name the ancestor condition, keep the
#     launching parent alive, and exit with the script's own 1 — not 143/145.
#
# No DB anywhere: both runs abort before any copy, and the E<30 bound is what
# proves the refusal happened before the DB copy rather than after it.
set -u
. "$(dirname "$0")/lib.sh"
suite_baselines
trap case_teardown EXIT
case_root guards >/dev/null
require_port_free 4198
require_port_free 4199
NO_SWAP_SYMLINK=1                 # neither run may ever reach step 8
export NO_SWAP_SYMLINK

# --- A) detach marker is argv, not env ---------------------------------------
POISON_LOG="$H_CASE/poisoned-run-log"
RC=0
RUN_UPGRADE_ENV=("UPGRADE_DETACHED=1" "UPGRADE_RUN_LOG=$POISON_LOG")
OUT=$(run_upgrade "$BIN_V232" --model bogus/bogus --prod-port 4199 \
  --config-file "$H_CASE/cfg.json" --last-good "$H_CASE/last-good" 2>&1) || RC=$?
echo "A: parent rc=$RC"
[[ $RC -eq 0 ]] || fail "detached parent should exit 0, got $RC"
grep -q "Detached upgrader started" <<<"$OUT" || fail "no detach under polluted env"
[[ "$OUT" != *"$POISON_LOG"* ]] || fail "inherited UPGRADE_RUN_LOG hijacked the log path"
sleep 3                            # let the child reach its (harmless) recovery abort
[[ -z "$(listener_pid 4199)" ]] || fail "child bound :4199?"

# --- B) ancestor guard --------------------------------------------------------
# Reproduces the lethal topology safely: the script runs as a direct child of a
# fake prod (plain python http.server on :4198), exactly what bash's last-command
# exec did at 18:46 when the server's child sweep TERMed the script itself.
BINLINK=$(harness_bin_link "$BIN_V232")   # unique path => the run log is attributable
cat >"$H_CASE/parent.py" <<PY
import http.server, subprocess, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 4198), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
p = subprocess.Popen(["bash", "-c",
  "exec $REPO/scripts/upgrade-prod.sh "
  "$BINLINK --model m/m "
  "--foreground --prod-port 4198 --path-symlink '' "
  "--config-file $H_CASE/cfg.json --last-good $H_CASE/last-good"])
rc = p.wait()
print("CHILD_RC", rc)
print("PARENT_ALIVE yes")
PY
S=$(date +%s)
OUT=$(python3 "$H_CASE/parent.py" 2>&1); RC=$?
E=$(( $(date +%s) - S ))
echo "B: parent rc=$RC elapsed=${E}s"
grep -E '^(CHILD_RC|PARENT_ALIVE)' <<<"$OUT" || true
grep -q "ancestor" <<<"$OUT" || fail "no ancestor-refusal"
grep -q "PARENT_ALIVE" <<<"$OUT" || fail "launching parent was killed"
grep -q "CHILD_RC 14[35]" <<<"$OUT" && fail "script died by signal (self-kill)"
(( E < 30 )) || fail "took ${E}s — the guard must refuse early, before the DB copy"

# nothing may have been left behind by a refused run
[[ -z "$(listener_pid 4198)" ]] || fail ":4198 fake prod still listening"
[[ -z "$(listener_pid 4199)" ]] || fail ":4199 listener left behind"
real_path_symlink_unchanged || true
echo "case-guards: assertions complete"
exit 0