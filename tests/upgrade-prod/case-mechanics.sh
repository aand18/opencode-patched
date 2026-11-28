#!/usr/bin/env bash
# Mechanics — per-run log, dated timestamps, VERDICT sentinel (replaces
# harness-task2.sh). The old version ran a --dry-run against live prod :4096 and
# therefore paid a 4.88 GB DEV_DB copy for a pure logging assertion (review §2).
# It now dry-runs a throwaway on :4120 booted on a fresh empty DB; the script
# still logs "Dev DB:", and the case asserts it points at the throwaway's copy.
#
# Two old-harness behaviors are deliberately gone:
#   - `rm -f /tmp/upgrade-prod.log` — that is the operator's follow-me link; a
#     dry-run never moves it (the script only links it for full runs), and this
#     case asserts it is exactly as found.
#   - `rm -f /tmp/upgrade-prod-*.log` — a glob that could destroy the audit log
#     of a concurrent real upgrade. lib.sh reaps only logs this suite provably
#     created (ownership marker inside the file).
set -u
. "$(dirname "$0")/lib.sh"
suite_baselines
trap case_teardown EXIT
case_root mechanics >/dev/null
require_port_free 4120
NO_SWAP_SYMLINK=1
export NO_SWAP_SYMLINK
MODEL="${GATE_MODEL:?run.sh/lib.sh must resolve the gate model first}"
DB="$H_CASE/mechanics.db"          # fresh path: the throwaway auto-creates ~4 KB
export TALLY_DB="$DB" TALLY_LABEL=case-mechanics
PID0=$(prod_pid)
LINK_WANT=$(readlink "$LOG_LINK" 2>/dev/null || true)

start_throwaway "$BIN_MID" 4120 "$DB" || exit 1
write_cfg "$H_CASE/cfg.json" "$BIN_MID" 2.2.6 4120
echo "$BIN_MID" >"$H_CASE/last-good"

RC=0
run_upgrade "$BIN_OLD" --model "$MODEL" --prompt-timeout 180 --dry-run \
  --prod-port 4120 --config-file "$H_CASE/cfg.json" --last-good "$H_CASE/last-good" >/dev/null || RC=$?
echo "dry-run(throwaway): rc=$RC"
[[ $RC -eq 0 ]] || { fail "dry-run rc=$RC"; printf '%s\n' "${LAST_OUT:-}" | tail -6; }

# 1) the run created its own per-run log (latest-link ownership is swap-e2e's job)
LOGP=$(last_run_log)
[[ -n "$LOGP" ]] || fail "no per-run log was created by this run"
[[ -n "$LOGP" && "$(basename "$LOGP")" =~ ^upgrade-prod-[0-9]{8}-[0-9]{6}\.log$ ]] \
  || fail "per-run log has an unexpected name: ${LOGP:-<none>}"
echo "  per-run log: ${LOGP:-<none>}"
# 2) dated timestamps
grep -qE '^\[[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$LOGP" 2>/dev/null \
  || fail "no dated timestamps in $LOGP"
# 3) verdict sentinel, final line of the run log
grep -q 'VERDICT: ' "$LOGP" 2>/dev/null || fail "no VERDICT line in $LOGP"
tail -n 1 "$LOGP" 2>/dev/null | grep -q 'VERDICT:' || fail "VERDICT is not the last line of $LOGP"
# 4) the dev DB is a copy of the THROWAWAY db, not of prod
devline=$(grep -oP 'Dev DB: \K\S+' <<<"${LAST_OUT:-}" | head -1)
[[ -n "$devline" ]] || fail "no 'Dev DB:' line — the dev instance never started"
[[ "$devline" == /tmp/upgrade-prod.??????/* ]] || fail "'Dev DB:' points outside the script's tmp dir: $devline"
dbsz=$(stat -c%s "$DB" 2>/dev/null || echo 0)
(( dbsz < 52428800 )) || fail "throwaway DB is $dbsz bytes — this case must boot a fresh empty DB, not a copy"
pass "Dev DB: $devline copied from a ${dbsz}-byte throwaway DB (no full-size copy)"
# 5) prod untouched, dev port clean, throwaway survived the dry-run
PID1=$(prod_pid)
[[ "$PID0" == "$PID1" ]] || fail "prod pid changed $PID0 -> $PID1"
[[ -z "$(listener_pid 4097)" ]] || fail "dev listener left on :4097"
[[ -n "$(listener_pid 4120)" ]] || fail "the dry-run stopped the throwaway"
# 6) the operator's follow-me link is untouched by a read-only run
[[ "$(readlink "$LOG_LINK" 2>/dev/null || true)" == "$LINK_WANT" ]] \
  || fail "dry-run moved the operator's $LOG_LINK ('$LINK_WANT' -> '$(readlink "$LOG_LINK" 2>/dev/null || true)')"
real_path_symlink_unchanged || true
echo "case-mechanics: assertions complete"
exit 0