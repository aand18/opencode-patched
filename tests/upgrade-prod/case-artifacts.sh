#!/usr/bin/env bash
# Artifacts — step 1a refreshes the rollback artifacts from the LIVE server
# (replaces harness-task1.sh). RED on purpose: the temp artifacts start out
# describing a binary that is NOT running; after the run they must describe the
# live throwaway on :4120, and the log must show the refresh.
#
# Two fixes carried from review §4.7: the throwaway boots on a FRESH EMPTY DB
# (the old harness .backup'd the 4.88 GB prod DB for an assertion about the
# shape of a json file — the gate prompts the provider, not the DB), and the
# case no longer carries its own model resolver or a pinned fallback model; it
# uses lib.sh's live resolve. --path-symlink "" pins step 8 for good measure.
#
# The old harness started the throwaway with the REAL prod password, so the cfg
# the script refreshed — which stores the captured env and is annotated
# "contains secrets" — leaked it into /tmp (review L3). Throwaways now boot with
# a random harness password and the case asserts that is what landed.
set -u
. "$(dirname "$0")/lib.sh"
suite_baselines
trap case_teardown EXIT
case_root artifacts >/dev/null
require_port_free 4120
NO_SWAP_SYMLINK=1
export NO_SWAP_SYMLINK
MODEL="${GATE_MODEL:?run.sh/lib.sh must resolve the gate model first}"
DB="$H_CASE/artifacts.db"          # fresh: the throwaway creates its own schema
export TALLY_DB="$DB" TALLY_LABEL=case-artifacts
CFG="$H_CASE/cfg.json"
LG="$H_CASE/last-good"
PID0=$(prod_pid)

# stale artifacts claiming a binary that is NOT running
write_cfg "$CFG" "$H_CASE/STALE-NOT-RUNNING" "0.0.0" 4120
echo "$BIN_OLD" >"$LG"

# a session id is present on purpose: step 1b must be skipped because this is
# :4120, not because the caller happens to have no session.
RUN_UPGRADE_ENV=("OPENCODE_SESSION_ID=${HARNESS_SESSION_ID:-none}")
start_throwaway "$BIN_MID" 4120 "$DB" || exit 1

RC=0
run_upgrade "$BIN_OLD" --model "$MODEL" --dry-run --prompt-timeout 180 \
  --prod-port 4120 --config-file "$CFG" --last-good "$LG" >/dev/null || RC=$?
echo "dry-run(throwaway): rc=$RC"
[[ $RC -eq 0 ]] || { fail "dry-run rc=$RC"; printf '%s\n' "${LAST_OUT:-}" | tail -6; }

grep -q "Verifying caller session model" <<<"${LAST_OUT:-}" && fail "step 1b ran for :4120"
grep -q "refreshed from live prod" <<<"${LAST_OUT:-}" || fail "no refresh log line"
grep -q "WARN:" <<<"${LAST_OUT:-}" || fail "no stale-artifact WARN"
python3 -c "import json,sys; d=json.load(open('$CFG')); sys.exit(0 if d['binary']=='$BIN_MID' else 1)" \
  || fail "cfg not refreshed to the live binary (got $(python3 -c "import json;print(json.load(open('$CFG')).get('binary'))" 2>/dev/null))"
grep -qF "$BIN_MID" "$LG" || fail "last-good not refreshed"
[[ "$(cat "$LG")" == "$BIN_MID" ]] || fail "last-good holds '$(cat "$LG")', expected $BIN_MID"
[[ -n "$(listener_pid 4120)" ]] || fail "the dry-run stopped the throwaway"

# the artifact must carry the throwaway's harness secret, never the real one
cap=$(python3 -c "import json;print((json.load(open('$CFG')).get('env') or {}).get('OPENCODE_SERVER_PASSWORD',''))" 2>/dev/null || true)
if [[ -n "$cap" && "$cap" == "$(harness_pw)" ]]; then
  pass "refreshed cfg captured the throwaway's harness secret, not the prod password"
else
  fail "the refreshed artifact did not carry the harness password — a real secret may have been captured"
fi
# no full-size copy anywhere in this case
dbsz=$(stat -c%s "$DB" 2>/dev/null || echo 0)
(( dbsz < 52428800 )) || fail "throwaway DB is $dbsz bytes — expected a fresh empty schema"
grep -q "DB backup:" <<<"${LAST_OUT:-}" && fail "artifact refresh ran a pre-swap DB backup"
[[ "$(prod_pid)" == "$PID0" ]] || fail "prod pid changed ($PID0 -> $(prod_pid))"
real_path_symlink_unchanged || true
echo "case-artifacts: assertions complete"
exit 0