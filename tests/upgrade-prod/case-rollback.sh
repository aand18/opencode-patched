#!/usr/bin/env bash
# Rollback / restore path — never exercised by the old suite (review §2 gap:
# "the restore site is plausibly correct but never proven"). Gated by
# RUN_SWAP_E2E=1 because it runs a real swap on the throwaway :4120 and gates
# through the dev instance.
#
# How the failure is injected deterministically, without touching the script:
# the "new binary" is a wrapper that satisfies step 0 (--version), behaves as
# the real build when launched as the DEV instance (so the model gate passes),
# and when launched as prod — the only difference being --port 4120 — writes a
# sidecar next to $OPENCODE_DB, sleeps past the 30 s bind window, and exits
# without binding. That leaves the run in phase prod-launched with prod down.
# The harness then replaces the live DB with the poisoned bytes (a write that
# landed AFTER the pre-swap backup) and TERMs the script, which is the same path
# the global-timeout watchdog takes: TERM trap -> rollback().
#
# Proven: the old binary is relaunched and serving on :4120, the DB is restored
# from the pre-swap backup (the poisoned bytes are gone, the pre-swap marker row
# is back), and step 8 never ran. The DB here is a fresh throwaway DB — the
# restore mechanism is content-independent, and real data is the swap-e2e case's
# job — so this case adds ~0 bytes to the run's wear.
set -u
. "$(dirname "$0")/lib.sh"
suite_baselines
trap case_teardown EXIT
case_root rollback >/dev/null
require_port_free 4120
MODEL="${GATE_MODEL:?run.sh/lib.sh must resolve the gate model first}"
DB="$H_CASE/rollback.db"
POISON="$H_CASE/poison-binary.sh"
SWAP_LINK="$H_CASE/path-link"
SIDECAR="$DB.prod-write"
SWAPPED="$H_CASE/db-was-poisoned"
NONCE="restore-$(date +%s)-$$"
REAL_BEFORE=$(readlink "$REAL_PATH_SYMLINK" 2>/dev/null || true)
export TALLY_DB="$DB" TALLY_LABEL=case-rollback
SWAP_SYMLINK="$SWAP_LINK"; export SWAP_SYMLINK; unset NO_SWAP_SYMLINK || true

# --- the injectable "new binary" ---------------------------------------------
cat >"$POISON" <<EOF
#!/usr/bin/env bash
# Rollback probe: real build as the dev instance, dead-on-arrival as prod.
case "\$1" in
  --version) echo "9.9.9-rollback-probe"; exit 0 ;;
esac
port=""; prev=""
for a in "\$@"; do [[ "\$prev" == "--port" ]] && port="\$a"; prev="\$a"; done
if [[ "\$port" == "4097" ]]; then exec "$BIN_MID" "\$@"; fi
printf 'POST-BACKUP-CORRUPTION-$NONCE\n' >>"\${OPENCODE_DB}.prod-write"
sleep 25            # hold past the 30 s bind window only if nobody intervenes
exit 1
EOF
chmod +x "$POISON"

# --- throwaway prod on a fresh db, with a pre-swap marker row ----------------
write_cfg "$H_CASE/cfg.json" "$BIN_OLD" "2.2.0" 4120
echo "$BIN_OLD" >"$H_CASE/last-good"
ln -sfn "$BIN_OLD" "$SWAP_LINK"
start_throwaway "$BIN_OLD" 4120 "$DB" || exit 1
register_db "$DB"                 # the pre-swap backup lands next to it: sweep registers it
rm -f "$SIDECAR" "$SWAPPED"
sqlite3 "$DB" "PRAGMA busy_timeout=8000;
CREATE TABLE IF NOT EXISTS harness_restore_marker(k text primary key, v text);
INSERT OR REPLACE INTO harness_restore_marker(k,v) VALUES('m','$NONCE');" >/dev/null \
  || { fail "could not write the pre-swap marker row into $DB"; exit 1; }

# --- run the swap in the background and signal it after prod is down ---------
run_upgrade_bg "$POISON" --model "$MODEL" --foreground --prompt-timeout 180 \
  --prod-port 4120 --config-file "$H_CASE/cfg.json" --last-good "$H_CASE/last-good"
i=0
until grep -q "DB backup: " "$BG_LOG" 2>/dev/null; do
  i=$((i+1)); (( i > 240 )) && { fail "the run never reached the pre-swap backup (see $BG_LOG)"; tail -8 "$BG_LOG" 2>/dev/null; break; }
  kill -0 "$BG_PID" 2>/dev/null || { fail "the run died before the pre-swap backup"; break; }
  sleep 0.5
done
i=0
until [[ -f "$SIDECAR" ]]; do
  i=$((i+1)); (( i > 120 )) && { fail "the injected prod launch never wrote $SIDECAR — no post-backup write to revert"; break; }
  sleep 0.25
done
if [[ -f "$SIDECAR" ]]; then
  mv -f "$SIDECAR" "$DB"            # a write that landed AFTER the backup is now the live DB
  : >"$SWAPPED"
  kill -TERM "$BG_PID" 2>/dev/null || fail "could not signal the run in phase prod-launched"
  pass "poisoned the live DB after the backup and signalled the script (the watchdog's own path)"
fi
RC=0
wait_upgrade_bg || RC=$?
echo "  rollback run: rc=$RC"
[[ -f "$SWAPPED" ]] || fail "the poisoning window was never reached — the restore assertions below would be vacuous"

# --- the restore path --------------------------------------------------------
grep -qE "SIGNAL received in phase 'prod-(stopped|launched)'" <<<"${LAST_OUT:-}" \
  || fail "no SIGNAL line in phase prod-stopped/prod-launched"
grep -q "ROLLBACK: restoring the previous prod" <<<"${LAST_OUT:-}" || fail "rollback never started"
grep -q "DB restored from " <<<"${LAST_OUT:-}" || fail "no 'DB restored from' line — the DB backup was not applied"
grep -q "rollback complete: $BIN_OLD serving on :4120" <<<"${LAST_OUT:-}" \
  || fail "the old binary did not come back on :4120 (log tail: $(printf '%s' "${LAST_OUT:-}" | tail -3 | tr '\n' ' '))"
[[ $RC -eq 1 ]] || fail "a rolled-back run should exit 1, got $RC"
tail -n 1 <<<"${LAST_OUT:-}" | grep -q "VERDICT: rolled-back" || fail "VERDICT is not 'rolled-back' as the last line"
[[ "$(exe_of 4120)" == "$BIN_OLD" ]] || fail ":4120 is served by '$(exe_of 4120)', expected the old binary $BIN_OLD"
pass "old binary back up on :4120 after the failed launch"

# --- the DB came back from the pre-swap backup -------------------------------
if grep -q "POST-BACKUP-CORRUPTION-$NONCE" "$DB" 2>/dev/null; then
  fail "the live DB still holds the post-backup write — the restore did not revert it"
else
  pass "the post-backup write is gone: the live DB was replaced by the pre-swap backup"
fi
back=$(sqlite3 -readonly "$DB" "select v from harness_restore_marker where k='m';" 2>/dev/null || true)
[[ "$back" == "$NONCE" ]] || fail "the restored DB lost the pre-swap marker row (got '${back:-<none>}')"
ls "$DB".bak.* >/dev/null 2>&1 || fail "no pre-swap backup file to restore from next to $DB"

# --- and nothing else moved --------------------------------------------------
[[ "$(readlink "$SWAP_LINK" 2>/dev/null || true)" == "$BIN_OLD" ]] \
  || fail "a rolled-back run repointed the swap symlink ($(readlink "$SWAP_LINK" 2>/dev/null || echo '<none>'))"
[[ "$(cat "$H_CASE/last-good")" == "$BIN_OLD" ]] || fail "a rolled-back run changed last-good"
[[ "$(readlink "$REAL_PATH_SYMLINK" 2>/dev/null || true)" == "$REAL_BEFORE" ]] \
  || fail "a rolled-back run moved the REAL PATH symlink"
[[ -z "$(listener_pid 4097)" ]] || fail "dev listener left on :4097 after the rollback"
real_path_symlink_unchanged || true
echo "case-rollback: assertions complete"
exit 0