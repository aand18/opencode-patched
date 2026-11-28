#!/usr/bin/env bash
# Preflight — --check-only against live prod :4096, read-only (replaces
# harness-task3.sh; harness-symlink.sh section B folds in here). No DB anywhere:
# step 1c is the line the script must stop on, and this case is what proves it.
#
# The wrong-model test is what the old suite could only run when
# OPENCODE_SESSION_ID happened to be set: step 1b fires only for :4096 *with* a
# session id. lib.sh always resolves HARNESS_SESSION_ID (this session's, or the
# newest live one), so the guard is exercised in-session AND standalone, and no
# remembered model is involved either way.
set -u
. "$(dirname "$0")/lib.sh"
suite_baselines
trap case_teardown EXIT
case_root preflight >/dev/null
NO_SWAP_SYMLINK=1                 # preflight must never reach step 8
export NO_SWAP_SYMLINK
require_port_free 4097
MODEL="${GATE_MODEL:?run.sh/lib.sh must resolve the gate model first}"
[[ -n "${HARNESS_SESSION_ID:-}" ]] || { fail "no live session id — the step-1b guard cannot be exercised"; exit 1; }
# A model that cannot exist on this server: synthetic, not a remembered build.
BADMODEL=harness-absent-provider/harness-absent-model
RUN_UPGRADE_ENV=("OPENCODE_SESSION_ID=$HARNESS_SESSION_ID")   # read by run_upgrade's env prefix
PID0=$(prod_pid)
[[ -n "$PID0" ]] || { fail "prod :4096 is not listening — preflight has nothing to probe"; exit 1; }

# --- 1) wrong model: abort at step 1b, fast, before any DB copy --------------
RC=0; S=$(date +%s)
run_upgrade "$BIN_OLD" --model "$BADMODEL" --check-only --dry-run >/dev/null || RC=$?
E=$(( $(date +%s) - S ))
echo "wrong-model: rc=$RC elapsed=${E}s"
[[ $RC -ne 0 ]] || fail "wrong model should exit nonzero"
grep -q "does not match calling session model" <<<"${LAST_OUT:-}" || fail "no mismatch abort (step 1b did not fire for session $HARNESS_SESSION_ID)"
(( E < 10 )) || fail "took ${E}s, expected <10s (the abort must precede any DB work)"
grep -q "Dev DB:" <<<"${LAST_OUT:-}" && fail "DB copy happened on the wrong-model path"

# --- 2) correct model: pass, and touch nothing --------------------------------
RC=0
run_upgrade "$BIN_OLD" --model "$MODEL" --check-only --dry-run >/dev/null || RC=$?
echo "correct-model: rc=$RC"
[[ $RC -eq 0 ]] || { fail "correct model rc=$RC"; printf '%s\n' "${LAST_OUT:-}" | tail -5; }
grep -q "Caller model check passed" <<<"${LAST_OUT:-}" || fail "no caller check line"
grep -q "health: ok" <<<"${LAST_OUT:-}" || fail "no health probe"
grep -q "model-present: ok" <<<"${LAST_OUT:-}" || fail "no model-present probe"
grep -q "VERDICT: ok" <<<"${LAST_OUT:-}" || fail "no ok verdict"
[[ -z "$(listener_pid 4097)" ]] || fail "dev instance started on :4097"
[[ "$(prod_pid)" == "$PID0" ]] || fail "prod pid changed ($PID0 -> $(prod_pid))"
# This grep replaces the old before/after temp-dir-count assertion, which was
# vacuous: the script mktemp -d's /tmp/upgrade-prod.XXXXXX on EVERY run and its
# EXIT trap removes it, so the count matches even if a full DB copy happened
# (review §6.3). Absence of the copy lines is the real check.
grep -qE "Dev DB:|DB backup:" <<<"${LAST_OUT:-}" && fail "check-only touched the DB (copy line in output)"
pass "check-only performed no DB copy (no 'Dev DB:'/'DB backup:' line in the run output)"

# --- 3) plain --check-only against live prod, real artifact paths -------------
# (harness-symlink.sh section B): discovery + env capture + step 1a refresh
# against the actual prod process, still read-only, with the real config paths
# so the real refresh path stays covered.
RC=0
run_upgrade "$BIN_MID" --model "$MODEL" --check-only >/dev/null || RC=$?
echo "check-only(real prod): rc=$RC"
[[ $RC -eq 0 ]] || { fail "check-only against live prod broke (rc=$RC)"; printf '%s\n' "${LAST_OUT:-}" | tail -5; }
grep -qE "Dev DB:|DB backup:" <<<"${LAST_OUT:-}" && fail "check-only(real prod) touched the DB"
[[ "$(prod_pid)" == "$PID0" ]] || fail "prod pid changed ($PID0 -> $(prod_pid))"
real_path_symlink_unchanged || true
echo "case-preflight: assertions complete"
exit 0