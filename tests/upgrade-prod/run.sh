#!/usr/bin/env bash
# Test suite for scripts/upgrade-prod.sh (the prod binary hot-swap). Run from the
# repo root:  bash tests/upgrade-prod/run.sh
#
# What runs by default — four behavior cases, all against throwaway state:
#   case-guards      the ancestor-refusal and detach-marker incidents (:4198/:4199)
#   case-preflight   --check-only against live prod :4096 (read-only)
#   case-mechanics   per-run log, dated timestamps, VERDICT sentinel (:4120)
#   case-artifacts   step-1a artifact refresh from a live server (:4120)
# The default run performs ZERO full-size DB copies: every throwaway boots on a
# fresh empty DB (a fresh OPENCODE_DB path auto-creates its own ~4 KB schema),
# and the only real-data work is behind the RUN_SWAP_E2E gate.
#
#   RUN_SWAP_E2E=1 bash tests/upgrade-prod/run.sh
# adds the expensive group: the end-to-end swap rehearsal on a copy of the real
# DB (step 8 symlink ownership, argv[0] canonicalization, the WAL-tail proof and
# the real-prod dry-run) and the rollback/restore-path case. Cost, measured
# 2026-11-28: ~19.5 GB written — exactly ONE .backup of the prod DB (4.88 GB)
# plus the three copies the script itself performs while swapping and probing
# (dev DB, pre-swap backup, the prod dry-run's dev DB). Do not run it in a loop.
#
# Two invariants the suite proves about itself on every run (they were the
# 2026-11-27 incidents): the real ~/.opencode/bin/opencode symlink and the
# operator's /tmp/upgrade-prod.log follow-me link are byte-identical before and
# after, and no harness file — DB, .bak.* orphan, or artifact cfg — is stranded
# in /tmp.
#
# Session-bound: the gate model is resolved live from prod :4096 (this session's
# id, else the newest live session). No fallback model is pinned — AGENTS.md
# forbids reusing a remembered model, so a run with no resolvable model refuses
# up front instead of guessing. The gate PONGs through the same tabbyAPI server
# that serves the agent running the suite, so every gate-running call passes
# --prompt-timeout 180 (the 60 s default starves behind a long generation).
#
# The staged binaries the cases rehearse with live in ~/.opencode/bin
# (BIN_OLD / BIN_MID / BIN_V232 in lib.sh); if one is pruned, restore it or
# export the override before running.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tests/upgrade-prod/lib.sh
suite_baselines
trap 'suite_teardown || true' EXIT

echo "== step 0: shell syntax (bash -n) =="
for f in scripts/*.sh tests/upgrade-prod/*.sh; do
  bash -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error scripts/upgrade-prod.sh tests/upgrade-prod/*.sh
else
  echo "note: shellcheck not installed - bash -n only"
fi

echo "== step 1: ports and fixtures =="
require_bins
# The script hardcodes its dev port 4097: a real swap in flight owns it, and two
# suite runs cannot overlap. Refuse here, not mid-run (review §6.8).
require_port_free 4097
require_port_free 4120
require_port_free 4198
require_port_free 4199
echo "  ok: :4097 :4120 :4198 :4199 free; staged binaries present"

echo "== step 2: gate model (live resolve, no pinned fallback) =="
resolve_gate_model

echo "== step 3: default cases — no full-size DB copy =="
for c in case-guards.sh case-preflight.sh case-mechanics.sh case-artifacts.sh; do
  echo "-- $c --"
  "tests/upgrade-prod/$c"
done

if [[ "${RUN_SWAP_E2E:-0}" == "1" ]]; then
  echo "== step 4: RUN_SWAP_E2E — real-data swap rehearsal + rollback path =="
  # Load caveat, still true: each section boots servers and gates through the
  # co-resident tabbyAPI server; the script's internal 90 s readiness budget
  # (READY_TIMEOUT, not a flag) can be starved by a long generation elsewhere on
  # that box. If only this step fails with "server not ready within 90.0s",
  # re-run it alone in a quieter window before reading anything into it.
  for c in case-swap-e2e.sh case-rollback.sh; do
    echo "-- $c --"
    "tests/upgrade-prod/$c"
  done
else
  echo "skipped the swap rehearsal — set RUN_SWAP_E2E=1 to run the full :4120 swap,"
  echo "the real-data WAL-tail proof and the rollback/restore case (~19.5 GB written)"
fi

echo "== step 5: self-proof (real state untouched, no residue) =="
# || true so every check runs and the summary below sees all of them (a failing
# assertion must not abort the run before FAILURES is printed).
real_path_symlink_unchanged || true
restore_operator_log || true
link_want=$(cat "$STATE/loglink.before" 2>/dev/null || true)
link_now=$(readlink "$LOG_LINK" 2>/dev/null || true)
if [[ "$link_now" != "$link_want" ]]; then
  fail "operator follow-me link moved: '${link_want:-<none>}' -> '${link_now:-<none>}'"
else
  pass "operator $LOG_LINK unchanged: ${link_now:-<none>}"
fi
assert_no_strays || true

read -r bytes count <<<"$(copies_total)"
full=$(copies_fullsize)
echo "== DB copy tally: $count copy operation(s), ${bytes:-0} bytes written, $full full-size (>=1 GB) =="
if [[ -s "$STATE/copies.tsv" ]]; then
  awk -F'\t' '{printf "  %10d MB  %-16s  %s\n", $1/1048576, $2, $3}' "$STATE/copies.tsv"
fi
if [[ "${RUN_SWAP_E2E:-0}" != "1" ]]; then
  # The default run boots every throwaway on a fresh empty DB, so it may copy
  # kilobytes of throwaway schema (the script's dev-instance copy) but never the
  # prod DB. Both halves of that claim are checked: the byte tally above, and an
  # independent scan for any >1 GB file appearing in /tmp.
  (( full == 0 )) || fail "default run performed $full full-size DB copy(ies); expected 0 (fresh empty DBs only)"
  (( count == 0 )) && pass "0 DB copy operations at all" || pass "0 full-size DB copies ($count small copy operation(s), ${bytes:-0} bytes total)"
  for f in /tmp/*; do
    [[ -f "$f" ]] || continue
    grep -qxF "$f" "$STATE/bigfiles.before" 2>/dev/null && continue
    (( $(stat -c%s "$f" 2>/dev/null || echo 0) > 1073741824 )) && fail "default run left a >1 GB file in /tmp: $f"
  done
  pass "no >1 GB file appeared in /tmp during the default run"
fi

if [[ -s "$STATE/failures" ]]; then
  echo "FAILURES:"
  sed 's/^/  - /' "$STATE/failures"
  echo "== RESULT: FAILED =="
  exit 1
fi
echo "ALL GREEN"
suite_teardown          # removes $SUITE_ROOT; the EXIT trap above is only for aborts
echo "(suite scratch root $SUITE_ROOT removed; the operator's $LOG_LINK and pre-existing run logs were left as found)"