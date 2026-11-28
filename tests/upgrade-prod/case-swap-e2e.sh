#!/usr/bin/env bash
# Swap end-to-end — the destructive rehearsal on a throwaway :4120, gated by
# RUN_SWAP_E2E=1. Merges harness-symlink.sh section A + harness-fix12.sh A/B
# (they tested ~90% the same thing, and one of them forgot --path-symlink and
# downgraded the real ~/.opencode/bin/opencode) and relocates harness-symlink.sh
# section C (real-prod dry-run) here, where the real-data cost belongs.
#
# Sections:
#   0  wal_tail_synthetic — proof that sqlite's online .backup carries an
#      un-checkpointed WAL frame and a plain cp does not (kilobytes).
#   A  step-1a argv[0] canonicalization + latest-link ownership, on a FRESH
#      EMPTY db (read-only run: no copy at all).
#   B  the ONE .backup of the prod DB this suite makes, plus the real-data
#      freshness proof: the newest live row and the row count of `part` must be
#      in the copy — i.e. the backup caught the WAL tail, not just the main file.
#   C  the full swap: VERDICT ok, step 8 repoints ONLY the temp link, the owner
#      moves the latest link, :4120 ends on the new binary, the pre-swap backup
#      exists, and the swapped server still answers on the real-data copy.
#   D  the real-prod dry-run (discovery + env capture against the actual prod
#      process, gate on a copy of real data).
#
# Wear budget: exactly 4 full-size copies (~19.5 GB on the 2026-11-28 DB) — the
# seed plus the three copies the script itself performs in C (dev DB, pre-swap
# backup) and D (dev DB). Everything is under $H_CASE except the seed, and
# teardown deletes the seed with its "$DB".bak.* siblings: the 9.8 GB of orphans
# that stranded yesterday cannot happen from here.
set -u
. "$(dirname "$0")/lib.sh"
suite_baselines
trap case_teardown EXIT
case_root swap-e2e >/dev/null
require_port_free 4120
MODEL="${GATE_MODEL:?run.sh/lib.sh must resolve the gate model first}"
DB="$LEGACY_DB"                   # the real-data seed, at the name review §4.8 asserts is gone
CFG="$H_CASE/cfg.json"
LG="$H_CASE/last-good"
SWAP_LINK="$H_CASE/path-link"
MARK="$H_CASE/operator-marker.log"
export TALLY_DB="$DB" TALLY_LABEL=case-swap-e2e
PID0=$(prod_pid)
[[ -n "$PID0" ]] || { fail "prod :4096 is not listening — the rehearsal reads its freshness baseline from it"; exit 1; }

# --- 0) the backup mechanism itself, on a throwaway db ------------------------
echo "-- 0) wal-tail proof (synthetic) --"
wal_tail_synthetic "$H_CASE" "$(date +%s)-$$" || true

# --- A) argv[0] canonicalization; a read-only run must not move the link ------
echo "-- A) step 1a argv[0] canonicalization (fresh empty db, read-only) --"
rm -f "$H_CASE/argv.db" "$H_CASE/argv.db-wal" "$H_CASE/argv.db-shm"   # fresh: auto-created schema
write_cfg "$CFG" "$BIN_OLD" "2.2.0" 4120            # describes a DIFFERENT binary
echo "$BIN_OLD" >"$LG"
echo marker >"$MARK"
ln -sfn "$MARK" "$LOG_LINK"                          # stand in as the operator's latest link
NO_SWAP_SYMLINK=1; export NO_SWAP_SYMLINK; unset SWAP_SYMLINK || true
start_throwaway "$BIN_MID" 4120 "$H_CASE/argv.db" 1 || exit 1   # PATH shim => argv[0] is "opencode"
WPID=$(listener_pid 4120)
echo "  throwaway argv0=$(tr '\0' '\n' <"/proc/$WPID/cmdline" | head -1) exe=$(exe_of 4120)"
RC=0
run_upgrade "$BIN_OLD" --model "$MODEL" --check-only --dry-run \
  --prod-port 4120 --config-file "$CFG" --last-good "$LG" >/dev/null || RC=$?
echo "  check-only(shim throwaway): rc=$RC"
[[ $RC -eq 0 ]] || { fail "check-only against the shim throwaway rc=$RC"; printf '%s\n' "${LAST_OUT:-}" | tail -6; }
CB=$(python3 -c "import json;print(json.load(open('$CFG'))['binary'])" 2>/dev/null || true)
[[ "$CB" == "$BIN_MID" ]] || fail "argv[0] clobbered the cfg binary: '$CB' (expected the canonical $BIN_MID)"
[[ "$(cat "$LG")" == "$BIN_MID" ]] || fail "last-good clobbered to '$(cat "$LG")' (expected $BIN_MID)"
grep -q "refreshing from /proc/" <<<"${LAST_OUT:-}" || fail "step 1a did not canonicalize from /proc/PID/exe"
[[ "$(readlink "$LOG_LINK")" == "$MARK" ]] || fail "read-only run moved the latest link"
stop_throwaway 4120

# --- B) the ONE prod-DB backup, and its freshness proof -----------------------
echo "-- B) one .backup of the live prod DB + WAL-tail freshness --"
SWAP_SYMLINK="$SWAP_LINK"; export SWAP_SYMLINK; unset NO_SWAP_SYMLINK || true
wal_bytes=$(stat -c%s "$LIVE_DB-wal" 2>/dev/null || echo 0)
register_db "$DB"                 # seed + "$DB".bak.* + -wal/-shm go at teardown (review L2)
max_before=$(sqlite3 -readonly "$LIVE_DB" "select max(rowid) from part;")
cnt_before=$(sqlite3 -readonly "$LIVE_DB" "select count(*) from part;")
backup_real_db "$DB" || exit 1
max_seed=$(sqlite3 -readonly "$DB" "select max(rowid) from part;" 2>/dev/null || echo 0)
cnt_seed=$(sqlite3 -readonly "$DB" "select count(*) from part;" 2>/dev/null || echo 0)
cnt_after=$(sqlite3 -readonly "$LIVE_DB" "select count(*) from part;")
newest_id=$(sqlite3 -readonly "$DB" "select id from part where rowid=$max_before;" 2>/dev/null || true)
echo "  part rows: live-before=$cnt_before seed=$cnt_seed live-after=$cnt_after; newest rowid=$max_before un-checkpointed-wal=${wal_bytes}B"
(( max_seed >= max_before )) || fail "seed is older than the live db at backup time (max rowid $max_seed < $max_before) — the WAL tail was not carried"
[[ -n "$newest_id" ]] || fail "the newest live row (rowid $max_before) is missing from the .backup copy"
(( cnt_seed >= cnt_before )) || fail "seed lost rows: $cnt_seed < $cnt_before (counted before the backup)"
(( cnt_seed <= cnt_after )) || fail "seed has more rows ($cnt_seed) than the live db after the backup ($cnt_after) — the two measurements do not line up"
pass "the copy carries the newest live row ($newest_id) and a row count between the pre/post backup live counts"

# --- C) the full swap: step 8 must only ever move $SWAP_LINK ------------------
echo "-- C) full swap on :4120 (real-data seed, temp --path-symlink) --"
real_before=$(readlink "$REAL_PATH_SYMLINK" 2>/dev/null || true)
write_cfg "$CFG" "$BIN_OLD" "2.2.0" 4120
echo "$BIN_OLD" >"$LG"
ln -sfn "$BIN_OLD" "$SWAP_LINK"
start_throwaway "$BIN_OLD" 4120 "$DB" || exit 1
RC=0
run_upgrade "$BIN_MID" --model "$MODEL" --foreground --prompt-timeout 180 \
  --prod-port 4120 --config-file "$CFG" --last-good "$LG" >/dev/null || RC=$?
echo "  swap: rc=$RC"
[[ $RC -eq 0 ]] || { fail "full swap rc=$RC"; printf '%s\n' "${LAST_OUT:-}" | tail -8; }
grep -q "VERDICT: ok" <<<"${LAST_OUT:-}" || fail "no ok verdict"
[[ "$(readlink "$SWAP_LINK")" == "$BIN_MID" ]] || fail "temp swap symlink not repointed ($(readlink "$SWAP_LINK"))"
grep -q "symlink repointed" <<<"${LAST_OUT:-}" || fail "no repoint log line"
[[ "$(readlink "$REAL_PATH_SYMLINK" 2>/dev/null || true)" == "$real_before" ]] \
  || fail "step 8 moved the REAL PATH symlink during a --prod-port 4120 swap ('$real_before' -> '$(readlink "$REAL_PATH_SYMLINK" 2>/dev/null || true)')"
[[ "$(cat "$LG")" == "$BIN_MID" ]] || fail "last-good not updated by the swap"
NOW=$(exe_of 4120)
[[ "$NOW" == "$BIN_MID" ]] || fail "throwaway not on the new binary (exe=$NOW)"
# the run that owns a swap moves the operator's latest link...
if readlink "$LOG_LINK" | grep -qE '^/tmp/upgrade-prod-[0-9]{8}-[0-9]{6}\.log$'; then
  tail -n 1 "$(readlink "$LOG_LINK")" | grep -q "VERDICT:" || fail "VERDICT not the last line of the run log"
  pass "the swap moved $LOG_LINK to its own run log (restored by teardown)"
else
  fail "owner did not move the latest link ($(readlink "$LOG_LINK" 2>/dev/null || echo '<none>'))"
fi
# ...and left the pre-swap backup in place next to the throwaway db
if ls "$DB".bak.* >/dev/null 2>&1; then
  pass "pre-swap backup present: $(ls "$DB".bak.* | tr '\n' ' ')(removed by teardown)"
else
  fail "no pre-swap backup was written next to $DB"
fi
# post-swap proof on :4120: the swapped server still serves the real-data copy
cnt_post=$(sqlite3 -readonly "$DB" "select count(*) from part;" 2>/dev/null || echo 0)
(( cnt_post >= cnt_seed )) || fail "the swapped server's db lost rows: $cnt_post < $cnt_seed"
if api_get 4120 "$(harness_pw)" "/api/model?directory=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$REPO")" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if (d.get("data") or []) else 1)'; then
  pass "post-swap: the new binary answers on :4120 over the real-data copy ($cnt_post part rows)"
else
  fail "post-swap: /api/model on :4120 did not return a model list"
fi
stop_throwaway 4120

# --- D) dry-run against live prod (relocated from harness-symlink.sh C) -------
# Real prod discovery + env capture + the gate on a copy of real data. Read-only
# with respect to prod: the script stops nothing and exits before step 5.
echo "-- D) real-prod dry-run (read-only against :4096) --"
NO_SWAP_SYMLINK=1; export NO_SWAP_SYMLINK; unset SWAP_SYMLINK || true
TALLY_DB="$LIVE_DB"; TALLY_LABEL=real-prod-dryrun; export TALLY_DB TALLY_LABEL
RC=0
run_upgrade "$BIN_MID" --model "$MODEL" --prompt-timeout 180 --dry-run >/dev/null || RC=$?
echo "  dry-run(live prod): rc=$RC"
[[ $RC -eq 0 ]] || { fail "real-prod dry-run rc=$RC"; printf '%s\n' "${LAST_OUT:-}" | tail -8; }
grep -q "VERDICT: ok" <<<"${LAST_OUT:-}" || fail "real-prod dry-run produced no ok verdict"
[[ "$(prod_pid)" == "$PID0" ]] || fail "the prod dry-run changed the prod pid ($PID0 -> $(prod_pid))"
[[ -z "$(listener_pid 4097)" ]] || fail "dev listener left on :4097 after the prod dry-run"

# --- section guards ----------------------------------------------------------
real_path_symlink_unchanged || true
echo "case-swap-e2e: assertions complete"
exit 0