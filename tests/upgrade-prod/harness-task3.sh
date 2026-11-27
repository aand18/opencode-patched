#!/usr/bin/env bash
# Task 3 harness — --check-only: non-destructive preflight.
# RED first: no --check-only exists; it is consumed as a positional and the
# pre-T3 code errors with a usage message.
set -u
REPO=/home/dev/opencode-patched
BIN=/home/dev/.opencode/bin/opencode-v2.2.0-latest-202610290031
MODEL="${GATE_MODEL:-tabbyapi/Qwen3.8-Flash-Next-exl3-3.18bpw_h6_ng8}"
BADMODEL=unbiased-strata/qwen3.8-flash-next-iq3_s
PID0=$(ss -tlnpH | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
FAIL=0
before=$(ls -d /tmp/upgrade-prod.?????? 2>/dev/null | wc -l)

# 1) wrong model must abort at step 1b, fast, with no DB copy
S=$(date +%s)
RC=0; OUT=$(cd "$REPO" && ./scripts/upgrade-prod.sh "$BIN" --model "$BADMODEL" --check-only --dry-run 2>&1) || RC=$?
E=$(( $(date +%s) - S ))
echo "wrong-model rc=$RC elapsed=${E}s"
[[ $RC -ne 0 ]] || { echo "FAIL: wrong model should exit nonzero"; FAIL=1; }
grep -q "does not match calling session model" <<<"$OUT" || { echo "FAIL: no mismatch abort"; FAIL=1; }
(( E < 10 )) || { echo "FAIL: took ${E}s, expected <10s"; FAIL=1; }
grep -q "Dev DB:" <<<"$OUT" && { echo "FAIL: DB copy happened"; FAIL=1; }

# 2) correct model must pass and touch nothing
RC=0; OUT=$(cd "$REPO" && ./scripts/upgrade-prod.sh "$BIN" --model "$MODEL" --check-only --dry-run 2>&1) || RC=$?
echo "correct rc=$RC"
[[ $RC -eq 0 ]] || { echo "FAIL: correct model rc=$RC"; echo "$OUT" | tail -5; FAIL=1; }
grep -q "Caller model check passed" <<<"$OUT" || { echo "FAIL: no caller check"; FAIL=1; }
grep -q "health: ok" <<<"$OUT" || { echo "FAIL: no health probe"; FAIL=1; }
grep -q "model-present: ok" <<<"$OUT" || { echo "FAIL: no model-present probe"; FAIL=1; }
grep -q "VERDICT: ok" <<<"$OUT" || { echo "FAIL: no ok verdict"; FAIL=1; }
ss -tlnpH | grep -q ':4097 ' && { echo "FAIL: dev instance started"; FAIL=1; }
PID1=$(ss -tlnpH | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
[[ "$PID0" == "$PID1" ]] || { echo "FAIL: prod pid changed"; FAIL=1; }
after=$(ls -d /tmp/upgrade-prod.?????? 2>/dev/null | wc -l)
[[ "$before" == "$after" ]] || { echo "FAIL: temp DB dirs created ($before -> $after)"; FAIL=1; }

if [[ $FAIL -eq 0 ]]; then echo "HARNESS PASS"; exit 0; else echo "HARNESS FAIL"; exit 1; fi